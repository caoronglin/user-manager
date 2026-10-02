//! Persisted state transitions for the validated snapshot manifest freshness.
//!
//! Missing or invalid manifests are unknown observations. They do not alter the
//! last known state and never create a notification. Only a known fresh/stale
//! transition is recorded in the Web database; the root-owned snapshot files
//! remain read-only to this process.

use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};

use super::notification::{self, NotificationIn};
use super::snapshot::SnapshotStore;

const MANIFEST_KIND: &str = "manifest";
const OBSERVER_INTERVAL: Duration = Duration::from_secs(30);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum FreshnessState {
    Fresh,
    Stale,
}

impl FreshnessState {
    fn as_str(self) -> &'static str {
        match self {
            Self::Fresh => "fresh",
            Self::Stale => "stale",
        }
    }

    fn from_str(value: &str) -> Option<Self> {
        match value {
            "fresh" => Some(Self::Fresh),
            "stale" => Some(Self::Stale),
            _ => None,
        }
    }
}

/// Poll the validated manifest and atomically persist known state transitions.
pub async fn run(db: Arc<Mutex<Connection>>, snapshots: SnapshotStore) {
    let mut interval = tokio::time::interval(OBSERVER_INTERVAL);
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

    loop {
        interval.tick().await;
        let Some(now) = unix_now() else {
            tracing::warn!("snapshot freshness observer clock unavailable");
            continue;
        };

        let result = match db.lock() {
            Ok(mut conn) => observe_manifest(&mut conn, &snapshots, now),
            Err(_) => {
                tracing::warn!("snapshot freshness observer database lock poisoned");
                continue;
            }
        };
        if let Err(error) = result {
            tracing::warn!(error = %error, "snapshot freshness observation failed");
        }
    }
}

/// Read freshness only through SnapshotStore's validated manifest path.
///
/// The initial known observation establishes a baseline without an alert. An
/// unknown observation (missing or invalid manifest) leaves that baseline
/// untouched, so recovery is reported only after a later known fresh state.
pub fn observe_manifest(
    conn: &mut Connection,
    snapshots: &SnapshotStore,
    now: i64,
) -> Result<bool, rusqlite::Error> {
    let observed = observed_manifest_state(snapshots, now);

    ensure_schema(conn)?;
    let Some(observed) = observed else {
        return Ok(false);
    };

    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let previous = tx
        .query_row(
            "SELECT status FROM snapshot_freshness_observer WHERE kind = ?1",
            params![MANIFEST_KIND],
            |row| row.get::<_, String>(0),
        )
        .optional()?;

    let Some(previous) = previous else {
        tx.execute(
            "INSERT INTO snapshot_freshness_observer(kind, status, observed_at)
             VALUES (?1, ?2, ?3)",
            params![MANIFEST_KIND, observed.as_str(), now],
        )?;
        tx.commit()?;
        return Ok(false);
    };

    let previous = FreshnessState::from_str(&previous).ok_or(rusqlite::Error::InvalidQuery)?;
    tx.execute(
        "UPDATE snapshot_freshness_observer SET status = ?1, observed_at = ?2 WHERE kind = ?3",
        params![observed.as_str(), now, MANIFEST_KIND],
    )?;

    if previous == observed {
        tx.commit()?;
        return Ok(false);
    }

    let (event_type, severity, title, summary) = match observed {
        FreshnessState::Stale => (
            "snapshot.stale",
            "warning",
            "Snapshot manifest is stale",
            "The validated snapshot manifest became stale.",
        ),
        FreshnessState::Fresh => (
            "snapshot.recovered",
            "info",
            "Snapshot manifest recovered",
            "The validated snapshot manifest is fresh again.",
        ),
    };
    notification::insert(
        &tx,
        &NotificationIn {
            id: uuid::Uuid::new_v4().to_string(),
            event_type: event_type.to_string(),
            severity: severity.to_string(),
            title: title.to_string(),
            summary: summary.to_string(),
            target: Some(MANIFEST_KIND.to_string()),
            source: Some("web".to_string()),
            event_id: Some(uuid::Uuid::new_v4().to_string()),
        },
    )?;
    tx.commit()?;
    Ok(true)
}

fn observed_manifest_state(snapshots: &SnapshotStore, now: i64) -> Option<FreshnessState> {
    // read() validates the manifest envelope, its protocol and schema, then
    // exposes the collector's aggregate state. freshness() independently
    // checks that this manifest itself has not aged past its threshold.
    let (manifest, freshness) = snapshots.read_with_freshness(MANIFEST_KIND, now)?;
    if !freshness.present {
        return None;
    }
    if freshness.stale {
        return Some(FreshnessState::Stale);
    }

    match manifest
        .data
        .get("overall")
        .and_then(serde_json::Value::as_str)
    {
        Some("stale") => Some(FreshnessState::Stale),
        Some("fresh") if freshness.fresh => Some(FreshnessState::Fresh),
        // Partial and unavailable are valid aggregate states, but do not prove
        // a global fresh or stale transition. Keep the last known state.
        _ => None,
    }
}

