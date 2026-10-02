//! P4a 集成测试：Web 用户管理（web_users.manage，绝不动 Linux）+ MFA/TOTP 注册与登录挑战。

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

async fn make_app() -> axum::Router {
    make_app_with_db().await.0
}

async fn make_app_with_db() -> (axum::Router, std::path::PathBuf) {
    let uniq = uuid::Uuid::new_v4();
    let snap = std::env::temp_dir().join(format!("umweb-p4a-snap-{uniq}"));
    std::fs::create_dir_all(&snap).unwrap();
    let db = std::env::temp_dir().join(format!("umweb-p4a-{uniq}.db"));
    let config = Config::for_tests(db.clone(), snap);
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
        user::insert_user(
            &conn,
            "u-view",
            "view_user",
            "viewer",
            &password::hash_password("viewpass").unwrap(),
        )
        .unwrap();
    }
    (build_router(state), db)
}

async fn send(
    app: axum::Router,
    method: Method,
    uri: &str,
    json_body: Option<&str>,
    cookie: Option<&str>,
    csrf: Option<&str>,
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
        .filter_map(|v| v.to_str().ok())
        .find(|c| c.starts_with("umweb_csrf="))
        .map(|c| {
            c["umweb_csrf=".len()..]
                .split(';')
                .next()
                .unwrap_or("")
                .to_string()
        })
        .unwrap_or_default()
}

fn login_failure_count(db: &std::path::Path) -> i64 {
    let conn = Connection::open(db).unwrap();
    conn.query_row(
        "SELECT COUNT(*) FROM notifications WHERE event_type = 'security.login_failed'",
        [],
        |row| row.get(0),
    )
    .unwrap()
}

#[tokio::test]
async fn login_failure_notification_is_redacted_and_globally_deduplicated() {
    // Keep both credential failures inside one fixed five-minute bucket.
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let remaining = 300 - now % 300;
    if remaining <= 2 {
        tokio::time::sleep(std::time::Duration::from_secs(remaining + 1)).await;
    }

    let (app, db) = make_app_with_db().await;
    for (username, password) in [
        ("admin_user", "admin-super-secret"),
        ("view_user", "view-super-secret"),
    ] {
        let body = serde_json::json!({ "username": username, "password": password }).to_string();
        let (status, _body, _headers) = send(
            app.clone(),
            Method::POST,
            "/api/auth/login",
            Some(&body),
            None,
            None,
        )
        .await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
    }

    // Simulate a process restart: reopen the same SQLite DB with a fresh limiter/session store.
    drop(app);
    let config = Config::for_tests(db.clone(), db.with_extension("snapshots"));
    let restarted = build_router(AppState::init(config).await.unwrap());
    let (status, _body, _) = send(
        restarted,
        Method::POST,
        "/api/auth/login",
        Some(r#"{"username":"admin_user","password":"restart-secret"}"#),
        None,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    let conn = Connection::open(&db).unwrap();
    let notification: (
        String,
        String,
        String,
        Option<String>,
        Option<String>,
        String,
    ) = conn
        .query_row(
            "SELECT event_type, severity, title, target, source, event_id
             FROM notifications WHERE event_type = 'security.login_failed'",
            [],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                ))
            },
        )
        .unwrap();
    let summary: String = conn
        .query_row(
            "SELECT summary FROM notifications WHERE event_type = 'security.login_failed'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(notification.0, "security.login_failed");
    assert_eq!(notification.1, "info");
    assert_eq!(notification.2, "Login failed");
    assert_eq!(summary, "A login credential verification failed.");
    assert_eq!(notification.3, None, "do not retain a username or target");
    assert_eq!(notification.4.as_deref(), Some("web"));
    assert!(notification.5.starts_with("security.login_failed:"));
    assert!(!summary.contains("admin_user"));
    assert!(!summary.contains("view_user"));
    assert!(!summary.contains("super-secret"));
    assert_eq!(login_failure_count(&db), 1, "same event bucket is global");
}

