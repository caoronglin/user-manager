#!/bin/bash
# test_scripts.sh - 独立脚本入口测试
set -uo pipefail

rl_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$rl_script_dir")"

rl_shell_files=()
rl_shell_list_error=""
rl_shell_list_file=""

if ! command -v git >/dev/null 2>&1; then
    rl_shell_list_error="git 不可用"
elif ! git -C "$PROJECT_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    rl_shell_list_error="项目目录不是 Git 工作树"
elif ! rl_shell_list_file="$(mktemp)"; then
    rl_shell_list_error="无法创建 Shell 文件清单"
elif ! git -C "$PROJECT_ROOT" ls-files -z -- \
    run.sh \
    user_manager.sh \
    verify_fixes.sh \
    'scripts/*.sh' \
    'lib/*.sh' \
    'tests/*.sh' >"$rl_shell_list_file"; then
    rl_shell_list_error="无法读取 Git 跟踪清单"
else
    while IFS= read -r -d '' rl_file; do
        # 工作区中已删除/尚未提交删除的 Git 跟踪文件不参与静态检查。
        [[ -f "$PROJECT_ROOT/$rl_file" ]] || continue
        case "$rl_file" in
        lib/tui_core.sh | lib/tui_*.sh | lib/ui_*.sh | tests/test_tui_*.sh)
            continue
            ;;
        esac
        rl_shell_files+=("$rl_file")
    done <"$rl_shell_list_file"

    if ((${#rl_shell_files[@]} == 0)); then
        rl_shell_list_error="Git 跟踪清单为空"
    fi
fi

if [[ -n "$rl_shell_list_file" ]]; then
    rm -f -- "$rl_shell_list_file"
fi

source "$rl_script_dir/test_framework.sh"

test_suite_start "Standalone Scripts"

test_start "setup_test_env 保留 mktemp 失败状态"
rl_setup_test_env_output=$(bash -c '
    source "$1" || exit 90
    declare -F setup_test_env >/dev/null || exit 91
    mktemp() { return 73; }
    setup_test_env
' _ "$PROJECT_ROOT/tests/test_framework.sh" 2>&1)
rl_setup_test_env_status=$?
if ((rl_setup_test_env_status == 1)); then
    test_pass
elif ((rl_setup_test_env_status == 0)); then
    test_fail "setup_test_env 掩盖了 mktemp 失败（输出: $rl_setup_test_env_output）"
else
    test_fail "测试前置条件失败，退出码为 $rl_setup_test_env_status（输出: $rl_setup_test_env_output）"
fi

test_start "非 TUI 项目 Shell 文件通过 bash -n"
rl_syntax_failure=""
if [[ -n "$rl_shell_list_error" ]]; then
    rl_syntax_failure="$rl_shell_list_error"
else
    for rl_file in "${rl_shell_files[@]}"; do
        if ! rl_syntax_output=$(bash -n "$PROJECT_ROOT/$rl_file" 2>&1); then
            rl_syntax_failure="$rl_file: $rl_syntax_output"
            break
        fi
    done
fi

if [[ -z "$rl_syntax_failure" ]]; then
    test_pass
else
    test_fail "$rl_syntax_failure"
fi

# 全量 ShellCheck warning 门禁默认不随 P1 运行（CI 已有独立 ShellCheck job），
# 需要时用 UM_INCLUDE_LINT=1 或 run_regression.sh --include-lint 显式开启。
if [[ "${UM_INCLUDE_LINT:-0}" == "1" ]]; then
    test_start "非 TUI 项目 Shell 文件通过 ShellCheck warning 门禁"
    if ! command -v shellcheck >/dev/null 2>&1; then
        test_fail "shellcheck 不可用"
    elif [[ -n "$rl_shell_list_error" ]]; then
        test_fail "$rl_shell_list_error"
    elif rl_shellcheck_output=$(
        cd "$PROJECT_ROOT" || exit 1
        shellcheck -x -S warning --format=gcc "${rl_shell_files[@]}" 2>&1
    ); then
        test_pass
    else
        rl_shellcheck_rc=$?
        test_fail "shellcheck 退出码 $rl_shellcheck_rc: $rl_shellcheck_output"
    fi
fi

for rl_script in rl-user-list rl-user-create rl-user-quota rl-user-resource rl-mail-test rl-backup-run rl-audit-query rl-smb-manage rl-action-list rl-hosts rl-remote-entry; do
    test_start "scripts/$rl_script.sh 存在且可执行"
    if [[ -x "$PROJECT_ROOT/scripts/$rl_script.sh" ]]; then
        test_pass
    else
        test_fail "scripts/$rl_script.sh 不存在或不可执行"
    fi
done

test_start "scripts/rl-user-list.sh --help 退出码为 0"
if bash "$PROJECT_ROOT/scripts/rl-user-list.sh" --help >/dev/null 2>&1; then
    test_pass
else
    test_fail "rl-user-list.sh --help 返回非零"
fi

test_start "scripts/rl-system-overview.sh 存在且可执行"
if [[ -x "$PROJECT_ROOT/scripts/rl-system-overview.sh" ]]; then
    test_pass
else
    test_fail "scripts/rl-system-overview.sh 不存在或不可执行"
fi

test_start "scripts/rl-system-overview.sh --help 退出码为 0"
if bash "$PROJECT_ROOT/scripts/rl-system-overview.sh" --help >/dev/null 2>&1; then
    test_pass
else
    test_fail "rl-system-overview.sh --help 返回非零"
fi

test_start "scripts/rl-smb-manage.sh --help 退出码为 0"
if bash "$PROJECT_ROOT/scripts/rl-smb-manage.sh" --help >/dev/null 2>&1; then
    test_pass
else
    test_fail "rl-smb-manage.sh --help 返回非零"
fi

test_start "scripts/rl-action-list.sh --help 退出码为 0"
if bash "$PROJECT_ROOT/scripts/rl-action-list.sh" --help >/dev/null 2>&1; then
    test_pass
else
    test_fail "rl-action-list.sh --help 返回非零"
fi

test_start "未跟踪的远程基础 Shell 文件显式通过语法门禁"
remote_shell_files=(
    lib/host_inventory.sh lib/host_probe_core.sh lib/host_provider.sh lib/execution_plan.sh
    scripts/rl-hosts.sh scripts/rl-remote-entry.sh
    tests/test_host_inventory.sh tests/test_host_provider.sh tests/test_execution_plan.sh tests/test_remote_cli.sh
)
remote_syntax_failure=""
for rl_file in "${remote_shell_files[@]}"; do
    if [[ ! -f "$PROJECT_ROOT/$rl_file" ]] || ! bash -n "$PROJECT_ROOT/$rl_file"; then
        remote_syntax_failure="$rl_file"
        break
    fi
done
if [[ -z "$remote_syntax_failure" ]]; then
    test_pass
else test_fail "远程基础文件语法失败或缺失: $remote_syntax_failure"; fi

test_suite_end
