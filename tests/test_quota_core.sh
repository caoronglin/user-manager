#!/bin/bash
# test_quota_core.sh - quota_core 组配额测试

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"

setup_test_env

source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/config.sh"
source "$PROJECT_ROOT/lib/quota_core.sh"

rl_setquota_log="$TEST_TMPDIR/setquota.log"

rl_priv_setquota() {
    printf '%s\n' "$*" >> "$rl_setquota_log"
}

rl_priv_repquota() {
    if [[ "${1:-}" == "-g" && "${2:-}" == "/home" ]]; then
        cat <<'EOF'
*** Report for group quotas on /home
Block grace time: 7days; Inode grace time: 7days
                        Block limits                File limits
Group           used    soft    hard  grace    used  soft  hard  grace
----------------------------------------------------------------------
testgroup --    1024    2048    2048              0     0     0
other     --       0       0       0              0     0     0
EOF
        return 0
    fi
    return 1
}

setquota() { return 0; }
repquota() { rl_priv_repquota "$@"; }
mountpoint() { return 0; }

test_suite_start "Quota Core group mode"

test_start "rl_quota_set_group: 使用组模式调用 setquota"
if rl_quota_set_group testgroup 4096 /home >/dev/null 2>&1 && \
   [[ "$(cat "$rl_setquota_log" 2>/dev/null)" == "-g testgroup 4096 4096 0 0 /home" ]]; then
    test_pass
else
    test_fail "未按组模式调用 rl_priv_setquota"
fi

test_start "rl_quota_get_group: 查询并筛选组配额行"
rl_group_quota="$(rl_quota_get_group testgroup /home 2>/dev/null || true)"
if [[ "$rl_group_quota" == testgroup\ --* ]]; then
    test_pass
else
    test_fail "未返回 testgroup 配额行: $rl_group_quota"
fi

test_start "rl_quota_set_group: 缺少参数时失败"
if ! rl_quota_set_group "" 4096 /home >/dev/null 2>&1; then
    test_pass
else
    test_fail "缺少组名时应失败"
fi

test_start "rl_quota_get_group: 缺少组名时失败"
if ! rl_quota_get_group "" /home >/dev/null 2>&1; then
    test_pass
else
    test_fail "缺少组名时应失败"
fi

cleanup_test_env
test_suite_end
