//! 路由组装。
//!
//! 安全边界（plan.md 第 5 / 8 节）：只装配**非特权只读 API**与 **Web 自身管理**路由。
//! 危险接口在这里**根本不存在**（不注册），因此命中即 404/405，而非 RBAC 403：
//! POST /api/users、DELETE/PATCH /api/users/:u、PUT .../quota、PUT .../resources、
//! POST /api/smb/password、POST/DELETE /api/smb/shares/:name、
//! POST /api/hosts/:id/exec、POST /api/system/*、POST /api/snapshots/refresh 等。
//! 也不提供任意 shell / command / SSH / file-path / log-path / URL-fetch 路由。

use axum::extract::State;
use axum::http::{header, HeaderValue, StatusCode};
use axum::response::IntoResponse;
use axum::routing::{delete, get, post};
use axum::{Json, Router};
use serde_json::{json, Value};

use crate::auth::password;
use crate::auth::session::{self, Session, SessionStore};
use crate::state::{AppState, SharedState};

/// 只读健康检查（无 capability 要求，供探针/负载均衡）。
async fn health() -> Json<Value> {
    Json(json!({ "ok": true, "data": { "status": "up" } }))
}

fn now_unix() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn session_id_from_cookie(headers: &axum::http::HeaderMap) -> Option<String> {
    let cookie = headers.get(header::COOKIE)?.to_str().ok()?;
    for kv in cookie.split(';') {
        if let Some(v) = kv.trim().strip_prefix("umweb_session=") {
            if !v.is_empty() {
                return Some(v.to_string());
            }
        }
    }
    None
}

fn client_ip(state: &SharedState, headers: &axum::http::HeaderMap) -> String {
    // 仅当配了 trusted_proxies 才考虑 X-Forwarded-For；否则用占位（真实连接 IP 由反代层提供，P6）。
    if !state.config.trusted_proxies.is_empty() {
        if let Some(xff) = headers.get("x-forwarded-for").and_then(|v| v.to_str().ok()) {
            if let Some(first) = xff.split(',').next() {
                return first.trim().to_string();
            }
        }
    }
    "unknown".to_string()
}

/// 登录：校验 Argon2id，建立服务端会话，下发 HttpOnly/Secure/SameSite=Strict Cookie。
async fn login(
    State(state): State<SharedState>,
    headers: axum::http::HeaderMap,
    Json(body): Json<Value>,
) -> Result<axum::response::Response, crate::error::ApiError> {
    let username = body
        .get("username")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let password_plain = body.get("password").and_then(Value::as_str).unwrap_or("");

    // 限流：IP + 用户名双维度；命中指数退避。
    let ip = client_ip(&state, &headers);
    let rkey = format!("login|{ip}|{username}");
    if let Err(wait) = state.rate_limiter.hit(&rkey) {
        tracing::info!(
            event = "security.login_failed",
            reason = "rate_limited",
            wait,
            "login throttled"
        );
        return Err(crate::error::ApiError::RateLimited);
    }

    let conn = state.db.lock().expect("db lock");
    let user = crate::store::user::get_by_username(&conn, &username);
    let ok = match &user {
        Some(u) => password::verify_password(password_plain, &u.password_hash).unwrap_or(false),
        None => false,
    };
    drop(conn);

    let user = match (ok, user) {
        (true, Some(u)) => u,
        _ => {
            tracing::info!(
                event = "security.login_failed",
                reason = "bad_credentials",
                "login failed"
            );
            // 统一返回未认证，避免用户枚举差异。
            return Err(crate::error::ApiError::Unauthorized);
        }
    };

    let (id_plain, id_hash) = SessionStore::new_session_id();
    let now = now_unix();
    let max_age = 3600 * 8;
    let csrf_token = crate::auth::csrf::sha256_hex(&uuid::Uuid::new_v4().to_string());
    // 需要 MFA：用户已启用 TOTP，或 web_admin 被强制 MFA 且尚未启用。
    let mfa_required =
        user.mfa_enabled || (state.config.enforce_mfa_admin && user.role == "web_admin");
    state.sessions.put(Session {
        id_hash: id_hash.clone(),
        user_id: user.id.clone(),
        role: user.role.clone(),
        mfa_done: !mfa_required,
        mfa_required,
        created_at: now,
        expires_at: now + max_age,
        csrf_token: csrf_token.clone(),
    });

    let mut resp = Json(json!({
        "ok": true,
        "data": {
            "username": user.username,
            "role": user.role,
            "mfa_required": mfa_required,
        }
    }))
    .into_response();
    let cookie = session::session_cookie(&id_plain, max_age, state.config.require_tls);
    if let Ok(v) = HeaderValue::from_str(&cookie) {
        resp.headers_mut().insert(header::SET_COOKIE, v);
    }
    // CSRF token 以可读 cookie 形式下发（double-submit 用）；非 HttpOnly 以便前端读取提交。
    let csrf_cookie = format!("umweb_csrf={csrf_token}; Path=/; SameSite=Strict; Secure");
    if let Ok(v) = HeaderValue::from_str(&csrf_cookie) {
        resp.headers_mut().append(header::SET_COOKIE, v);
    }
    Ok(resp)
}

