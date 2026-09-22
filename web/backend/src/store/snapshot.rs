//! Snapshot 只读读取层（P2）。
//!
//! Web 只通过本模块读取**只读快照**。安全边界：
//! - kind 必须命中固定 allowlist；文件名仅由 `{kind}.json` 派生，**拒绝任意文件路径**；
//! - 不 fork shell / 不执行任何命令；仅用 std::fs 读 + serde_json 解析；
//! - 输出附带 freshness 元数据，过期/缺失必须显式标识，不伪装实时。

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// 允许读取的快照类型白名单（与 lib/snapshot_core.sh 保持一致）。
pub const SNAPSHOT_KINDS: &[&str] = &[
    "users",
    "quota",
    "resources",
    "smb",
    "hosts",
    "gpu",
    "system",
    "audit-summary",
    "manifest",
];

/// 校验 kind 安全：仅小写字母/连字符，且在 allowlist 内。
pub fn is_allowed_kind(kind: &str) -> bool {
    !kind.is_empty()
        && kind.bytes().all(|b| b.is_ascii_lowercase() || b == b'-')
        && SNAPSHOT_KINDS.contains(&kind)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Envelope {
    pub schema_version: u32,
    #[serde(default)]
    pub protocol: String,
    #[serde(default)]
    pub kind: String,
    #[serde(default)]
    pub generator: String,
    #[serde(default)]
    pub source: String,
    pub generated_at: String,
    #[serde(default)]
    pub threshold_seconds: u64,
    #[serde(default)]
    pub data: serde_json::Value,
}

#[derive(Debug, Clone, Serialize)]
pub struct Freshness {
    pub present: bool,
    pub fresh: bool,
    pub stale: bool,
    pub age_seconds: Option<i64>,
    pub generated_at: Option<String>,
    pub threshold_seconds: u64,
}

pub struct SnapshotStore {
    dir: PathBuf,
}

impl SnapshotStore {
    pub fn new(dir: PathBuf) -> Self {
        Self { dir }
    }

    fn path_for(&self, kind: &str) -> Option<PathBuf> {
        if !is_allowed_kind(kind) {
            return None;
        }
        Some(self.dir.join(format!("{kind}.json")))
    }

    /// 读取并解析某 kind 的快照信封；文件不存在/非法 JSON/路径非法返回 None。
    pub fn read(&self, kind: &str) -> Option<Envelope> {
        let path = self.path_for(kind)?;
        let text = std::fs::read_to_string(&path).ok()?;
        let env: Envelope = serde_json::from_str(&text).ok()?;
        // 版本不符一律视为不可用（Web reader 拒识未知 schema_version）。
        if env.schema_version != CORE_SCHEMA_VERSION {
            return None;
        }
        Some(env)
    }

    /// 计算 freshness。now 为 Unix 秒。
    pub fn freshness(&self, kind: &str, now: i64) -> Freshness {
        let threshold = default_threshold(kind);
        match self.read(kind) {
            Some(env) => {
                let gen = parse_rfc3339(&env.generated_at).unwrap_or(now);
                let age = (now - gen).max(0);
                let fresh = age <= env.threshold_seconds as i64;
                Freshness {
                    present: true,
                    fresh,
                    stale: !fresh,
                    age_seconds: Some(age),
                    generated_at: Some(env.generated_at.clone()),
                    threshold_seconds: env.threshold_seconds,
                }
            }
            None => Freshness {
                present: false,
                fresh: false,
                stale: false,
                age_seconds: None,
                generated_at: None,
                threshold_seconds: threshold,
            },
        }
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }
}

/// 与 lib/snapshot_core.sh::SNAPSHOT_SCHEMA_VERSION 对齐。
pub const CORE_SCHEMA_VERSION: u32 = 1;

fn default_threshold(kind: &str) -> u64 {
    match kind {
        "system" | "resources" => 60,
        "users" | "quota" | "smb" => 300,
        "hosts" | "gpu" | "manifest" => 120,
        "audit-summary" => 30,
        _ => 300,
    }
}

/// 解析 RFC3339（`...Z`）为 Unix 秒。依赖 time crate，无外部命令。
fn parse_rfc3339(s: &str) -> Option<i64> {
    use time::format_description::well_known::Rfc3339;
    use time::UtcOffset;
    let dt = time::OffsetDateTime::parse(s, &Rfc3339).ok()?;
    // 统一换算到 UTC 秒。
    let _ = UtcOffset::UTC;
    Some(dt.unix_timestamp())
}
