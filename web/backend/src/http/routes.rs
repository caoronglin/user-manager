//! 路由组装。
//!
//! 安全边界（plan.md 第 5 / 8 节）：只装配**非特权只读 API**与 **Web 自身管理**路由。
//! 危险接口在这里**根本不存在**（不注册），因此命中即 404/405，而非 RBAC 403：
//! POST /api/users、DELETE/PATCH /api/users/:u、PUT .../quota、PUT .../resources、
//! POST /api/smb/password、POST/DELETE /api/smb/shares/:name、
//! POST /api/hosts/:id/exec、POST /api/system/*、POST /api/snapshots/refresh 等。
//! 也不提供任意 shell / command / SSH / file-path / log-path / URL-fetch 路由。

use axum::extract::State;
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::routing::{delete, get, post};
use axum::{Json, Router};

use serde_json::json;

use crate::auth::session::SessionStore;
use crate::state::{AppState, SharedState};
use crate::telemetry::redact;

/// 只读健康检查（无 capability 要求，供探针/负载均衡）。
async fn health() -> Json<serde_json::Value> {
    Json(json!({ "ok": true, "data": { "status": "up" } }))
}

/// 未认证的登录：校验 Argon2id、下发服务端会话 Cookie（HttpOnly/Secure/SameSite=Strict）。
async fn login(
    State(state): State<SharedState>,
) -> Result<axum::response::Response, crate::error::ApiError> {
    // P1 骨架：完整实现见 P4。这里仅示范结构，返回未认证占位以避免误导。
    let _ = &state.sessions;
    Err(crate::error::ApiError::Unauthorized)
}

/// 注销：删除服务端会话并清 Cookie。
async fn logout(
    State(state): State<SharedState>,
) -> Result<axum::response::Response, crate::error::ApiError> {
    // P1 骨架占位。
    let _ = state.sessions.clone();
    Ok(StatusCode::NO_CONTENT.into_response())
}

/// 返回当前 Web 用户与能力集合（前端 access 仅作 UX；真正授权在后端）。
async fn me(
    State(_state): State<SharedState>,
) -> Result<Json<serde_json::Value>, crate::error::ApiError> {
    // P1 骨架占位。
    Err(crate::error::ApiError::Unauthorized)
}

/// 会话管理（web_admin / sessions.manage）。
async fn list_sessions(
    State(state): State<SharedState>,
) -> Result<Json<serde_json::Value>, crate::error::ApiError> {
    // P1 骨架占位；不泄露敏感信息。
    let _ = &state.sessions;
    Ok(Json(json!({ "ok": true, "data": { "sessions": [] } })))
}

async fn revoke_session(
    State(state): State<SharedState>,
) -> Result<axum::response::Response, crate::error::ApiError> {
    // P1 骨架占位。
    let _ = state.sessions.clone();
    Ok(StatusCode::NO_CONTENT.into_response())
}

/// 示例只读 read 路由占位（P2 接 Snapshot Read）。缺省拒绝，需 capability。
async fn read_stub() -> Result<Json<serde_json::Value>, crate::error::ApiError> {
    Ok(Json(json!({ "ok": true, "data": {} })))
}

pub fn build_router(state: AppState) -> Router {
    let shared: SharedState = std::sync::Arc::new(state);

    // CSRF/Origin 校验只作用于**已注册的变更类路由**（POST/PUT/PATCH/DELETE），
    // 不作为全局层——否则未注册路径（危险接口）会被 CSRF 提前转成 403，
    // 破坏「危险路由必须 404/405 而非 403」的契约。request-id/安全头作为全局层，
    // 对未匹配路径只追加头、不短路，因此不影响 404 语义。
    let csrf_layer = axum::middleware::from_fn_with_state(
        shared.clone(),
        crate::http::middleware::csrf_origin_guard,
    );

    let mutating = Router::new()
        .route("/api/auth/login", post(login))
        .route("/api/auth/logout", post(logout))
        .route("/api/sessions/:id", delete(revoke_session))
        .route_layer(csrf_layer);

    Router::new()
        // 只读健康（无需认证）
        .route("/api/health", get(health))
        .route("/api/auth/me", get(me))
        // 会话管理列表（读；写走 mutating，带 CSRF）
        .route("/api/sessions", get(list_sessions))
        // 只读 read 路由占位（P2 接 Snapshot）。示例：/api/system-summary
        .route("/api/system-summary", get(read_stub))
        // 变更类路由（带 CSRF/Origin）
        .merge(mutating)
        // 注意：此处不注册任何 users/smb/hosts/system 的写路由。
        .layer(axum::middleware::from_fn_with_state(
            shared.clone(),
            crate::http::middleware::request_id,
        ))
        .layer(axum::middleware::from_fn_with_state(
            shared.clone(),
            crate::http::middleware::security_headers,
        ))
        .with_state(shared)
}

// 让未使用告警静默（骨架阶段部分函数暂未全量接线）。
#[allow(dead_code)]
fn _touch(_s: &SessionStore) {
    let _ = redact("");
}
