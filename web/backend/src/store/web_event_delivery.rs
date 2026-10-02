//! Independent outbox for safe Web-originated inbox events.
//!
//! The queue deliberately stores no notification title, summary, target,
//! username, source address, token identifier, or other event details. It
//! keeps only an opaque inbox row id, an opaque delivery id, a
//! fixed allowlisted event type, and timestamps.

use rusqlite::{params, Connection};

const PENDING_BATCH_SIZE: i64 = 32;
const RETAIN_TERMINAL_RECORDS: i64 = 2_000;

#[derive(Clone, Debug)]
pub struct Record {
    /// Opaque inbox row id; never included in outbound messages.
    pub notification_id: String,
    /// Random opaque id used for WeCom delivery history.
    pub delivery_id: String,
    pub event_type: String,
    pub created_at: i64,
    pub status: String,
}

/// Create independent durable bookkeeping during normal Web schema setup.
pub fn ensure_schema(conn: &Connection) -> Result<(), rusqlite::Error> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS web_event_delivery_queue (
             notification_id TEXT PRIMARY KEY,
             delivery_id TEXT NOT NULL UNIQUE,
             event_type TEXT NOT NULL CHECK (event_type IN (
                 'security.login_failed', 'security.token_revoked', 'snapshot.freshness_changed'
             )),
             created_at INTEGER NOT NULL,
             status TEXT NOT NULL CHECK (status IN (
                 'pending', 'sent', 'failed', 'disabled', 'not_selected', 'dry_run', 'throttled'
             )),
             processed_at INTEGER NOT NULL
         );
         CREATE INDEX IF NOT EXISTS idx_web_event_delivery_pending
             ON web_event_delivery_queue(status, created_at, delivery_id);
         CREATE TABLE IF NOT EXISTS web_event_delivery_throttle (
             event_type TEXT PRIMARY KEY CHECK (event_type IN (
                 'security.login_failed', 'security.token_revoked', 'snapshot.freshness_changed'
             )),
             reserved_at INTEGER NOT NULL
         );",
    )
}

/// Add one newly created inbox event to this independent queue in the same
/// transaction as its inbox insert. The queue key is the inbox row UUID, not
/// its event_id (which may contain a token identifier).
pub fn enqueue_notification(
    conn: &Connection,
    source_type: &str,
    notification_id: &str,
    created_at: i64,
) -> Result<(), rusqlite::Error> {
    let Some(event_type) = native_event_type(source_type) else {
        return Ok(());
    };
    conn.execute(
        "INSERT INTO web_event_delivery_queue
           (notification_id, delivery_id, event_type, created_at, status, processed_at)
         VALUES (?1, ?2, ?3, ?4, 'pending', 0)
         ON CONFLICT(notification_id) DO NOTHING",
        params![
            notification_id,
            uuid::Uuid::new_v4().to_string(),
            event_type,
            created_at
        ],
    )?;
    conn.execute(
        "DELETE FROM web_event_delivery_queue WHERE notification_id IN (
           SELECT notification_id FROM web_event_delivery_queue
           WHERE status != 'pending'
           ORDER BY processed_at DESC, delivery_id DESC
           LIMIT -1 OFFSET ?1
         )",
        [RETAIN_TERMINAL_RECORDS],
    )?;
    Ok(())
}

pub fn pending_records(conn: &Connection) -> Result<Vec<Record>, rusqlite::Error> {
    let mut statement = conn.prepare(
        "SELECT notification_id, delivery_id, event_type, created_at, status
         FROM web_event_delivery_queue WHERE status = 'pending'
         ORDER BY created_at, delivery_id LIMIT ?1",
    )?;
    let rows = statement.query_map([PENDING_BATCH_SIZE], |row| {
        Ok(Record {
            notification_id: row.get(0)?,
            delivery_id: row.get(1)?,
            event_type: row.get(2)?,
            created_at: row.get(3)?,
            status: row.get(4)?,
        })
    })?;
    rows.collect()
}

pub fn set_status(
    conn: &Connection,
    notification_id: &str,
    status: &str,
) -> Result<(), rusqlite::Error> {
    conn.execute(
        "UPDATE web_event_delivery_queue SET status = ?1, processed_at = ?2
         WHERE notification_id = ?3",
        params![status, now_unix(), notification_id],
    )?;
    Ok(())
}

/// Suppress bursts globally by fixed event type. This key contains no target
/// account or caller data and the five-minute reservation survives restarts.
pub fn reserve_wecom_slot(
    conn: &Connection,
    event_type: &str,
    now: i64,
) -> Result<bool, rusqlite::Error> {
    let changed = conn.execute(
        "INSERT INTO web_event_delivery_throttle(event_type, reserved_at)
         VALUES (?1, ?2)
         ON CONFLICT(event_type) DO UPDATE SET reserved_at = excluded.reserved_at
         WHERE web_event_delivery_throttle.reserved_at <= excluded.reserved_at - 300",
        params![event_type, now],
    )?;
    Ok(changed == 1)
}

