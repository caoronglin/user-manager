//! P3 Reports 只读 API 集成测试：reports.read 门禁、列表来自快照、CSV/JSON 导出。

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
    let snap = std::env::temp_dir().join(format!("umweb-rep-snap-{uniq}"));
    std::fs::create_dir_all(&snap).unwrap();
    let db = std::env::temp_dir().join(format!("umweb-rep-{uniq}.db"));
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

fn write_reports_snapshot(dir: &str) {
    let now = time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();
    let env = serde_json::json!({
        "schema_version": 1, "protocol": "user-manager-snapshot-v1", "kind": "reports",
        "generator": "user-manager", "source": "local", "generated_at": now, "threshold_seconds": 300,
        "data": { "reports": [
            {"name": "user_alice_2026.html", "size_bytes": 123, "modified_at": 1790000000},
            {"name": "quota_2026.csv", "size_bytes": 55, "modified_at": 1790000100}
        ], "count": 2 }
    });
    std::fs::write(
        format!("{dir}/reports.json"),
        serde_json::to_vec_pretty(&env).unwrap(),
    )
    .unwrap();
}

#[tokio::test]
async fn reports_requires_capability() {
    let (app, snap) = make_app().await;
    write_reports_snapshot(&snap);

    let (s, _b, _h) = send(app.clone(), Method::GET, "/api/reports", None, None).await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);

    // viewer 具备 reports.read（plan 6.2）→ 200
    let vc = login(app.clone(), "vw_user", "vwpass").await;
    let (s2, body2, _h2) = send(app.clone(), Method::GET, "/api/reports", None, Some(&vc)).await;
    assert_eq!(s2, StatusCode::OK);
    let v: serde_json::Value = serde_json::from_str(&body2).unwrap();
    assert_eq!(v["data"]["count"], 2);
    assert_eq!(v["data"]["reports"][0]["name"], "user_alice_2026.html");
}

#[tokio::test]
async fn reports_export_csv_and_json() {
    let (app, snap) = make_app().await;
    write_reports_snapshot(&snap);
    let c = login(app.clone(), "op_user", "oppass").await;

    let (sc, bodyc, hc) = send(
        app.clone(),
        Method::GET,
        "/api/reports/export?format=csv",
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
    assert!(bodyc.starts_with("name,size_bytes,modified_at\n"));
    assert_eq!(bodyc.lines().count(), 3);

    let (sj, bodyj, _hj) = send(
        app.clone(),
        Method::GET,
        "/api/reports/export?format=json",
        None,
        Some(&c),
    )
    .await;
    assert_eq!(sj, StatusCode::OK);
    let v: serde_json::Value = serde_json::from_str(&bodyj).unwrap();
    assert_eq!(v["reports"].as_array().unwrap().len(), 2);
}
