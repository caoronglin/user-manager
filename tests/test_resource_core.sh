#!/bin/bash
# test_resource_core.sh - systemd cgroup v2 资源限制测试

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$PROJECT_ROOT/lib"

source "$SCRIPT_DIR/test_framework.sh"

setup_test_env

export SUDO_NONINTERACTIVE=1
export USER_MANAGER_DATA_BASE="$TEST_TMPDIR/data"
export USER_MANAGER_BACKUP_ROOT="$TEST_TMPDIR/data/backup"
export RL_RESOURCE_LIMIT_UNIT_BASE="$TEST_TMPDIR/etc/systemd/system"
export RL_RESOURCE_MEMORY_HIGH="6G"
export RL_RESOURCE_TASKS_MAX="4096"
export RL_RESOURCE_IO_READ_BANDWIDTH_MAX="/dev/nvme0n1 200M"
export RL_RESOURCE_IO_WRITE_BANDWIDTH_MAX="/dev/nvme0n1 100M"

source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/config.sh"
source "$PROJECT_ROOT/lib/resource_core.sh"

rl_test_uid="4242"
rl_test_user="rltest"
declare -A rl_test_uid_map=(
    ["$rl_test_user"]="$rl_test_uid"
    ["rlgroupa"]="5101"
    ["rlgroupb"]="5102"
)
rl_systemctl_log="$TEST_TMPDIR/systemctl.log"

id() {
    if [[ "${1:-}" == "-u" && -n "${rl_test_uid_map[${2:-}]:-}" ]]; then
        printf '%s\n' "${rl_test_uid_map[${2:-}]}"
        return 0
    fi
    [[ "${1:-}" == "$rl_test_user" ]] && return 0
    command id "$@"
}

getent() {
    if [[ "${1:-}" == "group" && "${2:-}" == "testgroup" ]]; then
        printf '%s\n' 'testgroup:x:6000:rlgroupb,rlgroupa'
        return 0
    fi
    command getent "$@"
}

priv_mkdir() { command mkdir "$@"; }
priv_chown() { return 0; }
priv_chmod() { return 0; }
priv_systemctl() {
    printf '%s\n' "$*" >>"$rl_systemctl_log"
    return 0
}
priv_tee() {
    local rl_target="$1"
    command mkdir -p "$(dirname "$rl_target")"
    command tee "$rl_target"
}
priv_rm() { command rm "$@"; }
priv_rmdir() { command rmdir "$@"; }

test_suite_start "Resource Core cgroup2"

rl_expected_dir="$RL_RESOURCE_LIMIT_UNIT_BASE/user-${rl_test_uid}.slice.d"
rl_expected_file="$rl_expected_dir/$RESOURCE_LIMIT_FILENAME"

test_start "configure_resource_limits: 写入 user-UID.slice cgroup2 drop-in"
if configure_resource_limits "$rl_test_user" "150%" "8G" >/dev/null 2>&1 && [[ -f "$rl_expected_file" ]]; then
    test_pass
else
    test_fail "未写入 $rl_expected_file"
fi

rl_rendered_config="$(cat "$rl_expected_file" 2>/dev/null || true)"

test_start "configure_resource_limits: 使用 Slice 段和 DeepWiki 确认的 cgroup2 参数"
if [[ "$rl_rendered_config" == *"[Slice]"* ]] &&
    [[ "$rl_rendered_config" == *"CPUAccounting=yes"* ]] &&
    [[ "$rl_rendered_config" == *"CPUQuota=150%"* ]] &&
    [[ "$rl_rendered_config" == *"MemoryAccounting=yes"* ]] &&
    [[ "$rl_rendered_config" == *"MemoryHigh=6G"* ]] &&
    [[ "$rl_rendered_config" == *"MemoryMax=8G"* ]] &&
    [[ "$rl_rendered_config" == *"TasksAccounting=yes"* ]] &&
    [[ "$rl_rendered_config" == *"TasksMax=4096"* ]] &&
    [[ "$rl_rendered_config" == *"IOAccounting=yes"* ]] &&
    [[ "$rl_rendered_config" == *"IOReadBandwidthMax=/dev/nvme0n1 200M"* ]] &&
    [[ "$rl_rendered_config" == *"IOWriteBandwidthMax=/dev/nvme0n1 100M"* ]]; then
    test_pass
else
    test_fail "cgroup2 参数不完整: $rl_rendered_config"
fi

test_start "configure_resource_limits: 通过 systemctl set-property 即时应用"
rl_systemctl_output="$(cat "$rl_systemctl_log" 2>/dev/null || true)"
if [[ "$rl_systemctl_output" == *"daemon-reload"* ]] &&
    [[ "$rl_systemctl_output" == *"set-property --runtime user-${rl_test_uid}.slice"* ]] &&
    [[ "$rl_systemctl_output" == *"CPUQuota=150%"* ]] &&
    [[ "$rl_systemctl_output" == *"MemoryMax=8G"* ]] &&
    [[ "$rl_systemctl_output" == *"TasksMax=4096"* ]]; then
    test_pass
else
    test_fail "未按预期调用 systemctl set-property: $rl_systemctl_output"
fi

test_start "get_current_resource_limits: 从 user-UID.slice drop-in 读取 CPU 和内存"
rl_current_limits="$(get_current_resource_limits "$rl_test_user" 2>/dev/null || true)"
assert_equals "150%:8G" "$rl_current_limits" "应读取 slice drop-in"

