#!/bin/bash
# ui_menu_simple.sh - 简化版菜单系统 v3.0
# 提供清晰的3级菜单结构和简化的UI组件

set -uo pipefail

# ============================================================
# 简化颜色方案（5种颜色 + 重置）
# ============================================================
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_PRIMARY='\033[1;34m'    # 蓝色 - 主色调
C_SUCCESS='\033[1;32m'    # 绿色 - 成功
C_WARNING='\033[1;33m'    # 黄色 - 警告
C_ERROR='\033[1;31m'      # 红色 - 错误

# ============================================================
# 菜单状态管理
# ============================================================
declare -a MENU_HISTORY=()
declare -g MENU_CURRENT="主菜单"
declare -g MENU_WIDTH=60

# ============================================================
# 基础UI组件
# ============================================================

# 绘制标题头
draw_header() {
    local title="${1:-$MENU_CURRENT}"
    clear
    echo ""
    echo -e "${C_PRIMARY}╔══════════════════════════════════════════════════════════╗${C_RESET}"
    printf "${C_PRIMARY}║${C_RESET}  ${C_BOLD}%-54s${C_RESET}  ${C_PRIMARY}║${C_RESET}\n" "$title"
    echo -e "${C_PRIMARY}╚══════════════════════════════════════════════════════════╝${C_RESET}"
    echo ""
}

# 绘制分隔线
# shellcheck disable=SC2120
draw_line() {
    local width="${1:-$MENU_WIDTH}"
    local line=""
    for ((i=0; i<width; i++)); do
        line+="─"
    done
    echo -e "${C_DIM}${line}${C_RESET}"
}

