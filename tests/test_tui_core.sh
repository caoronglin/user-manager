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

test_start "无 locale 与 TERM 时 tui_detect_terminal 在 nounset 下安全降级"
unset_env_output="$(env -u LANG -u LC_ALL -u LC_CTYPE -u TERM bash -c 'set -uo pipefail; source "$1/lib/tui_core.sh"; tui_detect_terminal; printf "utf8=%s colors=%s cols=%s lines=%s" "$TUI_HAS_UTF8" "$TUI_HAS_COLORS" "$TUI_COLS" "$TUI_LINES"' _ "$PROJECT_ROOT" 2>&1)"
if [[ "$unset_env_output" == *"utf8=false"* ]] && [[ "$unset_env_output" == *"colors=false"* ]] && [[ "$unset_env_output" == *"cols="* ]] && [[ "$unset_env_output" == *"lines="* ]]; then
    test_pass
else
    test_fail "无 locale/TERM 时检测未安全降级，输出为: $unset_env_output"
fi

test_start "tui_effective_locale 按第一个非空 locale 选择"
locale_priority_output="$(env LC_ALL=C LC_CTYPE=C.utf8 LANG=en_US.utf8 bash -c 'set -uo pipefail; source "$1/lib/tui_core.sh"; printf "all=%s " "$(tui_effective_locale)"; LC_ALL= LC_CTYPE=C.utf8 LANG=C; printf "ctype=%s " "$(tui_effective_locale)"; LC_ALL= LC_CTYPE= LANG=C; printf "lang=%s" "$(tui_effective_locale)"' _ "$PROJECT_ROOT")"
if [[ "$locale_priority_output" == "all=C ctype=C.utf8 lang=C" ]]; then
    test_pass
else
    test_fail "locale 优先级或空值回退错误，输出为: $locale_priority_output"
fi

test_start "无效 locale 不会误判 UTF-8"
invalid_locale_output="$(env LC_ALL=definitely.invalid LC_CTYPE=C.utf8 LANG=C bash -c 'set -uo pipefail; source "$1/lib/tui_core.sh"; tui_detect_terminal; printf "locale=%s utf8=%s" "$(tui_effective_locale)" "$TUI_HAS_UTF8"' _ "$PROJECT_ROOT" 2>&1)"
if [[ "$invalid_locale_output" == *"locale=definitely.invalid"* ]] && [[ "$invalid_locale_output" == *"utf8=false"* ]]; then
    test_pass
else
    test_fail "无效 locale 未安全降级，输出为: $invalid_locale_output"
fi

test_start "UTF-9 locale 名称即使 charmap 为 UTF-8 也不会启用 UTF-8"
utf9_output="$(env -u LANG -u LC_ALL -u LC_CTYPE bash -c 'set -uo pipefail; source "$1/lib/tui_core.sh"; LC_ALL=UTF-9; locale(){ printf "UTF-8"; }; tui_detect_terminal; printf "locale=%s utf8=%s" "$(tui_effective_locale)" "$TUI_HAS_UTF8"' _ "$PROJECT_ROOT" 2>&1)"
if [[ "$utf9_output" == *"locale=UTF-9 utf8=false"* ]]; then
    test_pass
else
    test_fail "UTF-9 被误判为 UTF-8，输出为: $utf9_output"
fi

TUI_TEST_UTF8_LOCALE=""
while IFS= read -r TUI_TEST_LOCALE_CANDIDATE; do
    case "${TUI_TEST_LOCALE_CANDIDATE,,}" in
    *utf-8 | *utf8)
        TUI_TEST_UTF8_LOCALE="$TUI_TEST_LOCALE_CANDIDATE"
        break
        ;;
    esac
done < <(locale -a 2>/dev/null || true)

test_start "UTF-8 locale 下显示宽度正确处理 ANSI、CJK 与 emoji"
if [[ -z "$TUI_TEST_UTF8_LOCALE" ]]; then
    test_fail "测试环境没有可用的 UTF-8 locale"
