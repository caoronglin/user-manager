#!/bin/bash
# test_vm_core.sh - 虚拟机管理核心模块测试

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

export SUDO_NONINTERACTIVE="${SUDO_NONINTERACTIVE:-1}"
export USER_MANAGER_DATA_BASE="${USER_MANAGER_DATA_BASE:-$PROJECT_ROOT/data}"
export USER_MANAGER_BACKUP_ROOT="${USER_MANAGER_BACKUP_ROOT:-$PROJECT_ROOT/data/backup}"

source "$SCRIPT_DIR/test_framework.sh"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/config.sh"
source "$PROJECT_ROOT/lib/access_control.sh"
source "$PROJECT_ROOT/lib/privilege.sh"

if [[ -f "$PROJECT_ROOT/lib/vm_core.sh" ]]; then
    # shellcheck disable=SC1091
    source "$PROJECT_ROOT/lib/vm_core.sh"
fi

setup_test_env
test_suite_start "VM Core"

test_start "vm_core.sh 文件存在"
assert_file_exists "$PROJECT_ROOT/lib/vm_core.sh"

test_start "VM core 导出基础函数"
if declare -F list_virtual_machines >/dev/null && \
   declare -F show_virtual_machine_status >/dev/null && \
   declare -F start_virtual_machine >/dev/null && \
   declare -F shutdown_virtual_machine >/dev/null && \
   declare -F reboot_virtual_machine >/dev/null && \
   declare -F destroy_virtual_machine >/dev/null && \
   declare -F set_virtual_machine_autostart >/dev/null; then
    test_pass
else
    test_fail "VM core 未导出预期管理函数"
fi

test_start "virsh 命令进入权限白名单"
if priv_check_whitelist virsh >/dev/null 2>&1 && declare -F priv_virsh >/dev/null; then
    test_pass
else
    test_fail "virsh 未纳入 privilege.sh 白名单或缺少 priv_virsh 包装"
fi

test_start "list_virtual_machines 使用 virsh list --all"
virsh() {
    printf '%s\n' "$*" >> "$TEST_TMPDIR/virsh.calls"
    if [[ "${1:-}" == "list" && "${2:-}" == "--all" ]]; then
        printf ' Id   Name       State\n'
        printf ' -    demo-vm    shut off\n'
        return 0
    fi
    return 1
}
if declare -F list_virtual_machines >/dev/null && vm_output="$(list_virtual_machines 2>/dev/null)" && [[ "$vm_output" == *"demo-vm"* ]] && grep -qxF 'list --all' "$TEST_TMPDIR/virsh.calls"; then
    test_pass
else
    test_fail "list_virtual_machines 未按预期调用 virsh list --all"
fi

test_start "show_virtual_machine_status 查询指定虚拟机状态"
virsh() {
    printf '%s\n' "$*" >> "$TEST_TMPDIR/virsh-status.calls"
    if [[ "${1:-}" == "domstate" && "${2:-}" == "demo-vm" ]]; then
        printf 'running\n'
        return 0
    fi
    return 1
}
if declare -F show_virtual_machine_status >/dev/null && status_output="$(show_virtual_machine_status demo-vm 2>/dev/null)" && [[ "$status_output" == *"running"* ]] && grep -qxF 'domstate demo-vm' "$TEST_TMPDIR/virsh-status.calls"; then
    test_pass
else
    test_fail "show_virtual_machine_status 未按预期查询 domstate"
fi

test_start "生命周期操作通过 priv_virsh 执行"
priv_virsh() {
    printf '%s\n' "$*" >> "$TEST_TMPDIR/priv_virsh.calls"
    return 0
}
if declare -F start_virtual_machine >/dev/null && \
   declare -F shutdown_virtual_machine >/dev/null && \
   declare -F reboot_virtual_machine >/dev/null && \
   start_virtual_machine demo-vm >/dev/null 2>&1 && \
   shutdown_virtual_machine demo-vm >/dev/null 2>&1 && \
   reboot_virtual_machine demo-vm >/dev/null 2>&1 && \
   grep -qxF 'start demo-vm' "$TEST_TMPDIR/priv_virsh.calls" && \
   grep -qxF 'shutdown demo-vm' "$TEST_TMPDIR/priv_virsh.calls" && \
   grep -qxF 'reboot demo-vm' "$TEST_TMPDIR/priv_virsh.calls"; then
    test_pass
else
    test_fail "VM 生命周期操作未通过 priv_virsh 执行"
fi

test_start "空虚拟机名会被拒绝"
if declare -F start_virtual_machine >/dev/null && ! start_virtual_machine "" >/dev/null 2>&1; then
    test_pass
else
    test_fail "空虚拟机名不应被接受"
fi

cleanup_test_env
test_suite_end
