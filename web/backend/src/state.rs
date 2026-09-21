//! 应用状态：DB 连接、会话存储、限流器、能力 allowlist。
//!
//! 会话为**服务端存储**（不依赖无状态 JWT），便于强制注销、MFA 后轮换、权限变更后失效。

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use crate::auth::rate_limit::RateLimiter;
use crate::auth::session::SessionStore;
use crate::config::Config;

pub struct AppState {
    pub config: Config,
    // rusqlite 为同步连接；生产可用 r2d2 连接池。骨架先持有一个互斥连接占位。
    pub db: Arc<Mutex<rusqlite::Connection>>,
    pub sessions: Arc<SessionStore>,
    pub rate_limiter: Arc<RateLimiter>,
}

impl AppState {
    pub async fn init(config: Config) -> Result<Self, Box<dyn std::error::Error>> {
        // 确保父目录存在（部署脚本负责把 /var/lib/user-manager-web 设为 umweb 可写）。
        if let Some(parent) = config.db_path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        // 数据库文件 0600（Web 自身数据，不含 secret 明文：密码为 Argon2id hash，
        // token 为 hash，webhook/TOTP secret 为加密存储）。
        let conn = rusqlite::Connection::open(&config.db_path)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if let Ok(meta) = std::fs::metadata(&config.db_path) {
                let mut perm = meta.permissions();
                perm.set_mode(0o600);
                let _ = std::fs::set_permissions(&config.db_path, perm);
            }
        }
        crate::store::init_schema(&conn)?;

        let _enforce = config.enforce_mfa_admin;
        let _ = HashMap::<String, String>::new(); // 预留，避免未使用告警

        Ok(Self {
            config,
            db: Arc::new(Mutex::new(conn)),
            sessions: Arc::new(SessionStore::new()),
            rate_limiter: Arc::new(RateLimiter::new()),
        })
    }
}

pub type SharedState = Arc<AppState>;
