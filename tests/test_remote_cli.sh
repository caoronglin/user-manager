#!/bin/bash
# test_remote_cli.sh - 主机 CLI 与远端白名单入口契约测试

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/test_framework.sh"
setup_test_env
test_suite_start "Remote CLI"

hosts_cli="$PROJECT_ROOT/scripts/rl-hosts.sh"
remote_entry="$PROJECT_ROOT/scripts/rl-remote-entry.sh"

test_start "主机 CLI 与远端入口存在且可执行"
if [[ -x "$hosts_cli" && -x "$remote_entry" ]]; then
    test_pass
else test_fail "缺少可执行主机入口"; fi

test_start "两个入口 --help 均成功"
if bash "$hosts_cli" --help >/dev/null 2>&1 && bash "$remote_entry" --help >/dev/null 2>&1; then
    test_pass
else test_fail "入口 help 失败"; fi

test_start "远端入口 host.probe 输出版本化只读协议"
probe_output="$(bash "$remote_entry" host.probe 2>/dev/null || true)"
if [[ "$probe_output" == *"protocol=user-manager-readonly-v1"* ]] &&
    [[ "$probe_output" == *"action=host.probe"* ]] && [[ "$probe_output" == *"status=success"* ]] &&
    [[ "$probe_output" == *"end=1"* ]]; then
    test_pass
else test_fail "远端 host.probe 输出异常: $probe_output"; fi

test_start "远端入口拒绝写 action、多余参数和注入形态"
marker="$TEST_TMPDIR/remote-entry-injection"
if ! bash "$remote_entry" users.create >/dev/null 2>&1 &&
    ! bash "$remote_entry" host.probe extra >/dev/null 2>&1 &&
    ! bash "$remote_entry" "host.probe;touch $marker" >/dev/null 2>&1 && [[ ! -e "$marker" ]]; then
    test_pass
else test_fail "远端白名单可被绕过"; fi

test_start "远端入口 gpu.summary 使用稳定协议和退出语义"
gpu_rc=0
gpu_output="$(bash "$remote_entry" gpu.summary 2>/dev/null)" || gpu_rc=$?
if ((gpu_rc == 0 || gpu_rc == 1 || gpu_rc == 4)) &&
    [[ "$gpu_output" == *"protocol=user-manager-readonly-v1"* ]] &&
    [[ "$gpu_output" == *"action=gpu.summary"* ]] && [[ "$gpu_output" == *"end=1"* ]]; then
    test_pass
else test_fail "远端 GPU 协议异常: rc=$gpu_rc output=$gpu_output"; fi

test_start "主机 CLI 默认缺失 Inventory 时列出内置本机"
export USER_MANAGER_HOSTS_FILE="$TEST_TMPDIR/missing-hosts.conf"
list_output="$(USER_MANAGER_DATA_BASE="$TEST_TMPDIR/data" bash "$hosts_cli" list 2>/dev/null || true)"
if [[ "$list_output" == *"host_id|display_name|provider"* ]] && [[ "$list_output" == *"local|当前主机|local"* ]]; then
    test_pass
else test_fail "默认本机清单输出异常: $list_output"; fi

test_start "主机 CLI dry-run 仅生成本地计划"
dry_output="$(USER_MANAGER_DATA_BASE="$TEST_TMPDIR/data" bash "$hosts_cli" probe local --dry-run 2>/dev/null || true)"
if [[ "$dry_output" == *"plan.action=host.probe"* ]] && [[ "$dry_output" == *"plan.mode=dry-run"* ]] &&
    [[ "$dry_output" == *"summary.not_executed=1"* ]]; then
    test_pass
else test_fail "CLI dry-run 输出异常: $dry_output"; fi

test_start "主机 CLI 显式不存在 Inventory 返回非零"
if ! USER_MANAGER_DATA_BASE="$TEST_TMPDIR/data" bash "$hosts_cli" --inventory "$TEST_TMPDIR/not-found.conf" validate >/dev/null 2>&1; then
    test_pass
else test_fail "显式不存在 Inventory 被接受"; fi

test_start "主机 CLI 拒绝未知命令和多余参数"
if ! bash "$hosts_cli" shell >/dev/null 2>&1 && ! bash "$hosts_cli" probe local extra >/dev/null 2>&1; then
    test_pass
else test_fail "CLI 参数白名单可被绕过"; fi

cleanup_test_env
test_suite_end
