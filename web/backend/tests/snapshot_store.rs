use std::path::PathBuf;

use umweb::store::snapshot::SnapshotStore;

fn temp_dir() -> PathBuf {
    let path = std::env::temp_dir().join(format!(
        "umweb-snapshot-{}-{}",
        std::process::id(),
        uuid::Uuid::new_v4()
    ));
    std::fs::create_dir(&path).expect("create temp snapshot directory");
    path
}

fn now_rfc3339() -> String {
    time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .expect("format time")
}

fn snapshot(kind: &str, generated_at: &str) -> serde_json::Value {
    let threshold = match kind {
        "system" | "resources" | "logs" => 60,
        "hosts" | "gpu" | "manifest" => 120,
        "audit-summary" => 30,
        "reports" | "users" | "quota" | "smb" => 300,
        _ => 300,
    };
    serde_json::json!({
        "schema_version": 1,
        "protocol": "user-manager-snapshot-v1",
        "kind": kind,
        "generator": "user-manager",
        "source": "local",
        "generated_at": generated_at,
        "threshold_seconds": threshold,
        "data": {"ok": true}
    })
}

#[test]
fn rejects_wrong_kind_protocol_and_invalid_timestamp() {
    let dir = temp_dir();
    let store = SnapshotStore::new(dir.clone());
    let generated_at = now_rfc3339();

    let mut value = snapshot("quota", &generated_at);
    std::fs::write(dir.join("users.json"), value.to_string()).unwrap();
    assert!(
        store.read("users").is_none(),
        "mismatched kind must fail closed"
    );

    value = snapshot("users", &generated_at);
    value["protocol"] = serde_json::json!("user-manager-snapshot-v2");
    std::fs::write(dir.join("users.json"), value.to_string()).unwrap();
    assert!(
        store.read("users").is_none(),
        "unknown protocol must fail closed"
    );

    value = snapshot("users", "not-a-timestamp");
    std::fs::write(dir.join("users.json"), value.to_string()).unwrap();
    let freshness = store.freshness("users", time::OffsetDateTime::now_utc().unix_timestamp());
    assert!(
        !freshness.present,
        "malformed timestamp must not appear present/fresh"
    );

    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn future_timestamp_is_present_but_stale() {
    let dir = temp_dir();
    let store = SnapshotStore::new(dir.clone());
    let future = time::OffsetDateTime::now_utc() + time::Duration::minutes(10);
    let generated_at = future
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();
    std::fs::write(
        dir.join("users.json"),
        snapshot("users", &generated_at).to_string(),
    )
    .unwrap();

    let freshness = store.freshness("users", time::OffsetDateTime::now_utc().unix_timestamp());
    assert!(freshness.present);
    assert!(freshness.stale);
    assert!(!freshness.fresh);

    std::fs::remove_dir_all(dir).unwrap();
}

#[cfg(unix)]
#[test]
fn refuses_symlink_snapshot_files() {
    use std::os::unix::fs::symlink;

    let dir = temp_dir();
    let target = dir.join("external.json");
    std::fs::write(&target, snapshot("users", &now_rfc3339()).to_string()).unwrap();
    symlink(&target, dir.join("users.json")).unwrap();

    let store = SnapshotStore::new(dir.clone());
    assert!(store.read("users").is_none());

    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn refuses_oversized_snapshot_files() {
    let dir = temp_dir();
    let path = dir.join("users.json");
    std::fs::write(&path, vec![b' '; 16 * 1024 * 1024 + 1]).unwrap();

    let store = SnapshotStore::new(dir.clone());
    assert!(store.read("users").is_none());

    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn parses_manifest_snapshot_shape() {
    let dir = temp_dir();
    let store = SnapshotStore::new(dir.clone());
    let manifest = serde_json::json!({
        "schema_version": 1,
        "protocol": "user-manager-snapshot-v1",
        "generator": "user-manager",
        "source": "manifest",
        "generated_at": now_rfc3339(),
        "overall": "partial",
        "snapshots": [{"kind": "users", "present": true, "fresh": true}]
    });
    std::fs::write(dir.join("manifest.json"), manifest.to_string()).unwrap();

    let parsed = store.read("manifest").expect("valid manifest");
    assert_eq!(parsed.kind, "manifest");
    assert_eq!(parsed.data["overall"], "partial");
    assert_eq!(parsed.data["snapshots"].as_array().unwrap().len(), 1);

    std::fs::remove_dir_all(dir).unwrap();
}
