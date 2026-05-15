#!/bin/bash
# test_logs_presenter.sh - 日志展示层测试

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"
source "$PROJECT_ROOT/lib/env_core.sh"
source "$PROJECT_ROOT/lib/journalctl_core.sh"
source "$PROJECT_ROOT/lib/logs_core.sh"
source "$PROJECT_ROOT/lib/logs_presenter.sh"
source "$PROJECT_ROOT/lib/action_registry.sh"

setup_test_env

mock_journalctl() {
    case "$*" in
        *"-b 0"*)
            printf 'current boot line\nshared boot line\n'
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

journalctl() {
    mock_journalctl "$@"
}

systemctl() {
    mock_systemctl "$@"
}

JOURNALCTL_BIN=journalctl
SYSTEMCTL_BIN=systemctl

test_suite_start "Logs Presenter"

test_start "logs_present_cli prints title source and body"
output="$(logs_present_cli logs.boot --boot 0 --lines 5)"
if [[ "$output" == *"title=Boot logs"* ]] && [[ "$output" == *"source=journalctl"* ]] && [[ "$output" == *"body:"* ]] && [[ "$output" == *"current boot line"* ]]; then
    test_pass
else
    test_fail "CLI presenter output was: $output"
fi

test_start "logs_present_cli handles service argument"
output="$(logs_present_cli logs.service_recent ssh --lines 5)"
if [[ "$output" == *"title=Service recent logs"* ]] && [[ "$output" == *"unit=ssh.service"* ]] && [[ "$output" == *"ssh recent line one"* ]]; then
    test_pass
else
    test_fail "service presenter output was: $output"
fi

test_start "logs_present_cli reports unknown log action"
output="$(logs_present_cli logs.unknown 2>&1 || true)"
if [[ "$output" == *"未知日志 action"* ]]; then
    test_pass
else
    test_fail "unknown action output was: $output"
fi

test_start "logs_present_tui returns text without terminal control"
output="$(logs_present_tui logs.failed_services)"
if [[ "$output" == *"title=Failed systemd units"* ]] && [[ "$output" == *"ssh.service"* ]] && [[ "$output" != *$'\e['* ]]; then
    test_pass
else
    test_fail "TUI presenter output was: $output"
fi

test_start "logs_format_empty_state is readable"
output="$(logs_format_empty_state no-data)"
if [[ "$output" == *"没有可显示的日志"* ]] && [[ "$output" == *"no-data"* ]]; then
    test_pass
else
    test_fail "empty state output was: $output"
fi

test_start "encoded title and error message are decoded"
orig_logs_get_service_recent_def="$(declare -f logs_get_service_recent)"
logs_get_service_recent() {
    cat <<'OUT'
__LOGS_META__ status=error source=journalctl title=System%20log%20file%20%25%20check%20%3D%20ok
__LOGS_ERROR__ code=invalid-input message=service%20unit%20is%20required%0Aplease%20specify%20a%20unit%20name
OUT
    return 1
}
output="$(logs_present_cli logs.service_recent ssh --lines 5 2>&1 || true)"
if [[ "$output" == *"title=System log file % check = ok"* ]] && [[ "$output" == *"message=service unit is required"* ]] && [[ "$output" == *"please specify a unit name"* ]]; then
    test_pass
else
    test_fail "decoded presenter output was: $output"
fi

eval "$orig_logs_get_service_recent_def"

test_start "default log actions dispatch via action_run"
action_registry_reset
action_register_defaults
boot_output="$(action_run logs.boot cli --boot 0 --lines 5)"
compat_boot_output="$(action_run logs.boot cli logs.boot --boot 0 --lines 5)"
service_output="$(action_run logs.service_recent cli ssh --lines 5)"
if [[ "$boot_output" == *"title=Boot logs"* ]] && [[ "$boot_output" == *"source=journalctl"* ]] && [[ "$boot_output" == *"boot=0"* ]] && [[ "$boot_output" == *"current boot line"* ]] && [[ "$compat_boot_output" == "$boot_output" ]] && [[ "$service_output" == *"title=Service recent logs"* ]] && [[ "$service_output" == *"unit=ssh.service"* ]] && [[ "$service_output" == *"ssh recent line one"* ]]; then
    test_pass
else
    test_fail "action_run default outputs were: boot=$boot_output compat=$compat_boot_output service=$service_output"
fi

cleanup_test_env

test_suite_end
