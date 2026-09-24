//! P4 WeCom integration coverage: secret-at-rest, no secret response, optimistic
//! updates, capability checks, fixed endpoint validation, dry-run and history.

use axum::body::Body;
use axum::http::{header, HeaderMap, Method, Request, StatusCode};
use rusqlite::Connection;
use serde_json::Value;
use tower::ServiceExt;

use umweb::auth::password;
use umweb::config::Config;
use umweb::http::build_router;
use umweb::state::AppState;
use umweb::store::user;

struct TestApp {
    router: axum::Router,
    db_path: std::path::PathBuf,
    master_key: [u8; umweb::crypto::KEY_LEN],
    wecom_test_gate: std::sync::Arc<tokio::sync::Semaphore>,
}

async fn make_app() -> TestApp {
    let uniq = uuid::Uuid::new_v4();
    let root = std::env::temp_dir().join(format!("umweb-wecom-{uniq}"));
    std::fs::create_dir_all(&root).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
    }
    let snap = root.join("snapshots");
    std::fs::create_dir_all(&snap).unwrap();
    let db_path = root.join("app.db");
    let config = Config::for_tests(db_path.clone(), snap);
    let state = AppState::init(config).await.expect("state");
    let master_key = state.master_key;
    let wecom_test_gate = state.wecom_test_gate.clone();
    {
        let conn = state.db.lock().unwrap();
        user::insert_user(
            &conn,
            "u-admin",
            "admin_user",
            "web_admin",
            &password::hash_password("adminpass").unwrap(),
        )
        .unwrap();
        user::insert_user(
            &conn,
            "u-viewer",
            "viewer_user",
            "viewer",
            &password::hash_password("viewerpass").unwrap(),
        )
        .unwrap();
    }
    TestApp {
        router: build_router(state),
        db_path,
        master_key,
        wecom_test_gate,
    }
}

