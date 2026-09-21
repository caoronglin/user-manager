#!/bin/bash
# tui_core.sh - 原生TUI框架 v1.0.0
# 提供全屏界面、键盘导航、实时更新功能
# 无需外部依赖，纯Bash实现

set -uo pipefail

# ============================================================
# TUI配置常量
# ============================================================

# 这些值必须在无 TERM、无颜色以及 set -u 的调用环境中也存在。
TUI_HAS_COLORS="${TUI_HAS_COLORS:-false}"
TUI_HAS_UTF8="${TUI_HAS_UTF8:-false}"
TUI_INITIALIZED="${TUI_INITIALIZED:-false}"
TUI_RUNNING="${TUI_RUNNING:-false}"
TUI_REDRAW="${TUI_REDRAW:-false}"
TUI_COLS="${TUI_COLS:-80}"
TUI_LINES="${TUI_LINES:-24}"
TUI_OLD_STTY="${TUI_OLD_STTY:-}"
TUI_TERMINAL_SUPPORTED="${TUI_TERMINAL_SUPPORTED:-false}"
TUI_TERMINAL_ACTIVE="${TUI_TERMINAL_ACTIVE:-false}"
TUI_TERMINAL_REASON="${TUI_TERMINAL_REASON:-uninitialized}"
TUI_COLOR_BG="${TUI_COLOR_BG:-234}"
TUI_COLOR_FG="${TUI_COLOR_FG:-252}"
TUI_COLOR_ACCENT="${TUI_COLOR_ACCENT:-40}"
TUI_COLOR_ACCENT2="${TUI_COLOR_ACCENT2:-46}"
TUI_COLOR_SUCCESS="${TUI_COLOR_SUCCESS:-48}"
TUI_COLOR_MUTED="${TUI_COLOR_MUTED:-243}"
TUI_COLOR_HIGHLIGHT="${TUI_COLOR_HIGHLIGHT:-48}"
TUI_COLOR_SURFACE="${TUI_COLOR_SURFACE:-236}"
TUI_COLOR_BORDER="${TUI_COLOR_BORDER:-239}"
TUI_MENU_ITEMS=()
TUI_MENU_TITLE=""
TUI_MENU_INDEX=0
TUI_MENU_SCROLL_OFFSET=0
TUI_MENU_VISIBLE_ITEMS=0
TUI_MENU_VIEWPORT_END=""
TUI_MENU_RESULT=""
TUI_ACTIVE_MENU_ID=""

_tui_normalize_dimension() {
    local value="${1:-0}"
    local fallback="${2:-1}"
    [[ "$value" =~ ^[0-9]+$ ]] || value="$fallback"
    ((value < 1)) && value="$fallback"
    printf '%s\n' "$value"
}

_tui_clamp_row() {
    local row="${1:-0}"
    local lines="$(_tui_normalize_dimension "${TUI_LINES:-24}" 24)"
    [[ "$row" =~ ^-?[0-9]+$ ]] || row=0
    ((row < 0)) && row=0
    ((row >= lines)) && row=$((lines - 1))
    printf '%s\n' "$row"
}

_tui_clamp_col() {
    local col="${1:-0}"
    local cols="$(_tui_normalize_dimension "${TUI_COLS:-80}" 80)"
    [[ "$col" =~ ^-?[0-9]+$ ]] || col=0
    ((col < 0)) && col=0
    ((col >= cols)) && col=$((cols - 1))
    printf '%s\n' "$col"
}

# 选择不为空的 locale，不改写当前 shell 的环境。
tui_effective_locale() {
    local candidate
    for candidate in "${LC_ALL:-}" "${LC_CTYPE:-}" "${LANG:-}"; do
        if [[ -n "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    printf 'C\n'
}

# 判断 stdin/stdout 是否都连接到交互终端；可在测试中替换该函数。
tui_terminal_is_interactive() {
    [[ -t 0 && -t 1 ]]
}

# 全屏 TUI 需要可寻址光标。不能满足时绝不进入 raw mode 或备用屏幕。
tui_terminal_supported() {
    local term="${TERM:-}"

    TUI_TERMINAL_SUPPORTED=false
    case "$term" in
    '') TUI_TERMINAL_REASON='term-unset'; return 1 ;;
    dumb | unknown | cons25 | emacs) TUI_TERMINAL_REASON="unsupported-term:$term"; return 1 ;;
    esac
    if ! tui_terminal_is_interactive; then
        TUI_TERMINAL_REASON='not-interactive-terminal'
        return 1
    fi
    if ! command -v tput >/dev/null 2>&1; then
        TUI_TERMINAL_REASON='tput-unavailable'
        return 1
    fi
    if ! tput -T "$term" cup 0 0 >/dev/null 2>&1; then
        TUI_TERMINAL_REASON='cursor-addressing-unavailable'
        return 1
    fi
    TUI_TERMINAL_SUPPORTED=true
    TUI_TERMINAL_REASON='ready'
    return 0
}

