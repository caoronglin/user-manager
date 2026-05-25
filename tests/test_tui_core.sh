#!/bin/bash
# test_tui_core.sh - TUI 核心组件测试

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"

test_suite_start "TUI Core"

test_start "draw_usage_bar 在 C locale 下使用 ASCII 避免进度条乱码"
usage_bar_output="$(env LC_ALL=C LANG=C bash -c 'set -uo pipefail; source "$1/lib/common.sh"; C_BGREEN=""; C_DIM=""; C_RESET=""; draw_usage_bar 1 12' _ "$PROJECT_ROOT")"
if [[ "$usage_bar_output" == *"-"* ]] && [[ "$usage_bar_output" != *"▓"* ]] && [[ "$usage_bar_output" != *"░"* ]]; then
    test_pass
else
    test_fail "C locale 下 draw_usage_bar 仍输出 Unicode 块字符，输出为: $usage_bar_output"
fi

test_start "tui_progress_draw 在非 UTF-8 终端下使用 ASCII"
tui_progress_ascii_output="$(env LC_ALL=C LANG=C bash -c 'set -uo pipefail; source "$1/lib/tui_core.sh"; TUI_HAS_UTF8=false; TUI_COLOR_SUCCESS=2; TUI_COLOR_MUTED=8; tui_move(){ :; }; tui_fg(){ :; }; tui_reset(){ :; }; tui_progress_draw 1 1 12 10 CPU' _ "$PROJECT_ROOT")"
if [[ "$tui_progress_ascii_output" == *"#"* ]] && [[ "$tui_progress_ascii_output" == *"-"* ]] && [[ "$tui_progress_ascii_output" != *"█"* ]] && [[ "$tui_progress_ascii_output" != *"░"* ]]; then
    test_pass
else
    test_fail "非 UTF-8 TUI 进度条仍输出 Unicode 块字符，输出为: $tui_progress_ascii_output"
fi

