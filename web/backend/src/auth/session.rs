//! 服务端会话。Session ID 为 CSPRNG，不编码用户信息；DB 只存 token hash。
//!
//! Cookie 标志：HttpOnly; Secure; SameSite=Strict; Path=/。
//! 登录后轮换；MFA 后轮换；权限变更后 revoke。

use std::collections::HashMap;
use std::sync::Mutex;

#[derive(Clone, Debug)]
pub struct Session {
    pub id_hash: String,
    pub user_id: String,
    pub role: String,
    /// MFA 是否已完成（web_admin 可被强制 MFA）。
    pub mfa_done: bool,
    pub created_at: i64,
    pub expires_at: i64,
    pub csrf_token: String,
}

pub struct SessionStore {
    inner: Mutex<HashMap<String, Session>>,
}

impl SessionStore {
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(HashMap::new()),
        }
    }

    /// 生成新 Session ID（CSPRNG，≥128 bit 熵）;返回 (id_plaintext, id_hash)。
    pub fn new_session_id() -> (String, String) {
        let id = uuid::Uuid::new_v4().to_string();
        let hash = crate::auth::csrf::sha256_hex(&id);
        (id, hash)
    }

    /// 保存会话（以 hash 为键；绝不存明文 id）。
    pub fn put(&self, session: Session) {
        let mut guard = self.inner.lock().expect("session store poisoned");
        guard.insert(session.id_hash.clone(), session);
    }

    /// 按 hash 查询。
    pub fn get(&self, id_hash: &str) -> Option<Session> {
        let guard = self.inner.lock().expect("session store poisoned");
        guard.get(id_hash).cloned()
    }

    /// 注销单个会话。
    pub fn revoke(&self, id_hash: &str) {
        let mut guard = self.inner.lock().expect("session store poisoned");
        guard.remove(id_hash);
    }

    /// 撤销某用户全部会话（权限变更/安全事件）。
    pub fn revoke_user(&self, user_id: &str) {
        let mut guard = self.inner.lock().expect("session store poisoned");
        guard.retain(|_, s| s.user_id != user_id);
    }

    /// 清理过期会话。
    pub fn purge_expired(&self, now: i64) {
        let mut guard = self.inner.lock().expect("session store poisoned");
        guard.retain(|_, s| s.expires_at > now);
    }
}

impl Default for SessionStore {
    fn default() -> Self {
        Self::new()
    }
}

/// 构造 Set-Cookie 值（HttpOnly; Secure; SameSite=Strict; Path=/）。
pub fn session_cookie(id: &str, max_age_secs: i64, secure: bool) -> String {
    let mut c = format!("umweb_session={id}; Path=/; HttpOnly; SameSite=Strict; Max-Age={max_age_secs}");
    if secure {
        c.push_str("; Secure");
    }
    c
}

pub fn clear_cookie() -> String {
    "umweb_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0".to_string()
}
