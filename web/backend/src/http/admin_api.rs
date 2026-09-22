//! P4 MFA/TOTP API + Web 用户管理 API。
//!
//! - MFA（/api/auth/mfa/*）：用户自助启用/停用 TOTP；secret 加密存储，otpauth URL 只见一次。
//! - Web 用户管理（/api/web-users*）：仅操作 Web 身份库，**绝不触碰 Linux 账户**；
//!   capability web_users.manage（web_admin）。
//! - 登录两步流程：login 通过后若需 MFA → 返回 mfa_required + 挂起会话；
//!   /api/auth/mfa/verify 用挂起会话 + TOTP code 完成登录（flip mfa_done）。

use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, patch, post};
use axum::Json;
use serde_json::{json, Value};

use crate::auth::guard::{authenticate, parse_session_cookie, Auth};
use crate::auth::mfa;
use crate::auth::password;
use crate::state::SharedState;

const VALID_ROLES: &[&str] = &["viewer", "operator", "web_admin"];

// ---------- MFA ----------

/// POST /api/auth/mfa/setup —— 生成并加密保存 TOTP secret，返回一次性 otpauth URL。
async fn mfa_setup(
    State(state): State<SharedState>,
    headers: HeaderMap,
) -> Result<Response, ApiErr> {
    let auth: Auth = authenticate(&state, &headers)?;
    let secret = mfa::generate_secret();
    let cipher =
        crate::crypto::encrypt(&state.master_key, &secret).ok_or_else(|| bad("encrypt failed"))?;
    let conn = state.db.lock().unwrap();
    crate::store::user::set_mfa_secret(&conn, &auth.user_id, &cipher).map_err(|_| internal())?;
    drop(conn);
    let url =
        mfa::otpauth_url(&secret, &auth_user_name(&state, &auth.user_id)).map_err(|e| bad(&e))?;
    Ok(Json(json!({ "ok": true, "data": { "otpauth_url": url } })).into_response())
}

/// POST /api/auth/mfa/verify {code} —— 校验 code 并启用 MFA（对已登录用户自助启用）。
async fn mfa_verify_enable(
    State(state): State<SharedState>,
    headers: HeaderMap,
    Json(body): Json<Value>,
) -> Result<Response, ApiErr> {
    let auth = authenticate(&state, &headers)?;
    let code = body.get("code").and_then(Value::as_str).unwrap_or("");
    let conn = state.db.lock().unwrap();
    let cipher =
        crate::store::user::get_mfa_secret(&conn, &auth.user_id).ok_or(bad("MFA not set up"))?;
    let secret = crate::crypto::decrypt(&state.master_key, &cipher).ok_or(internal())?;
    let name = auth_user_name_locked(&conn, &auth.user_id);
    if !mfa::verify_code(&secret, &name, code) {
        drop(conn);
        return Err(bad("invalid code"));
    }
    crate::store::user::enable_mfa(&conn, &auth.user_id).map_err(|_| internal())?;
    drop(conn);
    Ok(Json(json!({ "ok": true, "data": { "mfa_enabled": true } })).into_response())
}

/// POST /api/auth/mfa/challenge {code} —— 使用**挂起的登录会话**完成 MFA，返回 Set-Cookie 不变。
async fn mfa_challenge(
    State(state): State<SharedState>,
    headers: HeaderMap,
    Json(body): Json<Value>,
) -> Result<Response, ApiErr> {
    let code = body.get("code").and_then(Value::as_str).unwrap_or("");
    let session_id = parse_session_cookie(&headers).ok_or_else(unauth)?;
    let id_hash = crate::auth::csrf::sha256_hex(&session_id);
    let session = state.sessions.get(&id_hash).ok_or_else(unauth)?;
    if !session.mfa_required || session.mfa_done {
        // 未处于 MFA 挂起态。
        return Err(unauth());
    }
    let conn = state.db.lock().unwrap();
    let cipher = crate::store::user::get_mfa_secret(&conn, &session.user_id).ok_or_else(unauth)?;
    let secret = crate::crypto::decrypt(&state.master_key, &cipher).ok_or(internal())?;
    let name = auth_user_name_locked(&conn, &session.user_id);
    drop(conn);
    if !mfa::verify_code(&secret, &name, code) {
        return Err(unauth());
    }
    state.sessions.set_mfa_done(&id_hash);
    Ok(Json(json!({ "ok": true, "data": { "mfa_required": false } })).into_response())
}

/// POST /api/auth/mfa/disable —— 停用自己的 MFA（需当前 TOTP code）。
async fn mfa_disable(
    State(state): State<SharedState>,
    headers: HeaderMap,
    Json(body): Json<Value>,
) -> Result<Response, ApiErr> {
    let auth = authenticate(&state, &headers)?;
    let code = body.get("code").and_then(Value::as_str).unwrap_or("");
    let conn = state.db.lock().unwrap();
    if let Some(cipher) = crate::store::user::get_mfa_secret(&conn, &auth.user_id) {
        if let Some(secret) = crate::crypto::decrypt(&state.master_key, &cipher) {
            let name = auth_user_name_locked(&conn, &auth.user_id);
            if !mfa::verify_code(&secret, &name, code) {
                drop(conn);
                return Err(bad("invalid code"));
            }
        }
    }
    crate::store::user::disable_mfa(&conn, &auth.user_id).map_err(|_| internal())?;
    drop(conn);
    Ok(Json(json!({ "ok": true, "data": { "mfa_enabled": false } })).into_response())
}

