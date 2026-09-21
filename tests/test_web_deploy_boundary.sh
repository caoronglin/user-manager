#!/bin/bash
# tests/test_web_deploy_boundary.sh — 部署权限边界静态断言（plan.md 12.3 / 14.5）
#
# 在当前环境无法启动/运行 systemd 服务的前提下，用静态断言锁定 umweb / 采集器
# systemd 单元的关键「永不提权」与「只读快照」边界，防止回归。

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/test_framework.sh"
setup_test_env
test_suite_start "Web deploy boundary (systemd)"

UMWEB_UNIT="$PROJECT_ROOT/etc/systemd/system/umweb.service"
SNAP_UNIT="$PROJECT_ROOT/etc/systemd/system/um-snapshot.service"

# 断言单元文件包含某条（去掉空白后精确匹配 key=value）指令。
has_directive() {
    local file="$1" want="$2"
    grep -Eq "^[[:space:]]*${want//./\\.}[[:space:]]*$" "$file"
}

test_start "umweb.service 存在"
if [[ -f "$UMWEB_UNIT" ]]; then test_pass
else test_fail "缺少 umweb.service"; fi

test_start "umweb.service 以非 root 用户 umweb 运行"
if has_directive "$UMWEB_UNIT" "User=umweb" && has_directive "$UMWEB_UNIT" "Group=umweb"; then
    test_pass
else
    test_fail "umweb 未绑定到非特权用户/组"
fi

test_start "umweb.service 禁止提权（NoNewPrivileges + 空能力集）"
if has_directive "$UMWEB_UNIT" "NoNewPrivileges=yes" &&
    has_directive "$UMWEB_UNIT" "CapabilityBoundingSet=" &&
    has_directive "$UMWEB_UNIT" "AmbientCapabilities=" &&
    has_directive "$UMWEB_UNIT" "RestrictSUIDSGID=yes"; then
    test_pass
else
    test_fail "umweb 缺少禁止提权的硬约束"
fi

test_start "umweb.service 只读快照 + 系统strict保护"
if has_directive "$UMWEB_UNIT" "ProtectSystem=strict" &&
    has_directive "$UMWEB_UNIT" "ReadOnlyPaths=/var/lib/user-manager-web/snapshots" &&
    has_directive "$UMWEB_UNIT" "ReadWritePaths=/var/lib/user-manager-web"; then
    test_pass
else
    test_fail "umweb 的读写路径/系统保护配置异常"
fi

test_start "采集器由 root 运行且与 umweb 分离"
if has_directive "$SNAP_UNIT" "User=root" &&
    has_directive "$SNAP_UNIT" "ReadWritePaths=/var/lib/user-manager-web/snapshots"; then
    test_pass
else
    test_fail "采集器单元配置异常"
fi

test_start "仓库未新增 umweb sudoers 授权"
if grep -rniE 'umweb.*NOPASSWD|^%umweb' "$PROJECT_ROOT/etc" 2>/dev/null; then
    test_fail "发现 umweb sudoers 授权"
else
    test_pass
fi

cleanup_test_env
test_suite_end
