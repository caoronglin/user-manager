#!/bin/bash
# test_logs_core.sh - 统一日志核心协议测试
# shellcheck disable=SC1091

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"
source "$PROJECT_ROOT/lib/env_core.sh"
source "$PROJECT_ROOT/lib/journalctl_core.sh"
source "$PROJECT_ROOT/lib/logs_core.sh"

setup_test_env

TMP_DIR="$TEST_TMPDIR/logs"
mkdir -p "$TMP_DIR"

encode_test_value() {
    local value="${1:-}"
    local encoded=""
    local ch i LC_ALL=C LANG=C

    for ((i = 0; i < ${#value}; i++)); do
        ch="${value:i:1}"
        case "$ch" in
            [-A-Za-z0-9._~/])
                encoded+="$ch"
                ;;
            *)
                printf -v ch '%%%02X' "'$ch"
                encoded+="$ch"
                ;;
        esac
    done

    printf '%s' "$encoded"
}

run_logs_case() {
    local script="$1"

    bash -c "$script" _ "$PROJECT_ROOT" 2>&1
}

mock_journalctl() {
    case "$*" in
        *"-b -1"*)
            printf 'previous boot error line\nshared boot line\n'
            ;;
        *"-b 0"*)
            printf 'current boot line\nshared boot line\nssh.service failed at boot\n'
            ;;
        *"-u ssh.service"*)
            printf 'ssh recent line one\nssh recent line two\n'
            ;;
        *)
            printf 'generic journal line\n'
            ;;
    esac
}

mock_systemctl() {
    case "$*" in
        *"--failed"*)
            cat <<'OUT'
UNIT LOAD ACTIVE SUB DESCRIPTION
ssh.service loaded failed failed OpenSSH server
OUT
            ;;
        *)
            printf 'systemctl mock\n'
            ;;
    esac
}

JOURNALCTL_BIN=mock_journalctl
SYSTEMCTL_BIN=mock_systemctl

test_suite_start "Logs Core"

test_start "logs_core 模块可加载并导出核心函数"
if declare -F logs_meta >/dev/null && \
   declare -F logs_body_marker >/dev/null && \
   declare -F logs_error >/dev/null && \
   declare -F _logs_arg_value >/dev/null && \
   declare -F _logs_tail_file >/dev/null && \
   declare -F logs_get_capability_status >/dev/null && \
   declare -F logs_get_boot_entries >/dev/null && \
   declare -F logs_get_failed_units >/dev/null && \
   declare -F logs_get_service_recent >/dev/null && \
   declare -F logs_get_boot_error_diff >/dev/null && \
   declare -F logs_get_system_file_tail >/dev/null && \
   declare -F logs_get_auth_failures >/dev/null; then
    test_pass
else
    test_fail "logs_core.sh 缺失或未导出预期函数"
fi

test_start "logs_meta 和 logs_error 编码特殊字符"
space_dir="$TMP_DIR/space dir"
space_file="$space_dir/system=1.log"
mkdir -p "$space_dir"
meta_output="$(logs_meta ok journalctl "Boot logs with spaces" "file=$space_file" "note=value=with=equals")"
encoded_space_file="$(encode_test_value "$space_file")"
if [[ "$meta_output" == *"__LOGS_META__ status=ok source=journalctl title=Boot%20logs%20with%20spaces"* ]] && \
   [[ "$meta_output" == *"file=$encoded_space_file"* ]] && \
   [[ "$meta_output" == *"note=value%3Dwith%3Dequals"* ]]; then
    test_pass
else
    test_fail "encoded meta output was: $meta_output"
fi

test_start "logs_error 编码消息中的空格和等号"
error_output="$(logs_error missing-env-core "env capability summary = not available" || true)"
if [[ "$error_output" == *"__LOGS_META__ status=error source=none title=Log%20error"* ]] && \
   [[ "$error_output" == *"__LOGS_ERROR__ code=missing-env-core message=env%20capability%20summary%20%3D%20not%20available"* ]]; then
    test_pass
else
    test_fail "encoded error output was: $error_output"
fi

test_start "logs_get_capability_status rejects missing env summary helper"
missing_capability_output="$(run_logs_case 'set -uo pipefail; source "$1/lib/env_core.sh"; source "$1/lib/journalctl_core.sh"; source "$1/lib/logs_core.sh"; unset -f env_capability_summary; logs_get_capability_status' || true)"
if [[ "$missing_capability_output" == *"__LOGS_ERROR__"* ]] && \
   [[ "$missing_capability_output" == *"missing-env-core"* ]] && \
   [[ "$missing_capability_output" == *"env%20capability%20summary%20is%20not%20available"* ]]; then
    test_pass
else
    test_fail "missing capability helper output was: $missing_capability_output"
fi

test_start "logs_get_auth_failures rejects missing env_has_command"
missing_env_command_output="$(run_logs_case 'set -uo pipefail; source "$1/lib/env_core.sh"; source "$1/lib/journalctl_core.sh"; source "$1/lib/logs_core.sh"; unset -f env_has_command; logs_get_auth_failures --lines 5' || true)"
if [[ "$missing_env_command_output" == *"__LOGS_ERROR__"* ]] && \
   [[ "$missing_env_command_output" == *"missing-env-core"* ]] && \
   [[ "$missing_env_command_output" == *"env%20capability%20helper%20is%20not%20available"* ]]; then
    test_pass
else
    test_fail "missing env_has_command output was: $missing_env_command_output"
