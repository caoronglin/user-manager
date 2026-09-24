//! Read-only consumer for the fixed root-to-Web event spool.
//!
//! This module has no path configuration, write API, shell access, or privilege
//! path. It opens the configured production directory and files read-only with
//! `openat`/`O_NOFOLLOW`, then records validated events in the Web database.

use std::ffi::{CStr, CString, OsStr, OsString};
use std::fs::File;
use std::io::{self, Read};
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Component, Path};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use reqwest::redirect::Policy;
use reqwest::Client;
use rusqlite::Connection;
use serde::Deserialize;
use serde_json::{json, Value};
use tokio::sync::Semaphore;
use url::Url;

use crate::crypto;
use crate::store::event_spool as spool_store;
use crate::store::wecom::{self, Delivery};

const EVENT_DIR: &str = "/var/lib/user-manager-web/events";
const MAX_EVENT_BYTES: usize = 16 * 1024;
const MAX_SCAN_FILES: usize = 1024;
const MAX_RESPONSE_BYTES: usize = 16 * 1024;
const MAX_ATTEMPTS: i64 = 3;
const POLL_INTERVAL: Duration = Duration::from_secs(30);

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct SpoolEvent {
    schema_version: u32,
    event_id: String,
    event_type: EventType,
    created_at: String,
    source: EventSource,
    severity: Severity,
    summary: String,
    data: EventData,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
enum EventType {
    #[serde(rename = "user.created")]
    UserCreated,
    #[serde(rename = "user.disabled")]
    UserDisabled,
}

impl EventType {
    fn as_str(self) -> &'static str {
        match self {
            Self::UserCreated => "user.created",
            Self::UserDisabled => "user.disabled",
        }
    }

    fn summary(self) -> &'static str {
        match self {
            Self::UserCreated => "User account created.",
            Self::UserDisabled => "User account disabled.",
        }
    }

    fn title(self) -> &'static str {
        match self {
            Self::UserCreated => "User account created",
            Self::UserDisabled => "User account disabled",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "lowercase")]
enum EventSource {
    Cli,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "lowercase")]
enum Severity {
    Info,
    Warning,
}

impl Severity {
    fn as_str(self) -> &'static str {
        match self {
            Self::Info => "info",
            Self::Warning => "warning",
        }
    }
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct EventData {
    username: String,
}

struct OpenDir(*mut libc::DIR);

impl Drop for OpenDir {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe {
                libc::closedir(self.0);
            }
        }
    }
}

/// Start the periodic read-only consumer. The fixed path is intentionally not
/// configurable through environment variables or Web settings.
pub async fn run(
    db: Arc<Mutex<Connection>>,
    master_key: [u8; crypto::KEY_LEN],
    outbound_gate: Arc<Semaphore>,
) {
    let mut interval = tokio::time::interval(POLL_INTERVAL);
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        interval.tick().await;
        if let Err(error) = consume_once(&db, &master_key, &outbound_gate).await {
            tracing::warn!(error = %error, "event spool scan failed");
        }
    }
}

/// One scan of the fixed production directory. Missing spool directory is a
/// normal empty state during deployment; it is never created by this process.
pub async fn consume_once(
    db: &Arc<Mutex<Connection>>,
    master_key: &[u8; crypto::KEY_LEN],
    outbound_gate: &Arc<Semaphore>,
) -> Result<usize, String> {
    consume_from_dir(db, master_key, outbound_gate, Path::new(EVENT_DIR)).await
}

