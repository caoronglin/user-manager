//! P4b 集成测试：API Token（hash-only、capability allowlist、过期、撤销）+ Bearer 认证。

use axum::body::Body;
use axum::http::{header, HeaderMap, Method, Request, StatusCode};
use rusqlite::Connection;
use serde_json::Value;
use tower::ServiceExt;

use umweb::auth::password;
use umweb::config::Config;
use umweb::http::build_router;
use umweb::state::AppState;
use umweb::store::token;
use umweb::store::user;

async fn make_app() -> (axum::Router, String) {
    let uniq = uuid::Uuid::new_v4();
    let snap = std::env::temp_dir().join(format!("umweb-tok-snap-{uniq}"));
    std::fs::create_dir_all(&snap).unwrap();
    let db = std::env::temp_dir().join(format!("umweb-tok-{uniq}.db"));
    let config = Config::for_tests(db.clone(), snap.clone());
    let state = AppState::init(config).await.expect("state");
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
    bearer: Option<&str>,
) -> (StatusCode, String, HeaderMap) {
    let mut b = Request::builder().method(method).uri(uri);
    if json_body.is_some() {
        b = b.header(header::CONTENT_TYPE, "application/json");
    }
    if let Some(c) = cookie {
        b = b.header(header::COOKIE, c);
    }
    if let Some(t) = csrf {
        b = b.header("x-csrf-token", t);
    }
    if let Some(tk) = bearer {
        b = b.header(header::AUTHORIZATION, format!("Bearer {tk}"));
    }
    let req = b
        .body(Body::from(json_body.unwrap_or("").to_string()))
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();
    let status = resp.status();
    let headers = resp.headers().clone();
    let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap();
    (status, String::from_utf8_lossy(&body).to_string(), headers)
}

fn cookie_pair(headers: &HeaderMap, name: &str) -> String {
    headers
        .get_all(header::SET_COOKIE)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .find(|c| c.starts_with(&format!("{name}=")))
        .map(|c| c.split(';').next().unwrap_or("").to_string())
        .unwrap_or_default()
}

fn cookie_value(headers: &HeaderMap, name: &str) -> String {
    cookie_pair(headers, name)
        .split_once('=')
        .map(|(_, v)| v.to_string())
        .unwrap_or_default()
}

