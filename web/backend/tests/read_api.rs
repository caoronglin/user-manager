//! P2 只读系统 API 集成测试：
//! - 登录/会话 → capability 默认拒绝；
//! - 只读路由来自 Snapshot，附 freshness（fresh / stale / 缺失显式标识）；
//! - 危险写路由必须 404/405（不存在）；
//! - 减去 capability → 403，无会话 → 401。

use axum::body::Body;
use axum::http::{header, HeaderMap, Method, Request, StatusCode};
use tower::ServiceExt;

use umweb::auth::password;
use umweb::config::Config;
use umweb::http::build_router;
use umweb::state::AppState;
use umweb::store::user;

async fn make_app(seed: bool) -> (axum::Router, String) {
    let uniq = uuid::Uuid::new_v4();
    let snap = std::env::temp_dir().join(format!("umweb-p2-snap-{uniq}"));
    std::fs::create_dir_all(&snap).unwrap();
    let db = std::env::temp_dir().join(format!("umweb-p2-{uniq}.db"));
    let config = Config::for_tests(db, snap.clone());
    let state = AppState::init(config).await.expect("state");
    if seed {
        let conn = state.db.lock().unwrap();
        let vh = password::hash_password("viewerpass").unwrap();
        let ah = password::hash_password("adminpass").unwrap();
        user::insert_user(&conn, "u-view", "viewer_user", "viewer", &vh).unwrap();
        user::insert_user(&conn, "u-admin", "admin_user", "web_admin", &ah).unwrap();
    }
    (build_router(state), snap.to_string_lossy().to_string())
}

