#!/bin/bash
# test_scripts.sh - 独立脚本入口测试
set -uo pipefail

rl_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$rl_script_dir")"
source "$rl_script_dir/test_framework.sh"

test_suite_start "Standalone Scripts"

for rl_script in rl-user-list rl-user-create rl-user-quota rl-user-resource rl-mail-test rl-backup-run rl-audit-query; do
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

test_suite_end
