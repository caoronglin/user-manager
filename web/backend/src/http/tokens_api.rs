//! P4b API Tokens API（tokens.manage）。明文只在创建时返回一次；DB 仅存 hash。
//!
//! 路由：POST /api/api-tokens 创建（返回一次性 token）、GET /api/api-tokens 列表（无 hash/明文）、
//! DELETE /api/api-tokens/:id 撤销。capability 请求集合必须是 KNOWN_CAPS 子集。

use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get};
use axum::Json;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use rand::RngCore;
use serde_json::{json, Value};

use crate::auth::guard::authenticate;
use crate::auth::rbac;
use crate::error::ApiError;
use crate::state::SharedState;

fn bad(m: &str) -> ApiError {
    ApiError::BadRequest(m.to_string())
}
fn internal() -> ApiError {
    ApiError::Internal("internal".to_string())
}

/// 生成随机 token（256-bit，base64url），返回 (plaintext, sha256_hex)。
fn generate_token() -> (String, String) {
    let mut bytes = [0u8; 32];
    rand::rngs::OsRng.fill_bytes(&mut bytes);
    let plain = URL_SAFE_NO_PAD.encode(bytes);
    let hash = crate::auth::csrf::sha256_hex(&plain);
    (plain, hash)
}

fn now_unix() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

async fn tokens_list(
    State(state): State<SharedState>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let auth = authenticate(&state, &headers)?;
    auth.require("tokens.manage")?;
    let conn = state.db.lock().unwrap();
    let rows = crate::store::token::list_tokens(&conn);
    drop(conn);
    let arr: Vec<Value> = rows
        .iter()
        .map(|t| {
            json!({
                "id": t.id,
                "name": t.name,
                "capabilities": t.capabilities,
                "created_at": t.created_at,
                "expires_at": t.expires_at,
                "revoked": t.revoked,
            })
        })
        .collect();
    Ok(Json(json!({ "ok": true, "data": { "tokens": arr } })).into_response())
}

async fn tokens_create(
    State(state): State<SharedState>,
    headers: HeaderMap,
    Json(body): Json<Value>,
) -> Result<Response, ApiError> {
    let auth = authenticate(&state, &headers)?;
    auth.require("tokens.manage")?;

    let name = body
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim()
        .to_string();
    if name.is_empty() || name.len() > 64 {
        return Err(bad("invalid name"));
    }
    let expire_days: i64 = body
        .get("expire_days")
        .and_then(Value::as_i64)
        .unwrap_or(90);
    if !(1..=3650).contains(&expire_days) {
        return Err(bad("expire_days out of range"));
    }
    let caps: Vec<String> = body
        .get("capabilities")
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default();
    if caps.is_empty() {
        return Err(bad("capabilities required"));
    }
    // 仅允许已知 capability（默认拒绝未知项）。
    for c in &caps {
        if !rbac::KNOWN_CAPS.contains(&c.as_str()) {
            return Err(bad(&format!("unknown capability: {c}")));
        }
    }

    let (plain, hash) = generate_token();
    let caps_json = serde_json::to_string(&caps).unwrap_or_else(|_| "[]".to_string());
    let id = uuid::Uuid::new_v4().to_string();
    let expires_at = now_unix() + expire_days * 86400;

    let conn = state.db.lock().unwrap();
    crate::store::token::insert_token(&conn, &id, &name, &hash, &caps_json, expires_at)
        .map_err(|_| internal())?;
    drop(conn);

    // 明文 token 仅在这一次响应返回；DB 不存明文。
    Ok((
        StatusCode::CREATED,
        Json(json!({
            "ok": true,
            "data": {
                "id": id, "name": name, "capabilities": caps,
                "expires_at": expires_at, "token": plain
            }
        })),
    )
        .into_response())
}

async fn tokens_revoke(
    State(state): State<SharedState>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<Response, ApiError> {
    let auth = authenticate(&state, &headers)?;
    auth.require("tokens.manage")?;
    let conn = state.db.lock().unwrap();
    crate::store::token::revoke_token(&conn, &id).map_err(|_| internal())?;
    drop(conn);
    Ok(StatusCode::NO_CONTENT.into_response())
}

pub fn router() -> axum::Router<SharedState> {
    axum::Router::new()
        .route("/api/api-tokens", get(tokens_list).post(tokens_create))
        .route("/api/api-tokens/:id", delete(tokens_revoke))
}
