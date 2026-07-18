#!/bin/bash
# test_action_registry.sh - 共享动作注册与分发测试

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"
source "$PROJECT_ROOT/lib/env_core.sh"
source "$PROJECT_ROOT/lib/action_registry.sh"

test_suite_start "Action Registry"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

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

test_start "repeat source does not clear registered action"
source_stderr="$TMP_DIR/repeat_source.stderr"
if source "$PROJECT_ROOT/lib/action_registry.sh" 2>"$source_stderr"; then
    source_rc=0
else
    source_rc=$?
fi
description="$(action_describe demo.run)"
if [[ "$source_rc" == "0" ]] && [[ ! -s "$source_stderr" ]] && action_exists demo.run && [[ "$description" == *"id=demo.run"* ]]; then
    test_pass
else
    test_fail "repeat source failed: rc=$source_rc stderr=$(<"$source_stderr") description=$description"
fi

test_start "writable error code containing r is corrected and locked under nounset"
constant_stdout="$TMP_DIR/writable_constant.stdout"
constant_stderr="$TMP_DIR/writable_constant.stderr"
if bash -u -c 'RL_ERR_PARAM=error; source "$1"; decl=$(declare -p RL_ERR_PARAM); [[ "$RL_ERR_PARAM" == "1" && "$decl" == declare\ -r* ]]; ! (RL_ERR_PARAM=7) 2>/dev/null' bash "$PROJECT_ROOT/lib/action_registry.sh" >"$constant_stdout" 2>"$constant_stderr"; then
    if [[ ! -s "$constant_stderr" ]]; then
        test_pass
    else
        test_fail "writable constant source produced stderr: $(<"$constant_stderr")"
    fi
else
    test_fail "writable constant was not corrected or locked: stdout=$(<"$constant_stdout") stderr=$(<"$constant_stderr")"
fi

test_start "declared unset writable error code is corrected under nounset"
unset_constant_stderr="$TMP_DIR/unset_writable_constant.stderr"
if bash -u -c 'declare RL_ERR_PARAM; source "$1"; decl=$(declare -p RL_ERR_PARAM); [[ "$RL_ERR_PARAM" == "1" && "$decl" == declare\ -r* ]]; ! (RL_ERR_PARAM=7) 2>/dev/null' bash "$PROJECT_ROOT/lib/action_registry.sh" >/dev/null 2>"$unset_constant_stderr"; then
    if [[ ! -s "$unset_constant_stderr" ]]; then
        test_pass
    else
        test_fail "declared unset writable source produced stderr: $(<"$unset_constant_stderr")"
    fi
else
    test_fail "declared unset writable constant was not corrected or locked: stderr=$(<"$unset_constant_stderr")"
fi

test_start "declared unset readonly error code rejects source under nounset"
unset_readonly_constant_stderr="$TMP_DIR/unset_readonly_constant.stderr"
if bash -u -c 'declare RL_ERR_PARAM; readonly RL_ERR_PARAM; source "$1"' bash "$PROJECT_ROOT/lib/action_registry.sh" >/dev/null 2>"$unset_readonly_constant_stderr"; then
    test_fail "declared unset readonly constant source unexpectedly succeeded"
else
    unset_readonly_diagnostic="$(<"$unset_readonly_constant_stderr")"
    if [[ "$unset_readonly_diagnostic" == *"RL_ERR_PARAM"* && "$unset_readonly_diagnostic" == *"value is ; expected 1"* && "$unset_readonly_diagnostic" != *"unbound variable"* && "$unset_readonly_diagnostic" != *"未绑定变量"* ]]; then
        test_pass
    else
        test_fail "declared unset readonly diagnostic was: $unset_readonly_diagnostic"
    fi
fi

test_start "incorrect readonly error code constant rejects source"
readonly_constant_stderr="$TMP_DIR/readonly_constant.stderr"
if bash -c 'RL_ERR_PARAM=99; readonly RL_ERR_PARAM; source "$1"' bash "$PROJECT_ROOT/lib/action_registry.sh" >/dev/null 2>"$readonly_constant_stderr"; then
    test_fail "incorrect readonly constant source unexpectedly succeeded"
elif [[ "$(<"$readonly_constant_stderr")" == *"RL_ERR_PARAM"* && "$(<"$readonly_constant_stderr")" == *"99"* && "$(<"$readonly_constant_stderr")" == *"1"* ]]; then
    test_pass
else
    test_fail "incorrect readonly constant diagnostic was: $(<"$readonly_constant_stderr")"
fi

test_start "action_exists detects registered action"
if action_exists demo.run; then
    test_pass
else
    test_fail "registered action was not found"
fi

test_start "action_mode_supported rejects empty id safely"
mode_stdout="$TMP_DIR/action_mode_empty.stdout"
mode_stderr="$TMP_DIR/action_mode_empty.stderr"
if action_mode_supported "" cli >"$mode_stdout" 2>"$mode_stderr"; then
    test_fail "empty id should not be accepted"
elif [[ -s "$mode_stdout" ]] || [[ -s "$mode_stderr" ]]; then
    test_fail "empty id produced output: stdout=$(<"$mode_stdout") stderr=$(<"$mode_stderr")"
else
    test_pass
fi

test_start "action_mode_supported rejects unknown action"
mode_stdout="$TMP_DIR/action_mode_unknown.stdout"
mode_stderr="$TMP_DIR/action_mode_unknown.stderr"
if action_mode_supported missing.action cli >"$mode_stdout" 2>"$mode_stderr"; then
    test_fail "unknown action should not be accepted"
