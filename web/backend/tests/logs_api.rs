//! P3 Logs 只读 API 集成测试：allowlist 源、拒绝任意 source、logs.read 门禁、下载。

use axum::body::Body;
use axum::http::{header, HeaderMap, Method, Request, StatusCode};
use tower::ServiceExt;

use umweb::auth::password;
use umweb::config::Config;
use umweb::http::build_router;
use umweb::state::AppState;
use umweb::store::user;

async fn make_app() -> (axum::Router, String) {
    let uniq = uuid::Uuid::new_v4();
    let snap = std::env::temp_dir().join(format!("umweb-logs-snap-{uniq}"));
    std::fs::create_dir_all(&snap).unwrap();
    let db = std::env::temp_dir().join(format!("umweb-logs-{uniq}.db"));
    let config = Config::for_tests(db, snap.clone());
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

async fn login(app: axum::Router, u: &str, p: &str) -> String {
    let (_s, _b, headers) = send(
        app,
        Method::POST,
        "/api/auth/login",
        Some(&format!(r#"{{"username":"{u}","password":"{p}"}}"#)),
        None,
    )
    .await;
    session_cookie_from(&headers)
}

fn write_logs_snapshot(dir: &str) {
    let now = time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();
    let env = serde_json::json!({
        "schema_version": 1, "protocol": "user-manager-snapshot-v1", "kind": "logs",
        "generator": "user-manager", "source": "local", "generated_at": now, "threshold_seconds": 60,
        "data": { "sources": {
            "boot": {"available": true, "lines": ["kernel: boot ok", "kernel: started"]},
            "failed-services": {"available": true, "lines": ["postfix failed"]},
            "auth-failures": {"available": true, "lines": ["Failed password for root"]}
        }}
    });
    std::fs::write(
        format!("{dir}/logs.json"),
        serde_json::to_vec_pretty(&env).unwrap(),
    )
    .unwrap();
}

#[tokio::test]
async fn logs_requires_auth_but_viewer_is_allowed() {
    // plan.md 6.2：viewer 具备基础 logs.read；403 路径由 audit（viewer 无 audit.read）覆盖。
    let (app, snap) = make_app().await;
    write_logs_snapshot(&snap);

    let (s, _b, _h) = send(
        app.clone(),
        Method::GET,
        "/api/logs?source=boot",
        None,
        None,
    )
    .await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);

    // viewer 具备 logs.read → 200
    let vc = login(app.clone(), "vw_user", "vwpass").await;
    let (s2, _b2, _h2) = send(
        app.clone(),
        Method::GET,
        "/api/logs?source=boot",
        None,
        Some(&vc),
    )
    .await;
    assert_eq!(s2, StatusCode::OK);
}

#[tokio::test]
async fn logs_allowlist_and_query() {
    let (app, snap) = make_app().await;
    write_logs_snapshot(&snap);
    let c = login(app.clone(), "op_user", "oppass").await;

    // allowlist 源可读
    let (s, body, _h) = send(
        app.clone(),
        Method::GET,
        "/api/logs?source=auth-failures",
        None,
        Some(&c),
    )
    .await;
    assert_eq!(s, StatusCode::OK);
    let v: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(v["data"]["source"], "auth-failures");
    assert_eq!(v["data"]["lines"][0], "Failed password for root");

    // 关键词过滤
    let (_s, body2, _h) = send(
        app.clone(),
        Method::GET,
        "/api/logs?source=boot&q=kernel",
        None,
        Some(&c),
    )
    .await;
    let v2: serde_json::Value = serde_json::from_str(&body2).unwrap();
    assert_eq!(v2["data"]["lines"].as_array().unwrap().len(), 2);
    let (_s3, body3, _h3) = send(
        app.clone(),
        Method::GET,
        "/api/logs?source=boot&q=nomatch",
        None,
        Some(&c),
    )
    .await;
    let v3: serde_json::Value = serde_json::from_str(&body3).unwrap();
    assert_eq!(v3["data"]["lines"].as_array().unwrap().len(), 0);

    // 任意/未知 source 被拒（400）
    for bad in ["/etc/passwd", "..", "arbitrary", ""] {
        let (sb, _b, _h) = send(
            app.clone(),
            Method::GET,
            &format!("/api/logs?source={bad}"),
            None,
            Some(&c),
        )
        .await;
        assert_eq!(sb, StatusCode::BAD_REQUEST, "source={bad} must be rejected");
    }

    // 下载 allowlist 源
    let (sd, bodyd, hd) = send(
        app.clone(),
        Method::GET,
        "/api/logs/download?source=boot",
        None,
        Some(&c),
    )
    .await;
    assert_eq!(sd, StatusCode::OK);
    assert_eq!(bodyd, "kernel: boot ok\nkernel: started");
    assert!(hd
        .get("content-disposition")
        .unwrap()
        .to_str()
        .unwrap()
        .contains("boot.log"));

    // 下载未知源被拒
    let (sdb, _b, _h) = send(
        app.clone(),
        Method::GET,
        "/api/logs/download?source=/etc/shadow",
        None,
        Some(&c),
    )
    .await;
    assert_eq!(sdb, StatusCode::BAD_REQUEST);
}
