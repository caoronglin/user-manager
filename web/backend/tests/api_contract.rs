//! API 契约门禁：危险接口必须**不存在**（命中返回 404/405），而不是 RBAC 403。
//!
//! 与 plan.md 14.4 对齐。这些断言比 "RBAC 返回 403" 更强：危险路由根本没有注册。

use axum::body::Body;
use axum::http::{Method, Request, StatusCode};
use tower::ServiceExt;

use umweb::config::Config;
use umweb::http::build_router;
use umweb::state::AppState;

async fn app() -> axum::Router {
    // 每个测试用独立临时 DB/快照目录。
    let uniq = uuid::Uuid::new_v4();
    std::env::set_var("UMWEB_DB_PATH", std::env::temp_dir().join(format!("umweb-{uniq}.db")));
    std::env::set_var(
        "UMWEB_SNAPSHOT_DIR",
        std::env::temp_dir().join(format!("umweb-snap-{uniq}")),
    );
    std::env::set_var("UMWEB_REQUIRE_TLS", "0");
    let config = Config::from_env().expect("config");
    let state = AppState::init(config).await.expect("state");
    build_router(state)
}

async fn call(router: axum::Router, method: Method, uri: &str) -> StatusCode {
    let req = Request::builder()
        .method(method)
        .uri(uri)
        .body(Body::empty())
        .unwrap();
    let resp = router.oneshot(req).await.unwrap();
    resp.status()
}

#[tokio::test]
async fn dangerous_user_routes_do_not_exist() {
    let r = app().await;
    assert_eq!(call(r.clone(), Method::POST, "/api/users").await, StatusCode::NOT_FOUND);
    assert_eq!(call(r.clone(), Method::DELETE, "/api/users/alice").await, StatusCode::NOT_FOUND);
    assert_eq!(call(r.clone(), Method::PATCH, "/api/users/alice").await, StatusCode::NOT_FOUND);
    assert_eq!(call(r.clone(), Method::PUT, "/api/users/alice/quota").await, StatusCode::METHOD_NOT_ALLOWED);
    assert_eq!(call(r.clone(), Method::PUT, "/api/users/alice/resources").await, StatusCode::METHOD_NOT_ALLOWED);
}

#[tokio::test]
async fn dangerous_smb_routes_do_not_exist() {
    let r = app().await;
    assert_eq!(call(r.clone(), Method::POST, "/api/smb/password").await, StatusCode::NOT_FOUND);
    assert_eq!(call(r.clone(), Method::POST, "/api/smb/shares").await, StatusCode::NOT_FOUND);
    assert_eq!(call(r.clone(), Method::DELETE, "/api/smb/shares/pub").await, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn dangerous_host_and_system_routes_do_not_exist() {
    let r = app().await;
    assert_eq!(call(r.clone(), Method::POST, "/api/hosts/compute-01/exec").await, StatusCode::NOT_FOUND);
    assert_eq!(call(r.clone(), Method::POST, "/api/hosts/compute-01/probe").await, StatusCode::NOT_FOUND);
    assert_eq!(call(r.clone(), Method::POST, "/api/system/reboot").await, StatusCode::NOT_FOUND);
    assert_eq!(call(r.clone(), Method::POST, "/api/snapshots/refresh").await, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn health_is_public_and_readonly() {
    let r = app().await;
    assert_eq!(call(r.clone(), Method::GET, "/api/health").await, StatusCode::OK);
    // health 只允许 GET，其他方法不得越权。
    assert_ne!(call(r.clone(), Method::POST, "/api/health").await, StatusCode::OK);
}

#[tokio::test]
async fn capability_mapping_defaults_to_deny() {
    // 未映射的 kind 不返回 capability；映射的 kind 返回预期的只读 capability。
    assert_eq!(umweb::auth::rbac::capability_for_snapshot("users"), Some("users.read"));
    assert_eq!(umweb::auth::rbac::capability_for_snapshot("etc-passwd"), None);

    let config = Config::from_env().expect("config");
    assert!(umweb::auth::rbac::is_allowed(&config, "viewer", "users.read"));
    // viewer 不具备 wecom.manage（默认拒绝）。
    assert!(!umweb::auth::rbac::is_allowed(&config, "viewer", "wecom.manage"));
    // 未知角色默认拒绝。
    assert!(!umweb::auth::rbac::is_allowed(&config, "owner", "users.read"));
}
