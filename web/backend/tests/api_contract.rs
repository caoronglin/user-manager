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
    // 每个测试用独立临时 DB/快照目录；用 Config::for_tests 直接构造，
    // 避免进程级 env::set_var 在并行测试间相互污染。
    let uniq = uuid::Uuid::new_v4();
    let config = Config::for_tests(
        std::env::temp_dir().join(format!("umweb-{uniq}.db")),
        std::env::temp_dir().join(format!("umweb-snap-{uniq}")),
    );
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
    for (m, u) in [
        (Method::POST, "/api/users"),
        (Method::DELETE, "/api/users/alice"),
        (Method::PATCH, "/api/users/alice"),
        (Method::PUT, "/api/users/alice/quota"),
        (Method::PUT, "/api/users/alice/resources"),
    ] {
        let s = call(r.clone(), m.clone(), u).await;
        assert!(not_implemented(s), "{m} {u} must be 404/405, got {s}");
    }
}

#[tokio::test]
async fn dangerous_smb_routes_do_not_exist() {
    let r = app().await;
    for (m, u) in [
        (Method::POST, "/api/smb/password"),
        (Method::POST, "/api/smb/shares"),
        (Method::DELETE, "/api/smb/shares/pub"),
    ] {
        let s = call(r.clone(), m.clone(), u).await;
        assert!(not_implemented(s), "{m} {u} must be 404/405, got {s}");
    }
}

#[tokio::test]
async fn dangerous_host_and_system_routes_do_not_exist() {
    let r = app().await;
    for (m, u) in [
        (Method::POST, "/api/hosts/compute-01/exec"),
        (Method::POST, "/api/hosts/compute-01/probe"),
        (Method::POST, "/api/system/reboot"),
        (Method::POST, "/api/snapshots/refresh"),
    ] {
        let s = call(r.clone(), m.clone(), u).await;
        assert!(not_implemented(s), "{m} {u} must be 404/405, got {s}");
    }
}

/// 危险写路由不得被实现：必须 404（不存在）或 405（方法不允许），绝不是 2xx。

#[tokio::test]
async fn health_is_public_and_readonly() {
    let r = app().await;
    assert_eq!(
        call(r.clone(), Method::GET, "/api/health").await,
        StatusCode::OK
    );
    // health 只允许 GET，其他方法不得越权。
    assert_ne!(
        call(r.clone(), Method::POST, "/api/health").await,
        StatusCode::OK
    );
}

/// 危险写路由不得被实现：必须 404（不存在）或 405（方法不允许），绝不是 2xx。
fn not_implemented(status: StatusCode) -> bool {
    status == StatusCode::NOT_FOUND || status == StatusCode::METHOD_NOT_ALLOWED
}

#[tokio::test]
async fn capability_mapping_defaults_to_deny() {
    // 未映射的 kind 不返回 capability；映射的 kind 返回预期的只读 capability。
    assert_eq!(
        umweb::auth::rbac::capability_for_snapshot("users"),
        Some("users.read")
    );
    assert_eq!(
        umweb::auth::rbac::capability_for_snapshot("etc-passwd"),
        None
    );

    let config = Config::for_tests(
        std::env::temp_dir().join("umweb-rbac.db"),
        std::env::temp_dir().join("umweb-rbac-snap"),
    );
    assert!(umweb::auth::rbac::is_allowed(
        &config,
        "viewer",
        "users.read"
    ));
    // viewer 不具备 wecom.manage（默认拒绝）。
    assert!(!umweb::auth::rbac::is_allowed(
        &config,
        "viewer",
        "wecom.manage"
    ));
    // 未知角色默认拒绝。
    assert!(!umweb::auth::rbac::is_allowed(
        &config,
        "owner",
        "users.read"
    ));
}