// ---------- Web 用户管理（web_users.manage） ----------

/// GET /api/web-users
async fn web_users_list(
    State(state): State<SharedState>,
    headers: HeaderMap,
) -> Result<Response, ApiErr> {
    let auth = authenticate(&state, &headers)?;
    auth.require("web_users.manage")?;
    let conn = state.db.lock().unwrap();
    let users = crate::store::user::list_users(&conn);
    let arr: Vec<Value> = users
        .iter()
        .map(|u| json!({ "id": u.id, "username": u.username, "role": u.role, "mfa_enabled": u.mfa_enabled }))
        .collect();
    drop(conn);
    Ok(Json(json!({ "ok": true, "data": { "users": arr } })).into_response())
}

/// POST /api/web-users {username, password, role}
async fn web_users_create(
    State(state): State<SharedState>,
    headers: HeaderMap,
    Json(body): Json<Value>,
) -> Result<Response, ApiErr> {
    let auth = authenticate(&state, &headers)?;
    auth.require("web_users.manage")?;
    let username = body
        .get("username")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let role = body
        .get("role")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let pw = body.get("password").and_then(Value::as_str).unwrap_or("");
    if !is_valid_username(&username) || !VALID_ROLES.contains(&role.as_str()) || pw.len() < 8 {
        return Err(bad("invalid username/role/password"));
    }
    let hash = password::hash_password(pw).map_err(|_| internal())?;
    let id = uuid::Uuid::new_v4().to_string();
    let conn = state.db.lock().unwrap();
    if crate::store::user::get_by_username(&conn, &username).is_some() {
        return Err(bad("username exists"));
    }
    crate::store::user::insert_user(&conn, &id, &username, &role, &hash)
        .map_err(|_| bad("create failed"))?;
    drop(conn);
    Ok((
        StatusCode::CREATED,
        Json(json!({ "ok": true, "data": { "id": id, "username": username, "role": role } })),
    )
        .into_response())
}

/// PATCH /api/web-users/:id {role?, password?}
async fn web_users_update(
    State(state): State<SharedState>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(body): Json<Value>,
) -> Result<Response, ApiErr> {
    let auth = authenticate(&state, &headers)?;
    auth.require("web_users.manage")?;
    let conn = state.db.lock().unwrap();
    if let Some(role) = body.get("role").and_then(Value::as_str) {
        if !VALID_ROLES.contains(&role) {
            return Err(bad("invalid role"));
        }
        crate::store::user::update_role(&conn, &id, role).map_err(|_| internal())?;
    }
    if let Some(pw) = body.get("password").and_then(Value::as_str) {
        if pw.len() < 8 {
            return Err(bad("password too short"));
        }
        let hash = password::hash_password(pw).map_err(|_| internal())?;
        crate::store::user::update_password(&conn, &id, &hash).map_err(|_| internal())?;
    }
    drop(conn);
    // 角色/密码变化后撤销该用户全部会话，强制重新登录。
    state.sessions.revoke_user(&id);
    Ok(Json(json!({ "ok": true })).into_response())
}

/// DELETE /api/web-users/:id —— 只删 Web 身份库记录，绝不触碰 Linux 账户。
async fn web_users_delete(
    State(state): State<SharedState>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<Response, ApiErr> {
    let auth = authenticate(&state, &headers)?;
    auth.require("web_users.manage")?;
    if id == auth.user_id {
        return Err(bad("cannot delete yourself"));
    }
    let conn = state.db.lock().unwrap();
    crate::store::user::delete_user(&conn, &id).map_err(|_| internal())?;
    drop(conn);
    state.sessions.revoke_user(&id);
    Ok(StatusCode::NO_CONTENT.into_response())
}

fn is_valid_username(u: &str) -> bool {
    !u.is_empty()
        && u.len() <= 64
        && u.bytes().all(|b| {
            b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_' || b == b'-' || b == b'.'
        })
}

fn auth_user_name(state: &SharedState, id: &str) -> String {
    let conn = state.db.lock().unwrap();
    auth_user_name_locked(&conn, id)
}
fn auth_user_name_locked(conn: &rusqlite::Connection, id: &str) -> String {
    conn.query_row(
        "SELECT username FROM web_users WHERE id = ?1",
        rusqlite::params![id],
        |r| r.get::<_, String>(0),
    )
    .unwrap_or_default()
}

// 错误构造助手。
use crate::error::ApiError;
type ApiErr = ApiError;
fn bad(m: &str) -> ApiError {
    ApiError::BadRequest(m.to_string())
}
fn unauth() -> ApiError {
    ApiError::Unauthorized
}
fn internal() -> ApiError {
    ApiError::Internal("internal".to_string())
}

pub fn mfa_router() -> axum::Router<SharedState> {
    axum::Router::new()
        .route("/api/auth/mfa/setup", post(mfa_setup))
        .route("/api/auth/mfa/verify", post(mfa_verify_enable))
        .route("/api/auth/mfa/challenge", post(mfa_challenge))
        .route("/api/auth/mfa/disable", post(mfa_disable))
}

pub fn web_users_router() -> axum::Router<SharedState> {
    axum::Router::new()
        .route("/api/web-users", get(web_users_list).post(web_users_create))
        .route(
            "/api/web-users/:id",
            patch(web_users_update).delete(web_users_delete),
        )
}
