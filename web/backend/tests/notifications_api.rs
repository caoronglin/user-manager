//! P4c 集成覆盖：通知 inbox 的查询、游标、去重、权限和已读操作。

use axum::body::Body;
use axum::http::{header, HeaderMap, Method, Request, StatusCode};
use rusqlite::Connection;
use serde_json::Value;
use tower::ServiceExt;

use umweb::auth::password;
use umweb::config::Config;
use umweb::http::build_router;
use umweb::state::AppState;
use umweb::store::notification::{self, NotificationIn};
use umweb::store::user;

async fn make_app() -> (axum::Router, String) {
    let uniq = uuid::Uuid::new_v4();
    let snap = std::env::temp_dir().join(format!("umweb-ntf-snap-{uniq}"));
    std::fs::create_dir_all(&snap).unwrap();
    let db = std::env::temp_dir().join(format!("umweb-ntf-{uniq}.db"));
    let config = Config::for_tests(db.clone(), snap);
    let state = AppState::init(config).await.expect("state");
    {
        let conn = state.db.lock().unwrap();
        user::insert_user(
            &conn,
            "u-op",
            "op_user",
            "operator",
            &password::hash_password("oppass").unwrap(),
        )
        .unwrap();
        user::insert_user(
            &conn,
            "u-vw",
            "vw_user",
            "viewer",
            &password::hash_password("vwpass").unwrap(),
        )
        .unwrap();
        for (id, event_type, severity, event_id) in [
            ("ntf-1", "host.offline", "warning", "event-1"),
            ("ntf-2", "security.login_failed", "info", "event-2"),
            ("ntf-3", "host.recovered", "info", "event-3"),
        ] {
            assert!(notification::insert(
                &conn,
                &NotificationIn {
                    id: id.into(),
                    event_type: event_type.into(),
                    severity: severity.into(),
                    title: format!("[{event_type}]"),
                    summary: "synthetic notification".into(),
                    target: Some("compute-01".into()),
                    source: Some("local".into()),
                    event_id: Some(event_id.into()),
                }
            )
            .unwrap());
        }
    }
    (build_router(state), db.to_string_lossy().to_string())
}

async fn send(
    app: axum::Router,
    method: Method,
    uri: &str,
    json_body: Option<&str>,
    cookie: Option<&str>,
    csrf: Option<&str>,
) -> (StatusCode, String, HeaderMap) {
    let mut builder = Request::builder().method(method).uri(uri);
    if json_body.is_some() {
        builder = builder.header(header::CONTENT_TYPE, "application/json");
    }
    if let Some(cookie) = cookie {
        builder = builder.header(header::COOKIE, cookie);
    }
    if let Some(csrf) = csrf {
        builder = builder.header("x-csrf-token", csrf);
    }
    let request = builder
        .body(Body::from(json_body.unwrap_or_default().to_string()))
        .unwrap();
    let response = app.oneshot(request).await.unwrap();
    let status = response.status();
    let headers = response.headers().clone();
    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    (status, String::from_utf8_lossy(&body).to_string(), headers)
}

fn cookie_pair(headers: &HeaderMap, name: &str) -> String {
    headers
        .get_all(header::SET_COOKIE)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .find(|cookie| cookie.starts_with(&format!("{name}=")))
        .map(|cookie| cookie.split(';').next().unwrap_or_default().to_string())
        .unwrap_or_default()
}

fn cookie_value(headers: &HeaderMap, name: &str) -> String {
    cookie_pair(headers, name)
        .split_once('=')
        .map(|(_, value)| value.to_string())
        .unwrap_or_default()
}