fi

test_start "logs_get_service_recent rejects missing unit normalizer"
missing_normalizer_output="$(run_logs_case 'set -uo pipefail; source "$1/lib/env_core.sh"; source "$1/lib/journalctl_core.sh"; source "$1/lib/logs_core.sh"; unset -f journalctl_normalize_unit_name; logs_get_service_recent ssh --lines 5' || true)"
if [[ "$missing_normalizer_output" == *"__LOGS_ERROR__"* ]] && \
   [[ "$missing_normalizer_output" == *"missing-journalctl-core"* ]] && \
   [[ "$missing_normalizer_output" == *"journalctl%20unit%20normalizer%20is%20not%20available"* ]]; then
    test_pass
else
    test_fail "missing unit normalizer output was: $missing_normalizer_output"
fi

test_start "logs_get_boot_error_diff rejects missing collector helper"
missing_collector_output="$(run_logs_case 'set -uo pipefail; source "$1/lib/env_core.sh"; source "$1/lib/journalctl_core.sh"; source "$1/lib/logs_core.sh"; unset -f journalctl_collect_boot_errors; logs_get_boot_error_diff --lines 20' || true)"
if [[ "$missing_collector_output" == *"__LOGS_ERROR__"* ]] && \
   [[ "$missing_collector_output" == *"missing-journalctl-core"* ]] && \
   [[ "$missing_collector_output" == *"journalctl%20boot%20error%20collector%20is%20not%20available"* ]]; then
    test_pass
else
    test_fail "missing boot collector output was: $missing_collector_output"
fi

test_start "logs_get_boot_error_diff rejects missing diff summarizer"
missing_summarizer_output="$(run_logs_case 'set -uo pipefail; source "$1/lib/env_core.sh"; source "$1/lib/journalctl_core.sh"; source "$1/lib/logs_core.sh"; unset -f journalctl_summarize_error_diff; logs_get_boot_error_diff --lines 20' || true)"
if [[ "$missing_summarizer_output" == *"__LOGS_ERROR__"* ]] && \
   [[ "$missing_summarizer_output" == *"missing-journalctl-core"* ]] && \
   [[ "$missing_summarizer_output" == *"journalctl%20error%20diff%20summarizer%20is%20not%20available"* ]]; then
    test_pass
else
    test_fail "missing diff summarizer output was: $missing_summarizer_output"
fi

test_start "logs_get_boot_entries emits metadata and body"
output="$(logs_get_boot_entries --boot 0 --lines 20)"
if [[ "$output" == *"__LOGS_META__ status=ok source=journalctl title=Boot%20logs"* ]] && \
   [[ "$output" == *"__LOGS_BODY__"* ]] && \
   [[ "$output" == *"current boot line"* ]]; then
    test_pass
else
    test_fail "boot output was: $output"
fi

test_start "logs_get_failed_units emits failed unit body"
output="$(logs_get_failed_units)"
if [[ "$output" == *"source=systemctl"* ]] && [[ "$output" == *"title=Failed%20systemd%20units"* ]] && [[ "$output" == *"ssh.service"* ]]; then
    test_pass
else
    test_fail "failed units output was: $output"
fi

test_start "logs_get_service_recent normalizes service name"
output="$(logs_get_service_recent ssh --lines 5)"
if [[ "$output" == *"title=Service%20recent%20logs"* ]] && [[ "$output" == *"unit=ssh.service"* ]] && [[ "$output" == *"ssh recent line one"* ]]; then
    test_pass
else
    test_fail "service recent output was: $output"
fi

test_start "logs_get_service_recent rejects empty unit"
output="$(logs_get_service_recent '' 2>&1 || true)"
if [[ "$output" == *"__LOGS_ERROR__"* ]] && \
   [[ "$output" == *"code=invalid-input"* ]] && \
   [[ "$output" == *"message=service%20unit%20is%20required"* ]]; then
    test_pass
else
    test_fail "empty service output was: $output"
fi

test_start "logs_get_boot_error_diff emits summary"
output="$(logs_get_boot_error_diff --lines 20)"
if [[ "$output" == *"title=Boot%20error%20diff"* ]] && [[ "$output" == *"new:"* ]]; then
    test_pass
else
    test_fail "diff output was: $output"
fi

test_start "logs_get_system_file_tail reads explicit file"
printf 'one\ntwo\nthree\n' > "$TMP_DIR/system.log"
output="$(logs_get_system_file_tail --file "$TMP_DIR/system.log" --lines 2)"
if [[ "$output" == *"title=System%20log%20file"* ]] && [[ "$output" == *"source=file"* ]] && [[ "$output" == *"two"* ]] && [[ "$output" == *"three"* ]]; then
    test_pass
else
    test_fail "file tail output was: $output"
fi

test_start "logs_get_auth_failures falls back to auth log"
printf 'Failed password for alice\nAccepted password for bob\n' > "$TMP_DIR/auth.log"
LOGS_AUTH_LOG="$TMP_DIR/auth.log"
output="$(JOURNALCTL_BIN=definitely_missing_user_manager_command_999 logs_get_auth_failures --lines 5)"
if [[ "$output" == *"title=Authentication%20failures"* ]] && [[ "$output" == *"Failed password for alice"* ]] && [[ "$output" != *"Accepted password"* ]]; then
    test_pass
else
    test_fail "auth failures output was: $output"
fi

cleanup_test_env

test_suite_end