async fn consume_from_dir(
    db: &Arc<Mutex<Connection>>,
    master_key: &[u8; crypto::KEY_LEN],
    outbound_gate: &Arc<Semaphore>,
    directory: &Path,
) -> Result<usize, String> {
    let _permit = outbound_gate
        .clone()
        .acquire_owned()
        .await
        .map_err(|_| "outbound gate closed".to_string())?;

    let events = read_events(directory).map_err(|_| "event spool unavailable".to_string())?;
    {
        let mut conn = db
            .lock()
            .map_err(|_| "database lock poisoned".to_string())?;
        spool_store::ensure_schema(&conn).map_err(|_| "event schema unavailable".to_string())?;
        for event in &events {
            spool_store::ingest(
                &mut conn,
                &event.event_id,
                event.event_type.as_str(),
                event.severity.as_str(),
                event.event_type.summary(),
                &event.data.username,
                &event.created_at,
            )
            .map_err(|_| "event ingestion failed".to_string())?;
        }
    }

    let pending = {
        let conn = db
            .lock()
            .map_err(|_| "database lock poisoned".to_string())?;
        spool_store::pending_records(&conn).map_err(|_| "event queue unavailable".to_string())?
    };
    let processed = pending.len();
    for record in pending {
        process_record(db, master_key, &record).await?;
    }
    Ok(processed)
}

async fn process_record(
    db: &Arc<Mutex<Connection>>,
    master_key: &[u8; crypto::KEY_LEN],
    record: &spool_store::Record,
) -> Result<(), String> {
    let settings = {
        let conn = db
            .lock()
            .map_err(|_| "database lock poisoned".to_string())?;
        wecom::get_settings(&conn).map_err(|_| "WeCom settings unavailable".to_string())?
    };
    let settings = match settings {
        Some(settings) if settings.enabled => settings,
        _ => return set_status(db, &record.event_id, "disabled"),
    };
    let selected_events =
        serde_json::from_str::<Vec<String>>(&settings.events_json).unwrap_or_default();
    if !selected_events
        .iter()
        .any(|kind| kind == &record.event_type)
    {
        return set_status(db, &record.event_id, "not_selected");
    }

    if settings.dry_run {
        insert_delivery(db, &dry_run_delivery(&record.event_id))?;
        return set_status(db, &record.event_id, "dry_run");
    }

    let now = now_unix();
    let reserved = {
        let conn = db
            .lock()
            .map_err(|_| "database lock poisoned".to_string())?;
        spool_store::reserve_wecom_slot(&conn, &record.event_type, &record.target, now)
            .map_err(|_| "WeCom throttle unavailable".to_string())?
    };
    if !reserved {
        insert_delivery(db, &throttled_delivery(&record.event_id))?;
        return set_status(db, &record.event_id, "throttled");
    }

    let Some(webhook) = settings
        .webhook_ciphertext
        .as_deref()
        .and_then(|ciphertext| crypto::decrypt_str(master_key, ciphertext))
        .and_then(|value| validate_webhook(&value).map(|url| (value, url)))
    else {
        insert_delivery(
            db,
            &failed_delivery(&record.event_id, 1, "configuration_error"),
        )?;
        return set_status(db, &record.event_id, "failed");
    };

    let outcome = send_event(&webhook.1, record).await;
    for delivery in &outcome {
        insert_delivery(db, delivery)?;
    }
    let status = if outcome.iter().any(|delivery| delivery.success) {
        "sent"
    } else {
        "failed"
    };
    let _ = webhook.0; // Keep the decrypted URL scoped to this delivery only.
    set_status(db, &record.event_id, status)
}

fn set_status(db: &Arc<Mutex<Connection>>, event_id: &str, status: &str) -> Result<(), String> {
    let conn = db
        .lock()
        .map_err(|_| "database lock poisoned".to_string())?;
    spool_store::set_status(&conn, event_id, status)
        .map_err(|_| "event status update failed".to_string())
}

fn insert_delivery(db: &Arc<Mutex<Connection>>, delivery: &Delivery) -> Result<(), String> {
    let conn = db
        .lock()
        .map_err(|_| "database lock poisoned".to_string())?;
    wecom::insert_delivery(&conn, delivery).map_err(|_| "delivery history write failed".to_string())
}

