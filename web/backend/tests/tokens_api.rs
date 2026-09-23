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
