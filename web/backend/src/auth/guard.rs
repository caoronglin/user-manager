//! 会话/Capability 守卫：从 Cookie 解析服务端会话 → 角色 → capability 集合。
//!
//! - 需求 capability 未满足默认拒绝（403）；无有效/过期会话 → 401；
//! - 只读路由据此强制 capability，与前端 access 解耦；
//! - 只暴露只读能力；不存在 Linux 特权 dangerous action。

use axum::http::HeaderMap;

use crate::auth::rbac;
use crate::config::Capabilities;
use crate::error::ApiError;
use crate::state::SharedState;

fn now_unix() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// 解析出的调用方能力上下文。
#[derive(Clone, Debug)]
pub struct Auth {
    pub user_id: String,
    pub role: String,
    pub capabilities: Capabilities,
    pub session_hash: String,
}

pub fn parse_session_cookie(headers: &HeaderMap) -> Option<String> {
    let cookie = headers.get(axum::http::header::COOKIE)?.to_str().ok()?;
    for kv in cookie.split(';') {
        if let Some(v) = kv.trim().strip_prefix("umweb_session=") {
            if !v.is_empty() {
                return Some(v.to_string());
            }
        }
    }
    None
}

fn bearer_token(headers: &HeaderMap) -> Option<String> {
    let v = headers
        .get(axum::http::header::AUTHORIZATION)?
        .to_str()
        .ok()?;
    v.strip_prefix("Bearer ")
        .map(|t| t.trim().to_string())
        .filter(|t| !t.is_empty())
}

/// 从请求头解析会话并解析能力；无/过期会话 → 401。
pub fn authenticate(state: &SharedState, headers: &HeaderMap) -> Result<Auth, ApiError> {
    // 优先 Bearer API Token（hash-only 校验）。
    if let Some(token) = bearer_token(headers) {
        let th = crate::auth::csrf::sha256_hex(&token);
        let now = now_unix();
        let conn = state.db.lock().unwrap();
        if let Some(row) = crate::store::token::find_active_by_hash(&conn, &th, now) {
            return Ok(Auth {
                user_id: format!("token:{}", row.id),
                role: "(token)".to_string(),
                capabilities: Capabilities {
                    allowed: row.capabilities.into_iter().collect(),
                },
                session_hash: th,
            });
        }
        return Err(ApiError::Unauthorized);
    }

    let session_id = parse_session_cookie(headers).ok_or(ApiError::Unauthorized)?;
    let id_hash = crate::auth::csrf::sha256_hex(&session_id);
    let session = state.sessions.get(&id_hash).ok_or(ApiError::Unauthorized)?;

    let now = now_unix();
    if session.expires_at <= now {
        return Err(ApiError::Unauthorized);
    }
    // 需要 MFA 但尚未完成 → 视为未认证（不得访问受 capability 保护的资源）。
    if session.mfa_required && !session.mfa_done {
        return Err(ApiError::Unauthorized);
    }

    let capabilities = rbac::capabilities_for(&state.config, &session.role);
    Ok(Auth {
        user_id: session.user_id,
        role: session.role,
        capabilities,
        session_hash: id_hash,
    })
}

impl Auth {
    /// 要求某 capability；不具备默认拒绝。
    pub fn require(&self, capability: &str) -> Result<(), ApiError> {
        if self.capabilities.allows(capability) {
            Ok(())
        } else {
            Err(ApiError::Forbidden)
        }
    }
}
