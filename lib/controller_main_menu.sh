#!/bin/bash
# controller_main_menu.sh - 主菜单控制器
# 目标：将入口与主循环控制逻辑从 user_manager.sh 中解耦

main_menu() {
    while true; do
        clear
        draw_header "用户与系统管理器 v0.2.1"

        safe_run check_expired_suspensions
        safe_run show_disk_usage_warnings

        echo ""
        draw_menu_submenu  1 "用户管理"
        draw_menu_submenu  2 "磁盘与配额管理"
        draw_menu_submenu  3 "网络与安全管理"
        draw_menu_submenu  4 "备份与恢复"
        draw_menu_submenu  5 "报告与统计"
        draw_menu_submenu  6 "系统维护"
        draw_menu_submenu  7 "审计与日志"
        draw_menu_exit "退出"
        draw_prompt
        opt="$(rl_read_menu_key)"

        case $opt in
            1)  safe_run user_management_menu ;;
            2)  safe_run disk_quota_menu ;;
            3)  safe_run network_security_menu ;;
            4)  safe_run backup_menu ;;
            5)  safe_run report_stats_menu ;;
            6)  safe_run system_menu ;;
            7)  safe_run audit_menu ;;
            0)  msg_ok "再见！"; exit 0 ;;
            *)  msg_err "无效的选项" ;;
        esac
        pause_continue
    done
}

controller_start() {
    check_dependencies || exit 1
    load_config || exit 1
    setup_trap_handler
    main_menu
}
