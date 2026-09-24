//! Web application WeCom configuration and fixed-template test delivery.
//!
//! The webhook is accepted only as the canonical Tencent endpoint, encrypted
//! before it reaches SQLite, and never returned or included in logs/audit.

use std::time::Duration;

use axum::extract::{Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post, put};
use axum::Json;
use reqwest::redirect::Policy;
use reqwest::Client;
use serde::Deserialize;
use serde_json::{json, Value};
use url::Url;

use crate::auth::guard::authenticate;
use crate::error::ApiError;
use crate::state::SharedState;
use crate::store::wecom::{self, Delivery, Settings};

const EVENT_CATALOG: &[&str] = &["user.created", "user.disabled"];
const MAX_WEBHOOK_BYTES: usize = 512;
const MAX_RESPONSE_BYTES: usize = 16 * 1024;
const MAX_ATTEMPTS: i64 = 3;

fn bad(message: &'static str) -> ApiError {
    ApiError::BadRequest(message.to_string())
}

fn internal() -> ApiError {
    ApiError::Internal("internal".to_string())
}

fn now_unix() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or(0)
}

/// Strict parser for the one outbound destination this feature can contact.
/// Returns the validated URL without exposing parse errors (which may contain it).
fn validate_webhook(input: &str) -> Result<Url, ApiError> {
    if input.len() > MAX_WEBHOOK_BYTES || input.trim() != input || input.is_empty() {
        return Err(bad("invalid WeCom webhook URL"));
    }
    let url = Url::parse(input).map_err(|_| bad("invalid WeCom webhook URL"))?;
    let has_userinfo = input
        .split_once("://")
        .and_then(|(_, remainder)| remainder.split(['/', '?', '#']).next())
        .map(|authority| authority.contains('@'))
        .unwrap_or(true);
    if url.scheme() != "https"
        || url.host_str() != Some("qyapi.weixin.qq.com")
        || !matches!(url.port(), None | Some(443))
        || url.path() != "/cgi-bin/webhook/send"
        || has_userinfo
        || !url.username().is_empty()
        || url.password().is_some()
        || url.fragment().is_some()
    {
        return Err(bad("invalid WeCom webhook URL"));
    }

    // Do not accept encoded delimiters, extra parameters, or alternate keys.
    let query = url
        .query()
        .ok_or_else(|| bad("invalid WeCom webhook URL"))?;
    let key = query
        .strip_prefix("key=")
        .filter(|value| !value.contains(['&', '%', '+', '#']))
        .ok_or_else(|| bad("invalid WeCom webhook URL"))?;
    if !(1..=128).contains(&key.len())
        || !key
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
    {
        return Err(bad("invalid WeCom webhook URL"));
    }
    Ok(url)
}

fn read_settings(state: &SharedState) -> Result<Option<Settings>, ApiError> {
    let conn = state.db.lock().map_err(|_| internal())?;
    wecom::get_settings(&conn).map_err(|_| internal())
}

fn events_from_json(raw: &str) -> Vec<String> {
    serde_json::from_str::<Vec<String>>(raw)
        .unwrap_or_default()
        .into_iter()
        .filter(|event| EVENT_CATALOG.contains(&event.as_str()))
        .collect()
}

fn settings_response(settings: Option<Settings>) -> Value {
    match settings {
        Some(settings) => json!({
            "enabled": settings.enabled,
            "dry_run": settings.dry_run,
            "webhook_configured": settings.webhook_ciphertext.is_some(),
            "webhook_masked": if settings.webhook_ciphertext.is_some() {
                Some("https://qyapi.weixin.qq.com/...key=***")
            } else {
                None
            },
            "events": events_from_json(&settings.events_json),
            "event_catalog": EVENT_CATALOG,
            "updated_at": settings.updated_at,
            "updated_by": settings.updated_by,
            "version": settings.version,
        }),
        None => json!({
            "enabled": false,
            "dry_run": false,
            "webhook_configured": false,
            "webhook_masked": null,
            "events": [],
            "event_catalog": EVENT_CATALOG,
            "updated_at": 0,
            "updated_by": "",
            "version": 0,
        }),
    }
}

