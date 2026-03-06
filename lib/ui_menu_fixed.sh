#!/bin/bash
# ui_menu_fixed.sh - 修复版现代化菜单系统 v2.0
# 提供清晰的层级结构和简化的颜色方案

set -uo pipefail

# ============================================================
# 简化颜色方案（仅使用5种颜色）
# ============================================================
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_PRIMARY='\033[1;34m'    # 蓝色 - 主色调
C_SECONDARY='\033[1;36m'  # 青色 - 次要
C_SUCCESS='\033[1;32m'    # 绿色 - 成功
C_WARNING='\033[1;33m'    # 黄色 - 警告
C_ERROR='\033[1;31m'      # 红色 - 错误

# ============================================================
# 图标（仅使用ASCII字符，确保兼容性）
# ============================================================
# shellcheck disable=SC2034
readonly ICON_MENU="[*]"
# shellcheck disable=SC2034
readonly ICON_SUB=">"
# shellcheck disable=SC2034
readonly ICON_BACK="<"
# shellcheck disable=SC2034
readonly ICON_SUCCESS="[OK]"
# shellcheck disable=SC2034
readonly ICON_ERROR="[ERR]"
# shellcheck disable=SC2034
readonly ICON_WARNING="[!]"

# ============================================================
# 菜单状态
# ============================================================
MENU_HISTORY=()
MENU_CURRENT="主菜单"

# ============================================================
# UI 组件函数
# ============================================================

# 清屏并显示标题
draw_header() {
    local title="$1"
    clear
    echo ""
    echo -e "${C_PRIMARY}════════════════════════════════════════════════${C_RESET}"
    echo -e "${C_BOLD}  ${title}${C_RESET}"
    echo -e "${C_PRIMARY}════════════════════════════════════════════════${C_RESET}"
    echo ""
}

# 绘制分隔线
draw_line() {
    echo -e "${C_DIM}──────────────────────────────────────────────${C_RESET}"
}

# 显示面包屑导航
draw_breadcrumb() {
    if [[ ${#MENU_HISTORY[@]} -eq 0 ]]; then
        echo -e "${C_DIM}主菜单${C_RESET}"
    else
        local path=""
        for item in "${MENU_HISTORY[@]}"; do
            path+="${C_DIM}${item}${C_RESET} / "
        done
        echo -e "${path}${C_BOLD}${MENU_CURRENT}${C_RESET}"
    fi
    echo ""
}

# 绘制菜单项
draw_menu_item() {
    local num="$1"
    local label="$2"
    printf '  %s[%2s]%s  %s\n' "$C_PRIMARY" "$num" "$C_RESET" "$label"
}

# 绘制子菜单项
draw_submenu_item() {
    local num="$1"
    local label="$2"
    printf '  %s[%2s]%s  %s %s>%s\n' "$C_SECONDARY" "$num" "$C_RESET" "$label" "$C_DIM" "$C_RESET"
}

# 绘制返回选项
draw_back_option() {
    echo ""
    printf '  %s[ 0]%s  %s返回上级菜单%s\n' "$C_DIM" "$C_RESET" "$C_WARNING" "$C_RESET"
}

# 绘制退出选项  
draw_exit_option() {
    echo ""
    printf '  %s[99]%s  %s退出程序%s\n' "$C_DIM" "$C_RESET" "$C_ERROR" "$C_RESET"
}

# 绘制提示符
draw_prompt() {
    echo ""
    echo -ne "  ${C_SECONDARY}»${C_RESET} "
}

# 显示成功消息
show_success() {
    echo -e "  ${C_SUCCESS}✓${C_RESET} $1"
}

# 显示错误消息
show_error() {
    msg_err "$1"
}

# 显示警告消息
show_warning() {
    echo -e "  ${C_WARNING}⚠${C_RESET} $1"
}

# 显示信息消息
show_info() {
    echo -e "  ${C_PRIMARY}ℹ${C_RESET} $1"
}

# ============================================================
# 菜单导航函数
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

# ============================================================
# 工具函数
# ============================================================

# 暂停等待用户按键
pause_continue() {
    echo ""
    echo -ne "  ${C_DIM}按 Enter 键继续...${C_RESET}"
    read -r
}

# 清屏并等待
clear_and_pause() {
    sleep 1
    clear
}

# 显示分隔区域
show_section() {
    local title="$1"
    echo ""
    draw_line
    echo -e "  ${C_BOLD}${title}${C_RESET}"
    draw_line
    echo ""
}

# 显示表格行
show_table_row() {
    local col1="$1"
    local col2="$2"
    local col3="${3:-}"
    
    if [[ -n "$col3" ]]; then
        printf '  %s│%s %-20s %s│%s %-30s %s│%s %s\n' "$C_DIM" "$C_RESET" "$col1" "$C_DIM" "$C_RESET" "$col2" "$C_DIM" "$C_RESET" "$col3"
    else
        printf '  %s│%s %-20s %s│%s %s\n' "$C_DIM" "$C_RESET" "$col1" "$C_DIM" "$C_RESET" "$col2"
    fi
}

# 显示表格头部
show_table_header() {
    local col1="$1"
    local col2="$2"
    local col3="${3:-}"
    
    if [[ -n "$col3" ]]; then
        printf '  %s┌──────────────────────┬──────────────────────────────┬────────────┐%s\n' "$C_PRIMARY" "$C_RESET"
        printf '  %s│%s %-20s %s│%s %-28s %s│%s %-10s %s│%s\n' "$C_PRIMARY" "$C_RESET" "$col1" "$C_PRIMARY" "$C_RESET" "$col2" "$C_PRIMARY" "$C_RESET" "$col3" "$C_PRIMARY" "$C_RESET"
        printf '  %s├──────────────────────┼──────────────────────────────┼────────────┤%s\n' "$C_PRIMARY" "$C_RESET"
    else
        printf '  %s┌──────────────────────┬──────────────────────────────────────────┐%s\n' "$C_PRIMARY" "$C_RESET"
        printf "  ${C_PRIMARY}│${C_RESET} %-20s ${C_PRIMARY}│${C_RESET} %-40s ${C_PRIMARY}│${C_RESET}\n" "$col1" "$col2"
        # shellcheck disable=SC2059
        printf "  ${C_PRIMARY}├──────────────────────┼──────────────────────────────────────────┤${C_RESET}\n"
    fi
}

# 显示表格尾部
show_table_footer() {
    local has_third_col="${1:-false}"
    
    if [[ "$has_third_col" == "true" ]]; then
        printf '  %s└──────────────────────┴──────────────────────────────┴────────────┘%s\n' "$C_PRIMARY" "$C_RESET"
    else
        printf '  %s└──────────────────────┴──────────────────────────────────────────┘%s\n' "$C_PRIMARY" "$C_RESET"
    fi
}

# ============================================================
# 模块初始化
# ============================================================

# 初始化UI模块
init_ui_module() {
    # 重置菜单状态
    reset_menu
    
    # 检查终端支持
    if [[ -z "${TERM:-}" ]] || [[ "$TERM" == "dumb" ]]; then
        # 简单模式，不使用颜色
        C_RESET=''
        C_BOLD=''
        C_DIM=''
        C_PRIMARY=''
        C_SECONDARY=''
        C_SUCCESS=''
        C_WARNING=''
        C_ERROR=''
    fi
    
    return 0
}

# 执行初始化
init_ui_module
