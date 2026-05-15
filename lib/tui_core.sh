#!/bin/bash
# tui_core.sh - 原生TUI框架 v1.0.0
# 提供全屏界面、键盘导航、实时更新功能
# 无需外部依赖，纯Bash实现

set -uo pipefail

# ============================================================
# TUI配置常量
# ============================================================

# 检测终端能力
tui_detect_terminal() {
    # 检查是否支持颜色
    if [[ -t 1 ]] && [[ -n "$TERM" ]]; then
        TUI_HAS_COLORS=true
        TUI_COLORS=$(tput colors 2>/dev/null || echo "8")
    else
        TUI_HAS_COLORS=false
        TUI_COLORS=0
    fi
    
    # 检查终端尺寸
    TUI_COLS=$(tput cols 2>/dev/null || echo "80")
    TUI_LINES=$(tput lines 2>/dev/null || echo "24")
    
    # 检查Unicode支持
    if [[ "$LANG" =~ UTF-8 ]] || [[ "$LC_ALL" =~ UTF-8 ]]; then
        TUI_HAS_UTF8=true
    else
        TUI_HAS_UTF8=false
    fi
}

# 初始化TUI
tui_init() {
    tui_detect_terminal
    
    # 保存原始终端设置
    TUI_OLD_STTY=$(stty -g 2>/dev/null)
    
    # 设置原始模式
    stty -echo -icanon time 0 min 0 2>/dev/null || true
    
    # 隐藏光标
    tput civis 2>/dev/null || true
    
    # 开启备用屏幕缓冲区
    tput smcup 2>/dev/null || true
    
    # 清屏
    tput clear 2>/dev/null || clear
    
    # 定义颜色（256色 - 现代暗色主题）
    if [[ "$TUI_HAS_COLORS" == "true" ]]; then
        TUI_COLOR_BG=234       # 深灰黑背景 (#1a1a2e)
        TUI_COLOR_FG=252       # 柔和白前景
        TUI_COLOR_ACCENT=39    # 亮蓝 #0088ff
        TUI_COLOR_ACCENT2=51   # 青色高亮
        TUI_COLOR_SUCCESS=48   # 翠绿
        TUI_COLOR_WARNING=221  # 金色
        TUI_COLOR_ERROR=203    # 柔和红
        TUI_COLOR_MUTED=243    # 中灰
        TUI_COLOR_HIGHLIGHT=45 # 电蓝
        TUI_COLOR_SURFACE=236  # 卡片背景
        TUI_COLOR_BORDER=239   # 边框灰
    fi
    
    TUI_INITIALIZED=true
    TUI_RUNNING=true
    TUI_REDRAW=true
    
    # 当前菜单状态
    TUI_MENU_INDEX=0
    TUI_MENU_ITEMS=()
    TUI_MENU_TITLE=""
    TUI_MENU_FOOTER=""
    
    # 组件注册表
    declare -gA TUI_COMPONENTS=()
    declare -ga TUI_COMPONENT_ORDER=()
    
    # 事件处理
    TUI_ON_KEY=""
    TUI_ON_RESIZE=""
    TUI_ON_TICK=""
    TUI_TICK_INTERVAL=1
    
    return 0
}

# 清理TUI
tui_cleanup() {
    [[ "$TUI_INITIALIZED" != "true" ]] && return 0
    
    # 恢复光标
    tput cnorm 2>/dev/null || true
    
    # 关闭备用屏幕缓冲区
    tput rmcup 2>/dev/null || true
    
    # 恢复终端设置
    [[ -n "$TUI_OLD_STTY" ]] && stty "$TUI_OLD_STTY" 2>/dev/null || true
    
    TUI_INITIALIZED=false
    TUI_RUNNING=false
}

# ============================================================
# 颜色和样式函数
# ============================================================

# 设置前景色
tui_fg() {
    local color="$1"
    tput setaf "$color" 2>/dev/null || true
}

# 设置背景色
tui_bg() {
    local color="$1"
    tput setab "$color" 2>/dev/null || true
}

# 重置样式
tui_reset() {
    tput sgr0 2>/dev/null || true
}