async fn send(
    app: axum::Router,
    method: Method,
    uri: &str,
    json_body: Option<&str>,
    cookie: Option<&str>,
) -> (StatusCode, String, HeaderMap) {
    let mut b = Request::builder().method(method).uri(uri);
    if json_body.is_some() {
        b = b.header(header::CONTENT_TYPE, "application/json");
    }
    if let Some(c) = cookie {
        b = b.header(header::COOKIE, c);
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

fn session_cookie_from(headers: &HeaderMap) -> String {
    headers
        .get_all(header::SET_COOKIE)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .find(|c| c.starts_with("umweb_session="))
        .map(|c| c.split(';').next().unwrap_or("").to_string())
        .unwrap_or_default()
}

fn csrf_cookie_from(headers: &HeaderMap) -> String {
    headers
        .get_all(header::SET_COOKIE)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .find(|cookie| cookie.starts_with("umweb_csrf="))
        .map(|cookie| {
            cookie["umweb_csrf=".len()..]
                .split(';')
                .next()
                .unwrap_or_default()
                .to_string()
        })
        .unwrap_or_default()
}

fn write_users_snapshot(dir: &str, generated_at: &str) {
    let env = serde_json::json!({
        "schema_version": 1,
        "protocol": "user-manager-snapshot-v1",
        "kind": "users",
        "generator": "user-manager",
        "source": "local",
        "generated_at": generated_at,
        "threshold_seconds": 300,
        "data": { "users": [ {"username":"alice","home":"/mnt/data01/alice","mountpoint":"/mnt/data01"} ], "count": 1 }
    });
    std::fs::write(
        format!("{dir}/users.json"),
        serde_json::to_vec_pretty(&env).unwrap(),
    )
    .unwrap();
}

#[tokio::test]
async fn read_users_requires_auth() {
    let (app, _snap) = make_app(true).await;
    let (status, _, _) = send(app, Method::GET, "/api/users", None, None).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn login_then_read_users_fresh() {
    let (app, snap) = make_app(true).await;
    // 写入一个新鲜的 users 快照。
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let gen = timestamp_rfc3339(now as i64);
    write_users_snapshot(&snap, &gen);

    let (status, _b, headers) = send(
        app.clone(),
        Method::POST,
        "/api/auth/login",
        Some(r#"{"username":"viewer_user","password":"viewerpass"}"#),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "login should succeed");
    let cookie = session_cookie_from(&headers);
    assert!(cookie.starts_with("umweb_session="), "session cookie set");

    let (status, body, _) = send(app.clone(), Method::GET, "/api/users", None, Some(&cookie)).await;
    assert_eq!(status, StatusCode::OK);
    let v: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(v["data"]["users"][0]["username"], "alice");
    assert_eq!(v["meta"]["freshness"]["present"], true);
    assert_eq!(v["meta"]["freshness"]["fresh"], true);
    assert_eq!(v["meta"]["freshness"]["stale"], false);
}

#[tokio::test]
async fn stale_and_missing_snapshot_are_flagged() {
    let (app, snap) = make_app(true).await;
    // stale：10 分钟前。
    let old = timestamp_rfc3339(
        (std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs()
            - 600) as i64,
    );
    write_users_snapshot(&snap, &old);

    let (_s, _b, headers) = send(
        app.clone(),
        Method::POST,
        "/api/auth/login",
        Some(r#"{"username":"viewer_user","password":"viewerpass"}"#),
        None,
    )
    .await;
    let cookie = session_cookie_from(&headers);

    let (_st, body, _h) = send(app.clone(), Method::GET, "/api/users", None, Some(&cookie)).await;
    let v: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(v["meta"]["freshness"]["stale"], true);

    // missing：system 快照从未生成 → present=false，但仍是 200（显式标识，而非假装有数据）。
    let (_st2, body2, _h2) = send(
        app.clone(),
        Method::GET,
        "/api/system-summary",
        None,
        Some(&cookie),
    )
    .await;
    let v2: serde_json::Value = serde_json::from_str(&body2).unwrap();
    assert_eq!(v2["meta"]["freshness"]["present"], false);
    assert!(v2["data"].is_null());
}

#[tokio::test]
async fn capability_default_deny_viewer_cannot_list_sessions() {
    let (app, _snap) = make_app(true).await;
    let (_s, _b, headers) = send(
        app.clone(),
        Method::POST,
        "/api/auth/login",
        Some(r#"{"username":"viewer_user","password":"viewerpass"}"#),
        None,
    )
    .await;
    let viewer_cookie = session_cookie_from(&headers);

    // viewer 无 sessions.manage → 403。
    let (status, _b1, _h) = send(
        app.clone(),
        Method::GET,
        "/api/sessions",
        None,
        Some(&viewer_cookie),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn admin_can_list_sessions_and_bad_password_is_401() {
    let (app, _snap) = make_app(true).await;

    // 错误密码统一 401。
    let (bad_status, _b, _h) = send(
        app.clone(),
        Method::POST,
        "/api/auth/login",
        Some(r#"{"username":"admin_user","password":"WRONG"}"#),
        None,
    )
    .await;
    assert_eq!(bad_status, StatusCode::UNAUTHORIZED);

    let (_s, _b2, headers) = send(
        app.clone(),
        Method::POST,
        "/api/auth/login",
        Some(r#"{"username":"admin_user","password":"adminpass"}"#),
        None,
    )
    .await;
    let admin_cookie = session_cookie_from(&headers);
    let csrf = csrf_cookie_from(&headers);
    let (status, body, _h) = send(
        app.clone(),
        Method::GET,
        "/api/sessions",
        None,
        Some(&admin_cookie),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let value: serde_json::Value = serde_json::from_str(&body).unwrap();
    let sessions = value["data"]["sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0]["current"], true);
    let session_id = sessions[0]["id"].as_str().unwrap();

    // Revocation is a CSRF-protected mutation and takes effect immediately.
    let req = Request::builder()
        .method(Method::DELETE)
        .uri(format!("/api/sessions/{session_id}"))
        .header(header::COOKIE, &admin_cookie)
        .body(Body::empty())
        .unwrap();
    let response = app.clone().oneshot(req).await.unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);

    let req = Request::builder()
        .method(Method::DELETE)
        .uri(format!("/api/sessions/{session_id}"))
        .header(header::COOKIE, &admin_cookie)
        .header("x-csrf-token", &csrf)
        .body(Body::empty())
        .unwrap();
    let response = app.clone().oneshot(req).await.unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    let (status, _, _) = send(
        app.clone(),
        Method::GET,
        "/api/auth/me",
        None,
        Some(&admin_cookie),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn dangerous_routes_still_404_even_when_authenticated() {
    let (app, _snap) = make_app(true).await;
    let (_s, _b, headers) = send(
        app.clone(),
        Method::POST,
        "/api/auth/login",
        Some(r#"{"username":"admin_user","password":"adminpass"}"#),
        None,
    )
    .await;
    let cookie = session_cookie_from(&headers);

    for (m, u) in [
        (Method::POST, "/api/users"),
        (Method::DELETE, "/api/users/alice"),
        (Method::PUT, "/api/users/alice/quota"),
        (Method::PUT, "/api/users/alice/resources"),
        (Method::POST, "/api/smb/shares"),
        (Method::DELETE, "/api/smb/shares/pub"),
        (Method::POST, "/api/hosts/local/exec"),
        (Method::POST, "/api/system/reboot"),
        (Method::POST, "/api/snapshots/refresh"),
    ] {
        let (status, _b, _h) = send(app.clone(), m.clone(), u, Some("{}"), Some(&cookie)).await;
        assert!(
            status == StatusCode::NOT_FOUND || status == StatusCode::METHOD_NOT_ALLOWED,
            "{m} {u} must be 404/405, got {status}"
        );
    }
}

fn timestamp_rfc3339(unix_secs: i64) -> String {
    let dt = time::OffsetDateTime::from_unix_timestamp(unix_secs).unwrap();
    dt.format(&time::format_description::well_known::Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_string())
}
