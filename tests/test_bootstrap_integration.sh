#!/bin/bash
# test_bootstrap_integration.sh - bootstrap 模块集成测试
# shellcheck disable=SC1091,SC2016

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"

run_project_bootstrap() {
    local script="$1"

    bash -c "$script" _ "$PROJECT_ROOT" 2>&1
}

test_suite_start "Bootstrap Integration"

test_start "bootstrap.sh 文件存在"
assert_file_exists "$PROJECT_ROOT/lib/bootstrap.sh"

test_start "bootstrap full profile 可加载"
if run_project_bootstrap 'set -uo pipefail; export SUDO_NONINTERACTIVE=1; export USER_MANAGER_DATA_BASE="$1/data"; export USER_MANAGER_BACKUP_ROOT="$1/data/backup"; SCRIPT_DIR="$1"; LIB_DIR="$1/lib"; source "$LIB_DIR/bootstrap.sh"; um_load_profile full' >/dev/null; then
    test_pass
else
    test_fail "full profile 加载失败"
fi

test_start "bootstrap full profile 加载 VM/GPU core"
if run_project_bootstrap 'set -uo pipefail; export SUDO_NONINTERACTIVE=1; export USER_MANAGER_DATA_BASE="$1/data"; export USER_MANAGER_BACKUP_ROOT="$1/data/backup"; SCRIPT_DIR="$1"; LIB_DIR="$1/lib"; source "$LIB_DIR/bootstrap.sh"; um_load_profile full || exit 1; declare -F list_virtual_machines >/dev/null && declare -F list_gpu_devices >/dev/null' >/dev/null; then
    test_pass
else
    test_fail "full profile 未加载 VM/GPU core"
fi

test_start "bootstrap 不再提供 v2 profile"
v2_profile_output="$(run_project_bootstrap 'set -uo pipefail; SCRIPT_DIR="$1"; LIB_DIR="$1/lib"; source "$LIB_DIR/bootstrap.sh"; um_load_profile v2' || true)"
if [[ "$v2_profile_output" == *"未知加载配置: v2"* ]]; then
    test_pass
else
    test_fail "bootstrap 仍然提供 v2 profile"
fi

test_start "bootstrap tui profile 可加载"
if run_project_bootstrap 'set -uo pipefail; export SUDO_NONINTERACTIVE=1; export USER_MANAGER_DATA_BASE="$1/data"; export USER_MANAGER_BACKUP_ROOT="$1/data/backup"; SCRIPT_DIR="$1"; LIB_DIR="$1/lib"; source "$LIB_DIR/bootstrap.sh"; um_load_profile tui' >/dev/null; then
    test_pass
else
    test_fail "tui profile 加载失败"
fi

test_start "未知 profile 返回失败并输出错误"
invalid_profile_output="$(run_project_bootstrap 'set -uo pipefail; SCRIPT_DIR="$1"; LIB_DIR="$1/lib"; source "$LIB_DIR/bootstrap.sh"; um_load_profile invalid_profile' || true)"
if [[ "$invalid_profile_output" == *"未知加载配置: invalid_profile"* ]]; then
    test_pass
else
    test_fail "未知 profile 未返回预期错误"
fi