#[tokio::test]
async fn login_rate_limit_and_internal_verification_errors_do_not_notify() {
    let (app, db) = make_app_with_db().await;
    let (unknown_status, _body, _) = send(
        app.clone(),
        Method::POST,
        "/api/auth/login",
        Some(r#"{"username":"unknown_user","password":"attempt-secret"}"#),
        None,
        None,
    )
    .await;
    assert_eq!(unknown_status, StatusCode::UNAUTHORIZED);
    assert_eq!(
        login_failure_count(&db),
        0,
        "a missing account has no verifier result"
    );

    for _ in 0..5 {
        let (status, _body, _headers) = send(
            app.clone(),
            Method::POST,
            "/api/auth/login",
            Some(r#"{"username":"admin_user","password":"adminpass"}"#),
            None,
            None,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
    }
    let (status, body, _) = send(
        app.clone(),
        Method::POST,
        "/api/auth/login",
        Some(r#"{"username":"admin_user","password":"adminpass"}"#),
        None,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS, "{body}");
    assert_eq!(
        login_failure_count(&db),
        0,
        "rate limiting is not a credential failure"
    );

    let (app, db) = make_app_with_db().await;
    {
        let conn = Connection::open(&db).unwrap();
        conn.execute(
            "UPDATE web_users SET password_hash = 'not-a-valid-phc' WHERE username = 'view_user'",
            [],
        )
        .unwrap();
    }
    let (status, _body, _) = send(
        app.clone(),
        Method::POST,
        "/api/auth/login",
        Some(r#"{"username":"view_user","password":"attempt-secret"}"#),
        None,
        None,
    )
    .await;
    assert_eq!(
        status,
        StatusCode::UNAUTHORIZED,
        "existing response is preserved"
    );
    assert_eq!(
        login_failure_count(&db),
        0,
        "malformed verifier is an internal error"
    );

    {
        let conn = Connection::open(&db).unwrap();
        conn.execute("DROP TABLE web_users", []).unwrap();
    }
    let (status, _body, _) = send(
        app,
        Method::POST,
        "/api/auth/login",
        Some(r#"{"username":"admin_user","password":"attempt-secret"}"#),
        None,
        None,
    )
    .await;
    assert_eq!(
        status,
        StatusCode::UNAUTHORIZED,
        "lookup error response is preserved"
    );
    assert_eq!(
        login_failure_count(&db),
        0,
        "database lookup errors are not credential failures"
    );
}

#[tokio::test]
async fn web_users_manage_requires_capability_and_csrf() {
    let app = make_app().await;

    // viewer(无 web_users.manage) → 403
    let (_s, _b, hv) = send(
        app.clone(),
        Method::POST,
        "/api/auth/login",
        Some(r#"{"username":"view_user","password":"viewpass"}"#),
        None,
        None,
    )
    .await;
    let vc = session_cookie_from(&hv);
    let vcsrf = csrf_cookie_from(&hv);
    let (s, _b2, _h) = send(
        app.clone(),
        Method::GET,
        "/api/web-users",
        None,
        Some(&vc),
        Some(&vcsrf),
    )
    .await;
    assert_eq!(s, StatusCode::FORBIDDEN);

    // admin 登录取 cookie + csrf
    let (_s3, _b3, ha) = send(
        app.clone(),
        Method::POST,
        "/api/auth/login",
        Some(r#"{"username":"admin_user","password":"adminpass"}"#),
        None,
        None,
    )
    .await;
    let ac = session_cookie_from(&ha);
    let acsrf = csrf_cookie_from(&ha);

    // POST 缺 CSRF token → 403
    let (s_nocsrf, _b, _h) = send(
        app.clone(),
        Method::POST,
        "/api/web-users",
        Some(r#"{"username":"newbie","password":"newBiePass1","role":"viewer"}"#),
        Some(&ac),
        None,
    )
    .await;
    assert_eq!(s_nocsrf, StatusCode::FORBIDDEN, "missing csrf must be 403");

    // 带 CSRF → 201 创建
    let (s_ok, body, _h) = send(
        app.clone(),
        Method::POST,
        "/api/web-users",
        Some(r#"{"username":"newbie","password":"newBiePass1","role":"viewer"}"#),
        Some(&ac),
        Some(&acsrf),
    )
    .await;
    assert_eq!(s_ok, StatusCode::CREATED);
    let v: Value = serde_json::from_str(&body).unwrap();
    let new_id = v["data"]["id"].as_str().unwrap().to_string();

    // 列表包含新用户
    let (_sl, lb, _hl) = send(
        app.clone(),
        Method::GET,
        "/api/web-users",
        None,
        Some(&ac),
        Some(&acsrf),
    )
    .await;
    assert!(lb.contains("newbie"));

    // 非法角色/短密码 → 400
    let (s_bad, _b, _h) = send(
        app.clone(),
        Method::POST,
        "/api/web-users",
        Some(r#"{"username":"x","password":"short","role":"viewer"}"#),
        Some(&ac),
        Some(&acsrf),
    )
    .await;
    assert_eq!(s_bad, StatusCode::BAD_REQUEST);

    // 变更角色 → 200（并撤销该用户会话）
    let (s_upd, _b, _h) = send(
        app.clone(),
        Method::PATCH,
        &format!("/api/web-users/{new_id}"),
        Some(r#"{"role":"operator"}"#),
        Some(&ac),
        Some(&acsrf),
    )
    .await;
    assert_eq!(s_upd, StatusCode::OK);

    // 删除 → 204；不能删自己 → 400
    let (s_del, _b, _h) = send(
        app.clone(),
        Method::DELETE,
        &format!("/api/web-users/{new_id}"),
        None,
        Some(&ac),
        Some(&acsrf),
    )
    .await;
    assert_eq!(s_del, StatusCode::NO_CONTENT);
    let admin_id = admin_id_of(&app, &ac, &acsrf).await;
    let (s_self, _b, _h) = send(
        app.clone(),
        Method::DELETE,
        &format!("/api/web-users/{admin_id}"),
        None,
        Some(&ac),
        Some(&acsrf),
    )
    .await;
    assert_eq!(s_self, StatusCode::BAD_REQUEST);
}

async fn admin_id_of(app: &axum::Router, ac: &str, acsrf: &str) -> String {
    let (_s, b, _h) = send(
        app.clone(),
        Method::GET,
        "/api/web-users",
        None,
        Some(ac),
        Some(acsrf),
    )
    .await;
    let v: Value = serde_json::from_str(&b).unwrap();
    v["data"]["users"]
        .as_array()
        .unwrap()
        .iter()
        .find(|u| u["username"] == "admin_user")
        .map(|u| u["id"].as_str().unwrap().to_string())
        .unwrap()
}

#[tokio::test]
async fn mfa_setup_verify_then_login_challenge() {
    let app = make_app().await;

    // viewer 登录（无 MFA）→ 直接拿到可用会话
    let (_s, _b, hv) = send(
        app.clone(),
        Method::POST,
        "/api/auth/login",
        Some(r#"{"username":"view_user","password":"viewpass"}"#),
        None,
        None,
    )
    .await;
    let vc = session_cookie_from(&hv);
    let vcsrf = csrf_cookie_from(&hv);

    // setup → 返回 otpauth URL（一次性）
    let (s_setup, sb, _h) = send(
        app.clone(),
        Method::POST,
        "/api/auth/mfa/setup",
        None,
        Some(&vc),
        Some(&vcsrf),
    )
    .await;
    assert_eq!(s_setup, StatusCode::OK);
    let setup: Value = serde_json::from_str(&sb).unwrap();
    let url = setup["data"]["otpauth_url"].as_str().unwrap().to_string();
    assert!(url.starts_with("otpauth://totp/"));
    // secret 从 otpauth URL 解析以生成当前 code（测试等价于用户的 authenticator app）。
    let secret_b32 = url
        .split("secret=")
        .nth(1)
        .unwrap()
        .split('&')
        .next()
        .unwrap();
    let totp = umweb::auth::mfa::totp_from_b32(secret_b32, "view_user").expect("totp");
    let code = totp.generate_current().to_string();

    // verify 未启用时无法用错 code
    let (s_bad, _b, _h) = send(
        app.clone(),
        Method::POST,
        "/api/auth/mfa/verify",
        Some(r#"{"code":"000000"}"#),
        Some(&vc),
        Some(&vcsrf),
    )
    .await;
    assert_eq!(s_bad, StatusCode::BAD_REQUEST);

    // verify 正确 code → 启用
    let (s_en, _b, _h) = send(
        app.clone(),
        Method::POST,
        "/api/auth/mfa/verify",
        Some(&format!(r#"{{"code":"{code}"}}"#)),
        Some(&vc),
        Some(&vcsrf),
    )
    .await;
    assert_eq!(s_en, StatusCode::OK);

    // 重新登录 → mfa_required=true，受保护资源暂 401
    let (_s2, _b2, hv2) = send(
        app.clone(),
        Method::POST,
        "/api/auth/login",
        Some(r#"{"username":"view_user","password":"viewpass"}"#),
        None,
        None,
    )
    .await;
    let vc2 = session_cookie_from(&hv2);
    let vcsrf2 = csrf_cookie_from(&hv2);
    let (s_gated, _b3, _h) = send(
        app.clone(),
        Method::GET,
        "/api/users",
        None,
        Some(&vc2),
        None,
    )
    .await;
    assert_eq!(
        s_gated,
        StatusCode::UNAUTHORIZED,
        "pending MFA session must be gated"
    );

    // challenge 正确 code → 完成 MFA，随后可读
    let (s_ch, _b, _h) = send(
        app.clone(),
        Method::POST,
        "/api/auth/mfa/challenge",
        Some(&format!(r#"{{"code":"{code}"}}"#)),
        Some(&vc2),
        Some(&vcsrf2),
    )
    .await;
    assert_eq!(s_ch, StatusCode::OK);
    let (s_after, _b, _h) = send(
        app.clone(),
        Method::GET,
        "/api/users",
        None,
        Some(&vc2),
        None,
    )
    .await;
    assert_eq!(s_after, StatusCode::OK, "after MFA, session usable");

    let (s_notifications, notifications_body, _) = send(
        app,
        Method::GET,
        "/api/notifications?type=security.login_failed",
        None,
        Some(&vc2),
        None,
    )
    .await;
    assert_eq!(s_notifications, StatusCode::OK);
    let notifications: Value = serde_json::from_str(&notifications_body).unwrap();
    assert_eq!(notifications["data"]["items"], serde_json::json!([]));
}
