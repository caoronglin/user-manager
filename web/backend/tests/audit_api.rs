//! P3 Audit 只读 API 集成测试：audit.read 门禁、过滤、游标分页、CSV/JSON 导出上限。

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
    let snap = std::env::temp_dir().join(format!("umweb-audit-snap-{uniq}"));
    std::fs::create_dir_all(&snap).unwrap();
    let db = std::env::temp_dir().join(format!("umweb-audit-{uniq}.db"));
    let config = Config::for_tests(db, snap.clone());
    let state = AppState::init(config).await.expect("state");
    {
        let conn = state.db.lock().unwrap();
        // operator 具备 audit.read；viewer 不具备。
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

fn write_audit_snapshot(dir: &str) {
    let now = time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();
    let recent = serde_json::json!([
        {"timestamp": now, "user":"alice","action":"users.create","target":"bob","result":"SUCCESS"},
        {"timestamp": now, "user":"carol","action":"smb.password","target":"dave","result":"FAILED"},
        {"timestamp": now, "user":"alice","action":"quota.set","target":"erin","result":"SUCCESS"},
    ]);
    let env = serde_json::json!({
        "schema_version": 1, "protocol": "user-manager-snapshot-v1", "kind": "audit-summary",
        "generator": "user-manager", "source": "local", "generated_at": now,
        "threshold_seconds": 30,
        "data": { "total_records": 3, "today_records": 3, "recent": recent, "source_file": "x" }
    });
    std::fs::write(
        format!("{dir}/audit-summary.json"),
        serde_json::to_vec_pretty(&env).unwrap(),
    )
    .unwrap();
}

#[tokio::test]
async fn audit_requires_auth_and_capability() {
    let (app, snap) = make_app().await;
    write_audit_snapshot(&snap);

    // 无会话 → 401
    let (s, _b, _h) = send(app.clone(), Method::GET, "/api/audit", None, None).await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);

    // viewer 无 audit.read → 403
    let vc = login(app.clone(), "vw_user", "vwpass").await;
    let (s2, _b2, _h2) = send(app.clone(), Method::GET, "/api/audit", None, Some(&vc)).await;
    assert_eq!(s2, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn audit_filters_and_cursor_and_export() {
    let (app, snap) = make_app().await;
    write_audit_snapshot(&snap);
    let c = login(app.clone(), "op_user", "oppass").await;

    // 过滤 user=alice → 2 条
    let (_s, body, _h) = send(
        app.clone(),
        Method::GET,
        "/api/audit?user=alice",
        None,
        Some(&c),
    )
    .await;
    let v: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(v["data"]["total_matched"], 2);

    // 游标分页：limit=1，两次取完 alice 的 2 条
    let (_s, body, _h) = send(
        app.clone(),
        Method::GET,
        "/api/audit?user=alice&limit=1",
        None,
        Some(&c),
    )
    .await;
    let v: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(v["data"]["items"].as_array().unwrap().len(), 1);
    let cur = v["data"]["next_cursor"].as_u64().unwrap();
    let (_s, body2, _h) = send(
        app.clone(),
        Method::GET,
        &format!("/api/audit?user=alice&limit=1&cursor={cur}"),
        None,
        Some(&c),
    )
    .await;
    let v2: serde_json::Value = serde_json::from_str(&body2).unwrap();
    assert_eq!(v2["data"]["items"].as_array().unwrap().len(), 1);
    assert!(v2["data"]["next_cursor"].is_null());

    // JSON 导出
    let (sj, bodyj, hj) = send(
        app.clone(),
        Method::GET,
        "/api/audit/export?format=json",
        None,
        Some(&c),
    )
    .await;
    assert_eq!(sj, StatusCode::OK);
    assert!(hj
        .get(header::CONTENT_TYPE)
        .unwrap()
        .to_str()
        .unwrap()
        .contains("application/json"));
    let ev: serde_json::Value = serde_json::from_str(&bodyj).unwrap();
    assert_eq!(ev["items"].as_array().unwrap().len(), 3);

    // CSV 导出
    let (sc, bodyc, hc) = send(
        app.clone(),
        Method::GET,
        "/api/audit/export?format=csv",
        None,
        Some(&c),
    )
    .await;
    assert_eq!(sc, StatusCode::OK);
    assert!(hc
        .get(header::CONTENT_TYPE)
        .unwrap()
        .to_str()
        .unwrap()
        .contains("text/csv"));
    assert!(bodyc.starts_with("timestamp,user,action,target,result\n"));
    assert_eq!(bodyc.lines().count(), 4); // header + 3 rows
}