fn read_events(directory: &Path) -> io::Result<Vec<SpoolEvent>> {
    let dir = match open_dir_without_symlinks(directory) {
        Ok(dir) => dir,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error),
    };
    let require_root_owner = directory == Path::new(EVENT_DIR);
    let directory_metadata = dir.metadata()?;
    if require_root_owner
        && (directory_metadata.uid() != 0
            || directory_metadata.gid() != unsafe { libc::getegid() }
            || directory_metadata.permissions().mode() & 0o777 != 0o750)
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "event spool directory ownership or mode is unsafe",
        ));
    }
    let names = read_directory_names(dir.as_raw_fd())?;
    let mut candidates = names
        .into_iter()
        .filter_map(|name| {
            let text = name.to_str()?;
            let stem = text.strip_suffix(".json")?;
            canonical_event_id(stem).map(|id| (name, id))
        })
        .collect::<Vec<_>>();
    candidates.sort_by(|left, right| left.0.cmp(&right.0));
    candidates.truncate(MAX_SCAN_FILES);

    let mut events = Vec::with_capacity(candidates.len());
    for (filename, expected_id) in candidates {
        if let Some(event) =
            read_event_file(dir.as_raw_fd(), &filename, &expected_id, require_root_owner)
        {
            events.push(event);
        }
    }
    Ok(events)
}

fn open_dir_without_symlinks(path: &Path) -> io::Result<File> {
    let mut current = File::open("/")?;
    for component in path.components() {
        let name = match component {
            Component::RootDir => continue,
            Component::Normal(name) => name,
            Component::CurDir | Component::ParentDir | Component::Prefix(_) => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "event directory path must be absolute and normalized",
                ));
            }
        };
        let c_name = CString::new(name.as_bytes())
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid path component"))?;
        let fd = unsafe {
            libc::openat(
                current.as_raw_fd(),
                c_name.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        current = unsafe { File::from_raw_fd(fd) };
    }
    Ok(current)
}

fn read_directory_names(fd: RawFd) -> io::Result<Vec<OsString>> {
    let duplicate = unsafe { libc::dup(fd) };
    if duplicate < 0 {
        return Err(io::Error::last_os_error());
    }
    let stream = unsafe { libc::fdopendir(duplicate) };
    if stream.is_null() {
        let error = io::Error::last_os_error();
        unsafe { libc::close(duplicate) };
        return Err(error);
    }
    let stream = OpenDir(stream);
    let mut names = Vec::new();
    loop {
        unsafe { *libc::__errno_location() = 0 };
        let entry = unsafe { libc::readdir(stream.0) };
        if entry.is_null() {
            let error_code = unsafe { *libc::__errno_location() };
            if error_code != 0 {
                return Err(io::Error::from_raw_os_error(error_code));
            }
            break;
        }
        let bytes = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) }.to_bytes();
        if bytes == b"." || bytes == b".." || !bytes.ends_with(b".json") {
            continue;
        }
        names.push(OsString::from(OsStr::from_bytes(bytes)));
        if names.len() >= MAX_SCAN_FILES * 4 {
            break;
        }
    }
    Ok(names)
}

fn read_event_file(
    dir_fd: RawFd,
    filename: &OsStr,
    expected_id: &str,
    require_root_owner: bool,
) -> Option<SpoolEvent> {
    let c_name = CString::new(filename.as_bytes()).ok()?;
    let fd = unsafe {
        libc::openat(
            dir_fd,
            c_name.as_ptr(),
            libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK,
        )
    };
    if fd < 0 {
        return None;
    }
    let file = unsafe { File::from_raw_fd(fd) };
    let metadata = file.metadata().ok()?;
    if !metadata.is_file()
        || metadata.nlink() != 1
        || metadata.size() > MAX_EVENT_BYTES as u64
        || (require_root_owner
            && (metadata.uid() != 0
                || metadata.gid() != unsafe { libc::getegid() }
                || metadata.permissions().mode() & 0o777 != 0o640))
    {
        return None;
    }
    let mut bytes = Vec::with_capacity(metadata.size() as usize);
    file.take((MAX_EVENT_BYTES + 1) as u64)
        .read_to_end(&mut bytes)
        .ok()?;
    if bytes.len() > MAX_EVENT_BYTES {
        return None;
    }
    let event = serde_json::from_slice::<SpoolEvent>(&bytes).ok()?;
    validate_event(event, expected_id)
}

fn canonical_event_id(value: &str) -> Option<String> {
    let parsed = uuid::Uuid::parse_str(value).ok()?;
    let canonical = parsed.hyphenated().to_string();
    (canonical == value).then_some(canonical)
}