/// 注销：revoke 会话并清除 Cookie。
async fn logout(
    State(state): State<SharedState>,
    headers: axum::http::HeaderMap,
) -> Result<axum::response::Response, crate::error::ApiError> {
    if let Some(id) = session_id_from_cookie(&headers) {
        state.sessions.revoke(&crate::auth::csrf::sha256_hex(&id));
    }
    let mut resp = StatusCode::NO_CONTENT.into_response();
    if let Ok(v) = HeaderValue::from_str(&session::clear_cookie()) {
        resp.headers_mut().insert(header::SET_COOKIE, v);
    }
    Ok(resp)
}

/// 当前 Web 用户 + 能力集合（前端 access 仅作 UX；真正授权在后端）。
async fn me(
    State(state): State<SharedState>,
    headers: axum::http::HeaderMap,
) -> Result<Json<Value>, crate::error::ApiError> {
    let auth = crate::auth::guard::authenticate(&state, &headers)?;
    let conn = state.db.lock().expect("db lock");
    let username = conn
        .query_row(
            "SELECT username FROM web_users WHERE id = ?1",
            rusqlite::params![auth.user_id],
            |r| r.get::<_, String>(0),
        )
        .unwrap_or_default();
    drop(conn);
    let caps: Vec<String> = auth.capabilities.allowed.iter().cloned().collect();
    Ok(Json(json!({
        "ok": true,
        "data": { "id": auth.user_id, "username": username, "role": auth.role, "capabilities": caps }
    })))
}

/// 会话管理列表（sessions.manage）。
async fn list_sessions(
    State(state): State<SharedState>,
    headers: axum::http::HeaderMap,
) -> Result<Json<Value>, crate::error::ApiError> {
    let auth = crate::auth::guard::authenticate(&state, &headers)?;
    auth.require("sessions.manage")?;
    state.sessions.purge_expired(now_unix());
    let sessions: Vec<Value> = state
        .sessions
        .list()
        .iter()
        .map(|session| {
            json!({
                "id": session.id_hash,
                "user_id": session.user_id,
                "role": session.role,
                "created_at": session.created_at,
                "expires_at": session.expires_at,
                "mfa_required": session.mfa_required,
                "mfa_done": session.mfa_done,
                "current": session.id_hash == auth.session_hash,
            })
        })
        .collect();
    Ok(Json(
        json!({ "ok": true, "data": { "sessions": sessions } }),
    ))
}

async fn revoke_session(
    State(state): State<SharedState>,
    headers: axum::http::HeaderMap,
    axum::extract::Path(id): axum::extract::Path<String>,
) -> Result<axum::response::Response, crate::error::ApiError> {
    let auth = crate::auth::guard::authenticate(&state, &headers)?;
    auth.require("sessions.manage")?;
    if id.len() != 64 || !id.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(crate::error::ApiError::BadRequest(
            "invalid session id".to_string(),
        ));
    }
    state.sessions.purge_expired(now_unix());
    if !state.sessions.revoke(&id) {
        return Err(crate::error::ApiError::NotFound);
    }
    let mut response = StatusCode::NO_CONTENT.into_response();
    if id == auth.session_hash {
        if let Ok(cookie) = HeaderValue::from_str(&session::clear_cookie()) {
            response.headers_mut().insert(header::SET_COOKIE, cookie);
        }
    }
    Ok(response)
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
        .merge(crate::http::admin_api::mfa_router())
        .merge(crate::http::admin_api::web_users_router())
        .merge(crate::http::tokens_api::router())
        .merge(crate::http::notifications_api::mutating_router())
        .merge(crate::http::wecom_api::mutating_router())
        .route_layer(csrf_layer);

    Router::new()
        .route("/api/health", get(health))
        .route("/api/auth/me", get(me))
        .route("/api/sessions", get(list_sessions))
        // P2 只读系统 API（全部来自 Snapshot；capability 默认拒绝）
        .merge(crate::http::read_api::router())
        .merge(crate::http::notifications_api::read_router())
        .merge(crate::http::wecom_api::read_router())
        .merge(crate::http::audit_api::router())
        .merge(crate::http::logs_api::router())
        .merge(crate::http::reports_api::router())
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
