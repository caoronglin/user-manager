#!/bin/bash
# test_journalctl_core.sh - journalctl/systemd 排障模块测试
# shellcheck disable=SC1091

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"

test_suite_start "Journalctl Core"

test_start "journalctl_core 模块可加载并导出核心函数"
if bash -c 'set -uo pipefail; source "$1/lib/common.sh"; source "$1/lib/journalctl_core.sh"; declare -F journalctl_show_boot_logs >/dev/null && declare -F journalctl_show_unit_recent_logs >/dev/null && declare -F journalctl_list_failed_services >/dev/null && declare -F journalctl_diagnose_service >/dev/null && declare -F journalctl_compare_boot_errors >/dev/null' _ "$PROJECT_ROOT" >/dev/null 2>&1; then
    test_pass
else
    test_fail "journalctl_core.sh 缺失或未导出预期函数"
fi

test_start "journalctl_extract_failed_units 解析 failed services"
failed_units_output="$({
    printf '  UNIT                          LOAD   ACTIVE SUB    DESCRIPTION\n'
    printf '  ssh.service                   loaded failed failed OpenBSD Secure Shell server\n'
    printf '  cron.service                  loaded active running Regular background program processing daemon\n'
    printf '  app@worker.service            loaded failed failed Demo Worker\n'
    printf '\n'
    printf '2 loaded units listed.\n'
} | bash -c 'set -uo pipefail; source "$1/lib/common.sh"; source "$1/lib/journalctl_core.sh"; journalctl_extract_failed_units' _ "$PROJECT_ROOT")"
if [[ "$failed_units_output" == $'ssh.service\napp@worker.service' ]]; then
    test_pass
else
    test_fail "failed services 解析结果不正确: $failed_units_output"
fi

test_start "journalctl_summarize_error_diff 统计新增/持续/已恢复错误"
error_diff_output="$(bash -c 'set -uo pipefail; source "$1/lib/common.sh"; source "$1/lib/journalctl_core.sh"; current=$'"'"'disk full\nservice timeout\nnew crash\nservice timeout'"'"'; previous=$'"'"'disk full\nold warning\nservice timeout'"'"'; journalctl_summarize_error_diff "$current" "$previous"' _ "$PROJECT_ROOT")"
expected_diff=$'new:1\npersistent:2\nresolved:1\nnew_items:new crash\npersistent_items:disk full\nservice timeout\nresolved_items:old warning'
if [[ "$error_diff_output" == "$expected_diff" ]]; then
    test_pass
else
    test_fail "错误对比统计不正确: $error_diff_output"
fi

test_start "journalctl_normalize_unit_name 自动补全 .service"
normalized_unit="$(bash -c 'set -uo pipefail; source "$1/lib/common.sh"; source "$1/lib/journalctl_core.sh"; journalctl_normalize_unit_name sshd' _ "$PROJECT_ROOT")"
assert_equals "sshd.service" "$normalized_unit"

test_suite_end
