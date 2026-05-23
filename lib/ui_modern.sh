#!/bin/bash
# shellcheck disable=SC2034
# ui_modern.sh - 现代玻璃拟态风格 UI 组件
# 提供命令面板、玻璃拟态视觉效果、动画和图标系统
# 说明：本文件包含可复用的调色板与图标目录，部分变量为对外暴露的 UI 资源。

# ============================================================
# ANSI 颜色和样式代码
# ============================================================

# 基本颜色
C_RESET='\033[0m'
C_BOLD='\033[1m'
# shellcheck disable=SC2034  # Unused color variables - available for future use
C_ITALIC='\033[3m'
C_UNDERLINE='\033[4m'
C_BLINK='\033[5m'
C_REVERSE='\033[7m'
C_HIDDEN='\033[8m'

# 前景色
# shellcheck disable=SC2034  # Unused color variables - available for future use
C_BLACK='\033[30m'
C_RED='\033[31m'
C_GREEN='\033[32m'
C_TEXT_WARN='\033[32m'
C_TEXT_INFO='\033[32m'
C_TEXT_ACCENT='\033[32m'
C_TEXT_SUBTLE='\033[32m'
C_WHITE='\033[37m'

# 亮前景色
C_LBLACK='\033[90m'
C_LRED='\033[91m'
C_LGREEN='\033[92m'
C_LYELLOW='\033[93m'
C_LBLUE='\033[94m'
C_LMAGENTA='\033[95m'
C_LCYAN='\033[96m'
C_LWHITE='\033[97m'

# 背景色
C_BG_BLACK='\033[40m'
C_BG_RED='\033[41m'
C_BG_GREEN='\033[42m'
C_BG_YELLOW='\033[43m'
C_BG_BLUE='\033[44m'
C_BG_MAGENTA='\033[45m'
C_BG_CYAN='\033[46m'
C_BG_WHITE='\033[47m'

# 玻璃拟态样式（半透明效果模拟）
C_GLASS_BG='\033[48;5;235m'     # 深色半透明背景
C_GLASS_FG='\033[38;5;250m'     # 浅色文字
C_GLASS_ACCENT='\033[38;5;40m'  # 强调色（绿色）
C_GLASS_SUCCESS='\033[38;5;84m' # 成功色（绿色）
C_GLASS_WARN='\033[38;5;40m'    # 警告色（绿色主题）
C_GLASS_ERROR='\033[38;5;203m'  # 错误色（红色）

# ============================================================
# 图标系统 - Unicode 符号
# ============================================================

# 导航图标
ICON_HOME='🏠'
ICON_BACK='←'
ICON_NEXT='→'
ICON_UP='↑'
ICON_DOWN='↓'
ICON_MENU='☰'
ICON_CLOSE='✕'
ICON_REFRESH='↻'
ICON_SEARCH='🔍'
ICON_FILTER='🔽'

# 状态图标
ICON_SUCCESS='✓'
ICON_ERROR='✗'
ICON_WARNING='⚠'
ICON_INFO='ℹ'
ICON_QUESTION='?'
ICON_PENDING='⏳'
ICON_RUNNING='▶'
ICON_PAUSED='⏸'
ICON_STOPPED='■'

# 用户/权限图标
ICON_USER='👤'
ICON_USERS='👥'
ICON_ADMIN='👑'
ICON_GUEST='😐'
ICON_LOCK='🔒'
ICON_UNLOCK='🔓'
ICON_KEY='🔑'
ICON_SHIELD='🛡'

# 文件/目录图标
# shellcheck disable=SC2034  # Unused icons - available for future use
ICON_FILE='📄'
ICON_FOLDER='📁'
ICON_FOLDER_OPEN='📂'

ICON_DRIVE='💾'
ICON_DISK='💿'
ICON_CLOUD='☁'
ICON_ARCHIVE='📦'
ICON_TRASH='🗑'

# 操作图标
ICON_ADD='➕'
ICON_REMOVE='➖'
ICON_EDIT='✏'
ICON_DELETE='🗑'
ICON_COPY='📋'
ICON_PASTE='📌'
ICON_CUT='✂'
ICON_SAVE='💾'
ICON_DOWNLOAD='⬇'
ICON_UPLOAD='⬆'
ICON_SHARE='↗'
ICON_PRINT='🖨'

