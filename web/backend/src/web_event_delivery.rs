//! Delivery loop for Web-originated inbox events.
//!
//! This outbox is independent of the privileged root-to-Web event spool. It
//! reads only notification ids/types/timestamps and creates outbound content
//! from fixed templates; notification text and targets are never transmitted.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use reqwest::redirect::Policy;
use reqwest::Client;
use rusqlite::Connection;
use serde_json::{json, Value};
use tokio::sync::Semaphore;
use url::Url;

use crate::crypto;
use crate::store::web_event_delivery as delivery_store;
use crate::store::wecom::{self, Delivery};

const POLL_INTERVAL: Duration = Duration::from_secs(30);
const MAX_PENDING_PER_POLL: usize = 32;
const MAX_RESPONSE_BYTES: usize = 16 * 1024;
const MAX_ATTEMPTS: i64 = 3;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum NativeEvent {
    LoginFailed,
    TokenRevoked,
    SnapshotFreshnessChanged,
}

impl NativeEvent {
    fn from_str(value: &str) -> Option<Self> {
        match value {
            "security.login_failed" => Some(Self::LoginFailed),
            "security.token_revoked" => Some(Self::TokenRevoked),
            "snapshot.freshness_changed" => Some(Self::SnapshotFreshnessChanged),
            _ => None,
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::LoginFailed => "security.login_failed",
            Self::TokenRevoked => "security.token_revoked",
            Self::SnapshotFreshnessChanged => "snapshot.freshness_changed",
        }
    }

    fn message(self) -> &'static str {
        match self {
            Self::LoginFailed => "Login credential verification failed.",
            Self::TokenRevoked => "An API token was revoked.",
            Self::SnapshotFreshnessChanged => "Snapshot freshness changed.",
        }
    }
}

/// Ensure the native-event outbox schema exists before serving requests.
pub fn initialize(db: &Arc<Mutex<Connection>>) -> Result<(), String> {
    let conn = db
        .lock()
        .map_err(|_| "database lock poisoned".to_string())?;
    delivery_store::ensure_schema(&conn).map_err(|_| "native event schema unavailable".to_string())
}

/// Periodically enqueue and deliver only allowlisted Web inbox events.
pub async fn run(
    db: Arc<Mutex<Connection>>,
    master_key: [u8; crypto::KEY_LEN],
    outbound_gate: Arc<Semaphore>,
) {
    let mut interval = tokio::time::interval(POLL_INTERVAL);
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        interval.tick().await;
        if let Err(error) = deliver_once(&db, &master_key, &outbound_gate).await {
            tracing::warn!(error = %error, "native Web event delivery pass failed");
        }
    }
}