fn validate_event(event: SpoolEvent, expected_id: &str) -> Option<SpoolEvent> {
    if event.schema_version != 1
        || event.event_id != expected_id
        || event.source != EventSource::Cli
        || event.summary != event.event_type.summary()
        || !valid_linux_username(&event.data.username)
        || time::OffsetDateTime::parse(
            &event.created_at,
            &time::format_description::well_known::Rfc3339,
        )
        .is_err()
    {
        return None;
    }
    Some(event)
}

fn valid_linux_username(username: &str) -> bool {
    let bytes = username.as_bytes();
    if bytes.is_empty() || bytes.len() > 32 {
        return false;
    }
    let first_ok = bytes[0].is_ascii_lowercase() || bytes[0] == b'_';
    first_ok
        && bytes[1..]
            .iter()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || b"_-".contains(byte))
}

fn validate_webhook(input: &str) -> Option<Url> {
    if input.is_empty() || input.len() > 512 || input.trim() != input {
        return None;
    }
    let url = Url::parse(input).ok()?;
    let authority = input.split_once("://")?.1.split(['/', '?', '#']).next()?;
    if url.scheme() != "https"
        || url.host_str() != Some("qyapi.weixin.qq.com")
        || !matches!(url.port(), None | Some(443))
        || url.path() != "/cgi-bin/webhook/send"
        || authority.contains('@')
        || !url.username().is_empty()
        || url.password().is_some()
        || url.fragment().is_some()
    {
        return None;
    }
    let key = url.query()?.strip_prefix("key=")?;
    if !(1..=128).contains(&key.len())
        || key.contains(['&', '%', '+', '#'])
        || !key
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
    {
        return None;
    }
    Some(url)
}

async fn send_event(url: &Url, event: &spool_store::Record) -> Vec<Delivery> {
    let client = match Client::builder()
        .redirect(Policy::none())
        .no_proxy()
        .connect_timeout(Duration::from_secs(3))
        .timeout(Duration::from_secs(8))
        .build()
    {
        Ok(client) => client,
        Err(_) => return vec![failed_delivery(&event.event_id, 1, "client_error")],
    };

    let kind = match event.event_type.as_str() {
        "user.created" => EventType::UserCreated,
        "user.disabled" => EventType::UserDisabled,
        _ => return vec![failed_delivery(&event.event_id, 1, "invalid_event")],
    };
    let payload = json!({
        "msgtype": "text",
        "text": {
            "content": format!(
                "[User Manager] {}\n对象: {}\n时间: {}",
                kind.title(),
                event.target,
                event.created_at,
            )
        }
    });

    let mut outcomes = Vec::with_capacity(MAX_ATTEMPTS as usize);
    for attempt in 1..=MAX_ATTEMPTS {
        let started_at = now_unix();
        let response = client
            .post(url.clone())
            .header(reqwest::header::CONTENT_TYPE, "application/json")
            .json(&payload)
            .send()
            .await;
        let delivery = match response {
            Err(error) => failed_delivery(
                &event.event_id,
                attempt,
                if error.is_timeout() {
                    "timeout"
                } else {
                    "network"
                },
            ),
            Ok(mut response) => {
                let status = response.status();
                let mut body = Vec::with_capacity(1024);
                let mut too_large = false;
                let mut body_error = None;
                loop {
                    match response.chunk().await {
                        Ok(Some(chunk)) => {
                            if body.len().saturating_add(chunk.len()) > MAX_RESPONSE_BYTES {
                                too_large = true;
                                break;
                            }
                            body.extend_from_slice(&chunk);
                        }
                        Ok(None) => break,
                        Err(error) => {
                            body_error = Some(if error.is_timeout() {
                                "timeout"
                            } else {
                                "network"
                            });
                            break;
                        }
                    }
                }
                if let Some(error_class) = body_error {
                    failed_http_delivery(
                        &event.event_id,
                        attempt,
                        started_at,
                        Some(status.as_u16() as i64),
                        None,
                        error_class,
                    )
                } else if too_large {
                    failed_http_delivery(
                        &event.event_id,
                        attempt,
                        started_at,
                        Some(status.as_u16() as i64),
                        None,
                        "response_too_large",
                    )
                } else {
                    let remote_code = serde_json::from_slice::<Value>(&body)
                        .ok()
                        .and_then(|value| value.get("errcode").and_then(Value::as_i64));
                    let http_status = status.as_u16() as i64;
                    let success = status.is_success() && remote_code == Some(0);
                    let error_class = if success {
                        None
                    } else if !status.is_success() {
                        Some("http_error")
                    } else if remote_code.is_some() {
                        Some("remote_error")
                    } else {
                        Some("invalid_response")
                    };
                    Delivery {
                        id: uuid::Uuid::new_v4().to_string(),
                        event_id: event.event_id.clone(),
                        attempt,
                        started_at,
                        finished_at: now_unix(),
                        http_status: Some(http_status),
                        remote_code: remote_code.map(|code| code.to_string()),
                        success,
                        error_class: error_class.map(str::to_string),
                    }
                }
            }
        };
        let retryable = is_retryable(&delivery);
        outcomes.push(delivery);
        if outcomes.last().is_some_and(|delivery| delivery.success) || !retryable {
            break;
        }
        if attempt < MAX_ATTEMPTS {
            tokio::time::sleep(Duration::from_millis(
                200_u64.saturating_mul(1_u64 << (attempt as u32 - 1)),
            ))
            .await;
        }
    }
    outcomes
}