# 系统图标
ICON_SETTINGS='⚙'
ICON_TOOLS='🛠'
ICON_BUG='🐛'
ICON_TERMINAL='💻'
ICON_SERVER='🖥'
ICON_NETWORK='🌐'
ICON_WIFI='📶'
ICON_BLUETOOTH='🔵'
ICON_BATTERY='🔋'
ICON_CLOCK='⏰'
ICON_CALENDAR='📅'
ICON_MAIL='✉'
ICON_PHONE='📞'
ICON_LOCATION='📍'

# ============================================================
# 玻璃拟态视觉效果函数
# ============================================================

# 清除屏幕并设置玻璃拟态背景
glass_clear() {
    # 清除屏幕
    printf '\033[2J\033[H'
    
    # 设置玻璃拟态背景（深色半透明效果）
    printf '%b' "$C_GLASS_BG"
}

# 重置样式
glass_reset() {
    printf '%b' "$C_RESET"
}

# 绘制玻璃拟态面板
# 用法: glass_panel <title> [width] [height]
glass_panel() {
    local title="$1"
    local width="${2:-60}"
    local height="${3:-10}"
    
    # 上边框
    printf '%b┌' "$C_GLASS_ACCENT"
    printf '%*s' $((width - 2)) '' | tr ' ' '─'
    printf '┐%b\n' "$C_RESET"
    
    # 标题行
    printf '%b│%b %b%s%b %*s%b│%b\n' \
        "$C_GLASS_ACCENT" "$C_RESET" \
        "$C_BOLD" "$title" "$C_RESET" \
        $((width - ${#title} - 4)) '' \
        "$C_GLASS_ACCENT" "$C_RESET"
    
    # 分隔线
    printf '%b├' "$C_GLASS_ACCENT"
    printf '%*s' $((width - 2)) '' | tr ' ' '─'
    printf '┤%b\n' "$C_RESET"
    
    # 内容区域（空行）
    local i
    for ((i = 0; i < height - 4; i++)); do
        printf '%b│%b%*s%b│%b\n' \
            "$C_GLASS_ACCENT" "$C_RESET" \
            $((width - 2)) '' \
            "$C_GLASS_ACCENT" "$C_RESET"
    done
    
    # 下边框
    printf '%b└' "$C_GLASS_ACCENT"
    printf '%*s' $((width - 2)) '' | tr ' ' '─'
    printf '┘%b\n' "$C_RESET"
}

# 绘制玻璃拟态按钮
# 用法: glass_button <text> [type] [width]
# type: primary, secondary, success, warning, danger
glass_button() {
    local text="$1"
    local type="${2:-primary}"
    local width="${3:-20}"
    
    # 根据类型选择颜色
    local color="$C_GLASS_ACCENT"
    case "$type" in
        primary) color="$C_GLASS_ACCENT" ;;
        secondary) color="$C_GLASS_FG" ;;
        success) color="$C_GLASS_SUCCESS" ;;
        warning) color="$C_GLASS_WARN" ;;
        danger) color="$C_GLASS_ERROR" ;;
    esac
    
    # 计算内边距
    local text_len=${#text}
    local padding=$(( (width - text_len - 2) / 2 ))
    local padding_right=$(( width - text_len - 2 - padding ))
    
    # 绘制按钮
    printf '%b╭' "$color"
    printf '%*s' $((width - 2)) '' | tr ' ' '─'
    printf '╮%b\n' "$C_RESET"
    
    printf '%b│%b%*s%b%s%b%*s%b│%b\n' \
        "$color" "$C_RESET" \
        $padding '' \
        "$C_BOLD" "$text" "$C_RESET" \
        $padding_right '' \
        "$color" "$C_RESET"
    
    printf '%b╰' "$color"
    printf '%*s' $((width - 2)) '' | tr ' ' '─'
    printf '╯%b\n' "$C_RESET"
}

