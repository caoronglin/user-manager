#!/bin/bash
# test_env_core.sh - 本机能力探测测试

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"
source "$PROJECT_ROOT/lib/env_core.sh"

test_suite_start "Environment Core"

test_start "env_has_command detects shell functions"
demo_env_command() { :; }
if env_has_command demo_env_command; then
    test_pass
else
    test_fail "env_has_command did not detect a declared function"
fi

test_start "env_has_command rejects missing commands"
if ! env_has_command definitely_missing_user_manager_command_999; then
    test_pass
else
    test_fail "env_has_command reported a missing command as present"
fi

test_start "env_has_systemd can be forced off for tests"
ENV_FORCE_SYSTEMD=0
if ! env_has_systemd; then
    test_pass
else
    test_fail "env_has_systemd ignored ENV_FORCE_SYSTEMD=0"
fi
unset ENV_FORCE_SYSTEMD

test_start "env_capability_status reports command capability"
output="$(env_capability_status command:demo_env_command)"
assert_contains "$output" "status=ok" "expected command capability to be ok"

test_start "env_capability_status reports missing capability"
output="$(env_capability_status command:definitely_missing_user_manager_command_999 || true)"
if [[ "$output" == *"status=missing"* ]] && [[ "$output" == *"capability=command:definitely_missing_user_manager_command_999"* ]]; then
    test_pass
else
    test_fail "missing capability output was: $output"
fi

test_start "env_capability_summary includes core commands"
summary="$(ENV_FORCE_SYSTEMD=0 env_capability_summary)"
if [[ "$summary" == *"journalctl="* ]] && [[ "$summary" == *"systemctl="* ]] && [[ "$summary" == *"systemd=missing"* ]]; then
    test_pass
else
    test_fail "unexpected capability summary: $summary"
fi

test_suite_end