else
    width_output="$(env -u LANG -u LC_CTYPE LC_ALL="$TUI_TEST_UTF8_LOCALE" bash -c 'set -uo pipefail; source "$1/lib/tui_core.sh"; tui_detect_terminal; ansi_text=$(printf "\033[31mA中文\033[0m"); printf "utf8=%s ansi=%s mixed=%s bmp=%s supplementary=%s combining=%s vs16=%s zwj=%s" "$TUI_HAS_UTF8" "$(tui_display_width "$ansi_text")" "$(tui_display_width A中文B)" "$(tui_display_width ⚙)" "$(tui_display_width 👤)" "$(tui_display_width $'"'"'e\u0301'"'"')" "$(tui_display_width $'"'"'⚙\ufe0f'"'"')" "$(tui_display_width $'"'"'👩\u200d💻'"'"')"' _ "$PROJECT_ROOT" 2>&1)"
    if [[ "$width_output" == *"utf8=true"* ]] && [[ "$width_output" == *"ansi=5"* ]] && [[ "$width_output" == *"mixed=6"* ]] && [[ "$width_output" == *"bmp=2"* ]] && [[ "$width_output" == *"supplementary=2"* ]] && [[ "$width_output" == *"combining=1"* ]] && [[ "$width_output" == *"vs16=2"* ]] && [[ "$width_output" == *"zwj=4"* ]]; then
        test_pass
    else
        test_fail "UTF-8 显示宽度不符合预期，输出为: $width_output"
    fi
fi

test_start "显示列宽裁剪与填充不会截断半个宽字符"
if [[ -z "$TUI_TEST_UTF8_LOCALE" ]]; then
    test_fail "测试环境没有可用的 UTF-8 locale"
else
    truncate_output="$(env -u LANG -u LC_CTYPE LC_ALL="$TUI_TEST_UTF8_LOCALE" bash -c 'set -uo pipefail; source "$1/lib/tui_core.sh"; tui_detect_terminal; truncated="$(tui_truncate_display A中文B 4)"; emoji_truncated="$(tui_truncate_display 👤A 1)"; padded="$(tui_pad_display A中 6)"; printf "truncated=%s width=%s emoji=%s emoji_width=%s padded_width=%s" "$truncated" "$(tui_display_width "$truncated")" "$emoji_truncated" "$(tui_display_width "$emoji_truncated")" "$(tui_display_width "$padded")"' _ "$PROJECT_ROOT" 2>&1)"
    if [[ "$truncate_output" == *"truncated=A中"* ]] && [[ "$truncate_output" == *"width=3"* ]] && [[ "$truncate_output" == *"emoji="*"emoji_width=0"* ]] && [[ "$truncate_output" == *"padded_width=6"* ]]; then
        test_pass
    else
        test_fail "宽字符裁剪/填充不安全，输出为: $truncate_output"
    fi
fi

test_start "菜单失效函数会清空所有共享状态"
invalidate_output="$(bash -c 'set -uo pipefail; source "$1/lib/tui_core.sh"; TUI_MENU_TITLE=title; TUI_MENU_ITEMS=(A B); TUI_MENU_INDEX=1; TUI_MENU_SCROLL_OFFSET=1; TUI_MENU_VISIBLE_ITEMS=2; TUI_MENU_VIEWPORT_END=2; TUI_MENU_RESULT=1; TUI_ACTIVE_MENU_ID=main; tui_menu_invalidate_state; printf "title=%s items=%s index=%s offset=%s visible=%s end=%s result=%s active=%s" "$TUI_MENU_TITLE" "${#TUI_MENU_ITEMS[@]}" "$TUI_MENU_INDEX" "$TUI_MENU_SCROLL_OFFSET" "$TUI_MENU_VISIBLE_ITEMS" "$TUI_MENU_VIEWPORT_END" "${TUI_MENU_RESULT:-}" "${TUI_ACTIVE_MENU_ID:-}"' _ "$PROJECT_ROOT")"
if [[ "$invalidate_output" == "title= items=0 index=0 offset=0 visible=0 end= result= active=" ]]; then
    test_pass
else
    test_fail "菜单失效函数未清空完整状态，输出为: $invalidate_output"
fi

test_start "菜单 viewport 会夹紧索引、滚动偏移和可见范围"
viewport_output="$(bash -c 'set -uo pipefail; source "$1/lib/tui_core.sh"; TUI_LINES=12; TUI_MENU_ITEMS=(A B C D E); TUI_MENU_INDEX=99; TUI_MENU_SCROLL_OFFSET=99; tui_menu_update_viewport 4 3; printf "full=%s/%s/%s/%s " "$TUI_MENU_INDEX" "$TUI_MENU_SCROLL_OFFSET" "$TUI_MENU_VISIBLE_ITEMS" "$TUI_MENU_VIEWPORT_END"; TUI_MENU_ITEMS=(); TUI_MENU_INDEX=99; TUI_MENU_SCROLL_OFFSET=99; tui_menu_update_viewport 4 3; printf "empty=%s/%s/%s/%s" "$TUI_MENU_INDEX" "$TUI_MENU_SCROLL_OFFSET" "$TUI_MENU_VISIBLE_ITEMS" "$TUI_MENU_VIEWPORT_END"' _ "$PROJECT_ROOT")"
if [[ "$viewport_output" == "full=4/0/5/5 empty=0/0/1/0" ]]; then
    test_pass
else
    test_fail "菜单 viewport 状态夹紧错误，输出为: $viewport_output"
fi

test_start "1-6、7、12、24 行菜单绘制的 move 坐标始终有效"
layout_output="$(bash -c 'set -uo pipefail; source "$1/lib/tui_core.sh"; TUI_COLS=12; tui_draw_box(){ TUI_BOX_CALLS=$((TUI_BOX_CALLS + 1)); }; tui_statusbar_draw(){ TUI_STATUS_CALLS=$((TUI_STATUS_CALLS + 1)); }; tui_fg(){ :; }; tui_bg(){ :; }; tui_reset(){ :; }; tui_reverse(){ :; }; TUI_BAD_MOVE=false; TUI_BOX_CALLS=0; TUI_STATUS_CALLS=0; TUI_DRAW_OK=true; tui_move(){ local row="${1:-0}" col="${2:-0}"; if (( row < 0 || row >= TUI_LINES || col < 0 || col >= TUI_COLS )); then TUI_BAD_MOVE=true; fi; }; for TUI_LINES in 1 2 3 4 5 6 7 12 24; do tui_menu_create "菜单" A B C D E F G H; if tui_menu_draw 2 2 10 >/dev/null 2>&1; then :; else TUI_DRAW_OK=false; fi; printf "%s:%s:%s:%s " "$TUI_LINES" "$TUI_BAD_MOVE" "$TUI_BOX_CALLS" "$TUI_STATUS_CALLS"; TUI_BAD_MOVE=false; TUI_BOX_CALLS=0; TUI_STATUS_CALLS=0; done; printf "ok=%s" "$TUI_DRAW_OK"' _ "$PROJECT_ROOT")"
if [[ "$layout_output" == "1:false:0:0 2:false:0:0 3:false:0:0 4:false:0:0 5:false:0:0 6:false:0:0 7:false:1:1 12:false:1:1 24:false:1:1 ok=true" ]]; then
    test_pass
else
    test_fail "窄/矮终端布局或 compact/normal 绘制契约不符，输出为: $layout_output"
fi

test_start "窄宽度 normal 菜单的中文分页状态提示不超过终端列宽"
menu_status_width_output="$(env LC_ALL="${TUI_TEST_UTF8_LOCALE:-C.utf8}" bash -c 'set -uo pipefail; source "$1/lib/tui_core.sh"; TUI_LINES=12; TUI_COLS=26; TUI_HAS_UTF8=true; TUI_MENU_ITEMS=(); for i in $(seq 1 22); do TUI_MENU_ITEMS+=("第${i}项"); done; tui_draw_box(){ :; }; tui_fg(){ :; }; tui_bg(){ :; }; tui_reset(){ :; }; tui_reverse(){ :; }; tui_move(){ printf "\n@%s:%s@" "$1" "$2"; }; render="$(tui_menu_draw 2 3 20)"; max_end=-1; checked_suffix=false; while IFS= read -r line; do [[ "$line" == *"@"*"@"* ]] || continue; marker="${line#*@}"; marker="${marker%%@*}"; payload="${line#*@*@}"; row="${marker%%:*}"; col="${marker#*:}"; width="$(tui_display_width "$payload")"; end=$((col + width)); (( end > max_end )) && max_end="$end"; (( end <= TUI_COLS )) || { printf "overflow=%s:%s:%s" "$row" "$col" "$end"; exit 0; }; [[ "$payload" == *"[1-6/22]"* ]] && checked_suffix=true; done <<< "$render"; [[ "$checked_suffix" == true ]] && printf "max_end=%s suffix=true" "$max_end" || printf "max_end=%s suffix=false" "$max_end"' _ "$PROJECT_ROOT" 2>&1)"
if [[ "$menu_status_width_output" == *"suffix=true"* ]] && [[ "$menu_status_width_output" =~ max_end=[0-9]+ ]]; then
    test_pass
else
    test_fail "窄宽度菜单底部提示未被正确裁剪，输出为: $menu_status_width_output"
fi

test_start "菜单 primitives 会将负坐标和尺寸限制在屏幕范围"
primitive_output="$(bash -c 'set -uo pipefail; source "$1/lib/tui_core.sh"; TUI_LINES=4; TUI_COLS=6; TUI_HAS_UTF8=false; TUI_BAD_MOVE=false; tui_move(){ local row="${1:-0}" col="${2:-0}"; if (( row < 0 || row >= TUI_LINES || col < 0 || col >= TUI_COLS )); then TUI_BAD_MOVE=true; fi; printf "\n"; }; tui_fg(){ :; }; tui_bg(){ :; }; tui_reset(){ :; }; tui_bold(){ :; }; assert_lines_fit(){ local render="$1" line width; while IFS= read -r line; do width="$(tui_display_width "$line")"; (( width <= TUI_COLS )) || return 1; done <<< "$render"; }; box_single="$(tui_draw_box 0 0 1 1 X)"; box_line="$(tui_draw_box 0 0 6 1 X)"; box_normal="$(tui_draw_box 0 0 6 3 X)"; center="$(tui_draw_center 0 中文)"; hline="$(tui_draw_hline 0 0 6)"; fill="$(tui_draw_fill 0 0 6 1 1)"; status="$(tui_statusbar_draw 0 very-long-left very-long-right)"; tui_draw_box -4 -5 -3 -2 X >/dev/null; tui_draw_center -3 中文 >/dev/null; tui_draw_hline -2 -3 -4 >/dev/null; tui_draw_fill -2 -3 -4 -4 1 >/dev/null; tui_statusbar_draw -1 very-long-left very-long-right >/dev/null; [[ "$TUI_BAD_MOVE" == false ]] && assert_lines_fit "$box_single" && assert_lines_fit "$box_line" && assert_lines_fit "$box_normal" && assert_lines_fit "$center" && assert_lines_fit "$hline" && assert_lines_fit "$fill" && assert_lines_fit "$status" && printf "done" || printf "bad-move"' _ "$PROJECT_ROOT")"
if [[ "$primitive_output" == "done" ]]; then
    test_pass
else
    test_fail "基础绘制函数仍传递负/越界坐标或输出超过屏幕宽度，输出为: $primitive_output"
fi

test_start "菜单 state 按键协议在同一 shell 保留导航状态并写入结果"
state_key_output="$(bash -c 'set -uo pipefail; source "$1/lib/tui_core.sh"; TUI_LINES=12; TUI_MENU_ITEMS=(A B C D E); TUI_MENU_VISIBLE_ITEMS=2; TUI_MENU_INDEX=0; TUI_MENU_SCROLL_OFFSET=0; state_stdout_log="$(mktemp)"; tui_menu_handle_key DOWN state >"$state_stdout_log"; down_index="$TUI_MENU_INDEX"; down_offset="$TUI_MENU_SCROLL_OFFSET"; down_result="${TUI_MENU_RESULT:-}"; down_stdout="$(<"$state_stdout_log")"; tui_menu_handle_key END state >"$state_stdout_log"; end_index="$TUI_MENU_INDEX"; end_offset="$TUI_MENU_SCROLL_OFFSET"; end_result="${TUI_MENU_RESULT:-}"; end_stdout="$(<"$state_stdout_log")"; tui_menu_handle_key HOME state >"$state_stdout_log"; home_index="$TUI_MENU_INDEX"; home_offset="$TUI_MENU_SCROLL_OFFSET"; home_result="${TUI_MENU_RESULT:-}"; home_stdout="$(<"$state_stdout_log")"; tui_menu_handle_key ENTER state >"$state_stdout_log"; enter_index="$TUI_MENU_INDEX"; enter_offset="$TUI_MENU_SCROLL_OFFSET"; enter_result="${TUI_MENU_RESULT:-}"; enter_stdout="$(<"$state_stdout_log")"; rm -f "$state_stdout_log"; printf "down=%s/%s/%s end=%s/%s/%s home=%s/%s/%s enter=%s/%s/%s stdout=%s|%s|%s|%s" "$down_index" "$down_offset" "$down_result" "$end_index" "$end_offset" "$end_result" "$home_index" "$home_offset" "$home_result" "$enter_index" "$enter_offset" "$enter_result" "$down_stdout" "$end_stdout" "$home_stdout" "$enter_stdout"' _ "$PROJECT_ROOT")"
if [[ "$state_key_output" == "down=1/0/ end=4/3/ home=0/0/ enter=0/0/0 stdout=|||" ]]; then
    test_pass
else
    test_fail "state 按键协议未在父 shell 保留状态，输出为: $state_key_output"
fi

test_start "菜单默认 stdout 按键协议保持兼容"
stdout_key_output="$(bash -c 'set -uo pipefail; source "$1/lib/tui_core.sh"; TUI_MENU_ITEMS=(A B C 返回); TUI_MENU_INDEX=1; printf "one=%s ten=" "$(tui_menu_handle_key 1)"; tui_menu_handle_key 10 >/dev/null || true; printf "zero=%s enter=%s quit=%s" "$(tui_menu_handle_key 0)" "$(tui_menu_handle_key ENTER)" "$(tui_menu_handle_key q)"' _ "$PROJECT_ROOT")"
if [[ "$stdout_key_output" == "one=0 ten=zero=3 enter=1 quit=-1" ]]; then
    test_pass
else
    test_fail "默认 stdout 按键协议发生变化，输出为: $stdout_key_output"
fi

test_start "未设置 TERM 时真实 tui_init 与主菜单绘制 smoke 可完成"
init_smoke_output="$(env -u LANG -u LC_ALL -u LC_CTYPE -u TERM bash -c 'set -uo pipefail; source "$1/lib/tui_core.sh"; tput_log="$(mktemp)"; tput(){ printf "%s\n" "$*" >> "$tput_log"; }; stty(){ :; }; clear(){ :; }; get_tui_managed_user_count(){ printf "0"; }; uptime(){ printf "up 1 minute"; }; source "$1/lib/tui_menus.sh"; tui_init; _tui_draw_menu main >/dev/null; tput_calls="$(<"$tput_log")"; color_values=("${TUI_COLOR_BG:-}" "${TUI_COLOR_FG:-}" "${TUI_COLOR_ACCENT:-}" "${TUI_COLOR_ACCENT2:-}" "${TUI_COLOR_SUCCESS:-}" "${TUI_COLOR_MUTED:-}" "${TUI_COLOR_HIGHLIGHT:-}" "${TUI_COLOR_SURFACE:-}" "${TUI_COLOR_BORDER:-}"); colors_defined=true; for color_token in "${color_values[@]}"; do [[ -n "$color_token" ]] || colors_defined=false; done; printf "initialized=%s colors=%s defined=%s tput=%s" "$TUI_INITIALIZED" "$TUI_HAS_COLORS" "$colors_defined" "${tput_calls:-none}"; rm -f "$tput_log"; tui_cleanup' _ "$PROJECT_ROOT" 2>&1)"
if [[ "$init_smoke_output" == *"initialized=true"* ]] && [[ "$init_smoke_output" == *"colors=false"* ]] && [[ "$init_smoke_output" == *"defined=true"* ]] && [[ "$init_smoke_output" != *"setaf"* ]] && [[ "$init_smoke_output" != *"setab"* ]]; then
    test_pass
else
    test_fail "未设置 TERM 时 tui_init/菜单 smoke 失败，输出为: $init_smoke_output"
fi

test_start "tui_run state 模式直接在父 shell 调用 handler"
tui_run_state_output="$(printf 'DOWN\nq\n' | env TERM= dumb= bash -c 'set -uo pipefail; source "$1/lib/tui_core.sh"; TUI_RUNNING=true; TUI_REDRAW=false; TUI_MENU_ITEMS=(A B C); TUI_MENU_VISIBLE_ITEMS=2; TUI_MENU_INDEX=0; TUI_MENU_SCROLL_OFFSET=0; draw_stub(){ :; }; tui_read_key(){ local key_in; IFS= read -r key_in || return 1; printf "%s" "$key_in"; }; state_handler(){ tui_menu_handle_key "$1" state >/dev/null; if [[ "${TUI_MENU_RESULT:-}" == "-1" ]]; then TUI_RUNNING=false; fi; }; tui_run draw_stub state_handler state; printf "index=%s running=%s" "$TUI_MENU_INDEX" "$TUI_RUNNING"' _ "$PROJECT_ROOT" 2>&1)"
if [[ "$tui_run_state_output" == "index=1 running=false" ]]; then
    test_pass
else
    test_fail "tui_run state 模式未在父 shell 执行 handler，输出为: $tui_run_state_output"
fi

test_start "TERM=dumb 明确拒绝全屏 TUI 且不启用颜色"
dumb_terminal_output="$(env TERM=dumb bash -c 'set -uo pipefail; source "$1/lib/tui_core.sh"; tui_terminal_supported; rc=$?; tui_detect_terminal; printf "rc=%s reason=%s colors=%s" "$rc" "$TUI_TERMINAL_REASON" "$TUI_HAS_COLORS"' _ "$PROJECT_ROOT" 2>&1)"
if [[ "$dumb_terminal_output" == "rc=1 reason=unsupported-term:dumb colors=false" ]]; then
    test_pass
else
    test_fail "TERM=dumb 未被安全拒绝，输出为: $dumb_terminal_output"
fi

test_start "非交互终端返回明确原因"
noninteractive_output="$(env TERM=xterm-256color bash -c 'set -uo pipefail; source "$1/lib/tui_core.sh"; tui_terminal_supported; rc=$?; printf "rc=%s reason=%s" "$rc" "$TUI_TERMINAL_REASON"' _ "$PROJECT_ROOT" 2>&1)"
if [[ "$noninteractive_output" == "rc=1 reason=not-interactive-terminal" ]]; then
    test_pass
else
    test_fail "非交互终端检测语义异常，输出为: $noninteractive_output"
fi

test_start "交互终端缺失光标寻址能力时拒绝 TUI"
capability_output="$(env TERM=fixture-term bash -c 'set -uo pipefail; source "$1/lib/tui_core.sh"; tui_terminal_is_interactive(){ return 0; }; tput(){ return 1; }; tui_terminal_supported; rc=$?; printf "rc=%s reason=%s" "$rc" "$TUI_TERMINAL_REASON"' _ "$PROJECT_ROOT" 2>&1)"
if [[ "$capability_output" == "rc=1 reason=cursor-addressing-unavailable" ]]; then
    test_pass
else
    test_fail "缺失 cursor addressing 未被拒绝，输出为: $capability_output"
fi

test_start "TERM=dumb 初始化不调用 tput 或 stty"
dumb_init_output="$(env TERM=dumb bash -c 'set -uo pipefail; source "$1/lib/tui_core.sh"; tput(){ printf "tput"; }; stty(){ printf "stty"; }; tui_init; printf " initialized=%s colors=%s" "$TUI_INITIALIZED" "$TUI_HAS_COLORS"' _ "$PROJECT_ROOT" 2>&1)"
if [[ "$dumb_init_output" == " initialized=true colors=false" ]]; then
    test_pass
else
    test_fail "TERM=dumb 初始化仍使用终端控制命令，输出为: $dumb_init_output"
fi

test_suite_end