test_start "remove_resource_limits: 移除 user-UID.slice drop-in"
if remove_resource_limits "$rl_test_uid" >/dev/null 2>&1 && [[ ! -f "$rl_expected_file" ]]; then
    test_pass
else
    test_fail "未移除 $rl_expected_file"
fi

test_start "remove_resource_limits: 重置运行时 set-property"
rl_systemctl_output="$(cat "$rl_systemctl_log" 2>/dev/null || true)"
if [[ "$rl_systemctl_output" == *"set-property --runtime user-${rl_test_uid}.slice CPUQuota= MemoryHigh=infinity MemoryMax=infinity TasksMax=infinity"* ]]; then
    test_pass
else
    test_fail "移除时未重置运行时资源限制: $rl_systemctl_output"
fi

test_start "rl_resource_list_group_members: 返回排序后的组成员列表"
rl_group_members="$(rl_resource_list_group_members testgroup 2>/dev/null || true)"
assert_equals $'rlgroupa\nrlgroupb' "$rl_group_members" "应读取 getent group 成员"

test_start "rl_resource_policy_apply_group: 为每个组成员创建资源配置"
if rl_resource_policy_apply_group testgroup "100%" "4G" >/dev/null 2>&1 &&
    [[ -f "$(rl_resource_config_file 5101)" ]] &&
    [[ -f "$(rl_resource_config_file 5102)" ]]; then
    test_pass
else
    test_fail "未为 testgroup 所有成员创建资源配置"
fi

test_start "rl_resource_policy_remove_group: 移除每个组成员资源配置"
if rl_resource_policy_remove_group testgroup >/dev/null 2>&1 &&
    [[ ! -f "$(rl_resource_config_file 5101)" ]] &&
    [[ ! -f "$(rl_resource_config_file 5102)" ]]; then
    test_pass
else
    test_fail "未移除 testgroup 所有成员资源配置"
fi

# PAM limits 回归：测试重定向目标到临时目录，禁止访问真实 /etc。
rl_resource_ulimit_file() { printf '%s/pam/%s.conf\n' "$TEST_TMPDIR" "$1"; }
write_privileged_text_file() {
    local target="$1"
    command mkdir -p "$(dirname "$target")"
    cat >"$target"
}
test_start "PAM limits: 正确写出 soft/hard 四列，且相同限额可重复设置"
pam_file="$(rl_resource_ulimit_file "$rl_test_user")"
if set_user_ulimit "$rl_test_user" nofile 65535 524288 >/dev/null 2>&1 &&
    set_user_ulimit "$rl_test_user" nofile 65535 524288 >/dev/null 2>&1 &&
    [[ "$(grep -c "^rltest soft nofile 65535$" "$pam_file")" == 1 ]] &&
    [[ "$(grep -c "^rltest hard nofile 524288$" "$pam_file")" == 1 ]]; then
    test_pass
else
    test_fail "PAM 四列格式错误或产生重复项"
fi

test_start "PAM limits: 相等软硬限额也应成功"
if set_user_ulimit "$rl_test_user" nproc 4096 4096 >/dev/null 2>&1 &&
    grep -qx 'rltest soft nproc 4096' "$pam_file" &&
    grep -qx 'rltest hard nproc 4096' "$pam_file"; then
    test_pass
else
    test_fail "软硬限额相等时配置失败"
fi

test_start "PAM limits: 删除指定项不影响其他资源"
if remove_user_ulimit "$rl_test_user" nofile >/dev/null 2>&1 &&
    ! grep -q 'nofile' "$pam_file" &&
    grep -qx 'rltest hard nproc 4096' "$pam_file"; then
    test_pass
else
    test_fail "删除 nofile 后破坏其他资源配置"
fi

test_start "PAM limits: 拒绝软限额超过硬限额及非法资源"
if ! set_user_ulimit "$rl_test_user" nofile 70000 60000 >/dev/null 2>&1 &&
    ! set_user_ulimit "$rl_test_user" bogus 1 2 >/dev/null 2>&1 &&
    ! set_user_ulimit "$rl_test_user" nofile 999999999999999999999 0 >/dev/null 2>&1; then
    test_pass
else
    test_fail "无效限额/资源类型未拒绝"
fi

test_start "PAM limits: 删除最后一个资源后移除管理文件"
if remove_user_ulimit "$rl_test_user" nproc >/dev/null 2>&1 &&
    [[ ! -e "$pam_file" ]]; then
    test_pass
else
    test_fail "空的管理文件应被移除"
fi

test_start "资源限制：--effective 只读展示真实 TasksMax 和继承后的 EffectiveTasksMax"
systemctl() {
    if [[ "${1:-}" == show && "${2:-}" == "user-4242.slice" ]]; then
        printf 'LoadState=loaded\nTasksMax=infinity\nEffectiveTasksMax=1024\nTasksCurrent=36\n'
        return 0
    fi
    return 1
}
effective_out="$(rl_resource_effective_tasks "$rl_test_user" 2>/dev/null || true)"
unset -f systemctl
if [[ "$effective_out" == *"unit=user-4242.slice"* ]] &&
    [[ "$effective_out" == *"TasksMax=infinity"* ]] &&
    [[ "$effective_out" == *"EffectiveTasksMax=1024"* ]]; then
    test_pass
else
    test_fail "未正确读取有效任务上限: $effective_out"
fi

cleanup_test_env
test_suite_end