async fn login(app: &axum::Router, username: &str, password: &str) -> (String, String) {
    let body = format!(r#"{{"username":"{username}","password":"{password}"}}"#);
    let (status, _body, headers) = send(
        app.clone(),
        Method::POST,
        "/api/auth/login",
        Some(&body),
        None,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    (
        cookie_pair(&headers, "umweb_session"),
        cookie_value(&headers, "umweb_csrf"),
    )
}

#[tokio::test]
async fn notification_list_filters_and_paginates_with_keyset_cursor() {
    let (app, _db) = make_app().await;
    let (cookie, csrf) = login(&app, "vw_user", "vwpass").await;

    let (status, body, _) = send(
        app.clone(),
        Method::GET,
        "/api/notifications?unread=true&limit=1",
        None,
        Some(&cookie),
        Some(&csrf),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let first: Value = serde_json::from_str(&body).unwrap();
    assert_eq!(first["data"]["items"].as_array().unwrap().len(), 1);
    assert_eq!(first["data"]["unread"], 3);
    assert!(first["data"]["next_cursor"].is_object());

    let cursor = &first["data"]["next_cursor"];
    let uri = format!(
        "/api/notifications?limit=1&cursor_ts={}&cursor_id={}",
        cursor["created_at"].as_i64().unwrap(),
        cursor["id"].as_str().unwrap()
    );
    let (status, body, _) = send(
        app.clone(),
        Method::GET,
        &uri,
        None,
        Some(&cookie),
        Some(&csrf),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let second: Value = serde_json::from_str(&body).unwrap();
    assert_eq!(second["data"]["items"].as_array().unwrap().len(), 1);
    assert_ne!(
        first["data"]["items"][0]["id"],
        second["data"]["items"][0]["id"]
    );

    let (status, body, _) = send(
        app.clone(),
        Method::GET,
        "/api/notifications?type=host.offline&limit=10",
        None,
        Some(&cookie),
        Some(&csrf),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let filtered: Value = serde_json::from_str(&body).unwrap();
    assert_eq!(filtered["data"]["items"].as_array().unwrap().len(), 1);
    assert_eq!(filtered["data"]["items"][0]["event_id"], "event-1");
    assert!(filtered["data"]["next_cursor"].is_null());

    for uri in [
        "/api/notifications?limit=201",
        "/api/notifications?unread=perhaps",
        "/api/notifications?cursor_ts=10",
    ] {
        let (status, _, _) = send(
            app.clone(),
            Method::GET,
            uri,
            None,
            Some(&cookie),
            Some(&csrf),
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{uri}");
    }
}

#[tokio::test]
async fn notification_access_requires_read_capability_and_manage_csrf() {
    let (app, _db) = make_app().await;
    let (status, _, _) = send(
        app.clone(),
        Method::GET,
        "/api/notifications",
        None,
        None,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    let (viewer_cookie, viewer_csrf) = login(&app, "vw_user", "vwpass").await;
    let (status, _, _) = send(
        app.clone(),
        Method::POST,
        "/api/notifications/read",
        Some(r#"{"id":"ntf-1"}"#),
        Some(&viewer_cookie),
        Some(&viewer_csrf),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    let (operator_cookie, operator_csrf) = login(&app, "op_user", "oppass").await;
    let (status, _, _) = send(
        app.clone(),
        Method::POST,
        "/api/notifications/read",
        Some(r#"{"id":"ntf-1"}"#),
        Some(&operator_cookie),
        None,
    )
    .await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "missing CSRF token must fail"
    );

    let (status, _, _) = send(
        app.clone(),
        Method::POST,
        "/api/notifications/read",
        Some(r#"{"id":"ntf-1"}"#),
        Some(&operator_cookie),
        Some(&operator_csrf),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    let (status, _, _) = send(
        app.clone(),
        Method::POST,
        "/api/notifications/read",
        Some(r#"{"id":"missing"}"#),
        Some(&operator_cookie),
        Some(&operator_csrf),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    let (status, body, _) = send(
        app.clone(),
        Method::POST,
        "/api/notifications/read-all",
        None,
        Some(&operator_cookie),
        Some(&operator_csrf),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let updated: Value = serde_json::from_str(&body).unwrap();
    assert_eq!(updated["data"]["updated"], 2);

    let (status, body, _) = send(
        app.clone(),
        Method::GET,
        "/api/notifications/unread-count",
        None,
        Some(&operator_cookie),
        Some(&operator_csrf),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let count: Value = serde_json::from_str(&body).unwrap();
    assert_eq!(count["data"]["unread"], 0);
}

#[tokio::test]
async fn notification_event_id_deduplicates_ingestion() {
    let (_app, db) = make_app().await;
    let conn = Connection::open(db).unwrap();
    let duplicate = NotificationIn {
        id: "ntf-duplicate".into(),
        event_type: "host.offline".into(),
        severity: "warning".into(),
        title: "duplicate event".into(),
        summary: "should not be inserted".into(),
        target: Some("compute-01".into()),
        source: Some("local".into()),
        event_id: Some("event-1".into()),
    };
    assert!(!notification::insert(&conn, &duplicate).unwrap());
    assert_eq!(notification::unread_count(&conn).unwrap(), 3);
}