fn is_retryable(delivery: &Delivery) -> bool {
    if delivery.success {
        return false;
    }
    match delivery.http_status {
        Some(429) | Some(500..=599) => true,
        Some(400..=499) => false,
        _ => matches!(delivery.error_class.as_deref(), Some("network" | "timeout")),
    }
}

fn dry_run_delivery(event_id: &str) -> Delivery {
    let now = now_unix();
    Delivery {
        id: uuid::Uuid::new_v4().to_string(),
        event_id: event_id.to_string(),
        attempt: 0,
        started_at: now,
        finished_at: now,
        http_status: None,
        remote_code: None,
        success: false,
        error_class: Some("dry_run".to_string()),
    }
}

fn throttled_delivery(event_id: &str) -> Delivery {
    let now = now_unix();
    Delivery {
        id: uuid::Uuid::new_v4().to_string(),
        event_id: event_id.to_string(),
        attempt: 0,
        started_at: now,
        finished_at: now,
        http_status: None,
        remote_code: None,
        success: false,
        error_class: Some("throttled_5m".to_string()),
    }
}

fn failed_delivery(event_id: &str, attempt: i64, error_class: &str) -> Delivery {
    failed_http_delivery(event_id, attempt, now_unix(), None, None, error_class)
}

fn failed_http_delivery(
    event_id: &str,
    attempt: i64,
    started_at: i64,
    http_status: Option<i64>,
    remote_code: Option<String>,
    error_class: &str,
) -> Delivery {
    Delivery {
        id: uuid::Uuid::new_v4().to_string(),
        event_id: event_id.to_string(),
        attempt,
        started_at,
        finished_at: now_unix(),
        http_status,
        remote_code,
        success: false,
        error_class: Some(error_class.to_string()),
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
    use rusqlite::params;
    use std::os::unix::fs::{symlink, PermissionsExt};

    struct TestDb {
        root: std::path::PathBuf,
        db: Arc<Mutex<Connection>>,
        key: [u8; crypto::KEY_LEN],
        gate: Arc<Semaphore>,
    }

    fn test_db() -> TestDb {
        let root = std::env::temp_dir().join(format!("umweb-spool-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&root).unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
        let conn = Connection::open_in_memory().unwrap();
        crate::store::init_schema(&conn).unwrap();
        TestDb {
            root,
            db: Arc::new(Mutex::new(conn)),
            key: [0x42; crypto::KEY_LEN],
            gate: Arc::new(Semaphore::new(1)),
        }
    }

    fn event_json(id: &str, kind: &str, username: &str) -> String {
        let summary = match kind {
            "user.created" => "User account created.",
            "user.disabled" => "User account disabled.",
            _ => unreachable!(),
        };
        serde_json::json!({
            "schema_version": 1,
            "event_id": id,
            "event_type": kind,
            "created_at": "2026-09-24T01:02:03Z",
            "source": "cli",
            "severity": if kind == "user.created" { "info" } else { "warning" },
            "summary": summary,
            "data": { "username": username }
        })
        .to_string()
    }

    fn write_event(dir: &Path, kind: &str, username: &str) -> String {
        let id = uuid::Uuid::new_v4().to_string();
        std::fs::write(
            dir.join(format!("{id}.json")),
            event_json(&id, kind, username),
        )
        .unwrap();
        id
    }

    async fn save_settings(
        db: &Arc<Mutex<Connection>>,
        enabled: bool,
        dry_run: bool,
        webhook: Option<&str>,
    ) {
        let conn = db.lock().unwrap();
        let encrypted = webhook.and_then(|url| crypto::encrypt_str(&[0x42; crypto::KEY_LEN], url));
        wecom::save_settings(
            &conn,
            &wecom::SettingsUpdate {
                expected_version: 0,
                enabled,
                dry_run,
                webhook_ciphertext: encrypted.as_deref(),
                events_json: r#"["user.created","user.disabled"]"#,
                updated_at: now_unix(),
                updated_by: "test",
            },
        )
        .unwrap();
    }

    #[test]
    fn validates_contract_and_rejects_bad_usernames_and_summaries() {
        let id = uuid::Uuid::new_v4().to_string();
        let valid: SpoolEvent =
            serde_json::from_str(&event_json(&id, "user.created", "alice_2")).unwrap();
        assert!(validate_event(valid, &id).is_some());

        for invalid_name in ["-alice", "Alice", "alice;id", "a".repeat(33).as_str()] {
            let raw = event_json(&id, "user.created", invalid_name);
            let parsed = serde_json::from_str::<SpoolEvent>(&raw).unwrap();
            assert!(validate_event(parsed, &id).is_none());
        }
        let mut wrong_summary = event_json(&id, "user.created", "alice");
        wrong_summary = wrong_summary.replace("User account created.", "custom text");
        let parsed = serde_json::from_str::<SpoolEvent>(&wrong_summary).unwrap();
        assert!(validate_event(parsed, &id).is_none());

        for bad in [
            event_json(&id, "user.created", "alice")
                .replace("\"schema_version\":1", "\"schema_version\":2"),
            event_json(&id, "user.created", "alice").replace("2026-09-24T01:02:03Z", "yesterday"),
            event_json(&id, "user.created", "alice")
                .replace("\"source\":\"cli\"", "\"source\":\"web\""),
            event_json(&id, "user.created", "alice")
                .replace("\"event_id\":", "\"extra\":true,\"event_id\":"),
        ] {
            let accepted = serde_json::from_str::<SpoolEvent>(&bad)
                .ok()
                .and_then(|parsed| validate_event(parsed, &id))
                .is_some();
            assert!(!accepted);
        }
    }

    #[test]
    fn reads_only_canonical_regular_single_link_files_without_symlinks() {
        let db = test_db();
        let dir = db.root.join("events");
        std::fs::create_dir(&dir).unwrap();
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o750)).unwrap();
        let valid_id = write_event(&dir, "user.created", "alice");

        let symlink_id = uuid::Uuid::new_v4().to_string();
        let outside = db.root.join("outside.json");
        std::fs::write(&outside, event_json(&symlink_id, "user.created", "bob")).unwrap();
        symlink(&outside, dir.join(format!("{symlink_id}.json"))).unwrap();

        let linked_id = uuid::Uuid::new_v4().to_string();
        let linked_path = dir.join(format!("{linked_id}.json"));
        std::fs::write(
            &linked_path,
            event_json(&linked_id, "user.created", "carol"),
        )
        .unwrap();
        std::fs::hard_link(&linked_path, db.root.join("hardlink.json")).unwrap();

        let wrong_name = uuid::Uuid::new_v4().to_string();
        std::fs::write(
            dir.join("not-a-uuid.json"),
            event_json(&wrong_name, "user.created", "dan"),
        )
        .unwrap();

        let oversize_id = uuid::Uuid::new_v4().to_string();
        let mut oversized = event_json(&oversize_id, "user.created", "erin");
        oversized.push_str(&" ".repeat(MAX_EVENT_BYTES + 1 - oversized.len()));
        std::fs::write(dir.join(format!("{oversize_id}.json")), oversized).unwrap();

        let events = read_events(&dir).unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].event_id, valid_id);

        let directory_link = db.root.join("events-link");
        symlink(&dir, &directory_link).unwrap();
        assert!(read_events(&directory_link).is_err());
    }

    #[tokio::test]
    async fn ingestion_is_idempotent_and_writes_one_notification() {
        let db = test_db();
        let dir = db.root.join("events");
        std::fs::create_dir(&dir).unwrap();
        save_settings(&db.db, false, false, None).await;
        write_event(&dir, "user.created", "alice");

        consume_from_dir(&db.db, &db.key, &db.gate, &dir)
            .await
            .unwrap();
        consume_from_dir(&db.db, &db.key, &db.gate, &dir)
            .await
            .unwrap();
        let conn = db.db.lock().unwrap();
        let notifications: i64 = conn
            .query_row("SELECT COUNT(*) FROM notifications", [], |row| row.get(0))
            .unwrap();
        let records: i64 = conn
            .query_row("SELECT COUNT(*) FROM event_spool_records", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(notifications, 1);
        assert_eq!(records, 1);
    }

    #[tokio::test]
    async fn dry_run_records_delivery_without_network_or_webhook() {
        let db = test_db();
        let dir = db.root.join("events");
        std::fs::create_dir(&dir).unwrap();
        save_settings(&db.db, true, true, None).await;
        let id = write_event(&dir, "user.created", "alice");

        consume_from_dir(&db.db, &db.key, &db.gate, &dir)
            .await
            .unwrap();
        let conn = db.db.lock().unwrap();
        let (status, class): (String, String) = conn
            .query_row(
                "SELECT status, (SELECT error_class FROM wecom_deliveries WHERE event_id = ?1) FROM event_spool_records WHERE event_id = ?1",
                params![id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(status, "dry_run");
        assert_eq!(class, "dry_run");
    }

    #[tokio::test]
    async fn duplicate_kind_and_target_is_suppressed_for_five_minutes() {
        let db = test_db();
        let dir = db.root.join("events");
        std::fs::create_dir(&dir).unwrap();
        save_settings(&db.db, true, false, None).await;
        let first_id = write_event(&dir, "user.created", "alice");
        consume_from_dir(&db.db, &db.key, &db.gate, &dir)
            .await
            .unwrap();
        let second_id = write_event(&dir, "user.created", "alice");
        consume_from_dir(&db.db, &db.key, &db.gate, &dir)
            .await
            .unwrap();

        let conn = db.db.lock().unwrap();
        let first_class: String = conn
            .query_row(
                "SELECT error_class FROM wecom_deliveries WHERE event_id = ?1",
                params![first_id],
                |row| row.get(0),
            )
            .unwrap();
        let second_class: String = conn
            .query_row(
                "SELECT error_class FROM wecom_deliveries WHERE event_id = ?1",
                params![second_id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(first_class, "configuration_error");
        assert_eq!(second_class, "throttled_5m");
    }

    #[test]
    fn throttle_reservation_expires_after_five_minutes() {
        let conn = Connection::open_in_memory().unwrap();
        spool_store::ensure_schema(&conn).unwrap();
        assert!(spool_store::reserve_wecom_slot(&conn, "user.created", "alice", 1000).unwrap());
        assert!(!spool_store::reserve_wecom_slot(&conn, "user.created", "alice", 1299).unwrap());
        assert!(spool_store::reserve_wecom_slot(&conn, "user.created", "alice", 1300).unwrap());
        assert!(spool_store::reserve_wecom_slot(&conn, "user.disabled", "alice", 1301).unwrap());
        assert!(spool_store::reserve_wecom_slot(&conn, "user.created", "bob", 1301).unwrap());
    }
}
