#!/bin/bash
# ui_modern.sh - 现代玻璃拟态风格 UI 组件
# 提供命令面板、玻璃拟态视觉效果、动画和图标系统

# ============================================================
# ANSI 颜色和样式代码
# ============================================================

# 基本颜色
readonly C_RESET='\033[0m'
readonly C_BOLD='\033[1m'
# shellcheck disable=SC2034  # Unused color variables - available for future use
readonly C_ITALIC='\033[3m'
readonly C_UNDERLINE='\033[4m'
readonly C_BLINK='\033[5m'
readonly C_REVERSE='\033[7m'
readonly C_HIDDEN='\033[8m'

# 前景色
# shellcheck disable=SC2034  # Unused color variables - available for future use
readonly C_BLACK='\033[30m'
readonly C_RED='\033[31m'
readonly C_GREEN='\033[32m'
readonly C_YELLOW='\033[33m'
readonly C_BLUE='\033[34m'
readonly C_MAGENTA='\033[35m'
readonly C_CYAN='\033[36m'
readonly C_WHITE='\033[37m'

# 亮前景色
readonly C_LBLACK='\033[90m'
readonly C_LRED='\033[91m'
readonly C_LGREEN='\033[92m'
readonly C_LYELLOW='\033[93m'
readonly C_LBLUE='\033[94m'
readonly C_LMAGENTA='\033[95m'
readonly C_LCYAN='\033[96m'
readonly C_LWHITE='\033[97m'

# 背景色
readonly C_BG_BLACK='\033[40m'
readonly C_BG_RED='\033[41m'
readonly C_BG_GREEN='\033[42m'
readonly C_BG_YELLOW='\033[43m'
readonly C_BG_BLUE='\033[44m'
readonly C_BG_MAGENTA='\033[45m'
readonly C_BG_CYAN='\033[46m'
readonly C_BG_WHITE='\033[47m'

# 玻璃拟态样式（半透明效果模拟）
readonly C_GLASS_BG='\033[48;5;235m'     # 深色半透明背景
readonly C_GLASS_FG='\033[38;5;250m'     # 浅色文字
readonly C_GLASS_ACCENT='\033[38;5;81m'  # 强调色（蓝绿色）
readonly C_GLASS_SUCCESS='\033[38;5;84m' # 成功色（绿色）
readonly C_GLASS_WARN='\033[38;5;220m'   # 警告色（黄色）
readonly C_GLASS_ERROR='\033[38;5;203m'  # 错误色（红色）

# ============================================================
# 图标系统 - Unicode 符号
# ============================================================

# 导航图标
readonly ICON_HOME='🏠'
readonly ICON_BACK='←'
readonly ICON_NEXT='→'
readonly ICON_UP='↑'
readonly ICON_DOWN='↓'
readonly ICON_MENU='☰'
readonly ICON_CLOSE='✕'
readonly ICON_REFRESH='↻'
readonly ICON_SEARCH='🔍'
readonly ICON_FILTER='🔽'

# 状态图标
readonly ICON_SUCCESS='✓'
readonly ICON_ERROR='✗'
readonly ICON_WARNING='⚠'
readonly ICON_INFO='ℹ'
readonly ICON_QUESTION='?'
readonly ICON_PENDING='⏳'
readonly ICON_RUNNING='▶'
readonly ICON_PAUSED='⏸'
readonly ICON_STOPPED='■'

# 用户/权限图标
readonly ICON_USER='👤'
readonly ICON_USERS='👥'
readonly ICON_ADMIN='👑'
readonly ICON_GUEST='😐'
readonly ICON_LOCK='🔒'
readonly ICON_UNLOCK='🔓'
readonly ICON_KEY='🔑'
readonly ICON_SHIELD='🛡'

# 文件/目录图标
# shellcheck disable=SC2034  # Unused icons - available for future use
readonly ICON_FILE='📄'
readonly ICON_FOLDER='📁'
readonly ICON_FOLDER_OPEN='📂'

readonly ICON_DRIVE='💾'
readonly ICON_DISK='💿'
readonly ICON_CLOUD='☁'
readonly ICON_ARCHIVE='📦'
readonly ICON_TRASH='🗑'

# 操作图标
readonly ICON_ADD='➕'
readonly ICON_REMOVE='➖'
readonly ICON_EDIT='✏'
readonly ICON_DELETE='🗑'
readonly ICON_COPY='📋'
readonly ICON_PASTE='📌'
readonly ICON_CUT='✂'
readonly ICON_SAVE='💾'
readonly ICON_DOWNLOAD='⬇'
readonly ICON_UPLOAD='⬆'
readonly ICON_SHARE='↗'
readonly ICON_PRINT='🖨'

# 系统图标
readonly ICON_SETTINGS='⚙'
readonly ICON_TOOLS='🛠'
readonly ICON_BUG='🐛'
readonly ICON_TERMINAL='💻'
readonly ICON_SERVER='🖥'
readonly ICON_NETWORK='🌐'
readonly ICON_WIFI='📶'
readonly ICON_BLUETOOTH='🔵'
readonly ICON_BATTERY='🔋'
readonly ICON_CLOCK='⏰'
readonly ICON_CALENDAR='📅'
readonly ICON_MAIL='✉'
readonly ICON_PHONE='📞'
readonly ICON_LOCATION='📍'

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
    
    printf '%b%*s%b\n' "$C_GLASS_FG" "$width" '' | tr ' ' "$char"
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
        sleep "${delay}ms"
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
        sleep "${delay}ms"
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
    printf '%*s' "$filled" '' | tr ' ' '█'
    printf '%*s' "$empty" '' | tr ' ' '░'
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

# 执行初始化
glass_init