#[tokio::test]
async fn token_create_list_revoke_and_bearer_auth() {
    let (app, _db) = make_app().await;
    let (_s, _b, ha) = send(
        app.clone(),
        Method::POST,
        "/api/auth/login",
        Some(r#"{"username":"admin_user","password":"adminpass"}"#),
        None,
        None,
        None,
    )
    .await;
    let ac = cookie_pair(&ha, "umweb_session");
    let acsrf = cookie_value(&ha, "umweb_csrf");

    // 未知 capability → 400
    let (s_bad, _b, _h) = send(
        app.clone(),
        Method::POST,
        "/api/api-tokens",
        Some(r#"{"name":"t1","capabilities":["root.evil"],"expire_days":30}"#),
        Some(&ac),
        Some(&acsrf),
        None,
    )
    .await;
    assert_eq!(s_bad, StatusCode::BAD_REQUEST);

    // API Tokens may not carry management permissions or perform writes.
    let (s_write_cap, _b, _h) = send(
        app.clone(),
        Method::POST,
        "/api/api-tokens",
        Some(r#"{"name":"writer","capabilities":["tokens.manage"],"expire_days":30}"#),
        Some(&ac),
        Some(&acsrf),
        None,
    )
    .await;
    assert_eq!(s_write_cap, StatusCode::BAD_REQUEST);

    // 创建 token：返回一次性明文
    let (s_ok, body, _h) = send(
        app.clone(),
        Method::POST,
        "/api/api-tokens",
        Some(r#"{"name":"reader","capabilities":["users.read","quota.read"],"expire_days":30}"#),
        Some(&ac),
        Some(&acsrf),
        None,
    )
    .await;
    assert_eq!(s_ok, StatusCode::CREATED);
    let v: Value = serde_json::from_str(&body).unwrap();
    let token = v["data"]["token"].as_str().unwrap().to_string();
    let tid = v["data"]["id"].as_str().unwrap().to_string();
    assert!(token.len() >= 40, "token should be long random");

    // 列表不含明文/hash
    let (_sl, lb, _hl) = send(
        app.clone(),
        Method::GET,
        "/api/api-tokens",
        None,
        Some(&ac),
        Some(&acsrf),
        None,
    )
    .await;
    assert!(
        !lb.contains(&token),
        "token plaintext must not appear in list"
    );
    assert!(lb.contains("reader"));

    // Bearer token 可用于只读 API（users.read）
    let (s_users, _b2, _h) = send(
        app.clone(),
        Method::GET,
        "/api/users",
        None,
        None,
        None,
        Some(&token),
    )
    .await;
    assert_eq!(s_users, StatusCode::OK);

    // Bearer token 访问未授权 capability → 403（audit.read not in token）
    let (s_audit, _b3, _h) = send(
        app.clone(),
        Method::GET,
        "/api/audit",
        None,
        None,
        None,
        Some(&token),
    )
    .await;
    assert_eq!(s_audit, StatusCode::FORBIDDEN);

    // 撤销后 Bearer 失效
    let (s_rev, _b, _h) = send(
        app.clone(),
        Method::DELETE,
        &format!("/api/api-tokens/{tid}"),
        None,
        Some(&ac),
        Some(&acsrf),
        None,
    )
    .await;
    assert_eq!(s_rev, StatusCode::NO_CONTENT);
    let (s_after, _b, _h) = send(
        app.clone(),
        Method::GET,
        "/api/users",
        None,
        None,
        None,
        Some(&token),
    )
    .await;
    assert_eq!(s_after, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn legacy_management_tokens_are_downgraded_to_read_only() {
    let (app, db) = make_app().await;
    let plaintext = "legacy-management-token";
    let token_hash = umweb::auth::csrf::sha256_hex(plaintext);
    let expires_at = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64
        + 3600;
    let conn = Connection::open(db).unwrap();
    token::insert_token(
        &conn,
        "legacy-id",
        "legacy-token",
        &token_hash,
        r#"["users.read","notifications.manage","tokens.manage"]"#,
        expires_at,
    )
    .unwrap();
    drop(conn);

    let (status, _, _) = send(
        app.clone(),
        Method::GET,
        "/api/users",
        None,
        None,
        None,
        Some(plaintext),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    let (status, _, _) = send(
        app.clone(),
        Method::POST,
        "/api/api-tokens",
        Some(r#"{"name":"escalated","capabilities":["users.read"],"expire_days":30}"#),
        None,
        None,
        Some(plaintext),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn token_revocation_emits_one_fixed_safe_notification_only_on_success() {
    let (app, db) = make_app().await;
    {
        let conn = Connection::open(&db).unwrap();
        user::insert_user(
            &conn,
            "u-viewer",
            "viewer_user",
            "viewer",
            &password::hash_password("viewerpass").unwrap(),
        )
        .unwrap();
    }

    let (_s, _b, admin_headers) = send(
        app.clone(),
        Method::POST,
        "/api/auth/login",
        Some(r#"{"username":"admin_user","password":"adminpass"}"#),
        None,
        None,
        None,
    )
    .await;
    let admin_cookie = cookie_pair(&admin_headers, "umweb_session");
    let admin_csrf = cookie_value(&admin_headers, "umweb_csrf");

    let (_s, _b, viewer_headers) = send(
        app.clone(),
        Method::POST,
        "/api/auth/login",
        Some(r#"{"username":"viewer_user","password":"viewerpass"}"#),
        None,
        None,
        None,
    )
    .await;
    let viewer_cookie = cookie_pair(&viewer_headers, "umweb_session");
    let viewer_csrf = cookie_value(&viewer_headers, "umweb_csrf");

    let (created, body, _) = send(
        app.clone(),
        Method::POST,
        "/api/api-tokens",
        Some(r#"{"name":"secret-token-name","capabilities":["users.read"],"expire_days":30}"#),
        Some(&admin_cookie),
        Some(&admin_csrf),
        None,
    )
    .await;
    assert_eq!(created, StatusCode::CREATED);
    let created: Value = serde_json::from_str(&body).unwrap();
    let token_plaintext = created["data"]["token"].as_str().unwrap().to_string();
    let token_id = created["data"]["id"].as_str().unwrap().to_string();
    let token_hash = umweb::auth::csrf::sha256_hex(&token_plaintext);

    // Anonymous and insufficiently privileged requests must not revoke or notify.
    let (anonymous, _, _) = send(
        app.clone(),
        Method::DELETE,
        &format!("/api/api-tokens/{token_id}"),
        None,
        None,
        None,
        None,
    )
    .await;
    assert_eq!(anonymous, StatusCode::UNAUTHORIZED);
    let (forbidden, _, _) = send(
        app.clone(),
        Method::DELETE,
        &format!("/api/api-tokens/{token_id}"),
        None,
        Some(&viewer_cookie),
        Some(&viewer_csrf),
        None,
    )
    .await;
    assert_eq!(forbidden, StatusCode::FORBIDDEN);

    {
        let conn = Connection::open(&db).unwrap();
        let revoked: i64 = conn
            .query_row(
                "SELECT revoked FROM api_tokens WHERE id = ?1",
                [&token_id],
                |row| row.get(0),
            )
            .unwrap();
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM notifications WHERE event_type = 'security.token_revoked'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(revoked, 0);
        assert_eq!(count, 0);
    }

    // A successful revocation creates one fixed notification without token,
    // username, or other request-specific values.
    let (revoked, _, _) = send(
        app.clone(),
        Method::DELETE,
        &format!("/api/api-tokens/{token_id}"),
        None,
        Some(&admin_cookie),
        Some(&admin_csrf),
        None,
    )
    .await;
    assert_eq!(revoked, StatusCode::NO_CONTENT);
    {
        let conn = Connection::open(&db).unwrap();
        let row: (
            String,
            String,
            String,
            String,
            Option<String>,
            Option<String>,
            Option<String>,
        ) = conn
            .query_row(
                "SELECT event_type, severity, title, summary, target, source, event_id
                 FROM notifications WHERE event_type = 'security.token_revoked'",
                [],
                |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                        row.get(5)?,
                        row.get(6)?,
                    ))
                },
            )
            .unwrap();
        assert_eq!(row.0, "security.token_revoked");
        assert_eq!(row.1, "warning");
        assert_eq!(row.2, "API token revoked");
        assert_eq!(row.3, "An API token was revoked.");
        assert_eq!(row.4, None);
        assert_eq!(row.5.as_deref(), Some("web"));
        assert_eq!(
            row.6.as_deref(),
            Some(format!("security.token_revoked:{token_id}").as_str())
        );
        let safe_fields = format!(
            "{} {} {} {:?} {:?} {:?} {:?}",
            row.0, row.1, row.2, row.3, row.4, row.5, row.6
        );
        assert!(!safe_fields.contains(&token_plaintext));
        assert!(!safe_fields.contains(&token_hash));
        assert!(!safe_fields.contains("admin_user"));
        assert!(!safe_fields.contains("viewer_user"));
    }

    // Repeating a successful request or naming an unknown token is a no-op for inbox.
    for id in [&token_id, "missing-token-id"] {
        let (status, _, _) = send(
            app.clone(),
            Method::DELETE,
            &format!("/api/api-tokens/{id}"),
            None,
            Some(&admin_cookie),
            Some(&admin_csrf),
            None,
        )
        .await;
        assert_eq!(status, StatusCode::NO_CONTENT);
    }
    let conn = Connection::open(&db).unwrap();
    let count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM notifications WHERE event_type = 'security.token_revoked'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(count, 1);
}