pub fn native_event_type(source_type: &str) -> Option<&'static str> {
    match source_type {
        "security.login_failed" => Some("security.login_failed"),
        "security.token_revoked" => Some("security.token_revoked"),
        "snapshot.stale" | "snapshot.recovered" => Some("snapshot.freshness_changed"),
        _ => None,
    }
}

fn now_unix() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::notification::{self, NotificationIn};

    #[test]
    fn allowlist_maps_snapshot_transitions_and_rejects_other_events() {
        assert_eq!(
            native_event_type("security.login_failed"),
            Some("security.login_failed")
        );
        assert_eq!(
            native_event_type("security.token_revoked"),
            Some("security.token_revoked")
        );
        assert_eq!(
            native_event_type("snapshot.stale"),
            Some("snapshot.freshness_changed")
        );
        assert_eq!(
            native_event_type("snapshot.recovered"),
            Some("snapshot.freshness_changed")
        );
        assert_eq!(native_event_type("host.offline"), None);
        assert_eq!(native_event_type("user.created"), None);
    }

    #[test]
    fn native_inbox_insert_enqueues_only_safe_metadata_idempotently() {
        let conn = Connection::open_in_memory().unwrap();
        crate::store::init_schema(&conn).unwrap();
        insert_notification(
            &conn,
            "login-bucket",
            "security.login_failed",
            "alice 192.0.2.4",
        );
        insert_notification(
            &conn,
            "security.token_revoked:token-secret",
            "security.token_revoked",
            "token-secret",
        );
        insert_notification(
            &conn,
            "snapshot-old",
            "snapshot.stale",
            "internal manifest detail",
        );
        insert_notification(
            &conn,
            "snapshot-new",
            "snapshot.recovered",
            "internal manifest detail",
        );
        insert_notification(&conn, "noise", "host.offline", "sensitive host details");

        let pending = pending_records(&conn).unwrap();
        assert_eq!(pending.len(), 4);
        assert_eq!(
            pending
                .iter()
                .filter(|row| row.event_type == "snapshot.freshness_changed")
                .count(),
            2
        );
        let serialized = serde_json::to_string(
            &pending
                .iter()
                .map(|row| {
                    (
                        &row.notification_id,
                        &row.delivery_id,
                        &row.event_type,
                        row.created_at,
                    )
                })
                .collect::<Vec<_>>(),
        )
        .unwrap();
        for secret in [
            "alice",
            "192.0.2.4",
            "token-secret",
            "internal manifest detail",
        ] {
            assert!(!serialized.contains(secret));
        }
        assert!(pending
            .iter()
            .all(|row| uuid::Uuid::parse_str(&row.notification_id).is_ok()));
        let id: String = conn
            .query_row(
                "SELECT q.delivery_id FROM web_event_delivery_queue q
                 JOIN notifications n ON n.id = q.notification_id
                 WHERE n.event_id = 'security.token_revoked:token-secret'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert!(uuid::Uuid::parse_str(&id).is_ok());

        // Duplicate notification ids do not create a second queued delivery.
        insert_notification(
            &conn,
            "security.token_revoked:token-secret",
            "security.token_revoked",
            "another secret",
        );
        assert_eq!(pending_records(&conn).unwrap().len(), 4);
    }

    #[test]
    fn throttle_is_global_per_fixed_kind_and_expires_after_five_minutes() {
        let conn = Connection::open_in_memory().unwrap();
        ensure_schema(&conn).unwrap();
        assert!(reserve_wecom_slot(&conn, "security.token_revoked", 1_000).unwrap());
        assert!(!reserve_wecom_slot(&conn, "security.token_revoked", 1_299).unwrap());
        assert!(reserve_wecom_slot(&conn, "security.token_revoked", 1_300).unwrap());
        assert!(reserve_wecom_slot(&conn, "snapshot.freshness_changed", 1_301).unwrap());
    }

    fn insert_notification(conn: &Connection, event_id: &str, event_type: &str, secret: &str) {
        notification::insert(
            conn,
            &NotificationIn {
                id: uuid::Uuid::new_v4().to_string(),
                event_type: event_type.to_string(),
                severity: "info".to_string(),
                title: format!("{secret} title"),
                summary: format!("{secret} summary"),
                target: Some(format!("{secret} target")),
                source: Some("web".to_string()),
                event_id: Some(event_id.to_string()),
            },
        )
        .unwrap();
    }
}
