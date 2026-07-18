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

priv_setquota() {
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
id() { [[ "${1:-}" == "alice" ]]; }
get_user_email() { [[ "${1:-}" == "alice" ]] && printf 'alice@example.com\n'; }
send_quota_hard_limit_email() {
    printf 'quota-mail %s|%s|%s|%s\n' "$1" "$2" "$3" "${4:-}" >> "$rl_setquota_log"
    [[ "${RL_QUOTA_MAIL_FAIL:-0}" != "1" ]]
}

test_suite_start "Quota Core group mode"

test_start "set_user_quota: 用户配额使用向上取整 KB 且 soft=hard"
: > "$rl_setquota_log"
if set_user_quota alice 1073741825 /home >/dev/null 2>&1 && \
   grep -q '^-u alice 1048577 1048577 0 0 /home$' "$rl_setquota_log"; then
    test_pass
else
    test_fail "用户配额未按字节向上取整为 KB 或 soft/hard 不一致"
fi

test_start "set_user_quota: 0 字节配额无效"
: > "$rl_setquota_log"
if ! set_user_quota alice 0 /home >/dev/null 2>&1 && [[ ! -s "$rl_setquota_log" ]]; then
    test_pass
else
    test_fail "0 字节配额应被拒绝且不调用 setquota"
fi

test_start "set_user_quota: 设置成功后发送硬配额通知且通知失败不阻断"
: > "$rl_setquota_log"
if set_user_quota alice 1073741824 /home >/dev/null 2>&1 && \
   grep -q '^quota-mail alice|alice@example.com|1.0 GB|' "$rl_setquota_log"; then
    RL_QUOTA_MAIL_FAIL=1
    set_user_quota alice 1073741824 /home >/dev/null 2>&1
    mail_fail_rc=$?
    unset RL_QUOTA_MAIL_FAIL
    if [[ "$mail_fail_rc" == "0" ]]; then
        test_pass
    else
        test_fail "通知失败不应阻断配额设置成功"
    fi
else
    test_fail "配额设置成功后未触发硬配额通知"
fi

test_start "rl_quota_set_group: 输入字节时按 KB 设置软/硬配额"
: > "$rl_setquota_log"
if rl_quota_set_group testgroup 1073741824 /home >/dev/null 2>&1 && \
   [[ "$(cat "$rl_setquota_log" 2>/dev/null)" == "-g testgroup 1048576 1048576 0 0 /home" ]]; then
    test_pass
else
    test_fail "未将字节正确转换为 KB 或未正确设置软/硬配额"
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

test_start "rl_quota_set_group: 非数字配额时失败"
if ! rl_quota_set_group testgroup "1G" /home >/dev/null 2>&1; then
    test_pass
else
    test_fail "非数字配额时应失败"
fi

test_start "rl_quota_get_group: 缺少组名时失败"
if ! rl_quota_get_group "" /home >/dev/null 2>&1; then
    test_pass
else
    test_fail "缺少组名时应失败"
fi


test_start "show_disk_usage_warnings: 非 TTY 输出纯文本且不重复百分比"
old_all_disks=("${ALL_DISKS[@]}")
old_data_base="$DATA_BASE"
old_threshold="$DISK_WARNING_THRESHOLD"
ALL_DISKS=(5)
DATA_BASE="$TEST_TMPDIR/mnt"
DISK_WARNING_THRESHOLD=90
mkdir -p "$DATA_BASE/data05"
mountpoint() { local p="${2:-$1}"; [[ "$p" == "$DATA_BASE/data05" ]]; }
df() {
    printf 'Filesystem 1K-blocks Used Available Use%% Mounted on\n'
    printf '/dev/mock 1000 960 40 96%% %s\n' "$DATA_BASE/data05"
}
warning_output="$(show_disk_usage_warnings 2>&1)"
warning_pct_count=$(printf '%s\n' "$warning_output" | grep -o '96%' | wc -l | tr -d ' ')
if [[ "$warning_output" == *"WARNING data05 96% > 90%"* ]] && \
   [[ "$warning_output" != *$'\033'* ]] && \
   [[ "$warning_pct_count" == "1" ]]; then
    test_pass
else
    test_fail "非 TTY 告警应为纯文本且只出现一次 96%，输出: $warning_output"
fi

test_start "show_disk_usage_warnings: 强制 TTY 输出不重复百分比"
USER_MANAGER_FORCE_TTY=1
tty_warning_output="$(show_disk_usage_warnings 2>&1)"
unset USER_MANAGER_FORCE_TTY
tty_pct_count=$(printf '%s\n' "$tty_warning_output" | grep -o '96%' | wc -l | tr -d ' ')
if [[ "$tty_pct_count" == "1" ]] && [[ "$tty_warning_output" == *"> 90%"* ]]; then
    test_pass
else
    test_fail "TTY 告警不应重复 96%，输出: $tty_warning_output"
fi
ALL_DISKS=("${old_all_disks[@]}")
DATA_BASE="$old_data_base"
DISK_WARNING_THRESHOLD="$old_threshold"
unset -f mountpoint df

cleanup_test_env
test_suite_end