# 检测终端能力
tui_detect_terminal() {
    local effective_locale
    local charmap=""
    local probe=$'é'
    effective_locale="$(tui_effective_locale)"

    if tui_terminal_supported; then
        TUI_HAS_COLORS=true
    else
        TUI_HAS_COLORS=false
    fi

    # 尺寸探测可以失败；会自动回退到安全的 80x24。
    tui_get_size

    # 检查Unicode支持
    TUI_HAS_UTF8=false
    if [[ "$effective_locale" =~ (^|[._-])[Uu][Tt][Ff]-?8($|@) ]]; then
        charmap="$(LC_ALL="$effective_locale" locale charmap 2>/dev/null || true)"
        if [[ "$charmap" =~ ^[Uu][Tt][Ff]-?8$ ]] && ((${#probe} == 1)); then
            TUI_HAS_UTF8=true
        fi
    fi
}

# 初始化TUI
tui_init() {
    tui_detect_terminal

    # 仅在完整终端能力已确认时触碰 tty 状态或发送控制序列。
    TUI_TERMINAL_ACTIVE=false
    TUI_OLD_STTY=""
    if [[ "${TUI_TERMINAL_SUPPORTED:-false}" == "true" ]]; then
        TUI_OLD_STTY="$(stty -g 2>/dev/null || true)"
        stty -echo -icanon time 0 min 0 2>/dev/null || true
        tput civis 2>/dev/null || true
        tput smcup 2>/dev/null || true
        tput clear 2>/dev/null || true
        TUI_TERMINAL_ACTIVE=true
    fi

    # 定义颜色（256色 - 现代暗色主题）
    if [[ "$TUI_HAS_COLORS" == "true" ]]; then
        # shellcheck disable=SC2034  # used in tui_menus.sh via source
        TUI_COLOR_BG=234    # 深灰黑背景 (#1a1a2e)
        TUI_COLOR_FG=252    # 柔和白前景
        TUI_COLOR_ACCENT=40 # 绿色
        # shellcheck disable=SC2034  # used in tui_menus.sh via source
        TUI_COLOR_ACCENT2=46   # 亮绿色高亮
        TUI_COLOR_SUCCESS=48   # 翠绿
        TUI_COLOR_MUTED=243    # 中灰
        TUI_COLOR_HIGHLIGHT=48 # 绿色选中
        # shellcheck disable=SC2034  # used in tui_menus.sh via source
        TUI_COLOR_SURFACE=236 # 卡片背景
        # shellcheck disable=SC2034  # used in tui_menus.sh via source
        TUI_COLOR_BORDER=239 # 边框灰
    fi

    TUI_INITIALIZED=true
    # shellcheck disable=SC2034  # used in tui_core.sh:762 and tui_manager.sh via source
    TUI_RUNNING=true
    TUI_REDRAW=true

    tui_menu_invalidate_state

    return 0
}

# 清理TUI
tui_cleanup() {
    [[ "${TUI_INITIALIZED:-false}" != "true" ]] && return 0

    # 仅恢复本次 tui_init 实际修改过的终端状态。
    if [[ "${TUI_TERMINAL_ACTIVE:-false}" == "true" ]]; then
        tput cnorm 2>/dev/null || true
        tput rmcup 2>/dev/null || true
        [[ -n "$TUI_OLD_STTY" ]] && stty "$TUI_OLD_STTY" 2>/dev/null || true
    fi

    TUI_OLD_STTY=""
    TUI_TERMINAL_ACTIVE=false
    TUI_INITIALIZED=false
    TUI_RUNNING=false
}

# ============================================================
# 颜色和样式函数
# ============================================================

# 设置前景色
tui_fg() {
    local color="${1:-0}"
    [[ "${TUI_HAS_COLORS:-false}" == "true" ]] || return 0
    tput setaf "$color" 2>/dev/null || true
}

# 设置背景色
tui_bg() {
    local color="${1:-0}"
    [[ "${TUI_HAS_COLORS:-false}" == "true" ]] || return 0
    tput setab "$color" 2>/dev/null || true
}

# 重置样式
tui_reset() {
    [[ "${TUI_TERMINAL_ACTIVE:-false}" == "true" ]] || return 0
    tput sgr0 2>/dev/null || true
}

# 粗体
tui_bold() {
    [[ "${TUI_TERMINAL_ACTIVE:-false}" == "true" ]] || return 0
    tput bold 2>/dev/null || true
}

# 下划线
tui_underline() {
    [[ "${TUI_TERMINAL_ACTIVE:-false}" == "true" ]] || return 0
    tput smul 2>/dev/null || true
}

# 反色
tui_reverse() {
    [[ "${TUI_TERMINAL_ACTIVE:-false}" == "true" ]] || return 0
    tput rev 2>/dev/null || true
}

# ============================================================
# 光标和屏幕函数
# ============================================================

# 移动光标
tui_move() {
    local row="$(_tui_clamp_row "${1:-0}")"
    local col="$(_tui_clamp_col "${2:-0}")"
    if [[ "${TUI_TERMINAL_ACTIVE:-false}" == "true" ]]; then
        tput cup "$row" "$col" 2>/dev/null || true
    fi
}

# 清屏
tui_clear() {
    if [[ "${TUI_TERMINAL_ACTIVE:-false}" == "true" ]]; then
        tput clear 2>/dev/null || true
    fi
}

# 清除到行尾
tui_clear_eol() {
    [[ "${TUI_TERMINAL_ACTIVE:-false}" == "true" ]] || return 0
    tput el 2>/dev/null || true
}

# 清除整行
tui_clear_line() {
    [[ "${TUI_TERMINAL_ACTIVE:-false}" == "true" ]] || return 0
    tput el1 2>/dev/null || true
    tput el 2>/dev/null || true
}

# 获取屏幕尺寸
tui_get_size() {
    local cols lines
    cols=""
    lines=""
    if [[ "${TUI_TERMINAL_SUPPORTED:-false}" == "true" ]]; then
        cols="$(tput cols 2>/dev/null || true)"
        lines="$(tput lines 2>/dev/null || true)"
    fi
    TUI_COLS="$(_tui_normalize_dimension "$cols" 80)"
    TUI_LINES="$(_tui_normalize_dimension "$lines" 24)"
}

# 去除 ANSI CSI 控制序列。
tui_strip_ansi() {
    local text="${1:-}"
    printf '%s' "$text" | LC_ALL=C sed -E $'s/\033\[[0-9;?]*[ -\/]*[@-~]//g'
}

# 返回单个 Bash 多字节字符的近似显示列宽。
tui_char_display_width() {
    local char="${1:-}"
    local codepoint

    [[ -z "$char" ]] && {
        printf '0\n'
        return 0
    }
    if [[ "${TUI_HAS_UTF8:-false}" != "true" ]]; then
        printf '1\n'
        return 0
    fi

    printf -v codepoint '%d' "'${char}"
    if ((codepoint == 0x200D || codepoint == 0xFE0E || codepoint == 0xFE0F || (codepoint >= 0x300 && codepoint <= 0x36F) || (codepoint >= 0x1AB0 && codepoint <= 0x1AFF) || (codepoint >= 0x1DC0 && codepoint <= 0x1DFF) || (codepoint >= 0x20D0 && codepoint <= 0x20FF) || (codepoint >= 0xFE20 && codepoint <= 0xFE2F))); then
        printf '0\n'
    elif ((codepoint < 0x20 || (codepoint >= 0x7F && codepoint <= 0x9F))); then
        printf '0\n'
    elif (((codepoint >= 0x1100 && codepoint <= 0x115F) || (codepoint >= 0x2300 && codepoint <= 0x23FF) || (codepoint >= 0x2600 && codepoint <= 0x27BF) || (codepoint >= 0x2329 && codepoint <= 0x232A) || (codepoint >= 0x2E80 && codepoint <= 0xA4CF) || (codepoint >= 0xAC00 && codepoint <= 0xD7A3) || (codepoint >= 0xF900 && codepoint <= 0xFAFF) || (codepoint >= 0xFE10 && codepoint <= 0xFE19) || (codepoint >= 0xFE30 && codepoint <= 0xFE6F) || (codepoint >= 0xFF00 && codepoint <= 0xFF60) || (codepoint >= 0xFFE0 && codepoint <= 0xFFE6) || (codepoint >= 0x1F000 && codepoint <= 0x1FAFF))); then
        printf '2\n'
    else
        printf '1\n'
    fi
}

tui_display_width() {
    local text="$(tui_strip_ansi "${1:-}")"
    local width=0 char

    if [[ "${TUI_HAS_UTF8:-false}" != "true" ]]; then
        printf '%s\n' "${#text}"
        return 0
    fi
    while [[ -n "$text" ]]; do
        char="${text:0:1}"
        text="${text:1}"
        width=$((width + $(tui_char_display_width "$char")))
    done
    printf '%s\n' "$width"
}

tui_truncate_display() {
    local text="${1:-}"
    local max_width="${2:-0}"
    local result="" char char_width current=0
    [[ "$max_width" =~ ^[0-9]+$ ]] || max_width=0

    while [[ -n "$text" ]]; do
        char="${text:0:1}"
        text="${text:1}"
        char_width="$(tui_char_display_width "$char")"
        ((current + char_width > max_width)) && break
        result+="$char"
        current=$((current + char_width))
    done
    printf '%s' "$result"
}

tui_pad_display() {
    local text="${1:-}"
    local target_width="${2:-0}"
    local current
    [[ "$target_width" =~ ^[0-9]+$ ]] || target_width=0
    text="$(tui_truncate_display "$text" "$target_width")"
    current="$(tui_display_width "$text")"
    printf '%s%*s' "$text" "$((target_width - current))" ''
}

# ============================================================
# 绘制函数
# ============================================================

# 绘制边框
tui_draw_box() {
    local row="${1:-0}"
    local col="${2:-0}"
    local width="${3:-1}"
    local height="${4:-1}"
    local title="${5:-}"
    local cols="$(_tui_normalize_dimension "${TUI_COLS:-80}" 80)"
    local lines="$(_tui_normalize_dimension "${TUI_LINES:-24}" 24)"
    [[ "$row" =~ ^-?[0-9]+$ ]] || row=0
    [[ "$col" =~ ^-?[0-9]+$ ]] || col=0
    [[ "$width" =~ ^-?[0-9]+$ ]] || width=1
    [[ "$height" =~ ^-?[0-9]+$ ]] || height=1
    ((row < 0)) && row=0
    ((col < 0)) && col=0
    ((row >= lines || col >= cols)) && return 0
    ((width < 1)) && width=1
    ((height < 1)) && height=1
    ((width > cols - col)) && width=$((cols - col))
    ((height > lines - row)) && height=$((lines - row))
    ((width < 1 || height < 1)) && return 0

    local h_line v_line tl tr bl br
    if [[ "${TUI_HAS_UTF8:-false}" == "true" ]]; then
        h_line="─"
        v_line="│"
        tl="┌"
        tr="┐"
        bl="└"
        br="┘"
    else
        h_line="-"
        v_line="|"
        tl="+"
        tr="+"
        bl="+"
        br="+"
    fi

    local safe_row="$(_tui_clamp_row "$row")"
    local safe_col="$(_tui_clamp_col "$col")"

    # 宽度/高度为 1 时只能绘制一个字符或一条边，避免重复角点和越界宽度。
    if ((width == 1 && height == 1)); then
        tui_move "$safe_row" "$safe_col"
        printf '%s' "$tl"
        return 0
    fi
    if ((height == 1)); then
        tui_move "$safe_row" "$safe_col"
        printf '%s' "$tl"
        for ((i = 0; i < width - 2; i++)); do printf '%s' "$h_line"; done
        ((width > 1)) && printf '%s' "$tr"
        return 0
    fi
    if ((width == 1)); then
        for ((i = 0; i < height; i++)); do
            tui_move "$(_tui_clamp_row "$((row + i))")" "$safe_col"
            if ((i == 0)); then
                printf '%s' "$tl"
            elif ((i == height - 1)); then
                printf '%s' "$bl"
            else
                printf '%s' "$v_line"
            fi
        done
        return 0
    fi

    # 顶部边框
    tui_move "$safe_row" "$safe_col"
    echo -n "$tl"
    for ((i = 0; i < width - 2; i++)); do echo -n "$h_line"; done
    echo -n "$tr"

    # 标题
    if [[ -n "$title" && width -ge 3 && height -gt 1 ]]; then
        local title_text=" $(tui_truncate_display "$title" "$((width - 2))") "
        local title_len="$(tui_display_width "$title_text")"
        local title_col=$((col + (width - title_len) / 2))
        tui_move "$safe_row" "$(_tui_clamp_col "$title_col")"
        tui_bold
        echo -n "$title_text"
        tui_reset
    fi

    # 侧边框
    for ((i = 1; i < height - 1; i++)); do
        tui_move "$(_tui_clamp_row "$((row + i))")" "$safe_col"
        echo -n "$v_line"
        tui_move "$(_tui_clamp_row "$((row + i))")" "$(_tui_clamp_col "$((col + width - 1))")"
        echo -n "$v_line"
    done

    # 底部边框
    tui_move "$(_tui_clamp_row "$((row + height - 1))")" "$safe_col"
    echo -n "$bl"
    for ((i = 0; i < width - 2; i++)); do echo -n "$h_line"; done
    echo -n "$br"
}

# 绘制文本
tui_draw_text() {
    local row="${1:-0}"
    local col="${2:-0}"
    local text="${3:-}"
    local color="${4:-${TUI_COLOR_FG:-252}}"
    local safe_row="$(_tui_clamp_row "$row")"
    local safe_col="$(_tui_clamp_col "$col")"
    local max_width=$((${TUI_COLS:-80} - safe_col))
    ((max_width < 0)) && max_width=0
    text="$(tui_truncate_display "$text" "$max_width")"
    [[ -n "$text" || max_width -eq 0 ]] || return 0

    tui_move "$safe_row" "$safe_col"
    tui_fg "$color"
    echo -n "$text"
    tui_reset
}

# 绘制居中文本
tui_draw_center() {
    local row="${1:-0}"
    local text="${2:-}"
    local color="${3:-${TUI_COLOR_FG:-252}}"
    local cols="$(_tui_normalize_dimension "${TUI_COLS:-80}" 80)"
    text="$(tui_truncate_display "$text" "$cols")"
    local len="$(tui_display_width "$text")"
    local col=$(((cols - len) / 2))
    ((col < 0)) && col=0

    tui_draw_text "$row" "$col" "$text" "$color"
}

# 绘制水平线
tui_draw_hline() {
    local row="${1:-0}"
    local col="${2:-0}"
    local width="${3:-0}"
    local char="${4:-─}"
    local safe_col="$(_tui_clamp_col "$col")"
    local available=$((${TUI_COLS:-80} - safe_col))
    [[ "$width" =~ ^[0-9]+$ ]] || width=0
    ((width > available)) && width="$available"
    ((width <= 0)) && return 0

    tui_move "$(_tui_clamp_row "$row")" "$safe_col"
    local current=0 char_width
    char_width="$(tui_char_display_width "$char")"
    ((char_width < 1)) && char_width=1
    while ((current + char_width <= width)); do
        echo -n "$char"
        current=$((current + char_width))
    done
}

# 绘制填充背景
tui_draw_fill() {
    local row="${1:-0}"
    local col="${2:-0}"
    local width="${3:-0}"
    local height="${4:-0}"
    local bg_color="${5:-0}"
    local safe_col="$(_tui_clamp_col "$col")"
    local safe_row="$(_tui_clamp_row "$row")"
    local available_width=$((${TUI_COLS:-80} - safe_col))
    local available_height=$((${TUI_LINES:-24} - safe_row))
    [[ "$width" =~ ^[0-9]+$ ]] || width=0
    [[ "$height" =~ ^[0-9]+$ ]] || height=0
    ((width > available_width)) && width="$available_width"
    ((height > available_height)) && height="$available_height"
    ((width <= 0 || height <= 0)) && return 0

    tui_bg "$bg_color"
    for ((i = 0; i < height; i++)); do
        tui_move "$(_tui_clamp_row "$((row + i))")" "$safe_col"
        for ((j = 0; j < width; j++)); do
            echo -n " "
        done
    done
    tui_reset
}

# ============================================================
# 菜单组件
# ============================================================

# 创建菜单
tui_menu_create() {
    local title="${1:-}"
    shift
    local items=("$@")

    TUI_MENU_TITLE="$title"
    TUI_MENU_ITEMS=("${items[@]}")
    TUI_MENU_INDEX=0
    TUI_MENU_SCROLL_OFFSET=0
    TUI_MENU_VISIBLE_ITEMS=${#items[@]}
    TUI_MENU_VIEWPORT_END=${#items[@]}
    TUI_MENU_RESULT=""
}

tui_menu_invalidate_state() {
    TUI_MENU_TITLE=""
    TUI_MENU_ITEMS=()
    TUI_MENU_INDEX=0
    TUI_MENU_SCROLL_OFFSET=0
    TUI_MENU_VISIBLE_ITEMS=0
    TUI_MENU_VIEWPORT_END=""
    TUI_MENU_RESULT=""
    TUI_ACTIVE_MENU_ID=""
}

_tui_menu_reconcile_viewport() {
    local total_items=${#TUI_MENU_ITEMS[@]}
    local visible_items="${TUI_MENU_VISIBLE_ITEMS:-1}"
    local max_offset

    [[ "$visible_items" =~ ^[0-9]+$ ]] || visible_items=1
    ((visible_items < 1)) && visible_items=1
    if ((total_items == 0)); then
        TUI_MENU_INDEX=0
        TUI_MENU_SCROLL_OFFSET=0
        TUI_MENU_VISIBLE_ITEMS=1
        TUI_MENU_VIEWPORT_END=0
        return 0
    fi
    ((visible_items > total_items)) && visible_items="$total_items"
    TUI_MENU_VISIBLE_ITEMS="$visible_items"
    [[ "${TUI_MENU_INDEX:-0}" =~ ^[0-9]+$ ]] || TUI_MENU_INDEX=0
    [[ "${TUI_MENU_SCROLL_OFFSET:-0}" =~ ^[0-9]+$ ]] || TUI_MENU_SCROLL_OFFSET=0
    ((TUI_MENU_INDEX >= total_items)) && TUI_MENU_INDEX=$((total_items - 1))
    max_offset=$((total_items - visible_items))
    ((TUI_MENU_SCROLL_OFFSET > max_offset)) && TUI_MENU_SCROLL_OFFSET="$max_offset"
    ((TUI_MENU_INDEX < TUI_MENU_SCROLL_OFFSET)) && TUI_MENU_SCROLL_OFFSET="$TUI_MENU_INDEX"
    ((TUI_MENU_INDEX >= TUI_MENU_SCROLL_OFFSET + visible_items)) && TUI_MENU_SCROLL_OFFSET=$((TUI_MENU_INDEX - visible_items + 1))
    ((TUI_MENU_SCROLL_OFFSET > max_offset)) && TUI_MENU_SCROLL_OFFSET="$max_offset"
    TUI_MENU_VIEWPORT_END=$((TUI_MENU_SCROLL_OFFSET + visible_items))
    ((TUI_MENU_VIEWPORT_END > total_items)) && TUI_MENU_VIEWPORT_END="$total_items"
}

tui_menu_update_viewport() {
    local first_item_row="${1:-0}"
    local reserved_bottom_rows="${2:-0}"
    local total_items=${#TUI_MENU_ITEMS[@]}
    local lines="$(_tui_normalize_dimension "${TUI_LINES:-24}" 24)"

    [[ "$first_item_row" =~ ^-?[0-9]+$ ]] || first_item_row=0
    [[ "$reserved_bottom_rows" =~ ^[0-9]+$ ]] || reserved_bottom_rows=0
    ((first_item_row < 0)) && first_item_row=0
    local available=$((lines - first_item_row - reserved_bottom_rows))
    ((available < 1)) && available=1
    TUI_MENU_VISIBLE_ITEMS="$available"
    ((TUI_MENU_VISIBLE_ITEMS > total_items && total_items > 0)) && TUI_MENU_VISIBLE_ITEMS="$total_items"
    _tui_menu_reconcile_viewport
}

# 绘制菜单
tui_menu_draw() {
    local start_row="$1"
    local start_col="$2"
    local width="$3"
    local total_items=${#TUI_MENU_ITEMS[@]}
    local lines="$(_tui_normalize_dimension "${TUI_LINES:-24}" 24)"
    local cols="$(_tui_normalize_dimension "${TUI_COLS:-80}" 80)"
    local safe_start_row="$start_row"
    local safe_start_col="$start_col"
    [[ "$safe_start_row" =~ ^-?[0-9]+$ ]] || safe_start_row=0
    [[ "$safe_start_col" =~ ^-?[0-9]+$ ]] || safe_start_col=0
    ((safe_start_row < 0)) && safe_start_row=0
    ((safe_start_col < 0)) && safe_start_col=0
    ((safe_start_row >= lines)) && safe_start_row=$((lines - 1))
    ((safe_start_col >= cols)) && safe_start_col=$((cols - 1))
    ((width < 1)) && width=1
    ((width > cols - safe_start_col)) && width=$((cols - safe_start_col))
    ((width < 1)) && return 0

    local max_menu_height=$((lines - safe_start_row - 1))
    ((max_menu_height < 1)) && max_menu_height=1
    local max_visible=$((max_menu_height - 3))
    ((max_visible < 1)) && max_visible=1
    TUI_LINES="$lines"
    if ((lines < 7)); then
        TUI_MENU_VISIBLE_ITEMS=1
        _tui_menu_reconcile_viewport
        local compact_row=0
        local compact_end="$TUI_MENU_VIEWPORT_END"
        ((compact_end > total_items)) && compact_end="$total_items"
        for ((i = TUI_MENU_SCROLL_OFFSET; i < compact_end && compact_row < lines; i++)); do
            local compact_text="$(tui_pad_display "${TUI_MENU_ITEMS[$i]:-}" "$width")"
            tui_move "$compact_row" "$safe_start_col"
            if [[ "$i" -eq "$TUI_MENU_INDEX" ]]; then
                tui_reverse
                tui_fg "$TUI_COLOR_HIGHLIGHT"
            else
                tui_fg "$TUI_COLOR_FG"
            fi
            printf '%s' "$compact_text"
            tui_reset
            ((compact_row++))
        done
        return 0
    else
        tui_menu_update_viewport $((safe_start_row + 2)) 2
    fi
    ((TUI_MENU_VISIBLE_ITEMS > max_visible)) && TUI_MENU_VISIBLE_ITEMS="$max_visible"
    _tui_menu_reconcile_viewport

    local menu_height=$((TUI_MENU_VISIBLE_ITEMS + 3))
    ((menu_height > max_menu_height)) && menu_height="$max_menu_height"
    ((menu_height < 1)) && menu_height=1

    # 绘制边框
    tui_draw_box "$safe_start_row" "$safe_start_col" "$width" "$menu_height" "$TUI_MENU_TITLE"

    # 绘制菜单项
    local item_row=$((safe_start_row + 2))
    local end_index=$((TUI_MENU_SCROLL_OFFSET + TUI_MENU_VISIBLE_ITEMS))
    ((end_index > total_items)) && end_index=$total_items
    for ((i = TUI_MENU_SCROLL_OFFSET; i < end_index; i++)); do
        local item="${TUI_MENU_ITEMS[$i]}"
        local display="$(tui_pad_display "  $item  " "$((width - 2))")"

        tui_move "$(_tui_clamp_row "$item_row")" "$(_tui_clamp_col "$((safe_start_col + 1))")"

        if [[ $i -eq $TUI_MENU_INDEX ]]; then
            tui_reverse
            tui_fg "$TUI_COLOR_HIGHLIGHT"
        else
            tui_fg "$TUI_COLOR_FG"
        fi

        printf "%s" "$display"
        tui_reset

        ((item_row++))
    done

    # 绘制底部提示
    local status_row=$((lines - 1))
    local status_col=$((safe_start_col + 1))
    local status_width=$((cols - status_col))
    local inner_width=$((width - 2))
    ((inner_width < 0)) && inner_width=0
    ((status_width > inner_width)) && status_width="$inner_width"
    ((status_width < 0)) && status_width=0
    local status_text
    if ((total_items > TUI_MENU_VISIBLE_ITEMS)); then
        local status_suffix="[$((TUI_MENU_SCROLL_OFFSET + 1))-${end_index}/${total_items}]"
        local status_prefix="↑/↓ 导航  Enter 选择  q 退出  "
        local suffix_width="$(tui_display_width "$status_suffix")"
        local prefix_width=$((status_width - suffix_width))
        ((prefix_width < 0)) && prefix_width=0
        status_text="$(tui_truncate_display "$status_prefix" "$prefix_width")${status_suffix}"
    else
        status_text="↑/↓ 导航  Enter 选择  q 退出"
        status_text="$(tui_truncate_display "$status_text" "$status_width")"
    fi
    tui_statusbar_draw "$status_row" "$status_text" "" "${TUI_COLOR_MUTED:-243}"
}

# 处理菜单键盘输入
tui_menu_handle_key() {
    local key="$1"
    local mode="${2:-stdout}"
    local visible_items="${TUI_MENU_VISIBLE_ITEMS:-${#TUI_MENU_ITEMS[@]}}"
    local total_items=${#TUI_MENU_ITEMS[@]}
    local result=""
    [[ "$mode" == "state" ]] && TUI_MENU_RESULT=""
    ((visible_items < 1)) && visible_items=1
    _tui_menu_reconcile_viewport

    case "$key" in
    0)
        ((total_items > 0)) && result="$((total_items - 1))"
        ;;
    [1-9] | [1-9][0-9]*)
        local direct_index=$((key - 1))
        if ((direct_index >= 0 && direct_index < total_items - 1)); then
            result="$direct_index"
        fi
        ;;
    UP | k)
        ((total_items > 0 && TUI_MENU_INDEX > 0)) && ((TUI_MENU_INDEX--))
        _tui_menu_reconcile_viewport
        TUI_REDRAW=true
        ;;
    DOWN | j)
        ((total_items > 0 && TUI_MENU_INDEX < total_items - 1)) && ((TUI_MENU_INDEX++))
        _tui_menu_reconcile_viewport
        TUI_REDRAW=true
        ;;
    HOME)
        TUI_MENU_INDEX=0
        TUI_MENU_SCROLL_OFFSET=0
        _tui_menu_reconcile_viewport
        TUI_REDRAW=true
        ;;
    END)
        ((total_items > 0)) && TUI_MENU_INDEX=$((total_items - 1))
        _tui_menu_reconcile_viewport
        TUI_REDRAW=true
        ;;
    ENTER)
        ((total_items > 0)) && result="$TUI_MENU_INDEX"
        ;;
    q | ESC)
        result="-1"
        ;;
    esac

    if [[ "$mode" == "state" ]]; then
        TUI_MENU_RESULT="$result"
        return 0
    fi
    if [[ -n "$result" ]]; then
        printf '%s\n' "$result"
        return 0
    fi
    return 1
}

# ============================================================
# 表格组件
# ============================================================

# 绘制表格
tui_table_draw() {
    local row="$1"
    local col="$2"
    local -a headers=("${!3}")
    local -a widths=("${!4}")
    local -a data=("${!5}")
    local selected="${6:--1}"

    local total_width=0
    for w in "${widths[@]}"; do
        ((total_width += w + 1))
    done

    # 绘制表头
    tui_move "$row" "$col"
    tui_bold
    tui_fg "$TUI_COLOR_ACCENT"
    for i in "${!headers[@]}"; do
        printf "%-${widths[$i]}s " "${headers[$i]}"
    done
    tui_reset

    # 绘制分隔线
    ((row++))
    tui_move "$row" "$col"
    tui_fg "$TUI_COLOR_MUTED"
    for w in "${widths[@]}"; do
        for ((i = 0; i < w; i++)); do echo -n "─"; done
        echo -n " "
    done
    tui_reset

    # 绘制数据行
    local data_row=$((row + 1))
    local item_idx=0
    local cols=${#headers[@]}

    for i in "${!data[@]}"; do
        local col_idx=$((i % cols))
        local display="${data[$i]}"
        [[ ${#display} -gt ${widths[$col_idx]} ]] && display="${display:0:${widths[$col_idx]}-3}..."

        tui_move "$data_row" $((col + col_idx * (widths[$col_idx] + 1)))

        if [[ $((item_idx / cols)) -eq $selected ]]; then
            tui_reverse
            tui_fg "$TUI_COLOR_HIGHLIGHT"
        else
            tui_fg "$TUI_COLOR_FG"
        fi

        printf "%-${widths[$col_idx]}s" "$display"
        tui_reset

        if (((i + 1) % cols == 0)); then
            ((data_row++))
            ((item_idx += cols))
        fi
    done
}

# ============================================================
# 进度条组件
# ============================================================

# 绘制进度条
tui_progress_draw() {
    local row="$1"
    local col="$2"
    local width="$3"
    local percent="$4"
    local label="${5:-}"

    local filled=$((width * percent / 100))
    local empty=$((width - filled))

    tui_move "$row" "$col"

    # 标签
    [[ -n "$label" ]] && echo -n "$label "

    # 进度条
    tui_fg "$TUI_COLOR_SUCCESS"
    for ((i = 0; i < filled; i++)); do
        echo -n "#"
    done

    tui_fg "$TUI_COLOR_MUTED"
    for ((i = 0; i < empty; i++)); do
        echo -n "-"
    done

    tui_reset
    echo -n " ${percent}%"
}

# ============================================================
# 输入框组件
# ============================================================

# 绘制输入框
tui_input_draw() {
    local row="$1"
    local col="$2"
    local width="$3"
    local label="$4"
    local value="$5"
    local cursor_pos="${6:-${#value}}"

    # 标签
    tui_move "$row" "$col"
    tui_fg "$TUI_COLOR_ACCENT"
    echo -n "$label"
    tui_reset

    # 输入框边框
    ((row++))
    tui_draw_box "$row" "$col" $((width + 4)) 3

    # 输入值
    tui_move $((row + 1)) $((col + 2))
    tui_fg "$TUI_COLOR_FG"
    printf "%-${width}s" "${value:0:$width}"
    tui_reset

    # 光标位置
    local cursor_col=$((col + 2 + cursor_pos))
    [[ $cursor_pos -gt $width ]] && cursor_col=$((col + 2 + width))
    tui_move $((row + 1)) "$cursor_col"
    [[ "${TUI_TERMINAL_ACTIVE:-false}" == "true" ]] && tput cnorm 2>/dev/null || true
}

tui_prompt_input() {
    local title="$1"
    local label="$2"
    local default_value="${3:-}"
    local value="$default_value"

    while true; do
        local width=40
        local row=$(((TUI_LINES - 7) / 2))
        local col=$(((TUI_COLS - (width + 4)) / 2))

        tui_clear
        tui_draw_box "$row" "$col" $((width + 4)) 6 "$title"
        tui_input_draw $((row + 1)) $((col + 2)) "$width" "$label" "$value"
        tui_move $((row + 4)) $((col + 2))
        tui_fg "$TUI_COLOR_MUTED"
        echo -n "Enter 确认  Esc 取消  Backspace 删除"
        tui_reset

        local key
        key=$(tui_read_key 2>/dev/null) || continue

        case "$key" in
        ENTER)
            REPLY_INPUT="$value"
            return 0
            ;;
        q | ESC)
            return 1
            ;;
        BACKSPACE | $'\x7f' | $'\b')
            value="${value%?}"
            ;;
        HOME)
            value="$default_value"
            ;;
        *)
            if [[ ${#key} -eq 1 && "$key" =~ [[:print:]] ]]; then
                value+="$key"
            fi
            ;;
        esac
    done
}

tui_prompt_select() {
    local title="$1"
    local label="$2"
    local default_index="${3:-0}"
    shift 3
    local options=("$@")

    ((${#options[@]} == 0)) && return 1

    local selected="$default_index"
    ((selected < 0)) && selected=0
    ((selected >= ${#options[@]})) && selected=0

    while true; do
        local width=50
        local height=$((${#options[@]} + 6))
        local row=$(((TUI_LINES - height) / 2))
        local col=$(((TUI_COLS - width) / 2))

        tui_clear
        tui_draw_box "$row" "$col" "$width" "$height" "$title"
        tui_move $((row + 1)) $((col + 2))
        tui_fg "$TUI_COLOR_ACCENT"
        echo -n "$label"
        tui_reset

        local option_row=$((row + 2))
        local i
        for i in "${!options[@]}"; do
            tui_move "$option_row" $((col + 2))
            if ((i == selected)); then
                tui_reverse
                tui_fg "$TUI_COLOR_HIGHLIGHT"
            else
                tui_fg "$TUI_COLOR_FG"
            fi
            printf "%-${width}s" "  ${options[$i]}"
            tui_reset
            ((option_row++))
        done

        tui_move $((row + height - 1)) $((col + 2))
        tui_fg "$TUI_COLOR_MUTED"
        echo -n "↑/↓ 选择  Enter 确认  Esc 取消"
        tui_reset

        local key
        key=$(tui_read_key 2>/dev/null) || continue

        case "$key" in
        UP | k)
            ((selected > 0)) && ((selected--))
            ;;
        DOWN | j)
            ((selected < ${#options[@]} - 1)) && ((selected++))
            ;;
        ENTER)
            # shellcheck disable=SC2034  # used in tui_manager.sh:461 via source
            TUI_PROMPT_INDEX="$selected"
            # shellcheck disable=SC2034  # used in 10+ controller files via source
            REPLY_INPUT="${options[$selected]}"
            return 0
            ;;
        q | ESC)
            return 1
            ;;
        esac
    done
}

# ============================================================
# 状态栏组件
# ============================================================

# 绘制状态栏
tui_statusbar_draw() {
    local row="${1:-0}"
    local left="${2:-}"
    local right="${3:-}"
    local color="${4:-${TUI_COLOR_ACCENT:-40}}"
    local cols="$(_tui_normalize_dimension "${TUI_COLS:-80}" 80)"
    local available_left=$((cols - $(tui_display_width "$right")))
    ((available_left < 0)) && available_left=0
    left="$(tui_truncate_display "$left" "$available_left")"
    left="$(tui_pad_display "$left" "$available_left")"

    tui_move "$(_tui_clamp_row "$row")" 0
    tui_bg "$color"
    tui_fg 0 # 黑色文字

    printf '%s' "$left"
    printf '%s' "$(tui_truncate_display "$right" "$cols")"

    tui_reset
}

# ============================================================
# 键盘输入处理
# ============================================================

tui_menu_prefix_can_extend() {
    local prefix="$1" max_option="${2:-0}"
    [[ "$prefix" =~ ^[0-9]+$ && "$max_option" =~ ^[0-9]+$ ]] || return 1
    ((max_option >= prefix * 10))
}

# 读取按键
tui_read_key() {
    local key
    IFS= read -rsn1 key 2>/dev/null || return 1

    # 处理转义序列
    if [[ "$key" == $'\x1b' ]]; then
        read -rsn2 -t 0.1 key 2>/dev/null || key="ESC"
        case "$key" in
        '[A') key="UP" ;;
        '[B') key="DOWN" ;;
        '[C') key="RIGHT" ;;
        '[D') key="LEFT" ;;
        '[H') key="HOME" ;;
        '[F') key="END" ;;
        *) key="ESC" ;;
        esac
    elif [[ "$key" == "" ]]; then
        key="ENTER"
    elif [[ "$key" =~ ^[1-9]$ ]]; then
        local next_key max_option=0 total_items=0
        if declare -p TUI_MENU_ITEMS >/dev/null 2>&1; then
            total_items=${#TUI_MENU_ITEMS[@]}
            ((total_items > 1)) && max_option=$((total_items - 1))
        fi
        while tui_menu_prefix_can_extend "$key" "$max_option"; do
            IFS= read -rsn1 -t "${TUI_MENU_DIGIT_TIMEOUT:-0.35}" next_key 2>/dev/null || break
            [[ "$next_key" =~ ^[0-9]$ ]] || break
            key+="$next_key"
        done
    fi

    echo "$key"
}

# ============================================================
# 主循环
# ============================================================

tui_handle_interrupt() {
    tui_cleanup
    if declare -F msg_warn >/dev/null 2>&1; then
        printf '\n'
        msg_warn "操作被中断"
    fi
    exit 130
}

# 运行主循环
tui_run() {
    local draw_func="$1"
    local key_handler="$2"
    local mode="${3:-stdout}"

    # 设置退出trap：中断时显式退出，避免在脚本 trap 中 return 产生 shell 噪声。
    trap 'tui_handle_interrupt' INT TERM

    while [[ "${TUI_RUNNING:-false}" == "true" ]]; do
        # 检查终端大小变化
        tui_get_size

        # 重绘
        if [[ "${TUI_REDRAW:-false}" == "true" ]]; then
            tui_clear
            "$draw_func"
            TUI_REDRAW=false
        fi

        # 读取按键（非阻塞）
        local key
        key=$(tui_read_key 2>/dev/null) || {
            [[ "${TUI_RUNNING:-false}" == "true" ]] || break
            continue
        }

        if [[ -n "$key" ]]; then
            # 处理按键
            if [[ "$mode" == "state" ]]; then
                "$key_handler" "$key"
            else
                local result
                result=$("$key_handler" "$key")

                # 检查返回值
                if [[ -n "$result" ]]; then
                    echo "$result"
                    return 0
                fi
            fi

            TUI_REDRAW=true
        fi

        [[ "${TUI_RUNNING:-false}" == "true" ]] && sleep 0.05
    done
    trap - INT TERM
}

# ============================================================
# 辅助函数
# ============================================================

# 确认对话框
tui_confirm() {
    local message="$1"
    local default="${2:-n}"

    local width=$((${#message} + 10))
    [[ $width -gt 60 ]] && width=60

    local row=$(((TUI_LINES - 5) / 2))
    local col=$(((TUI_COLS - width) / 2))

    # 绘制对话框
    tui_draw_box "$row" "$col" "$width" 5 "确认"

    tui_draw_center $((row + 2)) "$message"

    local yes_col=$((col + width / 2 - 10))
    tui_move $((row + 3)) "$yes_col"

    if [[ "$default" == "y" ]]; then
        tui_reverse
        echo -n "[Y]是"
        tui_reset
        echo -n "  [N]否"
    else
        echo -n "[Y]是  "
        tui_reverse
        echo -n "[N]否"
        tui_reset
    fi

    # 等待输入
    while true; do
        local key
        key=$(tui_read_key)

        case "$key" in
        y | Y) return 0 ;;
        n | N) return 1 ;;
        ENTER)
            [[ "$default" == "y" ]] && return 0 || return 1
            ;;
        LEFT | RIGHT)
            if [[ "$default" == "y" ]]; then
                default="n"
            else
                default="y"
            fi
            tui_move $((row + 3)) "$yes_col"
            if [[ "$default" == "y" ]]; then
                tui_reverse
                echo -n "[Y]是"
                tui_reset
                echo -n "  [N]否"
            else
                echo -n "[Y]是  "
                tui_reverse
                echo -n "[N]否"
                tui_reset
            fi
            ;;
        esac
    done
}

# 消息对话框
tui_message() {
    local title="$1"
    local message="$2"

    local width=$((${#message} + 8))
    [[ $width -gt 70 ]] && width=70
    [[ $width -lt 40 ]] && width=40

    local row=$(((TUI_LINES - 5) / 2))
    local col=$(((TUI_COLS - width) / 2))

    tui_draw_box "$row" "$col" "$width" 5 "$title"
    tui_draw_center $((row + 2)) "$message"

    tui_move $((row + 4)) $((col + (width - 10) / 2))
    tui_reverse
    echo -n "[ 确定 ]"
    tui_reset

    while true; do
        local key
        key=$(tui_read_key)
        [[ "$key" == "ENTER" || "$key" == "q" || "$key" == "ESC" ]] && break
    done
}

# 加载动画
tui_loading() {
    local message="$1"
    local duration="${2:-3}"

    local spinner=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    local row=$((TUI_LINES / 2))
    local col=$(((TUI_COLS - ${#message} - 4) / 2))

    local i=0
    local end_time=$(($(date +%s) + duration))

    while (($(date +%s) < end_time)); do
        tui_move "$row" "$col"
        tui_fg "$TUI_COLOR_ACCENT"
        echo -n "${spinner[$((i % 10))]} "
        tui_reset
        echo -n "$message"

        ((i++))
        sleep 0.1
    done
}

# 导出函数
export -f tui_init tui_cleanup
export -f tui_draw_box tui_draw_text tui_draw_center tui_draw_hline tui_draw_fill
export -f tui_effective_locale tui_strip_ansi tui_char_display_width tui_display_width tui_truncate_display tui_pad_display
export -f tui_menu_create tui_menu_invalidate_state tui_menu_update_viewport tui_menu_draw tui_menu_handle_key
export -f tui_table_draw tui_progress_draw tui_input_draw tui_statusbar_draw
export -f tui_read_key tui_run
export -f tui_confirm tui_message tui_loading tui_prompt_input tui_prompt_select