async fn get_settings(
    State(state): State<SharedState>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let auth = authenticate(&state, &headers)?;
    auth.require("wecom.manage")?;
    let settings = read_settings(&state)?;
    Ok(Json(json!({ "ok": true, "data": settings_response(settings) })).into_response())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PutSettings {
    enabled: bool,
    dry_run: bool,
    /// Omitted or null means preserve the encrypted value already stored.
    webhook: Option<String>,
    events: Vec<String>,
    version: i64,
}

async fn put_settings(
    State(state): State<SharedState>,
    headers: HeaderMap,
    Json(body): Json<PutSettings>,
) -> Result<Response, ApiError> {
    let auth = authenticate(&state, &headers)?;
    auth.require("wecom.manage")?;
    if body.version < 0 {
        return Err(bad("invalid version"));
    }
    if body.events.len() > EVENT_CATALOG.len() {
        return Err(bad("unknown WeCom event"));
    }
    let mut unique_events = std::collections::BTreeSet::new();
    for event in &body.events {
        if !EVENT_CATALOG.contains(&event.as_str()) || !unique_events.insert(event) {
            return Err(bad("unknown or duplicate WeCom event"));
        }
    }

    let old_settings = read_settings(&state)?;
    let old_version = old_settings
        .as_ref()
        .map(|settings| settings.version)
        .unwrap_or(0);
    if old_version != body.version {
        return Ok(conflict_response());
    }

    let webhook_ciphertext = match body.webhook.as_deref() {
        Some(webhook) => {
            // Validate before encryption; only opaque ciphertext enters SQLite.
            validate_webhook(webhook)?;
            Some(crate::crypto::encrypt_str(&state.master_key, webhook).ok_or_else(internal)?)
        }
        None => old_settings
            .as_ref()
            .and_then(|settings| settings.webhook_ciphertext.clone()),
    };

    if body.enabled && !body.dry_run && webhook_ciphertext.is_none() {
        return Err(bad("a webhook is required for live delivery"));
    }

    let events_json = serde_json::to_string(&body.events).map_err(|_| internal())?;
    let conn = state.db.lock().map_err(|_| internal())?;
    let saved = wecom::save_settings(
        &conn,
        &wecom::SettingsUpdate {
            expected_version: body.version,
            enabled: body.enabled,
            dry_run: body.dry_run,
            webhook_ciphertext: webhook_ciphertext.as_deref(),
            events_json: &events_json,
            updated_at: now_unix(),
            updated_by: &auth.user_id,
        },
    )
    .map_err(|_| internal())?;
    drop(conn);
    if !saved {
        return Ok(conflict_response());
    }

    audit(&state, &auth.user_id, "PUT", "settings.wecom", "success");
    let settings = read_settings(&state)?;
    Ok(Json(json!({ "ok": true, "data": settings_response(settings) })).into_response())
}

fn conflict_response() -> Response {
    (
        StatusCode::CONFLICT,
        Json(json!({
            "ok": false,
            "error": { "code": "VERSION_CONFLICT", "message": "settings changed; reload and retry" }
        })),
    )
        .into_response()
}

fn audit(state: &SharedState, user_id: &str, method: &str, route: &str, result: &str) {
    // Only fixed route and result labels enter audit; never include request values.
    if let Ok(conn) = state.db.lock() {
        let _ = conn.execute(
            "INSERT INTO web_audit (ts, web_user_id, method, route_name, capability, target, result)
             VALUES (?1, ?2, ?3, ?4, 'wecom.manage', 'wecom', ?5)",
            rusqlite::params![now_unix(), user_id, method, route, result],
        );
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct DeliveryQuery {
    limit: Option<usize>,
}

async fn delivery_history(
    State(state): State<SharedState>,
    headers: HeaderMap,
    Query(query): Query<DeliveryQuery>,
) -> Result<Response, ApiError> {
    let auth = authenticate(&state, &headers)?;
    auth.require("wecom.manage")?;
    let limit = query.limit.unwrap_or(50);
    if !(1..=100).contains(&limit) {
        return Err(bad("limit must be between 1 and 100"));
    }
    let conn = state.db.lock().map_err(|_| internal())?;
    let deliveries = wecom::list_deliveries(&conn, limit).map_err(|_| internal())?;
    let items: Vec<Value> = deliveries.iter().map(delivery_json).collect();
    Ok(Json(json!({ "ok": true, "data": { "deliveries": items } })).into_response())
}

fn delivery_json(delivery: &Delivery) -> Value {
    json!({
        "id": delivery.id,
        "event_id": delivery.event_id,
        "channel": "wecom",
        "attempt": delivery.attempt,
        "started_at": delivery.started_at,
        "finished_at": delivery.finished_at,
        "http_status": delivery.http_status,
        "remote_code": delivery.remote_code,
        "success": delivery.success,
        "error_class": delivery.error_class,
    })
}

async fn test_send(
    State(state): State<SharedState>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let auth = authenticate(&state, &headers)?;
    auth.require("wecom.manage")?;
    let settings = read_settings(&state)?.ok_or_else(|| bad("WeCom is not configured"))?;
    if !settings.enabled {
        return Err(bad("WeCom delivery is disabled"));
    }

    // Bound both repeated requests per user and concurrent outbound work. The
    // shared limiter permits five test sends per minute; the semaphore ensures
    // one bounded retry sequence can be active at a time.
    let _test_permit = state
        .wecom_test_gate
        .clone()
        .try_acquire_owned()
        .map_err(|_| ApiError::RateLimited)?;
    let rate_key = format!("wecom-test|{}", auth.user_id);
    if state.rate_limiter.hit(&rate_key).is_err() {
        return Err(ApiError::RateLimited);
    }

    let delivery_group_id = uuid::Uuid::new_v4().to_string();
    if settings.dry_run {
        let at = now_unix();
        persist_delivery(
            &state,
            &Delivery {
                id: uuid::Uuid::new_v4().to_string(),
                event_id: format!("notification.test:{delivery_group_id}"),
                attempt: 0,
                started_at: at,
                finished_at: at,
                http_status: None,
                remote_code: None,
                success: false,
                error_class: Some("dry_run".into()),
            },
        )?;
        audit(
            &state,
            &auth.user_id,
            "POST",
            "settings.wecom.test",
            "dry_run",
        );
        return Ok(Json(json!({
            "ok": true,
            "data": { "status": "DRY_RUN", "delivery_id": delivery_group_id, "attempts": 0 }
        }))
        .into_response());
    }

    let ciphertext = settings
        .webhook_ciphertext
        .as_deref()
        .ok_or_else(|| bad("a webhook is required for live delivery"))?;
    let webhook = crate::crypto::decrypt_str(&state.master_key, ciphertext).ok_or_else(internal)?;
    let url = validate_webhook(&webhook)?;
    // The secret-bearing String is needed only to form this request. It is never
    // formatted, traced, audited, or returned.
    let outcomes = send_fixed_test(&url, &delivery_group_id).await;
    for outcome in &outcomes {
        persist_delivery(&state, outcome)?;
    }
    let success = outcomes.last().is_some_and(|delivery| delivery.success);
    audit(
        &state,
        &auth.user_id,
        "POST",
        "settings.wecom.test",
        if success { "success" } else { "failed" },
    );
    let attempts = outcomes.len();
    let error_class = outcomes
        .last()
        .and_then(|delivery| delivery.error_class.clone());
    Ok(Json(json!({
        "ok": true,
        "data": {
            "status": if success { "SUCCESS" } else { "FAILED" },
            "delivery_id": delivery_group_id,
            "attempts": attempts,
            "error_class": error_class,
        }
    }))
    .into_response())
}

fn persist_delivery(state: &SharedState, delivery: &Delivery) -> Result<(), ApiError> {
    let conn = state.db.lock().map_err(|_| internal())?;
    wecom::insert_delivery(&conn, delivery).map_err(|_| internal())
}

async fn send_fixed_test(url: &Url, event_id: &str) -> Vec<Delivery> {
    let client = match Client::builder()
        .redirect(Policy::none())
        .no_proxy()
        .connect_timeout(Duration::from_secs(3))
        .timeout(Duration::from_secs(8))
        .build()
    {
        Ok(client) => client,
        Err(_) => {
            let started_at = now_unix();
            return vec![failed_delivery(
                event_id,
                1,
                started_at,
                None,
                None,
                "client_error",
            )];
        }
    };

    let timestamp = time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap_or_else(|_| now_unix().to_string());
    let payload = json!({
        "msgtype": "text",
        "text": {
            "content": format!(
                "[User Manager] 企业微信测试\n状态: OK\n来源: Web Console\n时间: {timestamp}"
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
                event_id,
                attempt,
                started_at,
                None,
                None,
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
                    failed_delivery(
                        event_id,
                        attempt,
                        started_at,
                        Some(status.as_u16() as i64),
                        None,
                        error_class,
                    )
                } else if too_large {
                    failed_delivery(
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
        if outcomes.last().is_some_and(|delivery| delivery.success) || !retryable {
            break;
        }
        if attempt < MAX_ATTEMPTS {
            // 200 ms, then 400 ms: bounded exponential backoff.
            let backoff_ms = 200_u64.saturating_mul(1_u64 << (attempt as u32 - 1));
            tokio::time::sleep(Duration::from_millis(backoff_ms)).await;
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

fn failed_delivery(
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

pub fn read_router() -> axum::Router<SharedState> {
    axum::Router::new()
        .route("/api/settings/wecom", get(get_settings))
        .route("/api/settings/wecom/deliveries", get(delivery_history))
}

pub fn mutating_router() -> axum::Router<SharedState> {
    axum::Router::new()
        .route("/api/settings/wecom", put(put_settings))
        .route("/api/settings/wecom/test", post(test_send))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_only_the_fixed_webhook_endpoint_and_single_key() {
        assert!(
            validate_webhook("https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=abc_123-Z")
                .is_ok()
        );
        for invalid in [
            "http://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=abc",
            "https://example.com/cgi-bin/webhook/send?key=abc",
            "https://user@qyapi.weixin.qq.com/cgi-bin/webhook/send?key=abc",
            "https://qyapi.weixin.qq.com/other?key=abc",
            "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=abc&x=y",
            "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=abc%26x",
            "https://@qyapi.weixin.qq.com/cgi-bin/webhook/send?key=abc",
            "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=",
        ] {
            assert!(validate_webhook(invalid).is_err(), "accepted {invalid}");
        }
    }

    #[test]
    fn success_requires_http_success_and_numeric_zero_errcode() {
        for (status, body, expected) in [
            (200, br#"{"errcode":0}"#.as_slice(), true),
            (200, br#"{"errcode":1}"#.as_slice(), false),
            (200, br#"{}"#.as_slice(), false),
            (503, br#"{"errcode":0}"#.as_slice(), false),
        ] {
            let status = reqwest::StatusCode::from_u16(status).unwrap();
            let remote = serde_json::from_slice::<Value>(body)
                .ok()
                .and_then(|value| value.get("errcode").and_then(Value::as_i64));
            assert_eq!(status.is_success() && remote == Some(0), expected);
        }
    }

    #[test]
    fn retry_policy_retries_only_network_timeout_429_and_server_errors() {
        let delivery = |http_status, error_class: Option<&str>| Delivery {
            id: "d".into(),
            event_id: "e".into(),
            attempt: 1,
            started_at: 1,
            finished_at: 1,
            http_status,
            remote_code: None,
            success: false,
            error_class: error_class.map(str::to_string),
        };
        assert!(is_retryable(&delivery(None, Some("network"))));
        assert!(is_retryable(&delivery(None, Some("timeout"))));
        assert!(is_retryable(&delivery(Some(429), Some("http_error"))));
        assert!(is_retryable(&delivery(Some(503), Some("http_error"))));
        assert!(!is_retryable(&delivery(Some(400), Some("http_error"))));
        assert!(!is_retryable(&delivery(Some(401), Some("timeout"))));
        assert!(!is_retryable(&delivery(
            Some(200),
            Some("invalid_response")
        )));
        assert!(!is_retryable(&delivery(Some(200), Some("remote_error"))));
    }
}
