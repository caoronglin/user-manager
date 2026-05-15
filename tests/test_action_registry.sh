#!/bin/bash
# test_action_registry.sh - 共享动作注册与分发测试

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"
source "$PROJECT_ROOT/lib/env_core.sh"
source "$PROJECT_ROOT/lib/action_registry.sh"

test_suite_start "Action Registry"

demo_action_handler() { printf 'demo:%s\n' "${1:-}"; }
demo_other_handler() { printf 'other\n'; }

test_start "action_register stores metadata"
action_registry_reset
action_register "demo.run" "Demo Run" "demo" demo_action_handler "none" "both" "safe"
description="$(action_describe demo.run)"
if [[ "$description" == *"id=demo.run"* ]] && [[ "$description" == *"handler=demo_action_handler"* ]]; then
    test_pass
else
    test_fail "unexpected action description: $description"
fi

test_start "action_exists detects registered action"
if action_exists demo.run; then
    test_pass
else
    test_fail "registered action was not found"
fi

test_start "action_run dispatches handler with arguments"
output="$(action_run demo.run cli hello)"
assert_equals "demo:hello" "$output" "action_run should pass remaining args to handler"

test_start "action_run rejects missing action"
output="$(action_run missing.action cli 2>&1 || true)"
if [[ "$output" == *"未知 action: missing.action"* ]]; then
    test_pass
else
    test_fail "missing action output was: $output"
fi

test_start "action_run rejects unsupported mode"
action_register "demo.tui" "Demo TUI" "demo" demo_other_handler "none" "tui" "safe"
output="$(action_run demo.tui cli 2>&1 || true)"
if [[ "$output" == *"不支持当前模式"* ]]; then
    test_pass
else
    test_fail "unsupported mode output was: $output"
fi

test_start "action_list_by_group prints ids"
ids="$(action_list_by_group demo)"
if [[ "$ids" == *"demo.run"* ]] && [[ "$ids" == *"demo.tui"* ]]; then
    test_pass
else
    test_fail "group list was: $ids"
fi

test_start "action_run checks required capability"
action_register "demo.missing" "Demo Missing" "demo" demo_other_handler "command:definitely_missing_user_manager_command_999" "both" "safe"
output="$(action_run demo.missing cli 2>&1 || true)"
if [[ "$output" == *"缺少能力"* ]]; then
    test_pass
else
    test_fail "capability guard output was: $output"
fi

test_suite_end
