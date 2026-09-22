//! 运行配置。所有项来自环境变量；secret 相关项绝不打印/日志化。
//!
//! 与权限域隔离：Web **不读取** CLI/TUI 特权域主密钥。Web 使用自己的
//! `/var/lib/user-manager-web/secrets/master.key`（P4 落地）。

use std::env;

/// Web 能力 allowlist（默认拒绝）。未列出的一律视为无权限。
#[derive(Clone, Debug)]
pub struct Capabilities {
    pub allowed: std::collections::BTreeSet<String>,
}

impl Capabilities {
    pub fn allows(&self, cap: &str) -> bool {
        self.allowed.contains(cap)
    }
}

#[derive(Clone, Debug)]
pub struct Config {
    pub bind_addr: String,
    pub bind_port: u16,
    /// 只读快照目录（root:umweb 0640；Web 仅读）。
    pub snapshot_dir: std::path::PathBuf,
    /// Web SQLite 数据库路径。
    pub db_path: std::path::PathBuf,
    /// Web 独立 secret master key 路径（P4）。
    pub master_key_path: std::path::PathBuf,
    /// 是否强制为 HTTPS（HSTS/Cookie Secure 依赖）。
    pub require_tls: bool,
    /// 受信任反代列表（仅这些来源的 X-Forwarded-For 才被采信）。
    pub trusted_proxies: Vec<String>,
    /// 允许的 Origin（CSRF Origin 校验用）。
    pub allowed_origins: Vec<String>,
    /// 角色 → 能力集合。
    pub capabilities: std::collections::BTreeMap<String, Capabilities>,
    /// 是否要求 web_admin 强制 MFA。
    pub enforce_mfa_admin: bool,
}

/// 配置错误（骨架：当前 from_env 不失败，保留类型以便后续校验）。
#[derive(Debug)]
pub enum ConfigError {
    Invalid(String),
}

impl std::fmt::Display for ConfigError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ConfigError::Invalid(m) => write!(f, "config error: {m}"),
        }
    }
}

impl std::error::Error for ConfigError {}

impl Config {
    /// 测试用构造器：直接给路径，避免进程级 env 在并行测试间相互污染。
    pub fn for_tests(db_path: std::path::PathBuf, snapshot_dir: std::path::PathBuf) -> Self {
        Self {
            bind_addr: "127.0.0.1".to_string(),
            bind_port: 0,
            snapshot_dir,
            db_path,
            master_key_path: std::env::temp_dir().join("umweb-test-master.key"),
            require_tls: false,
            trusted_proxies: Vec::new(),
            allowed_origins: Vec::new(),
            capabilities: default_role_capabilities(),
            enforce_mfa_admin: true,
        }
    }

    pub fn from_env() -> Result<Self, ConfigError> {
        let bind_addr = env::var("UMWEB_BIND_ADDR").unwrap_or_else(|_| "0.0.0.0".to_string());
        let bind_port = env::var("UMWEB_PORT")
            .ok()
            .and_then(|v| v.parse::<u16>().ok())
            .unwrap_or(8080);
        let snapshot_dir = env::var("UMWEB_SNAPSHOT_DIR")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|_| std::path::PathBuf::from("/var/lib/user-manager-web/snapshots"));
        let db_path = env::var("UMWEB_DB_PATH")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|_| std::path::PathBuf::from("/var/lib/user-manager-web/app.db"));
        let master_key_path = env::var("UMWEB_MASTER_KEY")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|_| {
                std::path::PathBuf::from("/var/lib/user-manager-web/secrets/master.key")
            });
        let require_tls = env::var("UMWEB_REQUIRE_TLS")
            .map(|v| matches!(v.as_str(), "1" | "true" | "yes"))
            .unwrap_or(true);
        let trusted_proxies = env::var("UMWEB_TRUSTED_PROXIES")
            .map(|v| {
                v.split(',')
                    .filter(|s| !s.is_empty())
                    .map(str::to_string)
                    .collect()
            })
            .unwrap_or_default();
        let allowed_origins = env::var("UMWEB_ALLOWED_ORIGINS")
            .map(|v| {
                v.split(',')
                    .filter(|s| !s.is_empty())
                    .map(str::to_string)
                    .collect()
            })
            .unwrap_or_default();
        let enforce_mfa_admin = env::var("UMWEB_ENFORCE_MFA_ADMIN")
            .map(|v| matches!(v.as_str(), "1" | "true" | "yes"))
            .unwrap_or(true);

        Ok(Self {
            bind_addr,
            bind_port,
            snapshot_dir,
            db_path,
            master_key_path,
            require_tls,
            trusted_proxies,
            allowed_origins,
            capabilities: default_role_capabilities(),
            enforce_mfa_admin,
        })
    }
}

// 为避免引入 toml 依赖，这里用代码内置默认角色→能力映射。
// viewer / operator / web_admin；不存在 owner/root/superadmin。
fn default_role_capabilities() -> std::collections::BTreeMap<String, Capabilities> {
    use std::collections::BTreeSet;
    let caps = |list: &[&str]| Capabilities {
        allowed: list
            .iter()
            .map(|s| s.to_string())
            .collect::<BTreeSet<String>>(),
    };

    let viewer = caps(&[
        "dashboard.read",
        "users.read",
        "quota.read",
        "resource.read",
        "smb.read",
        "hosts.read",
        "gpu.read",
        "reports.read",
        "logs.read",
        "notifications.read",
    ]);
    let operator = caps(&[
        "dashboard.read",
        "users.read",
        "quota.read",
        "resource.read",
        "smb.read",
        "hosts.read",
        "gpu.read",
        "reports.read",
        "logs.read",
        "notifications.read",
        "audit.read",
        "notifications.manage",
    ]);
    let web_admin = caps(&[
        "dashboard.read",
        "users.read",
        "quota.read",
        "resource.read",
        "smb.read",
        "hosts.read",
        "gpu.read",
        "reports.read",
        "logs.read",
        "notifications.read",
        "audit.read",
        "notifications.manage",
        "web_users.manage",
        "sessions.manage",
        "tokens.manage",
        "wecom.manage",
        "settings.manage",
    ]);

    let mut m = std::collections::BTreeMap::new();
    m.insert("viewer".to_string(), viewer);
    m.insert("operator".to_string(), operator);
    m.insert("web_admin".to_string(), web_admin);
    m
}