# 显示面包屑导航
draw_breadcrumb() {
    echo -ne "  ${C_DIM}位置：${C_RESET}"
    
    if [[ ${#MENU_HISTORY[@]} -eq 0 ]]; then
        echo -e "${C_BOLD}主菜单${C_RESET}"
    else
        local path=""
        for item in "${MENU_HISTORY[@]}"; do
            path+="${C_DIM}${item}${C_RESET} / "
        done
        echo -e "${path}${C_BOLD}${MENU_CURRENT}${C_RESET}"
    fi
    echo ""
}

# 绘制菜单项（一级菜单）
draw_menu_item() {
    local num="$1"
    local label="$2"
    local desc="${3:-}"
    
    if [[ -n "$desc" ]]; then
        printf "  ${C_PRIMARY}[%2s]${C_RESET}  ${C_BOLD}%-20s${C_RESET}  ${C_DIM}%s${C_RESET}\n" "$num" "$label" "$desc"
    else
        printf "  ${C_PRIMARY}[%2s]${C_RESET}  ${C_BOLD}%s${C_RESET}\n" "$num" "$label"
    fi
}

# 绘制子菜单项（二级菜单）
draw_submenu_item() {
    local num="$1"
    local label="$2"
    printf "  ${C_PRIMARY}[%2s]${C_RESET}  ${C_BOLD}%s${C_RESET}  ${C_DIM}>${C_RESET}\n" "$num" "$label"
}

# 绘制返回选项
draw_back_option() {
    echo ""
    # shellcheck disable=SC2059
    printf "  ${C_DIM}[ 0]${C_RESET}  ${C_WARNING}↩  返回上级菜单${C_RESET}\n"
}

# 绘制退出选项
draw_exit_option() {
    echo ""
    # shellcheck disable=SC2059
    printf "  ${C_DIM}[99]${C_RESET}  ${C_ERROR}✕  退出程序${C_RESET}\n"
}

# 绘制提示符
draw_prompt() {
    echo ""
    echo -ne "  ${C_PRIMARY}❯${C_RESET} "
}

# ============================================================
# 消息显示函数
# ============================================================

show_success() {
    echo -e "  ${C_SUCCESS}✓${C_RESET} $1"
}

show_error() {
    echo -e "  ${C_ERROR}✗${C_RESET} $1" >&2
}

show_warning() {
    echo -e "  ${C_WARNING}⚠${C_RESET} $1"
}

show_info() {
    echo -e "  ${C_PRIMARY}ℹ${C_RESET} $1"
}

# ============================================================
# 菜单导航管理
# ============================================================

# 进入子菜单
enter_submenu() {
    local menu_name="$1"
    MENU_HISTORY+=("$MENU_CURRENT")
    MENU_CURRENT="$menu_name"
}

# 返回上级菜单
back_menu() {
    if [[ ${#MENU_HISTORY[@]} -gt 0 ]]; then
        MENU_CURRENT="${MENU_HISTORY[-1]}"
        unset 'MENU_HISTORY[-1]'
        return 0
    fi
    return 1
}

# 重置菜单状态
reset_menu() {
    MENU_HISTORY=()
    MENU_CURRENT="主菜单"
}

# 获取菜单深度
get_menu_depth() {
    echo $((${#MENU_HISTORY[@]} + 1))
}

# ============================================================
# 输入处理函数
# ============================================================

# 读取用户选择
read_choice() {
    draw_prompt
    read -r choice
    echo "$choice"
}

# 读取确认（y/n）
read_confirm() {
    local prompt="${1:-确认操作？}"
    echo -ne "  ${prompt} ${C_DIM}[y/N]${C_RESET} "
    read -r confirm
    [[ "$confirm" =~ ^[Yy]$ ]]
}

# 读取字符串输入
read_input() {
    local prompt="$1"
    local default="${2:-}"
    
    echo -ne "  ${prompt}"
    [[ -n "$default" ]] && echo -ne " ${C_DIM}[${default}]${C_RESET}"
    echo -ne ": "
    
    read -r input
    echo "${input:-$default}"
}

# 读取密码（隐藏输入）
read_password() {
    local prompt="${1:-请输入密码：}"
    echo -ne "  ${prompt}"
    read -rs password
    echo ""
    echo "$password"
}

# ============================================================
# 工具函数
# ============================================================

# 暂停等待用户按键
pause_continue() {
    echo ""
    echo -ne "  ${C_DIM}按 Enter 键继续...${C_RESET}"
    read -r
}

# 清屏
clear_screen() {
    clear
}

# 显示分隔区域
show_section() {
    local title="$1"
    echo ""
    # shellcheck disable=SC2119
    draw_line
    echo -e "  ${C_BOLD}${title}${C_RESET}"
    # shellcheck disable=SC2119
    draw_line
    echo ""
}

# 显示表格行（2列）
show_table_row() {
    local col1="$1"
    local col2="$2"
    printf "  ${C_DIM}│${C_RESET} %-18s ${C_DIM}│${C_RESET} %s\n" "$col1" "$col2"
}

# 显示表格行（3列）
show_table_row_3col() {
    local col1="$1"
    local col2="$2"
    local col3="$3"
    printf "  ${C_DIM}│${C_RESET} %-15s ${C_DIM}│${C_RESET} %-25s ${C_DIM}│${C_RESET} %s\n" "$col1" "$col2" "$col3"
}

# 显示表格头部（2列）
show_table_header() {
    local col1="$1"
    local col2="$2"
    # shellcheck disable=SC2059
    printf "  ${C_PRIMARY}┌────────────────────┬──────────────────────────────────────────┐${C_RESET}\n"
    printf "  ${C_PRIMARY}│${C_RESET} %-18s ${C_PRIMARY}│${C_RESET} %-40s ${C_PRIMARY}│${C_RESET}\n" "$col1" "$col2"
    # shellcheck disable=SC2059
    printf "  ${C_PRIMARY}├────────────────────┼──────────────────────────────────────────┤${C_RESET}\n"
}

# 显示表格头部（3列）
show_table_header_3col() {
    local col1="$1"
    local col2="$2"
    local col3="$3"
    # shellcheck disable=SC2059
    printf "  ${C_PRIMARY}┌─────────────────┬─────────────────────────┬────────────────────┐${C_RESET}\n"
    printf "  ${C_PRIMARY}│${C_RESET} %-15s ${C_PRIMARY}│${C_RESET} %-23s ${C_PRIMARY}│${C_RESET} %-18s ${C_PRIMARY}│${C_RESET}\n" "$col1" "$col2" "$col3"
    # shellcheck disable=SC2059
    printf "  ${C_PRIMARY}├─────────────────┼─────────────────────────┼────────────────────┤${C_RESET}\n"
}

# 显示表格尾部（2列）
show_table_footer() {
    # shellcheck disable=SC2059
    printf "  ${C_PRIMARY}└────────────────────┴──────────────────────────────────────────┘${C_RESET}\n"
}

# 显示表格尾部（3列）
show_table_footer_3col() {
    # shellcheck disable=SC2059
    printf "  ${C_PRIMARY}└─────────────────┴─────────────────────────┴────────────────────┘${C_RESET}\n"
}

# ============================================================
# 模块初始化
# ============================================================

# 初始化UI模块
init_ui_simple() {
    # 重置菜单状态
    reset_menu
    
    # 检查终端是否支持颜色
    if [[ -z "${TERM:-}" ]] || [[ "$TERM" == "dumb" ]] || [[ ! -t 1 ]]; then
        # 禁用颜色
        C_RESET=''
        C_BOLD=''
        C_DIM=''
        C_PRIMARY=''
        # shellcheck disable=SC2034
        C_SECONDARY=''
        C_SUCCESS=''
        C_WARNING=''
        C_ERROR=''
    fi
    
    return 0
}

# 执行初始化
init_ui_simple