async fn send(
    app: axum::Router,
    method: Method,
    uri: &str,
    body: Option<&str>,
    cookie: Option<&str>,
    csrf: Option<&str>,
) -> (StatusCode, String, HeaderMap) {
    let mut request = Request::builder().method(method).uri(uri);
    if body.is_some() {
        request = request.header(header::CONTENT_TYPE, "application/json");
    }
    if let Some(cookie) = cookie {
        request = request.header(header::COOKIE, cookie);
    }
    if let Some(csrf) = csrf {
        request = request.header("x-csrf-token", csrf);
    }
    let response = app
        .oneshot(
            request
                .body(Body::from(body.unwrap_or_default().to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status();
    let headers = response.headers().clone();
    let bytes = axum::body::to_bytes(response.into_body(), 1024 * 1024)
        .await
        .unwrap();
    (status, String::from_utf8_lossy(&bytes).to_string(), headers)
}

fn cookie_value(headers: &HeaderMap, name: &str) -> String {
    headers
        .get_all(header::SET_COOKIE)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .find(|cookie| cookie.starts_with(&format!("{name}=")))
        .and_then(|cookie| cookie.split(';').next())
        .and_then(|cookie| cookie.split_once('='))
        .map(|(_, value)| value.to_string())
        .unwrap_or_default()
}

async fn login(app: &axum::Router, username: &str, password: &str) -> (String, String) {
    let (status, _body, headers) = send(
        app.clone(),
        Method::POST,
        "/api/auth/login",
        Some(&format!(
            r#"{{"username":"{username}","password":"{password}"}}"#
        )),
        None,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    (
        format!("umweb_session={}", cookie_value(&headers, "umweb_session")),
        cookie_value(&headers, "umweb_csrf"),
    )
}

#[tokio::test]
async fn wecom_secret_is_encrypted_masked_and_updates_are_optimistic() {
    let app = make_app().await;
    let (cookie, csrf) = login(&app.router, "admin_user", "adminpass").await;
    let secret_url = "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=secret_key_123";
    let put = format!(
        r#"{{"enabled":true,"dry_run":true,"webhook":"{secret_url}","events":["user.created"],"version":0}}"#
    );
    let (status, body, _) = send(
        app.router.clone(),
        Method::PUT,
        "/api/settings/wecom",
        Some(&put),
        Some(&cookie),
        Some(&csrf),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert!(!body.contains("secret_key_123"));
    let value: Value = serde_json::from_str(&body).unwrap();
    assert_eq!(value["data"]["webhook_configured"], true);
    assert_eq!(
        value["data"]["webhook_masked"],
        "https://qyapi.weixin.qq.com/...key=***"
    );
    assert_eq!(
        value["data"]["event_catalog"],
        serde_json::json!(["user.created", "user.disabled"])
    );
    assert_eq!(value["data"]["version"], 1);

    let conn = Connection::open(&app.db_path).unwrap();
    let ciphertext: String = conn
        .query_row(
            "SELECT webhook_ciphertext FROM wecom_settings WHERE id = 1",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_ne!(ciphertext, secret_url);
    assert_eq!(
        umweb::crypto::decrypt_str(&app.master_key, &ciphertext).as_deref(),
        Some(secret_url)
    );
    drop(conn);

    let (status_get, get_body, _) = send(
        app.router.clone(),
        Method::GET,
        "/api/settings/wecom",
        None,
        Some(&cookie),
        None,
    )
    .await;
    assert_eq!(status_get, StatusCode::OK);
    assert!(!get_body.contains("secret_key_123"));

    // Omitted webhook retains ciphertext; stale version gets a 409.
    let update = r#"{"enabled":true,"dry_run":true,"events":["user.disabled"],"version":1}"#;
    let (status_update, update_body, _) = send(
        app.router.clone(),
        Method::PUT,
        "/api/settings/wecom",
        Some(update),
        Some(&cookie),
        Some(&csrf),
    )
    .await;
    assert_eq!(status_update, StatusCode::OK, "{update_body}");
    let (status_conflict, _conflict, _) = send(
        app.router.clone(),
        Method::PUT,
        "/api/settings/wecom",
        Some(update),
        Some(&cookie),
        Some(&csrf),
    )
    .await;
    assert_eq!(status_conflict, StatusCode::CONFLICT);
    let conn = Connection::open(&app.db_path).unwrap();
    let retained: String = conn
        .query_row(
            "SELECT webhook_ciphertext FROM wecom_settings WHERE id = 1",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(retained, ciphertext);
}

#[tokio::test]
async fn event_catalog_matches_worker_dispatcher_and_hides_undeliverable_legacy_events() {
    let app = make_app().await;
    let (cookie, csrf) = login(&app.router, "admin_user", "adminpass").await;
    let expected_catalog = serde_json::json!(["user.created", "user.disabled"]);

    let (status, body, _) = send(
        app.router.clone(),
        Method::GET,
        "/api/settings/wecom",
        None,
        Some(&cookie),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let initial: Value = serde_json::from_str(&body).unwrap();
    assert_eq!(initial["data"]["event_catalog"], expected_catalog);

    // These event classes are not accepted by the current spool dispatcher,
    // and the manual fixed-template test is not a subscription event.
    for unsupported in [
        "security.login_failed",
        "snapshot.stale",
        "host.offline",
        "notification.test",
    ] {
        let body = serde_json::json!({
            "enabled": false,
            "dry_run": true,
            "events": [unsupported],
            "version": 0,
        })
        .to_string();
        let (status, response, _) = send(
            app.router.clone(),
            Method::PUT,
            "/api/settings/wecom",
            Some(&body),
            Some(&cookie),
            Some(&csrf),
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{unsupported}: {response}");
    }

    let supported =
        r#"{"enabled":false,"dry_run":true,"events":["user.created","user.disabled"],"version":0}"#;
    let (status, body, _) = send(
        app.router.clone(),
        Method::PUT,
        "/api/settings/wecom",
        Some(supported),
        Some(&cookie),
        Some(&csrf),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");

    // Older settings may contain catalog entries from a previous, wider UI.
    // Keep them out of the API response so the frontend cannot resubmit them.
    let conn = Connection::open(&app.db_path).unwrap();
    conn.execute(
        "UPDATE wecom_settings SET events_json = ?1 WHERE id = 1",
        [r#"["security.login_failed","host.offline"]"#],
    )
    .unwrap();
    drop(conn);
    let (status, body, _) = send(
        app.router.clone(),
        Method::GET,
        "/api/settings/wecom",
        None,
        Some(&cookie),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let settings: Value = serde_json::from_str(&body).unwrap();
    assert_eq!(settings["data"]["event_catalog"], expected_catalog);
    assert_eq!(settings["data"]["events"], serde_json::json!([]));
}

#[tokio::test]
async fn dry_run_test_uses_fixed_message_and_records_bounded_history_without_network() {
    let app = make_app().await;
    let (cookie, csrf) = login(&app.router, "admin_user", "adminpass").await;
    let put = r#"{"enabled":true,"dry_run":true,"events":[],"version":0}"#;
    let (status, body, _) = send(
        app.router.clone(),
        Method::PUT,
        "/api/settings/wecom",
        Some(put),
        Some(&cookie),
        Some(&csrf),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");

    // Arbitrary input is ignored; the endpoint has no message parameter and
    // dry-run completes without a webhook configured or an outbound request.
    let (test_status, test_body, _) = send(
        app.router.clone(),
        Method::POST,
        "/api/settings/wecom/test",
        Some(r#"{"text":"attacker-controlled message"}"#),
        Some(&cookie),
        Some(&csrf),
    )
    .await;
    assert_eq!(test_status, StatusCode::OK, "{test_body}");
    assert!(test_body.contains("DRY_RUN"));
    assert!(!test_body.contains("attacker-controlled message"));

    let (history_status, history_body, _) = send(
        app.router.clone(),
        Method::GET,
        "/api/settings/wecom/deliveries?limit=20",
        None,
        Some(&cookie),
        None,
    )
    .await;
    assert_eq!(history_status, StatusCode::OK, "{history_body}");
    let history: Value = serde_json::from_str(&history_body).unwrap();
    assert_eq!(history["data"]["deliveries"].as_array().unwrap().len(), 1);
    assert_eq!(history["data"]["deliveries"][0]["error_class"], "dry_run");
    assert_eq!(history["data"]["deliveries"][0]["attempt"], 0);
}

#[tokio::test]
async fn wecom_test_send_is_rate_limited_and_single_flight() {
    let app = make_app().await;
    let (cookie, csrf) = login(&app.router, "admin_user", "adminpass").await;
    let put = r#"{"enabled":true,"dry_run":true,"events":[],"version":0}"#;
    let (status, body, _) = send(
        app.router.clone(),
        Method::PUT,
        "/api/settings/wecom",
        Some(put),
        Some(&cookie),
        Some(&csrf),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");

    let held = app.wecom_test_gate.clone().try_acquire_owned().unwrap();
    let (busy_status, _, _) = send(
        app.router.clone(),
        Method::POST,
        "/api/settings/wecom/test",
        None,
        Some(&cookie),
        Some(&csrf),
    )
    .await;
    assert_eq!(busy_status, StatusCode::TOO_MANY_REQUESTS);
    drop(held);

    for _ in 0..5 {
        let (status, body, _) = send(
            app.router.clone(),
            Method::POST,
            "/api/settings/wecom/test",
            None,
            Some(&cookie),
            Some(&csrf),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{body}");
    }
    let (limited_status, body, _) = send(
        app.router.clone(),
        Method::POST,
        "/api/settings/wecom/test",
        None,
        Some(&cookie),
        Some(&csrf),
    )
    .await;
    assert_eq!(limited_status, StatusCode::TOO_MANY_REQUESTS, "{body}");
}

#[tokio::test]
async fn wecom_routes_require_auth_capability_csrf_and_fixed_url() {
    let app = make_app().await;
    let (unauth, _body, _) = send(
        app.router.clone(),
        Method::GET,
        "/api/settings/wecom",
        None,
        None,
        None,
    )
    .await;
    assert_eq!(unauth, StatusCode::UNAUTHORIZED);

    let (viewer_cookie, viewer_csrf) = login(&app.router, "viewer_user", "viewerpass").await;
    let (forbidden, _body, _) = send(
        app.router.clone(),
        Method::GET,
        "/api/settings/wecom",
        None,
        Some(&viewer_cookie),
        None,
    )
    .await;
    assert_eq!(forbidden, StatusCode::FORBIDDEN);

    let (admin_cookie, admin_csrf) = login(&app.router, "admin_user", "adminpass").await;
    let bad_url = r#"{"enabled":true,"dry_run":false,"webhook":"https://127.0.0.1/cgi-bin/webhook/send?key=secret","events":[],"version":0}"#;
    let (bad_status, _bad_body, _) = send(
        app.router.clone(),
        Method::PUT,
        "/api/settings/wecom",
        Some(bad_url),
        Some(&admin_cookie),
        Some(&admin_csrf),
    )
    .await;
    assert_eq!(bad_status, StatusCode::BAD_REQUEST);

    let no_csrf = r#"{"enabled":false,"dry_run":false,"events":[],"version":0}"#;
    let (csrf_status, _csrf_body, _) = send(
        app.router.clone(),
        Method::PUT,
        "/api/settings/wecom",
        Some(no_csrf),
        Some(&admin_cookie),
        Some(&viewer_csrf),
    )
    .await;
    assert_eq!(csrf_status, StatusCode::FORBIDDEN);
}