test_start "profile 模块集合按 full/tui 区分加载"
profile_matrix_output="$(run_project_bootstrap 'set -uo pipefail; temp_root="$(mktemp -d)"; temp_lib="$temp_root/lib"; mkdir -p "$temp_lib"; cleanup() { rm -rf "$temp_root"; }; trap cleanup EXIT; modules=(common.sh ui_modern.sh config.sh env_core.sh action_registry.sh access_control.sh privilege.sh quota_core.sh user_core.sh email_core.sh audit_core.sh resource_core.sh backup_excludes.sh backup_core.sh backup_verify.sh firewall_core.sh dns_core.sh symlink_core.sh report_core.sh system_core.sh vm_core.sh gpu_core.sh tui_core.sh); for module in "${modules[@]}"; do printf "UM_TEST_LOADED_MODULES+=(\"%s\")\n" "$module" > "$temp_lib/$module"; done; SCRIPT_DIR="$1"; LIB_DIR="$temp_lib"; source "$1/lib/bootstrap.sh"; UM_TEST_LOADED_MODULES=(); um_load_profile full || exit 1; printf "full:%s\n" "${UM_TEST_LOADED_MODULES[*]}"; UM_TEST_LOADED_MODULES=(); unset USER_MANAGER_BOOTSTRAP_LOADED; source "$1/lib/bootstrap.sh"; um_load_profile tui || exit 1; printf "tui:%s\n" "${UM_TEST_LOADED_MODULES[*]}"')"
full_modules="$(printf '%s\n' "$profile_matrix_output" | grep '^full:')"
tui_modules="$(printf '%s\n' "$profile_matrix_output" | grep '^tui:')"
if [[ "$full_modules" == *"ui_modern.sh"* ]] && [[ "$full_modules" == *"vm_core.sh"* ]] && [[ "$full_modules" == *"gpu_core.sh"* ]] && [[ "$full_modules" != *"tui_core.sh"* ]] && [[ "$tui_modules" == *"tui_core.sh"* ]] && [[ "$tui_modules" != *"ui_modern.sh"* ]]; then
    test_pass
else
    test_fail "profile 模块加载集合与预期不一致"
fi

test_start "跨 profile 重复模块只加载一次"
cache_output="$(run_project_bootstrap 'set -uo pipefail; temp_root="$(mktemp -d)"; temp_lib="$temp_root/lib"; mkdir -p "$temp_lib"; cleanup() { rm -rf "$temp_root"; }; trap cleanup EXIT; modules=(common.sh config.sh env_core.sh action_registry.sh access_control.sh privilege.sh quota_core.sh user_core.sh tui_core.sh ui_modern.sh email_core.sh audit_core.sh resource_core.sh backup_excludes.sh backup_core.sh backup_verify.sh firewall_core.sh dns_core.sh symlink_core.sh report_core.sh system_core.sh vm_core.sh gpu_core.sh); for module in "${modules[@]}"; do if [[ "$module" == "common.sh" ]]; then printf "declare -gi COMMON_LOAD_COUNT=0\nCOMMON_LOAD_COUNT=\$((COMMON_LOAD_COUNT+1))\n" > "$temp_lib/$module"; else printf ":\n" > "$temp_lib/$module"; fi; done; SCRIPT_DIR="$1"; LIB_DIR="$temp_lib"; source "$1/lib/bootstrap.sh"; um_load_profile tui || exit 1; um_load_profile full || exit 1; printf "%s" "$COMMON_LOAD_COUNT"')"
if [[ "$cache_output" == "1" ]]; then
    test_pass
else
    test_fail "重复模块未被缓存，common.sh 加载次数=$cache_output"
fi

test_start "缺失模块时 profile 加载失败并报告路径"
missing_module_output="$(run_project_bootstrap 'set -uo pipefail; temp_root="$(mktemp -d)"; temp_lib="$temp_root/lib"; mkdir -p "$temp_lib"; cleanup() { rm -rf "$temp_root"; }; trap cleanup EXIT; modules=(common.sh config.sh env_core.sh action_registry.sh access_control.sh privilege.sh quota_core.sh user_core.sh tui_core.sh); for module in "${modules[@]}"; do printf ":\n" > "$temp_lib/$module"; done; SCRIPT_DIR="$1"; LIB_DIR="$temp_lib"; source "$1/lib/bootstrap.sh"; um_load_profile full' || true)"
if [[ "$missing_module_output" == *"模块不存在:"* ]] && [[ "$missing_module_output" == *"ui_modern.sh"* ]]; then
    test_pass
else
    test_fail "缺失模块时未返回预期错误"
fi

test_start "入口脚本 user_manager.sh 接入 bootstrap"
if grep -q 'source "\$LIB_DIR/bootstrap.sh"' "$PROJECT_ROOT/user_manager.sh"; then
    test_pass
else
    test_fail "user_manager.sh 未接入 bootstrap"
fi

test_start "兼容入口 user_manager_v2.sh 已移除"
assert_file_not_exists "$PROJECT_ROOT/user_manager_v2.sh" "user_manager_v2.sh 应已删除"

test_start "入口脚本 tui_manager.sh 接入 bootstrap"
if grep -q 'source "\$LIB_DIR/bootstrap.sh"' "$PROJECT_ROOT/tui_manager.sh"; then
    test_pass
else
    test_fail "tui_manager.sh 未接入 bootstrap"
fi

test_start "用户工作流控制器存在并导出 create_or_assign_user"
if run_project_bootstrap 'set -uo pipefail; export SUDO_NONINTERACTIVE=1; export USER_MANAGER_DATA_BASE="$1/data"; export USER_MANAGER_BACKUP_ROOT="$1/data/backup"; SCRIPT_DIR="$1"; LIB_DIR="$1/lib"; source "$LIB_DIR/bootstrap.sh"; um_load_profile full || exit 1; source "$LIB_DIR/controller_user_workflows.sh"; declare -F create_or_assign_user >/dev/null' >/dev/null; then
    test_pass
else
    test_fail "controller_user_workflows.sh 缺失或未导出 create_or_assign_user"
fi

test_start "用户工作流控制器导出 change_user_password"
if run_project_bootstrap 'set -uo pipefail; export SUDO_NONINTERACTIVE=1; export USER_MANAGER_DATA_BASE="$1/data"; export USER_MANAGER_BACKUP_ROOT="$1/data/backup"; SCRIPT_DIR="$1"; LIB_DIR="$1/lib"; source "$LIB_DIR/bootstrap.sh"; um_load_profile full || exit 1; source "$LIB_DIR/controller_user_workflows.sh"; declare -F change_user_password >/dev/null' >/dev/null; then
    test_pass
else
    test_fail "controller_user_workflows.sh 未导出 change_user_password"
fi

test_start "用户工作流控制器导出 delete/rename/suspend"
if run_project_bootstrap 'set -uo pipefail; export SUDO_NONINTERACTIVE=1; export USER_MANAGER_DATA_BASE="$1/data"; export USER_MANAGER_BACKUP_ROOT="$1/data/backup"; SCRIPT_DIR="$1"; LIB_DIR="$1/lib"; source "$LIB_DIR/bootstrap.sh"; um_load_profile full || exit 1; source "$LIB_DIR/controller_user_workflows.sh"; declare -F delete_user_account >/dev/null && declare -F rename_user_account >/dev/null && declare -F suspend_or_enable_user >/dev/null' >/dev/null; then
    test_pass
else
    test_fail "controller_user_workflows.sh 未完整导出 delete/rename/suspend"
fi

test_start "用户工作流控制器导出 quota/resource"
if run_project_bootstrap 'set -uo pipefail; export SUDO_NONINTERACTIVE=1; export USER_MANAGER_DATA_BASE="$1/data"; export USER_MANAGER_BACKUP_ROOT="$1/data/backup"; SCRIPT_DIR="$1"; LIB_DIR="$1/lib"; source "$LIB_DIR/bootstrap.sh"; um_load_profile full || exit 1; source "$LIB_DIR/controller_user_workflows.sh"; declare -F modify_user_quota >/dev/null && declare -F modify_user_resource_limits >/dev/null' >/dev/null; then
    test_pass
else
    test_fail "controller_user_workflows.sh 未完整导出 quota/resource"
fi

test_start "用户工作流控制器导出 list_managed_users"
if run_project_bootstrap 'set -uo pipefail; export SUDO_NONINTERACTIVE=1; export USER_MANAGER_DATA_BASE="$1/data"; export USER_MANAGER_BACKUP_ROOT="$1/data/backup"; SCRIPT_DIR="$1"; LIB_DIR="$1/lib"; source "$LIB_DIR/bootstrap.sh"; um_load_profile full || exit 1; source "$LIB_DIR/controller_user_workflows.sh"; declare -F list_managed_users >/dev/null' >/dev/null; then
    test_pass
else
    test_fail "controller_user_workflows.sh 未导出 list_managed_users"
fi

test_start "用户工作流已拆分为细粒度控制器文件"
if [[ -f "$PROJECT_ROOT/lib/controller_user_common.sh" ]] && [[ -f "$PROJECT_ROOT/lib/controller_user_listing.sh" ]] && [[ -f "$PROJECT_ROOT/lib/controller_user_passwords.sh" ]] && [[ -f "$PROJECT_ROOT/lib/controller_user_password_change.sh" ]] && [[ -f "$PROJECT_ROOT/lib/controller_user_notifications.sh" ]] && [[ -f "$PROJECT_ROOT/lib/controller_user_lifecycle.sh" ]] && [[ -f "$PROJECT_ROOT/lib/controller_user_provisioning.sh" ]] && [[ -f "$PROJECT_ROOT/lib/controller_user_provisioning_support.sh" ]] && [[ -f "$PROJECT_ROOT/lib/controller_user_limits.sh" ]]; then
    test_pass
else
    test_fail "缺少拆分后的用户控制器文件"
fi

test_start "用户工作流聚合控制器 source 全部子控制器"
if grep -q 'source "\$LIB_DIR/controller_user_common.sh"' "$PROJECT_ROOT/lib/controller_user_workflows.sh" && grep -q 'source "\$LIB_DIR/controller_user_listing.sh"' "$PROJECT_ROOT/lib/controller_user_workflows.sh" && grep -q 'source "\$LIB_DIR/controller_user_passwords.sh"' "$PROJECT_ROOT/lib/controller_user_workflows.sh" && grep -q 'source "\$LIB_DIR/controller_user_lifecycle.sh"' "$PROJECT_ROOT/lib/controller_user_workflows.sh" && grep -q 'source "\$LIB_DIR/controller_user_provisioning.sh"' "$PROJECT_ROOT/lib/controller_user_workflows.sh" && grep -q 'source "\$LIB_DIR/controller_user_limits.sh"' "$PROJECT_ROOT/lib/controller_user_workflows.sh"; then
    test_pass
else
    test_fail "controller_user_workflows.sh 未聚合全部子控制器"
fi

test_start "密码控制器 source 变更与通知子控制器"
if grep -q 'source "\$LIB_DIR/controller_user_password_change.sh"' "$PROJECT_ROOT/lib/controller_user_passwords.sh" && grep -q 'source "\$LIB_DIR/controller_user_notifications.sh"' "$PROJECT_ROOT/lib/controller_user_passwords.sh"; then
    test_pass
else
    test_fail "controller_user_passwords.sh 未聚合密码子控制器"
fi

test_start "创建控制器 source support 子控制器"
if grep -q 'source "\$LIB_DIR/controller_user_provisioning_support.sh"' "$PROJECT_ROOT/lib/controller_user_provisioning.sh"; then
    test_pass
else
    test_fail "controller_user_provisioning.sh 未聚合 support 子控制器"
fi

test_start "主入口接入用户工作流控制器"
if grep -q 'source "\$LIB_DIR/controller_user_workflows.sh"' "$PROJECT_ROOT/user_manager.sh"; then
    test_pass
else
    test_fail "user_manager.sh 未接入 controller_user_workflows.sh"
fi

test_start "入口脚本与 profile 绑定保持一致"
if grep -q 'um_load_profile full' "$PROJECT_ROOT/user_manager.sh" && grep -q 'um_load_profile tui' "$PROJECT_ROOT/tui_manager.sh"; then
    test_pass
else
    test_fail "入口脚本与 profile 的绑定不一致"
fi

test_suite_end