test_start "长菜单会根据终端高度启用分页"
menu_paging_output="$(bash -c 'set -uo pipefail; source "$1/lib/tui_core.sh"; TUI_LINES=12; TUI_COLS=80; TUI_COLOR_HIGHLIGHT=51; TUI_COLOR_FG=255; TUI_COLOR_MUTED=242; tui_draw_box(){ :; }; tui_move(){ :; }; tui_fg(){ :; }; tui_reset(){ :; }; tui_reverse(){ :; }; tui_statusbar_draw(){ :; }; tui_menu_create "超长菜单" A B C D E F G H I J K L; tui_menu_draw 2 2 40; printf "visible=%s offset=%s total=%s" "$TUI_MENU_VISIBLE_ITEMS" "$TUI_MENU_SCROLL_OFFSET" "${#TUI_MENU_ITEMS[@]}"' _ "$PROJECT_ROOT")"
if [[ "$menu_paging_output" == *"visible="* ]] && [[ "$menu_paging_output" != *"visible=12"* ]] && [[ "$menu_paging_output" == *"total=12"* ]]; then
    test_pass
else
    test_fail "长菜单未启用分页，输出为: $menu_paging_output"
fi

test_start "菜单向下移动时会推动滚动窗口"
scroll_output="$(bash -c 'set -uo pipefail; source "$1/lib/tui_core.sh"; TUI_LINES=12; TUI_COLS=80; TUI_COLOR_HIGHLIGHT=51; TUI_COLOR_FG=255; TUI_COLOR_MUTED=242; tui_draw_box(){ :; }; tui_move(){ :; }; tui_fg(){ :; }; tui_reset(){ :; }; tui_reverse(){ :; }; tui_statusbar_draw(){ :; }; tui_menu_create "超长菜单" A B C D E F G H I J K L; tui_menu_draw 2 2 40 >/dev/null; for _ in 1 2 3 4 5 6; do tui_menu_handle_key DOWN >/dev/null || true; done; printf "index=%s offset=%s visible=%s" "$TUI_MENU_INDEX" "$TUI_MENU_SCROLL_OFFSET" "$TUI_MENU_VISIBLE_ITEMS"' _ "$PROJECT_ROOT")"
if [[ "$scroll_output" == *"index=6"* ]] && [[ "$scroll_output" != *"offset=0"* ]]; then
    test_pass
else
    test_fail "菜单滚动窗口未随选择移动，输出为: $scroll_output"
fi

test_start "菜单支持 Home/End 快速跳转"
home_end_output="$(bash -c 'set -uo pipefail; source "$1/lib/tui_core.sh"; TUI_LINES=12; TUI_COLS=80; TUI_COLOR_HIGHLIGHT=51; TUI_COLOR_FG=255; TUI_COLOR_MUTED=242; tui_draw_box(){ :; }; tui_move(){ :; }; tui_fg(){ :; }; tui_reset(){ :; }; tui_reverse(){ :; }; tui_statusbar_draw(){ :; }; tui_menu_create "菜单" A B C D E F G; tui_menu_draw 2 2 40 >/dev/null; tui_menu_handle_key END >/dev/null || true; printf "end=%s " "$TUI_MENU_INDEX"; tui_menu_handle_key HOME >/dev/null || true; printf "home=%s" "$TUI_MENU_INDEX"' _ "$PROJECT_ROOT")"
if [[ "$home_end_output" == *"end=6"* ]] && [[ "$home_end_output" == *"home=0"* ]]; then
    test_pass
else
    test_fail "Home/End 跳转未按预期工作，输出为: $home_end_output"
fi

test_start "菜单支持数字键直接选择含多位编号"
direct_digit_output="$(bash -c 'set -uo pipefail; source "$1/lib/tui_core.sh"; TUI_LINES=24; TUI_COLS=80; TUI_COLOR_HIGHLIGHT=51; TUI_COLOR_FG=255; TUI_COLOR_MUTED=242; tui_draw_box(){ :; }; tui_move(){ :; }; tui_fg(){ :; }; tui_reset(){ :; }; tui_reverse(){ :; }; tui_statusbar_draw(){ :; }; tui_menu_create "菜单" A B C D E F G H I J 返回; tui_menu_draw 2 2 40 >/dev/null; printf "one=%s " "$(tui_menu_handle_key 1)"; printf "ten=%s " "$(tui_menu_handle_key 10)"; printf "zero=%s" "$(tui_menu_handle_key 0)"' _ "$PROJECT_ROOT")"
if [[ "$direct_digit_output" == *"one=0"* && "$direct_digit_output" == *"ten=9"* && "$direct_digit_output" == *"zero=10"* ]]; then
    test_pass
else
    test_fail "数字直选未按预期映射，输出为: $direct_digit_output"
fi

test_start "tui_read_key 根据当前菜单范围读取多位编号"
read_digit_output="$(bash -c 'set -uo pipefail; source "$1/lib/tui_core.sh"; TUI_MENU_ITEMS=(A B C D E F G H I J 返回); long_key="$(printf "10" | TUI_MENU_DIGIT_TIMEOUT=0.01 tui_read_key)"; TUI_MENU_ITEMS=(A B 返回); short_key="$(printf "10" | TUI_MENU_DIGIT_TIMEOUT=0.01 tui_read_key)"; printf "long=%s short=%s" "$long_key" "$short_key"' _ "$PROJECT_ROOT")"
if [[ "$read_digit_output" == *"long=10"* && "$read_digit_output" == *"short=1"* ]]; then
    test_pass
else
    test_fail "TUI 按键读取未按菜单范围处理多位编号，输出为: $read_digit_output"
fi

test_start "tui_prompt_input 支持默认值确认"
prompt_default_output="$(bash -c 'set -uo pipefail; source "$1/lib/tui_core.sh"; TUI_LINES=24; TUI_COLS=80; TUI_COLOR_HIGHLIGHT=51; TUI_COLOR_FG=255; TUI_COLOR_MUTED=242; TUI_COLOR_ACCENT=39; tui_draw_box(){ :; }; tui_move(){ :; }; tui_fg(){ :; }; tui_reset(){ :; }; tui_reverse(){ :; }; tui_draw_center(){ :; }; tui_clear(){ :; }; tput(){ :; }; key_file="$(mktemp)"; printf "%s\n" ENTER > "$key_file"; tui_read_key(){ local key; IFS= read -r key < "$key_file" || return 1; tail -n +2 "$key_file" > "$key_file.next"; mv "$key_file.next" "$key_file"; printf "%s\n" "$key"; return 0; }; tui_prompt_input "标题" "用户名" "alice" >/dev/null; rm -f "$key_file" "$key_file.next"; printf "value=%s" "$REPLY_INPUT"' _ "$PROJECT_ROOT")"
if [[ "$prompt_default_output" == *"value=alice"* ]]; then
    test_pass
else
    test_fail "tui_prompt_input 未正确返回默认值，输出为: $prompt_default_output"
fi

test_start "tui_prompt_input 支持文本输入与退格"
prompt_text_output="$(bash -c 'set -uo pipefail; source "$1/lib/tui_core.sh"; TUI_LINES=24; TUI_COLS=80; TUI_COLOR_HIGHLIGHT=51; TUI_COLOR_FG=255; TUI_COLOR_MUTED=242; TUI_COLOR_ACCENT=39; tui_draw_box(){ :; }; tui_move(){ :; }; tui_fg(){ :; }; tui_reset(){ :; }; tui_reverse(){ :; }; tui_draw_center(){ :; }; tui_clear(){ :; }; tput(){ :; }; key_file="$(mktemp)"; printf "%s\n" a b c BACKSPACE d ENTER > "$key_file"; tui_read_key(){ local key; IFS= read -r key < "$key_file" || return 1; tail -n +2 "$key_file" > "$key_file.next"; mv "$key_file.next" "$key_file"; printf "%s\n" "$key"; return 0; }; tui_prompt_input "标题" "用户名" "" >/dev/null; rm -f "$key_file" "$key_file.next"; printf "value=%s" "$REPLY_INPUT"' _ "$PROJECT_ROOT")"
if [[ "$prompt_text_output" == *"value=abd"* ]]; then
    test_pass
else
    test_fail "tui_prompt_input 未正确处理输入/退格，输出为: $prompt_text_output"
fi

test_start "tui_prompt_select 支持默认选项确认"
select_default_output="$(bash -c 'set -uo pipefail; source "$1/lib/tui_core.sh"; TUI_LINES=24; TUI_COLS=80; TUI_COLOR_HIGHLIGHT=51; TUI_COLOR_FG=255; TUI_COLOR_MUTED=242; TUI_COLOR_ACCENT=39; tui_draw_box(){ :; }; tui_move(){ :; }; tui_fg(){ :; }; tui_reset(){ :; }; tui_reverse(){ :; }; tui_draw_center(){ :; }; tui_clear(){ :; }; key_file="$(mktemp)"; printf "%s\n" ENTER > "$key_file"; tui_read_key(){ local key; IFS= read -r key < "$key_file" || return 1; tail -n +2 "$key_file" > "$key_file.next"; mv "$key_file.next" "$key_file"; printf "%s\n" "$key"; return 0; }; tui_prompt_select "标题" "请选择" 1 red green blue >/dev/null; rm -f "$key_file" "$key_file.next"; printf "value=%s index=%s" "$REPLY_INPUT" "$TUI_PROMPT_INDEX"' _ "$PROJECT_ROOT")"
if [[ "$select_default_output" == *"value=green"* ]] && [[ "$select_default_output" == *"index=1"* ]]; then
    test_pass
else
    test_fail "tui_prompt_select 未正确返回默认选项，输出为: $select_default_output"
fi

test_start "tui_prompt_select 支持上下切换"
select_nav_output="$(bash -c 'set -uo pipefail; source "$1/lib/tui_core.sh"; TUI_LINES=24; TUI_COLS=80; TUI_COLOR_HIGHLIGHT=51; TUI_COLOR_FG=255; TUI_COLOR_MUTED=242; TUI_COLOR_ACCENT=39; tui_draw_box(){ :; }; tui_move(){ :; }; tui_fg(){ :; }; tui_reset(){ :; }; tui_reverse(){ :; }; tui_draw_center(){ :; }; tui_clear(){ :; }; key_file="$(mktemp)"; printf "%s\n" DOWN DOWN ENTER > "$key_file"; tui_read_key(){ local key; IFS= read -r key < "$key_file" || return 1; tail -n +2 "$key_file" > "$key_file.next"; mv "$key_file.next" "$key_file"; printf "%s\n" "$key"; return 0; }; tui_prompt_select "标题" "请选择" 0 red green blue >/dev/null; rm -f "$key_file" "$key_file.next"; printf "value=%s index=%s" "$REPLY_INPUT" "$TUI_PROMPT_INDEX"' _ "$PROJECT_ROOT")"
if [[ "$select_nav_output" == *"value=blue"* ]] && [[ "$select_nav_output" == *"index=2"* ]]; then
    test_pass
else
    test_fail "tui_prompt_select 未正确处理上下切换，输出为: $select_nav_output"
fi

test_suite_end
