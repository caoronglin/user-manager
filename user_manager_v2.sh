#!/bin/bash
# user_manager_v2.sh - 用户与系统管理器 v7.0 (简化版)
# 版本: v7.0.0
# 要求: Ubuntu/Debian, 已配置 user quota + rsnapshot + UFW

set -uo pipefail

# === 获取脚本目录 ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# === 加载所有模块（按依赖顺序）===
# shellcheck disable=SC1091
source "$LIB_DIR/common.sh"        # 基础工具函数
# shellcheck disable=SC1091
source "$LIB_DIR/config.sh"        # 配置管理
# shellcheck disable=SC1091
source "$LIB_DIR/access_control.sh" # 访问控制
# shellcheck disable=SC1091
source "$LIB_DIR/privilege.sh"     # 权限封装
# shellcheck disable=SC1091
source "$LIB_DIR/privilege_cache.sh" # 权限缓存
# shellcheck disable=SC1091
source "$LIB_DIR/audit_core.sh"    # 审计日志（新增）
# shellcheck disable=SC1091
source "$LIB_DIR/ui_menu_simple.sh" # 简化菜单系统（新增）

# 功能模块
# shellcheck disable=SC1091
source "$LIB_DIR/user_core.sh"     # 用户管理
# shellcheck disable=SC1091
source "$LIB_DIR/quota_core.sh"    # 配额管理
# shellcheck disable=SC1091
source "$LIB_DIR/resource_core.sh" # 资源限制
# shellcheck disable=SC1091
source "$LIB_DIR/backup_core.sh"   # 备份恢复
# shellcheck disable=SC1091
source "$LIB_DIR/firewall_core.sh" # 防火墙
# shellcheck disable=SC1091
source "$LIB_DIR/dns_core.sh"      # DNS管理
# shellcheck disable=SC1091
source "$LIB_DIR/symlink_core.sh"  # 软链接
# shellcheck disable=SC1091
source "$LIB_DIR/report_core.sh"   # 报告统计
# shellcheck disable=SC1091
source "$LIB_DIR/system_core.sh"   # 系统维护
# shellcheck disable=SC1091
source "$LIB_DIR/miniforge_core.sh" # Miniforge

# ============================================================
#  菜单显示函数（使用新的简化UI）
# ============================================================

# 显示主菜单
show_main_menu() {
    draw_header "用户与系统管理器 v7.0"
    draw_breadcrumb
    
    show_section "用户管理"
    draw_menu_item "1" "创建用户" "添加新用户并设置配额"
    draw_menu_item "2" "修改密码" "重置用户密码"
    draw_menu_item "3" "删除用户" "删除用户及数据"
    draw_menu_item "4" "重命名用户" "更改用户名"
    draw_menu_item "5" "暂停/启用用户" "控制用户访问权限"
    
    show_section "配置管理"
    draw_menu_item "6" "配额管理" "调整磁盘配额"
    draw_menu_item "7" "资源限制" "设置CPU/内存限制"
    draw_menu_item "8" "查看用户列表" "显示所有用户信息"
    draw_menu_item "9" "磁盘概览" "查看磁盘使用情况"
    
    show_section "系统功能"
    draw_submenu_item "10" "备份与恢复"
    draw_submenu_item "11" "防火墙管理"
    draw_submenu_item "12" "DNS控制"
    draw_submenu_item "13" "软链接管理"
    draw_submenu_item "14" "作业统计"
    draw_submenu_item "15" "密码轮换"
    draw_submenu_item "16" "报告统计"
    draw_submenu_item "17" "系统维护"
    
    draw_exit_option
}

# 处理主菜单选择
handle_main_menu() {
    local choice="$1"
    
    case "$choice" in
        1) safe_run create_or_assign_user ;;
        2) safe_run change_user_password ;;
        3) safe_run delete_user_account ;;
        4) safe_run rename_user_account ;;
        5) safe_run suspend_or_enable_user ;;
        6) safe_run modify_user_quota ;;
        7) safe_run modify_user_resource_limits ;;
        8) safe_run list_managed_users ;;
        9) safe_run show_disk_overview ;;
        10) safe_run backup_menu ;;
        11) safe_run firewall_menu ;;
        12) safe_run dns_menu ;;
        13) safe_run symlink_menu ;;
        14) safe_run job_stats_menu ;;
        15) safe_run password_rotation_menu ;;
        16) safe_run report_menu ;;
        17) safe_run system_menu ;;
        99) 
            show_info "感谢使用，再见！"
            audit_log "$AUDIT_OP_LOGOUT" "system" "$AUDIT_RESULT_SUCCESS" "用户退出系统"
            exit 0
            ;;
        *)
            show_error "无效选项: $choice"
            return 1
            ;;
    esac
    
    return 0
}

# ============================================================
#  主程序入口
# ============================================================

main() {
    # 加载配置
    load_config || {
        show_error "配置加载失败，程序退出"
        exit 1
    }
    
    # 初始化审计系统
    audit_init || {
        show_warning "审计系统初始化失败，继续运行但无法记录审计日志"
    }
    
    # 记录登录
    audit_log "$AUDIT_OP_LOGIN" "system" "$AUDIT_RESULT_SUCCESS" "用户登录系统"
    
    # 初始化菜单系统
    init_ui_simple
    reset_menu
    
    # 主循环
    while true; do
        show_main_menu
        local choice
        choice=$(read_choice)
        
        if [[ -n "$choice" ]]; then
            handle_main_menu "$choice"
            pause_continue
        fi
    done
}

# 安全运行函数（包装器）
safe_run() {
    local func="$1"
    shift
    
    if declare -f "$func" &>/dev/null; then
        "$func" "$@"
    else
        show_error "函数不存在: $func"
        return 1
    fi
}

# 运行主程序
main "$@"