/// Run one bounded pass. The queue is in Web's database and does not access
/// or mutate the root-owned spool.
pub async fn deliver_once(
    db: &Arc<Mutex<Connection>>,
    master_key: &[u8; crypto::KEY_LEN],
    outbound_gate: &Arc<Semaphore>,
) -> Result<usize, String> {
    let _permit = outbound_gate
        .clone()
        .acquire_owned()
        .await
        .map_err(|_| "outbound gate closed".to_string())?;

    let pending = {
        let conn = db
            .lock()
            .map_err(|_| "database lock poisoned".to_string())?;
        delivery_store::pending_records(&conn)
            .map_err(|_| "native event queue unavailable".to_string())?
            .into_iter()
            .take(MAX_PENDING_PER_POLL)
            .collect::<Vec<_>>()
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
    record: &delivery_store::Record,
) -> Result<(), String> {
    let Some(kind) = NativeEvent::from_str(&record.event_type) else {
        return set_status(db, &record.notification_id, "failed");
    };
    let settings = {
        let conn = db
            .lock()
            .map_err(|_| "database lock poisoned".to_string())?;
        wecom::get_settings(&conn).map_err(|_| "WeCom settings unavailable".to_string())?
    };
    let settings = match settings {
        Some(settings) if settings.enabled => settings,
        _ => return set_status(db, &record.notification_id, "disabled"),
    };
    let selected_events =
        serde_json::from_str::<Vec<String>>(&settings.events_json).unwrap_or_default();
    if !selected_events.iter().any(|event| event == kind.as_str()) {
        return set_status(db, &record.notification_id, "not_selected");
    }

    if settings.dry_run {
        insert_delivery(db, &dry_run_delivery(&record.delivery_id))?;
        return set_status(db, &record.notification_id, "dry_run");
    }

    let now = now_unix();
    let reserved = {
        let conn = db
            .lock()
            .map_err(|_| "database lock poisoned".to_string())?;
        delivery_store::reserve_wecom_slot(&conn, kind.as_str(), now)
            .map_err(|_| "native event throttle unavailable".to_string())?
    };
    if !reserved {
        insert_delivery(
            db,
            &non_network_delivery(&record.delivery_id, "throttled_5m"),
        )?;
        return set_status(db, &record.notification_id, "throttled");
    }

    let Some(webhook) = settings
        .webhook_ciphertext
        .as_deref()
        .and_then(|ciphertext| crypto::decrypt_str(master_key, ciphertext))
        .and_then(|value| crate::event_spool::validate_webhook(&value).map(|url| (value, url)))
    else {
        insert_delivery(
            db,
            &failed_delivery(&record.delivery_id, 1, "configuration_error"),
        )?;
        return set_status(db, &record.notification_id, "failed");
    };

    // The payload is synthesized from the enum only. No inbox title, summary,
    // target, event id, username, IP, token, password, or arbitrary detail can
    // flow into the external request.
    let payload = fixed_payload(kind);
    let outcomes = send_payload(&webhook.1, &record.delivery_id, &payload).await;
    for outcome in &outcomes {
        insert_delivery(db, outcome)?;
    }
    let status = if outcomes.iter().any(|outcome| outcome.success) {
        "sent"
    } else {
        "failed"
    };
    let _ = webhook.0;
    set_status(db, &record.notification_id, status)
}

fn fixed_payload(kind: NativeEvent) -> Value {
    json!({
        "msgtype": "text",
        "text": { "content": format!("[User Manager] {}", kind.message()) }
    })
}

fn set_status(
    db: &Arc<Mutex<Connection>>,
    notification_id: &str,
    status: &str,
) -> Result<(), String> {
    let conn = db
        .lock()
        .map_err(|_| "database lock poisoned".to_string())?;
    delivery_store::set_status(&conn, notification_id, status)
        .map_err(|_| "native event status update failed".to_string())
}

fn insert_delivery(db: &Arc<Mutex<Connection>>, delivery: &Delivery) -> Result<(), String> {
    let conn = db
        .lock()
        .map_err(|_| "database lock poisoned".to_string())?;
    wecom::insert_delivery(&conn, delivery).map_err(|_| "delivery history write failed".to_string())
}

async fn send_payload(url: &Url, event_id: &str, payload: &Value) -> Vec<Delivery> {
    let client = match Client::builder()
        .redirect(Policy::none())
        .no_proxy()
        .connect_timeout(Duration::from_secs(3))
        .timeout(Duration::from_secs(8))
        .build()
    {
        Ok(client) => client,
        Err(_) => return vec![failed_delivery(event_id, 1, "client_error")],
    };

    let mut outcomes = Vec::with_capacity(MAX_ATTEMPTS as usize);
    for attempt in 1..=MAX_ATTEMPTS {
        let started_at = now_unix();
        let response = client
            .post(url.clone())
            .header(reqwest::header::CONTENT_TYPE, "application/json")
            .json(payload)
            .send()
            .await;
        let delivery = match response {
            Err(error) => failed_delivery(
                event_id,
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
                        event_id,
                        attempt,
                        started_at,
                        Some(status.as_u16() as i64),
                        None,
                        error_class,
                    )
                } else if too_large {
                    failed_http_delivery(
                        event_id,
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
                        event_id: event_id.to_string(),
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
        if outcomes.last().is_some_and(|outcome| outcome.success) || !retryable {
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
    non_network_delivery(event_id, "dry_run")
}

fn non_network_delivery(event_id: &str, error_class: &str) -> Delivery {
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
        error_class: Some(error_class.to_string()),
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
    use crate::store::notification::{self, NotificationIn};
    use crate::store::wecom::SettingsUpdate;

    fn delivery(http_status: Option<i64>, error_class: Option<&str>, success: bool) -> Delivery {
        Delivery {
            id: uuid::Uuid::new_v4().to_string(),
            event_id: uuid::Uuid::new_v4().to_string(),
            attempt: 1,
            started_at: now_unix(),
            finished_at: now_unix(),
            http_status,
            remote_code: None,
            success,
            error_class: error_class.map(str::to_string),
        }
    }

    #[test]
    fn templates_are_fixed_and_independent_of_notification_details() {
        for (event_type, expected) in [
            (
                "security.login_failed",
                "[User Manager] Login credential verification failed.",
            ),
            (
                "security.token_revoked",
                "[User Manager] An API token was revoked.",
            ),
            (
                "snapshot.freshness_changed",
                "[User Manager] Snapshot freshness changed.",
            ),
        ] {
            let kind = NativeEvent::from_str(event_type).unwrap();
            assert_eq!(fixed_payload(kind)["text"]["content"], expected);
            assert!(NativeEvent::from_str("host.offline").is_none());
        }
        let serialized = fixed_payload(NativeEvent::TokenRevoked).to_string();
        for secret in ["alice", "192.0.2.7", "token-secret", "password-secret"] {
            assert!(!serialized.contains(secret));
        }
    }

    #[test]
    fn retries_only_network_timeout_rate_limit_and_server_errors() {
        for delivery in [
            delivery(None, Some("network"), false),
            delivery(None, Some("timeout"), false),
            delivery(Some(429), Some("http_error"), false),
            delivery(Some(500), Some("http_error"), false),
            delivery(Some(503), Some("response_too_large"), false),
        ] {
            assert!(is_retryable(&delivery));
        }
        for delivery in [
            delivery(Some(200), None, true),
            delivery(Some(200), Some("invalid_response"), false),
            delivery(Some(200), Some("remote_error"), false),
            delivery(Some(200), Some("response_too_large"), false),
            delivery(Some(400), Some("http_error"), false),
            delivery(Some(403), Some("http_error"), false),
        ] {
            assert!(!is_retryable(&delivery));
        }
    }

    #[tokio::test]
    async fn dry_run_delivers_native_events_to_history_without_network_or_sensitive_ids() {
        let conn = Connection::open_in_memory().unwrap();
        crate::store::init_schema(&conn).unwrap();
        let db = Arc::new(Mutex::new(conn));
        initialize(&db).unwrap();
        {
            let conn = db.lock().unwrap();
            let webhook = "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=dummy";
            let encrypted = crypto::encrypt_str(&[0x4c; crypto::KEY_LEN], webhook).unwrap();
            assert!(wecom::save_settings(
                &conn,
                &SettingsUpdate {
                    expected_version: 0,
                    enabled: true,
                    dry_run: true,
                    webhook_ciphertext: Some(&encrypted),
                    events_json: r#"["security.login_failed","security.token_revoked","snapshot.freshness_changed"]"#,
                    updated_at: now_unix(),
                    updated_by: "test-admin",
                }
            )
            .unwrap());
            for (event_id, event_type, secret) in [
                (
                    "security.login_failed:123",
                    "security.login_failed",
                    "alice 192.0.2.7",
                ),
                (
                    "security.token_revoked:token-secret",
                    "security.token_revoked",
                    "token-secret",
                ),
                (
                    "snapshot.stale:event",
                    "snapshot.stale",
                    "internal snapshot detail",
                ),
            ] {
                notification::insert(
                    &conn,
                    &NotificationIn {
                        id: uuid::Uuid::new_v4().to_string(),
                        event_type: event_type.into(),
                        severity: "warning".into(),
                        title: format!("{secret} title"),
                        summary: format!("{secret} summary"),
                        target: Some(secret.into()),
                        source: Some("web".into()),
                        event_id: Some(event_id.into()),
                    },
                )
                .unwrap();
            }
        }

        let gate = Arc::new(Semaphore::new(1));
        assert_eq!(
            deliver_once(&db, &[0x4c; crypto::KEY_LEN], &gate)
                .await
                .unwrap(),
            3
        );
        let conn = db.lock().unwrap();
        let statuses: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM web_event_delivery_queue WHERE status = 'dry_run'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(statuses, 3);
        let (history_count, id): (i64, String) = conn
            .query_row(
                "SELECT COUNT(*), MIN(event_id) FROM wecom_deliveries",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(history_count, 3);
        assert!(!id.contains("token-secret"));
    }
}