# 粗体
tui_bold() {
    tput bold 2>/dev/null || true
}

# 下划线
tui_underline() {
    tput smul 2>/dev/null || true
}

# 反色
tui_reverse() {
    tput rev 2>/dev/null || true
}

# ============================================================
# 光标和屏幕函数
# ============================================================

# 移动光标
tui_move() {
    local row="$1"
    local col="$2"
    tput cup "$row" "$col" 2>/dev/null || true
}

# 清屏
tui_clear() {
    tput clear 2>/dev/null || clear
}

# 清除到行尾
tui_clear_eol() {
    tput el 2>/dev/null || true
}

# 清除整行
tui_clear_line() {
    tput el1 2>/dev/null || true
    tput el 2>/dev/null || true
}

# 获取屏幕尺寸
tui_get_size() {
    TUI_COLS=$(tput cols 2>/dev/null || echo "80")
    TUI_LINES=$(tput lines 2>/dev/null || echo "24")
}

# ============================================================
# 绘制函数
# ============================================================

# 绘制边框
tui_draw_box() {
    local row="$1"
    local col="$2"
    local width="$3"
    local height="$4"
    local title="${5:-}"
    
    local h_line v_line tl tr bl br
    if [[ "$TUI_HAS_UTF8" == "true" ]]; then
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
    
    # 顶部边框
    tui_move "$row" "$col"
    echo -n "$tl"
    for ((i = 0; i < width - 2; i++)); do echo -n "$h_line"; done
    echo -n "$tr"
    
    # 标题
    if [[ -n "$title" ]]; then
        local title_len=${#title}
        local title_col=$(( col + (width - title_len) / 2 ))
        tui_move "$row" "$title_col"
        tui_bold
        echo -n " $title "
        tui_reset
    fi
    
    # 侧边框
    for ((i = 1; i < height - 1; i++)); do
        tui_move $((row + i)) "$col"
        echo -n "$v_line"
        tui_move $((row + i)) $((col + width - 1))
        echo -n "$v_line"
    done
    
    # 底部边框
    tui_move $((row + height - 1)) "$col"
    echo -n "$bl"
    for ((i = 0; i < width - 2; i++)); do echo -n "$h_line"; done
    echo -n "$br"
}

# 绘制文本
tui_draw_text() {
    local row="$1"
    local col="$2"
    local text="$3"
    local color="${4:-$TUI_COLOR_FG}"
    
    tui_move "$row" "$col"
    tui_fg "$color"
    echo -n "$text"
    tui_reset
}

# 绘制居中文本
tui_draw_center() {
    local row="$1"
    local text="$2"
    local color="${3:-$TUI_COLOR_FG}"
    
    local len=${#text}
    local col=$(( (TUI_COLS - len) / 2 ))
    
    tui_draw_text "$row" "$col" "$text" "$color"
}

# 绘制水平线
tui_draw_hline() {
    local row="$1"
    local col="$2"
    local width="$3"
    local char="${4:─}"
    
    tui_move "$row" "$col"
    for ((i = 0; i < width; i++)); do
        echo -n "$char"
    done
}

# 绘制填充背景
tui_draw_fill() {
    local row="$1"
    local col="$2"
    local width="$3"
    local height="$4"
    local bg_color="$5"
    
    tui_bg "$bg_color"
    for ((i = 0; i < height; i++)); do
        tui_move $((row + i)) "$col"
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
    local title="$1"
    shift
    local items=("$@")
    
    TUI_MENU_TITLE="$title"
    TUI_MENU_ITEMS=("${items[@]}")
    TUI_MENU_INDEX=0
    TUI_MENU_SCROLL_OFFSET=0
    TUI_MENU_VISIBLE_ITEMS=${#items[@]}
}

# 绘制菜单
tui_menu_draw() {
    local start_row="$1"
    local start_col="$2"
    local width="$3"
    local total_items=${#TUI_MENU_ITEMS[@]}
    local max_visible=$(( TUI_LINES - start_row - 5 ))
    (( max_visible < 1 )) && max_visible=1

    if (( total_items < max_visible )); then
        TUI_MENU_VISIBLE_ITEMS=$total_items
    else
        TUI_MENU_VISIBLE_ITEMS=$max_visible
    fi

    local max_offset=$(( total_items - TUI_MENU_VISIBLE_ITEMS ))
    (( max_offset < 0 )) && max_offset=0
    (( TUI_MENU_SCROLL_OFFSET > max_offset )) && TUI_MENU_SCROLL_OFFSET=$max_offset

    local menu_height=$(( TUI_MENU_VISIBLE_ITEMS + 4 ))
    
    # 绘制边框
    tui_draw_box "$start_row" "$start_col" "$width" "$menu_height" "$TUI_MENU_TITLE"
    
    # 绘制菜单项
    local item_row=$((start_row + 2))
    local end_index=$(( TUI_MENU_SCROLL_OFFSET + TUI_MENU_VISIBLE_ITEMS ))
    (( end_index > total_items )) && end_index=$total_items
    for ((i = TUI_MENU_SCROLL_OFFSET; i < end_index; i++)); do
        local item="${TUI_MENU_ITEMS[$i]}"
        local display="  $item  "
        
        tui_move "$item_row" $((start_col + 2))
        
        if [[ $i -eq $TUI_MENU_INDEX ]]; then
            tui_reverse
            tui_fg "$TUI_COLOR_HIGHLIGHT"
        else
            tui_fg "$TUI_COLOR_FG"
        fi
        
        printf "%-${width}s" "$display"
        tui_reset
        
        ((item_row++))
    done
    
    # 绘制底部提示
    tui_move $((start_row + menu_height)) "$((start_col + 2))"
    tui_fg "$TUI_COLOR_MUTED"
    if (( total_items > TUI_MENU_VISIBLE_ITEMS )); then
        printf "↑/↓ 导航  Enter 选择  q 退出  [%d-%d/%d]" \
            $((TUI_MENU_SCROLL_OFFSET + 1)) "$end_index" "$total_items"
    else
        echo "↑/↓ 导航  Enter 选择  q 退出"
    fi
    tui_reset
}

# 处理菜单键盘输入
tui_menu_handle_key() {
    local key="$1"
    local visible_items="${TUI_MENU_VISIBLE_ITEMS:-${#TUI_MENU_ITEMS[@]}}"
    
    case "$key" in
        UP|k)
            ((TUI_MENU_INDEX > 0)) && ((TUI_MENU_INDEX--))
            (( TUI_MENU_INDEX < TUI_MENU_SCROLL_OFFSET )) && TUI_MENU_SCROLL_OFFSET=$TUI_MENU_INDEX
            TUI_REDRAW=true
            ;;
        DOWN|j)
            ((TUI_MENU_INDEX < ${#TUI_MENU_ITEMS[@]} - 1)) && ((TUI_MENU_INDEX++))
            if (( TUI_MENU_INDEX >= TUI_MENU_SCROLL_OFFSET + visible_items )); then
                TUI_MENU_SCROLL_OFFSET=$((TUI_MENU_INDEX - visible_items + 1))
            fi
            TUI_REDRAW=true
            ;;
        HOME)
            TUI_MENU_INDEX=0
            TUI_MENU_SCROLL_OFFSET=0
            TUI_REDRAW=true
            ;;
        END)
            TUI_MENU_INDEX=$(( ${#TUI_MENU_ITEMS[@]} - 1 ))
            TUI_MENU_SCROLL_OFFSET=$(( TUI_MENU_INDEX - visible_items + 1 ))
            (( TUI_MENU_SCROLL_OFFSET < 0 )) && TUI_MENU_SCROLL_OFFSET=0
            TUI_REDRAW=true
            ;;
        ENTER)
            echo "$TUI_MENU_INDEX"
            return 0
            ;;
        q|ESC)
            echo "-1"
            return 0
            ;;
    esac
    
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
        
        if (( (i + 1) % cols == 0 )); then
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
        if [[ "$TUI_HAS_UTF8" == "true" ]]; then
            echo -n "█"
        else
            echo -n "#"
        fi
    done
    
    tui_fg "$TUI_COLOR_MUTED"
    for ((i = 0; i < empty; i++)); do
        if [[ "$TUI_HAS_UTF8" == "true" ]]; then
            echo -n "░"
        else
            echo -n "-"
        fi
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
    tput cnorm 2>/dev/null || true
}

tui_prompt_input() {
    local title="$1"
    local label="$2"
    local default_value="${3:-}"
    local value="$default_value"

    while true; do
        local width=40
        local row=$(( (TUI_LINES - 7) / 2 ))
        local col=$(( (TUI_COLS - (width + 4)) / 2 ))

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
            q|ESC)
                return 1
                ;;
            BACKSPACE|$'\x7f'|$'\b')
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

    (( ${#options[@]} == 0 )) && return 1

    local selected="$default_index"
    (( selected < 0 )) && selected=0
    (( selected >= ${#options[@]} )) && selected=0

    while true; do
        local width=50
        local height=$(( ${#options[@]} + 6 ))
        local row=$(( (TUI_LINES - height) / 2 ))
        local col=$(( (TUI_COLS - width) / 2 ))

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
            if (( i == selected )); then
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
            UP|k)
                (( selected > 0 )) && ((selected--))
                ;;
            DOWN|j)
                (( selected < ${#options[@]} - 1 )) && ((selected++))
                ;;
            ENTER)
                TUI_PROMPT_INDEX="$selected"
                REPLY_INPUT="${options[$selected]}"
                return 0
                ;;
            q|ESC)
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
    local row="$1"
    local left="$2"
    local right="$3"
    local color="${4:-$TUI_COLOR_ACCENT}"
    
    tui_move "$row" 0
    tui_bg "$color"
    tui_fg 0  # 黑色文字
    
    printf "%-$((TUI_COLS - ${#right}))s" "$left"
    echo -n "$right"
    
    tui_reset
}

# ============================================================
# 键盘输入处理
# ============================================================

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
    
    # 设置退出trap：中断时显式退出，避免在脚本 trap 中 return 产生 shell 噪声。
    trap 'tui_handle_interrupt' INT TERM
    trap 'tui_cleanup' EXIT
    
    while $TUI_RUNNING; do
        # 检查终端大小变化
        tui_get_size
        
        # 重绘
        if $TUI_REDRAW; then
            tui_clear
            "$draw_func"
            TUI_REDRAW=false
        fi
        
        # 读取按键（非阻塞）
        local key
        key=$(tui_read_key 2>/dev/null) || continue
        
        if [[ -n "$key" ]]; then
            # 处理按键
            local result
            result=$("$key_handler" "$key")
            
            # 检查返回值
            if [[ -n "$result" ]]; then
                echo "$result"
                return 0
            fi
            
            TUI_REDRAW=true
        fi
        
        sleep 0.05
    done
}

# ============================================================
# 辅助函数
# ============================================================

# 确认对话框
tui_confirm() {
    local message="$1"
    local default="${2:-n}"
    
    local width=$(( ${#message} + 10 ))
    [[ $width -gt 60 ]] && width=60
    
    local row=$(( (TUI_LINES - 5) / 2 ))
    local col=$(( (TUI_COLS - width) / 2 ))
    
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
            y|Y) return 0 ;;
            n|N) return 1 ;;
            ENTER)
                [[ "$default" == "y" ]] && return 0 || return 1
                ;;
            LEFT|RIGHT)
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
    
    local width=$(( ${#message} + 8 ))
    [[ $width -gt 70 ]] && width=70
    [[ $width -lt 40 ]] && width=40
    
    local row=$(( (TUI_LINES - 5) / 2 ))
    local col=$(( (TUI_COLS - width) / 2 ))
    
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
    local col=$(( (TUI_COLS - ${#message} - 4) / 2 ))
    
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
export -f tui_menu_create tui_menu_draw tui_menu_handle_key
export -f tui_table_draw tui_progress_draw tui_input_draw tui_statusbar_draw
export -f tui_read_key tui_run
export -f tui_confirm tui_message tui_loading tui_prompt_input tui_prompt_select
