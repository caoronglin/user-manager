//! Idempotency and delivery suppression for the read-only root event spool.

use rusqlite::{params, Connection, OptionalExtension};

use super::notification::{self, NotificationIn};

#[derive(Clone, Debug)]
pub struct Record {
    pub event_id: String,
    pub event_type: String,
    pub target: String,
    pub created_at: String,
    pub status: String,
}

/// Keep spool bookkeeping in the Web database. Nothing here writes to the
/// root-owned event directory.
pub fn ensure_schema(conn: &Connection) -> Result<(), rusqlite::Error> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS event_spool_records (
             event_id TEXT PRIMARY KEY,
             event_type TEXT NOT NULL,
             target TEXT NOT NULL,
             created_at TEXT NOT NULL,
             status TEXT NOT NULL DEFAULT 'pending',
             processed_at INTEGER NOT NULL
         );
         CREATE TABLE IF NOT EXISTS wecom_event_throttle (
             event_type TEXT NOT NULL,
             target TEXT NOT NULL,
             reserved_at INTEGER NOT NULL,
             PRIMARY KEY(event_type, target)
         );",
    )
}

/// Atomically create the inbox notification and the pending spool record.
/// Returns true only for the first sighting of this event id.
pub fn ingest(
    conn: &mut Connection,
    event_id: &str,
    event_type: &str,
    severity: &str,
    summary: &str,
    target: &str,
    created_at: &str,
) -> Result<bool, rusqlite::Error> {
    let tx = conn.transaction()?;
    let inserted = tx.execute(
        "INSERT INTO event_spool_records
           (event_id, event_type, target, created_at, status, processed_at)
         VALUES (?1, ?2, ?3, ?4, 'pending', ?5)
         ON CONFLICT(event_id) DO NOTHING",
        params![event_id, event_type, target, created_at, now_unix()],
    )?;
    if inserted == 1 {
        notification::insert(
            &tx,
            &NotificationIn {
                id: uuid::Uuid::new_v4().to_string(),
                event_type: event_type.to_string(),
                severity: severity.to_string(),
                title: match event_type {
                    "user.created" => "User account created".to_string(),
                    "user.disabled" => "User account disabled".to_string(),
                    _ => "System event".to_string(),
                },
                summary: summary.to_string(),
                target: Some(target.to_string()),
                source: Some("cli".to_string()),
                event_id: Some(event_id.to_string()),
            },
        )?;
    }
    tx.commit()?;
    Ok(inserted == 1)
}

pub fn get_record(conn: &Connection, event_id: &str) -> Result<Option<Record>, rusqlite::Error> {
    conn.query_row(
        "SELECT event_id, event_type, target, created_at, status
         FROM event_spool_records WHERE event_id = ?1",
        params![event_id],
        |row| {
            Ok(Record {
                event_id: row.get(0)?,
                event_type: row.get(1)?,
                target: row.get(2)?,
                created_at: row.get(3)?,
                status: row.get(4)?,
            })
        },
    )
    .optional()
}

pub fn pending_records(conn: &Connection) -> Result<Vec<Record>, rusqlite::Error> {
    let mut statement = conn.prepare(
        "SELECT event_id, event_type, target, created_at, status
         FROM event_spool_records WHERE status = 'pending'
         ORDER BY processed_at, event_id LIMIT 256",
    )?;
    let rows = statement
        .query_map([], |row| {
            Ok(Record {
                event_id: row.get(0)?,
                event_type: row.get(1)?,
                target: row.get(2)?,
                created_at: row.get(3)?,
                status: row.get(4)?,
            })
        })?
        .collect();
    rows
}

pub fn set_status(conn: &Connection, event_id: &str, status: &str) -> Result<(), rusqlite::Error> {
    conn.execute(
        "UPDATE event_spool_records SET status = ?1 WHERE event_id = ?2",
        params![status, event_id],
    )?;
    Ok(())
}

/// Reserve an event-type/target delivery slot. Same-kind notifications for
/// the same target are suppressed for five minutes across process restarts.
pub fn reserve_wecom_slot(
    conn: &Connection,
    event_type: &str,
    target: &str,
    now: i64,
) -> Result<bool, rusqlite::Error> {
    let changed = conn.execute(
        "INSERT INTO wecom_event_throttle(event_type, target, reserved_at)
         VALUES (?1, ?2, ?3)
         ON CONFLICT(event_type, target) DO UPDATE SET reserved_at = excluded.reserved_at
         WHERE wecom_event_throttle.reserved_at <= excluded.reserved_at - 300",
        params![event_type, target, now],
    )?;
    Ok(changed == 1)
}

fn now_unix() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or(0)
}
