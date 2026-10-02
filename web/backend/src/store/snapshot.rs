//! Snapshot 只读读取层（P2）。
//!
//! Web 只通过本模块读取**只读快照**。安全边界：
//! - kind 必须命中固定 allowlist；文件名仅由 `{kind}.json` 派生，**拒绝任意文件路径**；
//! - 不 fork shell / 不执行任何命令；仅用 std::fs 读 + serde_json 解析；
//! - 输出附带 freshness 元数据，过期/缺失必须显式标识，不伪装实时。

use std::fs::{File, OpenOptions};
use std::io::{self, Read};
use std::path::{Component, Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;

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
    "logs",
    "reports",
    "manifest",
];

const SNAPSHOT_PROTOCOL: &str = "user-manager-snapshot-v1";
const SNAPSHOT_GENERATOR: &str = "user-manager";
const MAX_SNAPSHOT_BYTES: u64 = 16 * 1024 * 1024;

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

impl Freshness {
    fn absent(threshold_seconds: u64) -> Self {
        Self {
            present: false,
            fresh: false,
            stale: false,
            age_seconds: None,
            generated_at: None,
            threshold_seconds,
        }
    }
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
        if !path_has_no_symlink_components(&path) {
            return None;
        }
        let file = open_snapshot_file(&path).ok()?;
        let metadata = file.metadata().ok()?;
        if !metadata.is_file() || metadata.len() == 0 || metadata.len() > MAX_SNAPSHOT_BYTES {
            return None;
        }
        let mut bytes = Vec::with_capacity(metadata.len() as usize);
        file.take(MAX_SNAPSHOT_BYTES + 1)
            .read_to_end(&mut bytes)
            .ok()?;
        if bytes.len() as u64 > MAX_SNAPSHOT_BYTES {
            return None;
        }
        let text = String::from_utf8(bytes).ok()?;
        let env = if kind == "manifest" {
            parse_manifest(&text)?
        } else {
            serde_json::from_str::<Envelope>(&text).ok()?
        };
        // Bind each file to its requested kind and the exact snapshot protocol.
        // Missing or malformed metadata must never look like a fresh snapshot.
        if env.schema_version != CORE_SCHEMA_VERSION
            || env.protocol != SNAPSHOT_PROTOCOL
            || env.kind != kind
            || env.generator != SNAPSHOT_GENERATOR
            || env.source.is_empty()
            || env.source.len() > 64
            || !env
                .source
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
            || env.threshold_seconds != default_threshold(kind)
            || parse_rfc3339(&env.generated_at).is_none()
        {
            return None;
        }
        Some(env)
    }

    /// 计算 freshness。now 为 Unix 秒。
    pub fn freshness(&self, kind: &str, now: i64) -> Freshness {
        let threshold = default_threshold(kind);
        self.read_with_freshness(kind, now)
            .map(|(_, freshness)| freshness)
            .unwrap_or_else(|| Freshness::absent(threshold))
    }

    /// Read a validated snapshot and derive freshness from that same file
    /// version, avoiding two reads that could straddle an atomic replacement.
    pub fn read_with_freshness(&self, kind: &str, now: i64) -> Option<(Envelope, Freshness)> {
        let env = self.read(kind)?;
        let generated_at = parse_rfc3339(&env.generated_at)?;
        // Small clock skew is tolerated; a far-future timestamp is explicitly
        // stale rather than clamped into a falsely fresh age.
        let raw_age = now - generated_at;
        let age = raw_age.max(0);
        let fresh = raw_age >= -300 && raw_age <= env.threshold_seconds as i64;
        let freshness = Freshness {
            present: true,
            fresh,
            stale: !fresh,
            age_seconds: Some(age),
            generated_at: Some(env.generated_at.clone()),
            threshold_seconds: env.threshold_seconds,
        };
        Some((env, freshness))
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }
}

#[derive(Deserialize)]
struct ManifestEnvelope {
    schema_version: u32,
    protocol: String,
    generator: String,
    source: String,
    generated_at: String,
    overall: String,
    snapshots: Vec<Value>,
}

fn parse_manifest(text: &str) -> Option<Envelope> {
    let manifest: ManifestEnvelope = serde_json::from_str(text).ok()?;
    if !matches!(
        manifest.overall.as_str(),
        "fresh" | "partial" | "stale" | "unavailable"
    ) {
        return None;
    }
    Some(Envelope {
        schema_version: manifest.schema_version,
        protocol: manifest.protocol,
        kind: "manifest".to_string(),
        generator: manifest.generator,
        source: manifest.source,
        generated_at: manifest.generated_at,
        threshold_seconds: default_threshold("manifest"),
        data: serde_json::json!({
            "overall": manifest.overall,
            "snapshots": manifest.snapshots,
        }),
    })
}

fn path_has_no_symlink_components(path: &Path) -> bool {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else if let Ok(cwd) = std::env::current_dir() {
        cwd.join(path)
    } else {
        return false;
    };
    let mut current = PathBuf::new();
    for component in absolute.components() {
        match component {
            Component::RootDir => current.push(component.as_os_str()),
            Component::CurDir => {}
            // Reject traversal instead of allowing path normalization to obscure
            // a symlink in a parent component.
            Component::ParentDir => return false,
            Component::Normal(part) => {
                current.push(part);
                let metadata = match std::fs::symlink_metadata(&current) {
                    Ok(metadata) => metadata,
                    Err(_) => return false,
                };
                if metadata.file_type().is_symlink() {
                    return false;
                }
            }
            Component::Prefix(_) => return false,
        }
    }
    true
}

#[cfg(unix)]
fn open_snapshot_file(path: &Path) -> io::Result<File> {
    use std::os::unix::fs::OpenOptionsExt;

    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
}

#[cfg(not(unix))]
fn open_snapshot_file(path: &Path) -> io::Result<File> {
    OpenOptions::new().read(true).open(path)
}

/// 与 lib/snapshot_core.sh::SNAPSHOT_SCHEMA_VERSION 对齐。
pub const CORE_SCHEMA_VERSION: u32 = 1;

fn default_threshold(kind: &str) -> u64 {
    match kind {
        "system" | "resources" => 60,
        "users" | "quota" | "smb" => 300,
        "hosts" | "gpu" | "manifest" => 120,
        "logs" => 60,
        "reports" => 300,
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
