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

test_start "logs_get_boot_entries emits metadata and body"
output="$(logs_get_boot_entries --boot 0 --lines 20)"
if [[ "$output" == *"__LOGS_META__ status=ok source=journalctl title=Boot logs"* ]] && \
   [[ "$output" == *"__LOGS_BODY__"* ]] && \
   [[ "$output" == *"current boot line"* ]]; then
    test_pass
else
    test_fail "boot output was: $output"
fi

test_start "logs_get_failed_units emits failed unit body"
output="$(logs_get_failed_units)"
if [[ "$output" == *"source=systemctl"* ]] && [[ "$output" == *"ssh.service"* ]]; then
    test_pass
else
    test_fail "failed units output was: $output"
fi

test_start "logs_get_service_recent normalizes service name"
output="$(logs_get_service_recent ssh --lines 5)"
if [[ "$output" == *"unit=ssh.service"* ]] && [[ "$output" == *"ssh recent line one"* ]]; then
    test_pass
else
    test_fail "service recent output was: $output"
fi

test_start "logs_get_service_recent rejects empty unit"
output="$(logs_get_service_recent '' 2>&1 || true)"
if [[ "$output" == *"__LOGS_ERROR__"* ]] && [[ "$output" == *"service unit is required"* ]]; then
    test_pass
else
    test_fail "empty service output was: $output"
fi

test_start "logs_get_boot_error_diff emits summary"
output="$(logs_get_boot_error_diff --lines 20)"
if [[ "$output" == *"title=Boot error diff"* ]] && [[ "$output" == *"new:"* ]]; then
    test_pass
else
    test_fail "diff output was: $output"
fi

test_start "logs_get_system_file_tail reads explicit file"
printf 'one\ntwo\nthree\n' > "$TMP_DIR/system.log"
output="$(logs_get_system_file_tail --file "$TMP_DIR/system.log" --lines 2)"
if [[ "$output" == *"source=file"* ]] && [[ "$output" == *"two"* ]] && [[ "$output" == *"three"* ]]; then
    test_pass
else
    test_fail "file tail output was: $output"
fi

test_start "logs_get_auth_failures falls back to auth log"
printf 'Failed password for alice\nAccepted password for bob\n' > "$TMP_DIR/auth.log"
LOGS_AUTH_LOG="$TMP_DIR/auth.log"
output="$(JOURNALCTL_BIN=definitely_missing_user_manager_command_999 logs_get_auth_failures --lines 5)"
if [[ "$output" == *"Failed password for alice"* ]] && [[ "$output" != *"Accepted password"* ]]; then
    test_pass
else
    test_fail "auth failures output was: $output"
fi

cleanup_test_env

test_suite_end
