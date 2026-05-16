#!/bin/bash
# test_tui_logs_view.sh - 原生 TUI 日志视图测试

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"

test_suite_start "TUI Logs View"

test_start "纯文本渲染包含标题、正文与返回提示"
render_output="$(bash -c 'set -uo pipefail; source "$1/lib/tui_views_logs.sh"; tui_logs_render_text "Boot logs" $'"'"'line1\nline2'"'"' 0 20' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$render_output" == *"Boot logs"* ]] \
    && [[ "$render_output" == *"line1"* ]] \
    && [[ "$render_output" == *"q 返回"* ]]; then
    test_pass
else
    test_fail "日志纯文本渲染缺少必要内容，输出为: $render_output"
fi

test_start "打开 action 会调用 presenter 并渲染 action id 与正文"
open_output="$(bash -c 'set -uo pipefail; source "$1/lib/tui_views_logs.sh"; logs_present_tui(){ printf "present:%s:%s\n" "$1" "$2"; printf "rendered body\n"; }; tui_logs_render_text(){ printf "title=%s\n%s\n" "$1" "$2"; }; TUI_LOGS_TEST_KEYS=q tui_logs_open_action logs.boot --boot 0' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$open_output" == *"title=logs.boot"* ]] \
    && [[ "$open_output" == *"present:logs.boot:--boot"* ]] \
    && [[ "$open_output" == *"rendered body"* ]]; then
    test_pass
else
    test_fail "日志 action 未按预期调用 presenter/render，输出为: $open_output"
fi

test_start "run_log_viewer 兼容 wrapper 调用系统日志 action"
wrapper_output="$(bash -c 'set -uo pipefail; source "$1/lib/tui_views_logs.sh"; tui_logs_open_action(){ printf "%s %s %s\n" "$1" "$2" "$3"; }; run_log_viewer' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$wrapper_output" == "logs.system_file_tail --lines 120" ]]; then
    test_pass
else
    test_fail "run_log_viewer 未调用 logs.system_file_tail，输出为: $wrapper_output"
fi

test_start "run_log_viewer 使用测试按键渲染后退出且不阻塞"
viewer_output="$(bash -c 'set -uo pipefail; source "$1/lib/tui_views_logs.sh"; logs_present_tui(){ printf "viewer body\n"; }; tui_logs_render_text(){ printf "render:%s:%s:%s\n" "$1" "$3" "$2"; }; TUI_LOGS_TEST_KEYS=q run_log_viewer' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$viewer_output" == *"render:logs.system_file_tail:0:viewer body"* ]]; then
    test_pass
else
    test_fail "run_log_viewer 未在测试按键下渲染并退出，输出为: $viewer_output"
fi

test_start "日志 view 支持滚动与刷新循环"
loop_output="$(bash -c 'set -uo pipefail; source "$1/lib/tui_views_logs.sh"; calls_file=$(mktemp); trap "rm -f \"$calls_file\"" EXIT; logs_present_tui(){ local count; count=$(wc -c < "$calls_file"); count=$((count + 1)); printf x >> "$calls_file"; printf "present-call:%s\n" "$count"; printf "line1\nline2\nline3\n"; }; tui_logs_render_text(){ printf "render:%s:offset=%s\n%s\n" "$1" "$3" "$2"; }; TUI_LOGS_TEST_KEYS=$'"'"'DOWN\nr\nq'"'"' tui_logs_open_action logs.boot' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$loop_output" == *"present-call:1"* ]] \
    && [[ "$loop_output" == *"present-call:2"* ]] \
    && [[ "$loop_output" == *"render:logs.boot:offset=1"* ]]; then
    test_pass
else
    test_fail "日志 view 未正确处理 DOWN/r/q，输出为: $loop_output"
fi

test_suite_end