# 绘制玻璃拟态输入框
# 用法: glass_input <label> [width]
glass_input() {
    local label="$1"
    local width="${2:-50}"
    
    printf '%b%s:%b\n' "$C_GLASS_FG" "$label" "$C_RESET"
    printf '%b┌' "$C_GLASS_ACCENT"
    printf '%*s' $((width - 2)) '' | tr ' ' '─'
    printf '┐%b\n' "$C_RESET"
    printf '%b│%b%*s%b│%b\n' \
        "$C_GLASS_ACCENT" "$C_RESET" \
        $((width - 2)) '' \
        "$C_GLASS_ACCENT" "$C_RESET"
    printf '%b└' "$C_GLASS_ACCENT"
    printf '%*s' $((width - 2)) '' | tr ' ' '─'
    printf '┘%b\n' "$C_RESET"
}

# 绘制分隔线
# 用法: glass_separator [width] [style]
# style: single, double, dashed
glass_separator() {
    local width="${1:-60}"
    local style="${2:-single}"
    
    local char='─'
    case "$style" in
        single) char='─' ;;
        double) char='═' ;;
        dashed) char='╌' ;;
    esac
    
    printf '%b%*s%b\n' "$C_GLASS_FG" "$width" '' "$C_RESET" | tr ' ' "$char"
}

# ============================================================
# 动画效果函数
# ============================================================

# 淡入效果（通过逐渐增加亮度模拟）
# 用法: glass_fade_in [duration_ms]
glass_fade_in() {
    local duration="${1:-500}"
    local steps=10
    local delay=$((duration / steps))
    
    # 清屏
    printf '\033[2J\033[H'
    
    # 模拟淡入（通过延迟显示）
    local i
    for ((i = 0; i < steps; i++)); do
        printf '\033[2J\033[H'
        printf '%bLoading...%b\n' "$C_DIM" "$C_RESET"
        sleep "$(printf '%.3f' "$(echo "${delay} / 1000" | bc -l 2>/dev/null || echo "0.1")")"
    done
    
    printf '\033[2J\033[H'
}

# 打字机效果
# 用法: glass_typewriter <text> [delay_ms]
glass_typewriter() {
    local text="$1"
    local delay="${2:-50}"
    
    local i
    for ((i = 0; i < ${#text}; i++)); do
        printf '%s' "${text:$i:1}"
        sleep "$(printf '%.3f' "$(echo "${delay} / 1000" | bc -l 2>/dev/null || echo "0.1")")"
    done
    printf '\n'
}

# 进度条动画
# 用法: glass_progress <current> <total> [width]
glass_progress() {
    local current="$1"
    local total="$2"
    local width="${3:-40}"
    
    local percentage=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))
    
    printf '%b[' "$C_GLASS_ACCENT"
    printf '%*s' "$filled" '' | tr ' ' '#'
    printf '%*s' "$empty" '' | tr ' ' '-'
    printf '%b]%b %3d%%%b\n' "$C_GLASS_ACCENT" "$C_RESET" "$percentage" "$C_RESET"
}

# ============================================================
# 初始化
# ============================================================

# 检测终端支持
glass_detect_terminal() {
    local term="${TERM:-unknown}"
    local colors=8
    
    # 检测颜色支持
    if [[ -n "${COLORTERM:-}" ]]; then
        case "$COLORTERM" in
            truecolor|24bit) colors=16777216 ;;
            *) colors=256 ;;
        esac
    elif [[ "$term" == *"256color"* ]]; then
        colors=256
    fi
    
    # 检测 Unicode 支持
    local unicode_support=false
    if [[ "${LANG:-}" == *"UTF"* ]] || [[ "${LC_ALL:-}" == *"UTF"* ]]; then
        unicode_support=true
    fi
    
    echo "{
  \"terminal\": \"$term\",
  \"colors\": $colors,
  \"unicode\": $unicode_support
}"
}

# 模块初始化
glass_init() {
    # 清屏并设置背景
    printf '\033[2J\033[H'
    
    # 显示初始化信息
    printf '%b%b %s%b\n' "$C_DIM" "$ICON_INFO" "Initializing glassmorphism UI..." "$C_RESET"
}

# 模块已加载（不自动执行清屏和初始化输出）
