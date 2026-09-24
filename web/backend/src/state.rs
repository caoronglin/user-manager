//! 应用状态：DB 连接、会话存储、限流器、能力 allowlist。
//!
//! 会话为**服务端存储**（不依赖无状态 JWT），便于强制注销、MFA 后轮换、权限变更后失效。

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
    /// Single in-flight live/dry-run WeCom test to bound outbound work.
    pub wecom_test_gate: Arc<tokio::sync::Semaphore>,
    pub snapshots: crate::store::snapshot::SnapshotStore,
    pub master_key: [u8; crate::crypto::KEY_LEN],
}

impl AppState {
    pub async fn init(config: Config) -> Result<Self, Box<dyn std::error::Error>> {
        // 预先原子创建/验证 SQLite 主库，避免 SQLite 在宽松 umask 下新建
        // 可被其他本地用户读取的 DB。WAL/SHM 侧文件由 systemd UMask=0077 保护。
        // 数据只包含密码 hash、token hash 与加密后的 Web secret。
        let (_db_file, _created) = crate::crypto::open_private_file(&config.db_path)?;
        let conn = rusqlite::Connection::open(&config.db_path)?;
        crate::store::init_schema(&conn)?;
        let master_key = crate::crypto::load_or_create_master_key(&config.master_key_path)?;

        Ok(Self {
            config: config.clone(),
            db: Arc::new(Mutex::new(conn)),
            sessions: Arc::new(SessionStore::new()),
            rate_limiter: Arc::new(RateLimiter::new()),
            wecom_test_gate: Arc::new(tokio::sync::Semaphore::new(1)),
            snapshots: crate::store::snapshot::SnapshotStore::new(config.snapshot_dir.clone()),
            master_key,
        })
    }
}

pub type SharedState = Arc<AppState>;

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::{symlink, PermissionsExt};

    fn temp_dir() -> std::path::PathBuf {
        let path = std::env::temp_dir().join(format!(
            "umweb-state-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir(&path).expect("create temp dir");
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        path
    }

    #[tokio::test]
    async fn database_and_master_key_are_private() {
        let dir = temp_dir();
        let config = Config::for_tests(dir.join("app.db"), dir.join("snapshots"));
        let _state = AppState::init(config.clone())
            .await
            .expect("initialize state");
        assert_eq!(
            std::fs::metadata(&config.db_path)
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        assert_eq!(
            std::fs::metadata(&config.master_key_path)
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn database_symlink_is_rejected() {
        let dir = temp_dir();
        let target = dir.join("target.db");
        std::fs::write(&target, b"not a database").unwrap();
        let database = dir.join("app.db");
        symlink(&target, &database).unwrap();
        let config = Config::for_tests(database, dir.join("snapshots"));
        assert!(AppState::init(config).await.is_err());
        assert_eq!(std::fs::read(&target).unwrap(), b"not a database");
        std::fs::remove_dir_all(dir).unwrap();
    }
}