fn ensure_schema(conn: &Connection) -> Result<(), rusqlite::Error> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS snapshot_freshness_observer (
             kind TEXT PRIMARY KEY,
             status TEXT NOT NULL CHECK (status IN ('fresh', 'stale')),
             observed_at INTEGER NOT NULL
         );",
    )
}

fn unix_now() -> Option<i64> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()
        .map(|duration| duration.as_secs() as i64)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::fs;
    use std::path::PathBuf;

    struct TestDirs {
        root: PathBuf,
        snapshot_store: SnapshotStore,
        db_path: PathBuf,
    }

    impl TestDirs {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "umweb-snapshot-observer-{}-{}",
                std::process::id(),
                uuid::Uuid::new_v4()
            ));
            fs::create_dir(&root).expect("create observer test directory");
            let snapshots = root.join("snapshots");
            fs::create_dir(&snapshots).expect("create snapshot directory");
            Self {
                snapshot_store: SnapshotStore::new(snapshots),
                db_path: root.join("app.db"),
                root,
            }
        }

        fn open_db(&self) -> Connection {
            let conn = Connection::open(&self.db_path).expect("open observer test database");
            crate::store::init_schema(&conn).expect("initialize Web database schema");
            conn
        }

        fn write_manifest_state(&self, generated_at: &str, overall: &str) {
            let manifest = json!({
                "schema_version": 1,
                "protocol": "user-manager-snapshot-v1",
                "generator": "user-manager",
                "source": "manifest",
                "generated_at": generated_at,
                "overall": overall,
                "snapshots": []
            });
            fs::write(
                self.snapshot_store.dir().join("manifest.json"),
                manifest.to_string(),
            )
            .expect("write test manifest");
        }

        fn write_manifest(&self, generated_at: &str) {
            self.write_manifest_state(generated_at, "fresh");
        }

        fn generated_at(unix: i64) -> String {
            time::OffsetDateTime::from_unix_timestamp(unix)
                .expect("valid test timestamp")
                .format(&time::format_description::well_known::Rfc3339)
                .expect("format test timestamp")
        }

        fn notification_count(conn: &Connection, event_type: &str) -> i64 {
            conn.query_row(
                "SELECT COUNT(*) FROM notifications WHERE event_type = ?1",
                params![event_type],
                |row| row.get(0),
            )
            .expect("count observer notifications")
        }

        fn known_state(conn: &Connection) -> Option<String> {
            conn.query_row(
                "SELECT status FROM snapshot_freshness_observer WHERE kind = ?1",
                params![MANIFEST_KIND],
                |row| row.get(0),
            )
            .optional()
            .expect("read persisted observer state")
        }
    }

    impl Drop for TestDirs {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    #[test]
    fn missing_and_invalid_manifests_remain_unknown_without_notifications() {
        let dirs = TestDirs::new();
        let mut conn = dirs.open_db();

        assert!(!observe_manifest(&mut conn, &dirs.snapshot_store, 1_800_000_000).unwrap());
        assert_eq!(TestDirs::known_state(&conn), None);

        fs::write(dirs.snapshot_store.dir().join("manifest.json"), "not json")
            .expect("write invalid manifest");
        assert!(!observe_manifest(&mut conn, &dirs.snapshot_store, 1_800_000_001).unwrap());
        assert_eq!(TestDirs::known_state(&conn), None);
        assert_eq!(TestDirs::notification_count(&conn, "snapshot.stale"), 0);
        assert_eq!(TestDirs::notification_count(&conn, "snapshot.recovered"), 0);
    }

    #[test]
    fn writes_only_fresh_stale_transitions_and_persists_them() {
        let dirs = TestDirs::new();
        let mut conn = dirs.open_db();
        let fresh_at = 1_800_000_000;
        dirs.write_manifest(&TestDirs::generated_at(fresh_at));

        assert!(!observe_manifest(&mut conn, &dirs.snapshot_store, fresh_at).unwrap());
        assert_eq!(TestDirs::known_state(&conn).as_deref(), Some("fresh"));

        // The transition state survives a process/database reconnect.
        drop(conn);
        let mut conn = dirs.open_db();
        let stale_at = fresh_at + 121;
        dirs.write_manifest(&TestDirs::generated_at(fresh_at));
        assert!(observe_manifest(&mut conn, &dirs.snapshot_store, stale_at).unwrap());
        assert!(!observe_manifest(&mut conn, &dirs.snapshot_store, stale_at + 1).unwrap());
        assert_eq!(TestDirs::known_state(&conn).as_deref(), Some("stale"));

        let recovered_at = stale_at + 10;
        dirs.write_manifest(&TestDirs::generated_at(recovered_at));
        assert!(observe_manifest(&mut conn, &dirs.snapshot_store, recovered_at).unwrap());
        assert!(!observe_manifest(&mut conn, &dirs.snapshot_store, recovered_at + 1).unwrap());
        assert_eq!(TestDirs::known_state(&conn).as_deref(), Some("fresh"));

        assert_eq!(TestDirs::notification_count(&conn, "snapshot.stale"), 1);
        assert_eq!(TestDirs::notification_count(&conn, "snapshot.recovered"), 1);
        let stale: (String, String, String, String, String) = conn
            .query_row(
                "SELECT severity, title, summary, target, source FROM notifications
                 WHERE event_type = 'snapshot.stale'",
                [],
                |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                    ))
                },
            )
            .expect("read stale notification");
        assert_eq!(
            stale,
            (
                "warning".into(),
                "Snapshot manifest is stale".into(),
                "The validated snapshot manifest became stale.".into(),
                "manifest".into(),
                "web".into(),
            )
        );
        let recovered: (String, String, String) = conn
            .query_row(
                "SELECT severity, summary, source FROM notifications
                 WHERE event_type = 'snapshot.recovered'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .expect("read recovered notification");
        assert_eq!(
            recovered,
            (
                "info".into(),
                "The validated snapshot manifest is fresh again.".into(),
                "web".into(),
            )
        );
    }

    #[test]
    fn unknown_observations_preserve_last_known_state() {
        let dirs = TestDirs::new();
        let mut conn = dirs.open_db();
        let fresh_at = 1_800_000_000;
        dirs.write_manifest(&TestDirs::generated_at(fresh_at));
        assert!(!observe_manifest(&mut conn, &dirs.snapshot_store, fresh_at).unwrap());

        fs::write(dirs.snapshot_store.dir().join("manifest.json"), "{}").unwrap();
        assert!(!observe_manifest(&mut conn, &dirs.snapshot_store, fresh_at + 121).unwrap());
        assert_eq!(TestDirs::known_state(&conn).as_deref(), Some("fresh"));
        assert_eq!(TestDirs::notification_count(&conn, "snapshot.stale"), 0);

        dirs.write_manifest(&TestDirs::generated_at(fresh_at));
        assert!(observe_manifest(&mut conn, &dirs.snapshot_store, fresh_at + 121).unwrap());
        assert_eq!(TestDirs::notification_count(&conn, "snapshot.stale"), 1);
    }

    #[test]
    fn aggregate_stale_transitions_but_partial_and_unavailable_remain_unknown() {
        let dirs = TestDirs::new();
        let mut conn = dirs.open_db();
        let now = 1_800_000_000;

        dirs.write_manifest(&TestDirs::generated_at(now));
        assert!(!observe_manifest(&mut conn, &dirs.snapshot_store, now).unwrap());
        assert_eq!(TestDirs::known_state(&conn).as_deref(), Some("fresh"));

        dirs.write_manifest_state(&TestDirs::generated_at(now + 1), "partial");
        assert!(!observe_manifest(&mut conn, &dirs.snapshot_store, now + 1).unwrap());
        assert_eq!(TestDirs::known_state(&conn).as_deref(), Some("fresh"));
        assert_eq!(TestDirs::notification_count(&conn, "snapshot.stale"), 0);

        dirs.write_manifest_state(&TestDirs::generated_at(now + 2), "stale");
        assert!(observe_manifest(&mut conn, &dirs.snapshot_store, now + 2).unwrap());
        assert_eq!(TestDirs::known_state(&conn).as_deref(), Some("stale"));

        dirs.write_manifest_state(&TestDirs::generated_at(now + 3), "unavailable");
        assert!(!observe_manifest(&mut conn, &dirs.snapshot_store, now + 3).unwrap());
        assert_eq!(TestDirs::known_state(&conn).as_deref(), Some("stale"));

        dirs.write_manifest(&TestDirs::generated_at(now + 4));
        assert!(observe_manifest(&mut conn, &dirs.snapshot_store, now + 4).unwrap());
        assert_eq!(TestDirs::known_state(&conn).as_deref(), Some("fresh"));
        assert_eq!(TestDirs::notification_count(&conn, "snapshot.stale"), 1);
        assert_eq!(TestDirs::notification_count(&conn, "snapshot.recovered"), 1);
    }
}