elif [[ -s "$mode_stdout" ]] || [[ -s "$mode_stderr" ]]; then
    test_fail "unknown action produced output: stdout=$(<"$mode_stdout") stderr=$(<"$mode_stderr")"
else
    test_pass
fi

test_start "action_requirements_met rejects empty id safely"
req_stdout="$TMP_DIR/action_req_empty.stdout"
req_stderr="$TMP_DIR/action_req_empty.stderr"
if action_requirements_met "" >"$req_stdout" 2>"$req_stderr"; then
    test_fail "empty id should not satisfy requirements"
elif [[ -s "$req_stdout" ]] || [[ -s "$req_stderr" ]]; then
    test_fail "empty id produced output: stdout=$(<"$req_stdout") stderr=$(<"$req_stderr")"
else
    test_pass
fi

test_start "action_requirements_met rejects unknown action"
req_stdout="$TMP_DIR/action_req_unknown.stdout"
req_stderr="$TMP_DIR/action_req_unknown.stderr"
if action_requirements_met missing.action >"$req_stdout" 2>"$req_stderr"; then
    test_fail "unknown action should not satisfy requirements"
elif [[ -s "$req_stdout" ]] || [[ -s "$req_stderr" ]]; then
    test_fail "unknown action produced output: stdout=$(<"$req_stdout") stderr=$(<"$req_stderr")"
else
    test_pass
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

test_start "action_run reports missing handler"
action_register "demo.broken" "Demo Broken" "demo" definitely_missing_handler "none" "both" "safe"
output="$(action_run demo.broken cli 2>&1 || true)"
if [[ "$output" == *"action handler 不存在"* ]]; then
    test_pass
else
    test_fail "missing handler output was: $output"
fi

test_start "default log actions dispatch natural args and compat id prefix"
action_registry_reset
source "$PROJECT_ROOT/lib/logs_presenter.sh"

mock_journalctl() {
    case "$*" in
        *"-b 0"*) printf 'boot ok\n' ;;
        *"-u ssh.service"*) printf 'ssh ok\n' ;;
        *) printf 'generic\n' ;;
    esac
}

mock_systemctl() {
    case "$*" in
        *"--failed"*) printf 'UNIT LOAD ACTIVE SUB DESCRIPTION\nssh.service loaded failed failed OpenSSH server\n' ;;
        *) printf 'systemctl ok\n' ;;
    esac
}

journalctl() { mock_journalctl "$@"; }
systemctl() { mock_systemctl "$@"; }

JOURNALCTL_BIN=journalctl
SYSTEMCTL_BIN=systemctl

action_register_defaults
boot_output="$(action_run logs.boot cli --boot 0 --lines 5)"
compat_boot_output="$(action_run logs.boot cli logs.boot --boot 0 --lines 5)"
service_output="$(action_run logs.service_recent cli ssh --lines 5)"
if [[ "$boot_output" == *"title=Boot logs"* ]] && [[ "$boot_output" == *"boot=0"* ]] && [[ "$boot_output" == *"boot ok"* ]] && [[ "$compat_boot_output" == "$boot_output" ]] && [[ "$service_output" == *"title=Service recent logs"* ]] && [[ "$service_output" == *"unit=ssh.service"* ]] && [[ "$service_output" == *"ssh ok"* ]]; then
    test_pass
else
    test_fail "default log action dispatch output was: boot=$boot_output compat=$compat_boot_output service=$service_output"
fi

test_start "error code constants are defined"
if [[ "$RL_ERR_SUCCESS" == "0" ]] && [[ "$RL_ERR_PARAM" == "1" ]] && [[ "$RL_ERR_PERMISSION" == "2" ]] && [[ "$RL_ERR_RUNTIME" == "3" ]]; then
    test_pass
else
    test_fail "error code constants not defined correctly: success=$RL_ERR_SUCCESS param=$RL_ERR_PARAM perm=$RL_ERR_PERMISSION runtime=$RL_ERR_RUNTIME"
fi

test_start "action_run returns RL_ERR_PARAM for unknown action"
action_registry_reset
action_run missing.action cli 2>/dev/null
rc=$?
if [[ "$rc" == "$RL_ERR_PARAM" ]]; then
    test_pass
else
    test_fail "expected RC=$RL_ERR_PARAM, got RC=$rc"
fi

test_start "action_run returns RL_ERR_PARAM for unsupported mode"
action_register "demo.tui.only" "Demo TUI Only" "demo" demo_other_handler "none" "tui" "safe"
action_run demo.tui.only cli 2>/dev/null
rc=$?
if [[ "$rc" == "$RL_ERR_PARAM" ]]; then
    test_pass
else
    test_fail "expected RC=$RL_ERR_PARAM, got RC=$rc"
fi

test_start "action_run returns RL_ERR_PERMISSION for missing capability"
action_register "demo.needs.cap" "Demo Cap" "demo" demo_other_handler "command:definitely_missing_cmd_999" "both" "safe"
action_run demo.needs.cap cli 2>/dev/null
rc=$?
if [[ "$rc" == "$RL_ERR_PERMISSION" ]]; then
    test_pass
else
    test_fail "expected RC=$RL_ERR_PERMISSION, got RC=$rc"
fi

test_start "action_run returns RL_ERR_RUNTIME for missing handler"
action_register "demo.broken.handler" "Demo Broken" "demo" definitely_missing_handler "none" "both" "safe"
action_run demo.broken.handler cli 2>/dev/null
rc=$?
if [[ "$rc" == "$RL_ERR_RUNTIME" ]]; then
    test_pass
else
    test_fail "expected RC=$RL_ERR_RUNTIME, got RC=$rc"
fi

test_suite_end
