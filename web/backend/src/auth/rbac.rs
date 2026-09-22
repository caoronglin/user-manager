//! 能力 RBAC：默认拒绝。未显式出现在 allowlist 的能力一律拒绝。
//!
//! 铁律（plan.md 0.3）：绝不把 `action_registry.sh` 的 `risk=safe` 当作 Web-safe。
//! Web 只在 `config.capabilities` 中显式列出的能力被授予；这里不存在
//! "Linux 特权 dangerous action" 的概念——危险操作在设计上就不在 Web。

use crate::config::{Capabilities, Config};

/// 依据角色返回能力集合；未知角色 → 空集合（默认拒绝）。
pub fn capabilities_for(config: &Config, role: &str) -> Capabilities {
    config
        .capabilities
        .get(role)
        .cloned()
        .unwrap_or(Capabilities {
            allowed: std::collections::BTreeSet::new(),
        })
}

/// 判定是否允许；默认拒绝。
pub fn is_allowed(config: &Config, role: &str, capability: &str) -> bool {
    capabilities_for(config, role).allows(capability)
}

/// 能力 → 只读快照 kind 映射的**白名单**（P2 使用，防止任意字段遍历）。
/// 未列出的 capability/kind 组合一律拒绝，绝不回退到任意路径。
pub const CAP_TO_SNAPSHOT: &[(&str, &str)] = &[
    ("users.read", "users"),
    ("quota.read", "quota"),
    ("resource.read", "resources"),
    ("smb.read", "smb"),
    ("hosts.read", "hosts"),
    ("gpu.read", "gpu"),
    ("dashboard.read", "system"),
    ("audit.read", "audit-summary"),
    ("logs.read", "logs"),
];

/// 读取某 kind 快照所需的 capability；未映射 → None（拒绝）。
pub fn capability_for_snapshot(kind: &str) -> Option<&'static str> {
    CAP_TO_SNAPSHOT
        .iter()
        .find(|(_, k)| *k == kind)
        .map(|(c, _)| *c)
}
