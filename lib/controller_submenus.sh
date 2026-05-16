#!/bin/bash
# controller_submenus.sh - 子菜单控制器
# 从 user_manager.sh 提取的菜单与路由逻辑

# === 备份管理菜单 ===
_handle_backup() {
    local opt="$1"
    case $opt in
        1)
            read_input "请输入用户名"; local username="$REPLY_INPUT"
            [[ -z "$username" ]] && return
            manual_backup_user "$username"
            ;;
        2)
            read_input "请输入用户名"; local username="$REPLY_INPUT"
            [[ -z "$username" ]] && return
            read_input "备份点名称 (留空=最新)"; local backup_name="$REPLY_INPUT"
            restore_user_backup "$username" "$backup_name"
            ;;
        3)
            read_input "请输入用户名"; local username="$REPLY_INPUT"
            [[ -z "$username" ]] && return
            show_backup_status "$username"
            ;;
        4)  list_backup_users ;;
        5)
            read_input "请输入用户名"; local username="$REPLY_INPUT"
            [[ -z "$username" ]] && return
            read_input "备份时间（小时，0-23）"; local backup_hour="$REPLY_INPUT"
            configure_backup_schedule "$username" "$backup_hour"
            ;;
        6)
            read_input "请输入用户名"; local username="$REPLY_INPUT"
            [[ -z "$username" ]] && return
            remove_backup_schedule "$username"
            ;;
        7)  show_backup_schedules ;;
        8)  backup_all_users ;;
        9)  backup_all_users_parallel ;;
        10) show_backup_batches ;;
        11)
            read_input "批次ID (如 20251029_174643)"; local batch_id="$REPLY_INPUT"
            read_input "要恢复的用户名"; local username="$REPLY_INPUT"
            restore_from_batch "$batch_id" "$username"
            ;;
        *)  msg_err "无效的选项" ;;
    esac
}

backup_menu() {
    run_submenu "备份与恢复" _handle_backup \
        "1:手动备份用户" \
        "2:恢复用户数据" \
        "3:查看备份状态" \
        "4:列出备份用户" \
        "5:设置定时备份" \
        "6:取消定时备份" \
        "7:查看备份计划" \
        "8:备份所有用户" \
        "9:并行备份所有用户" \
        "10:查看批次记录" \
        "11:从批次恢复"
}

# === 防火墙管理菜单 ===
_handle_firewall() {
    local opt="$1"
    case $opt in
        1)
            read_input "用户名"; local username="$REPLY_INPUT"
            read_input "端口号"; local port="$REPLY_INPUT"
            read_input "协议 (tcp/udp)" "tcp"; local protocol="$REPLY_INPUT"
            read_input "来源IP (可选)"; local from_ip="$REPLY_INPUT"
            add_port_rule "$username" "$port" "$protocol" "$from_ip"
            ;;
        2)
            read_input "用户名"; local username="$REPLY_INPUT"
            read_input "端口号"; local port="$REPLY_INPUT"
            read_input "协议 (tcp/udp)" "tcp"; local protocol="$REPLY_INPUT"
            delete_port_rule "$username" "$port" "$protocol"
            ;;
        3)  list_firewall_rules ;;
        4)
            read_input "用户名"; local username="$REPLY_INPUT"
            list_user_firewall_rules "$username"
            ;;
        5)  show_port_usage ;;
        6)
            read_input "用户名"; local username="$REPLY_INPUT"
            read_input "起始端口"; local start_port="$REPLY_INPUT"
            read_input "结束端口"; local end_port="$REPLY_INPUT"
            read_input "协议 (tcp/udp)" "tcp"; local protocol="$REPLY_INPUT"
            add_port_range "$username" "$start_port" "$end_port" "$protocol"
            ;;
        7)
            read_input "用户名"; local username="$REPLY_INPUT"
            msg_info "服务类型: ${C_BCYAN}web${C_RESET}, ${C_BCYAN}database${C_RESET}, ${C_BCYAN}ssh${C_RESET}, ${C_BCYAN}jupyter${C_RESET}"
            read_input "选择服务"; local service="$REPLY_INPUT"
            apply_service_template "$username" "$service"
            ;;
        8)  init_ufw ;;
        *)  msg_err "无效的选项" ;;
    esac
}

firewall_menu() {
    run_submenu "防火墙规则" _handle_firewall \
        "1:添加端口规则" \
        "2:删除端口规则" \
        "3:查看全部规则" \
        "4:查看用户规则" \
        "5:端口使用概览" \
        "6:添加端口范围" \
        "7:应用服务模板" \
        "8:初始化 UFW"
}

# === DNS 管理菜单 ===
_handle_dns() {
    local opt="$1"
    case $opt in
        1)  show_dns_whitelist ;;
        2)
            read_input "请输入域名"; local domain="$REPLY_INPUT"
            add_dns_entry "$domain"
            ;;
        3)
            read_input "请输入域名"; local domain="$REPLY_INPUT"
            remove_dns_entry "$domain"
            ;;
        4)
            read_input "请输入用户名"; local username="$REPLY_INPUT"
            apply_dns_restrictions "$username"
            ;;
        5)
            read_input "请输入用户名"; local username="$REPLY_INPUT"
            remove_dns_restrictions "$username"
            ;;
        6)
            read_input "请输入用户名"; local username="$REPLY_INPUT"
            show_dns_status "$username"
            ;;
        7)  apply_all_dns_restrictions ;;
        8)  refresh_dns_rules ;;
        *)  msg_err "无效的选项" ;;
    esac
}

dns_menu() {
    run_submenu "DNS 访问控制" _handle_dns \
        "1:查看白名单" \
        "2:添加域名" \
        "3:移除域名" \
        "4:启用 DNS 限制" \
        "5:移除 DNS 限制" \
        "6:查看用户状态" \
        "7:批量应用限制" \
        "8:刷新 DNS 规则"
}

# === 作业统计菜单 ===
_handle_job_stats() {
    local opt="$1"
    case $opt in
        1)  collect_all_job_stats ;;
        2)
            read_input "请输入用户名"; local username="$REPLY_INPUT"
            get_weekly_job_stats "$username"
            ;;
        3)
            read_input "请输入用户名"; local username="$REPLY_INPUT"
            get_monthly_job_stats "$username"
            ;;
        4)
            read_input "请输入用户名"; local username="$REPLY_INPUT"
            collect_user_jobs "$username"
            ;;
        *)  msg_err "无效的选项" ;;
    esac
}

job_stats_menu() {
    run_submenu "作业统计" _handle_job_stats \
        "1:收集全部用户统计" \
        "2:查看周统计" \
        "3:查看月统计" \
        "4:查看当前进程"
}

# === 符号链接管理菜单 ===
_handle_symlink() {
    local opt="$1"
    case $opt in
        1)
            read_input "用户名"; local username="$REPLY_INPUT"
            read_input "链接名称"; local link_name="$REPLY_INPUT"
            read_input "目标路径"; local target_path="$REPLY_INPUT"
            create_user_symlink "$username" "$link_name" "$target_path"
            ;;
        2)
            read_input "用户名"; local username="$REPLY_INPUT"
            read_input "目标盘号 (${ALL_DISKS[*]})"; local disk_num="$REPLY_INPUT"
            read_input "子目录 (可选)"; local subdir="$REPLY_INPUT"
            create_cross_disk_symlink "$username" "$disk_num" "$subdir"
            ;;
        3)
            read_input "用户名"; local username="$REPLY_INPUT"
            list_user_symlinks "$username"
            ;;
        4)
            read_input "用户名"; local username="$REPLY_INPUT"
            list_user_symlinks "$username"
            read_input "要删除的链接名称"; local link_name="$REPLY_INPUT"
            delete_user_symlink "$username" "$link_name"
            ;;
        5)
            read_input "用户名"; local username="$REPLY_INPUT"
            cleanup_broken_symlinks "$username"
            ;;
        6)
            read_input "用户名"; local username="$REPLY_INPUT"
            read_input "共享名称"; local shared_name="$REPLY_INPUT"
            read_input "共享路径"; local shared_path="$REPLY_INPUT"
            create_shared_symlink "$username" "$shared_name" "$shared_path"
            ;;
        7)
            read_input "共享名称"; local shared_name="$REPLY_INPUT"
            read_input "共享路径"; local shared_path="$REPLY_INPUT"
            if confirm_action "为所有用户创建共享链接？"; then
                create_shared_for_all "$shared_name" "$shared_path"
            fi
            ;;
        8)  show_all_symlinks_overview ;;
        *)  msg_err "无效的选项" ;;
    esac
}

symlink_menu() {
    run_submenu "符号链接与共享" _handle_symlink \
        "1:创建用户符号链接" \
        "2:创建跨盘链接" \
        "3:查看用户符号链接" \
        "4:删除用户符号链接" \
        "5:清理断链" \
        "6:创建共享链接" \
        "7:为所有用户创建共享链接" \
        "8:符号链接概览"
}

# === 密码轮换菜单 ===
_handle_password_rotation() {
    local opt="$1"
    case $opt in
        1)  show_password_rotation_status ;;
        2)
            read_input "轮换间隔（天）" "${PASSWORD_ROTATE_INTERVAL_DAYS:-90}"
            local interval="$REPLY_INPUT"
            configure_password_rotation "$interval"
            ;;
        3)  remove_password_rotation ;;
        4)  manual_password_rotation ;;
        *)  msg_err "无效的选项" ;;
    esac
}

password_rotation_menu() {
    run_submenu "密码轮换" _handle_password_rotation \
        "1:查看轮换状态" \
        "2:设置定时轮换" \
        "3:取消定时轮换" \
        "4:立即执行轮换"
}

# --- 查看审计日志 ---
view_audit_log() {
    draw_header "查看审计日志"

    if [[ ! -f "$AUDIT_LOG_FILE" ]]; then
        msg_warn "审计日志文件不存在"
        return 0
    fi

    msg_info "最近 50 条审计记录:"
    echo ""
    tail -50 "$AUDIT_LOG_FILE" | while IFS='|' read -r timestamp operation _ result details; do
        printf "  ${C_DIM}%-20s${C_RESET} ${C_BOLD}%-15s${C_RESET} %-20s %s\n" \
            "$timestamp" "$operation" "$result" "${details:0:50}"
    done
    echo ""
}

# --- 审计统计分析 ---
show_audit_stats() {
    draw_header "审计统计分析"

    if [[ ! -f "$AUDIT_LOG_FILE" ]]; then
        msg_warn "审计日志文件不存在"
        return 0
    fi

    local total_ops success_count failure_count
    total_ops=$(wc -l < "$AUDIT_LOG_FILE")
    success_count=$(grep -c "SUCCESS" "$AUDIT_LOG_FILE" || echo 0)
    failure_count=$(grep -c -E "(FAILURE|ERROR|DENIED)" "$AUDIT_LOG_FILE" || echo 0)

    draw_info_card "总操作数:" "$total_ops"
    draw_info_card "成功:" "${C_BGREEN}$success_count${C_RESET}"
    draw_info_card "失败/拒绝:" "${C_BRED}$failure_count${C_RESET}"
    echo ""
}

view_journald_audit_log() {
    draw_header "查看 Journald 审计日志"
    read_input "最近日志行数" "50"; local lines="$REPLY_INPUT"
    audit_view_journald_log "${lines:-50}"
    echo ""
}

# === 报告与统计菜单 ===
_handle_report() {
    local opt="$1"
    case $opt in
        1)
            read_input "输出文件 (留空=自动生成)"; local output_file="$REPLY_INPUT"
            if [[ -z "$output_file" ]]; then
                generate_html_report
            else
                generate_html_report "$output_file"
            fi
            ;;
        2)  generate_user_statistics ;;
        3)  generate_quota_report ;;
        4)  generate_resource_report ;;
        5)  show_user_resource_usage ;;
        6)
            read_input "请输入用户名"; local username="$REPLY_INPUT"
            show_single_user_resource "$username"
            ;;
        7)  show_user_creation_log ;;
        8)
            read_input "用户名"; local username="$REPLY_INPUT"
            query_user_history "$username"
            ;;
        9)
            read_input "开始日期 (YYYY-MM-DD)"; local start_date="$REPLY_INPUT"
            read_input "结束日期 (YYYY-MM-DD)"; local end_date="$REPLY_INPUT"
            query_by_date_range "$start_date" "$end_date"
            ;;
        10) analyze_operation_trends ;;
        11) analyze_anomalies ;;
        12) generate_log_summary ;;
        13)
            read_input "输出文件 (留空=自动)"; local output_file="$REPLY_INPUT"
            export_full_report "$output_file"
            ;;
        14)
            read_input "输出文件 (留空=自动)"; local output_file="$REPLY_INPUT"
            export_users_csv "$output_file"
            ;;
        15)
            read_input "请输入用户名"; local username="$REPLY_INPUT"
            if [[ -n "$username" ]]; then
                local report_file
                report_file="$REPORT_DIR/user_${username}_$(date +%Y%m%d).html"
                if generate_user_personal_report "$username" "$report_file"; then
                    send_user_report_email "$username" "$report_file"
                fi
            fi
            ;;
        16)
            if confirm_action "确认为所有用户生成并发送报告？"; then
                send_all_user_reports
            fi
            ;;
        17) setup_weekly_report_cron ;;
        18) remove_weekly_report_cron ;;
        19) view_weekly_report_log ;;
        20) view_audit_log ;;
        21) show_audit_stats ;;
        *)  msg_err "无效的选项" ;;
    esac
}

report_menu() {
    run_submenu "报告与分析" _handle_report \
        "1:生成系统 HTML 报告" \
        "2:用户统计报告" \
        "3:配额使用报告" \
        "4:资源限制报告" \
        "5:实时资源使用" \
        "6:单用户资源详情" \
        "7:查看操作日志" \
        "8:查询用户历史" \
        "9:按日期查询" \
        "---" \
        "10:操作趋势分析" \
        "11:异常检测分析" \
        "12:日志摘要报告" \
        "---" \
        "13:导出完整报告" \
        "14:导出用户 CSV" \
        "15:生成并发送个人报告" \
        "16:为所有用户发送报告" \
        "17:设置每周自动报告" \
        "18:取消每周自动报告" \
        "19:查看自动报告日志" \
        "---" \
        "20:查看审计日志" \
        "21:审计统计分析"
}

_handle_system() {
    local opt="$1"
    case $opt in
        1)  show_system_info ;;
        2)  show_memory_info ;;
        3)  launch_btop_monitor ;;
        4)  launch_htop_monitor ;;
        5)  check_hardware_health ;;
        6)  analyze_system_logs ;;
        7)  analyze_crash_causes ;;
        8)  configure_oom_protection ;;
        9)  show_network_info ;;
        10) show_cpu_info ;;
        11) show_memory_info_detailed ;;
        12) show_disk_info ;;
        13) show_network_hardware_info ;;
        14) run_full_hardware_check ;;
        15) show_ubuntu_maintenance_panel ;;
        16)
            read_input "boot 引用 (0=当前, -1=上次)" "0"; local boot_ref="$REPLY_INPUT"
            read_input "最近日志行数" "100"; local lines="$REPLY_INPUT"
            action_run logs.boot cli --boot "${boot_ref:-0}" --lines "${lines:-100}"
            ;;
        17) action_run logs.failed_services cli ;;
        18)
            read_input "服务名 (如 ssh / docker.service)"; local unit="$REPLY_INPUT"
            read_input "最近日志行数" "80"; local lines="$REPLY_INPUT"
            [[ -n "$unit" ]] && action_run logs.service_recent cli "$unit" --lines "${lines:-80}"
            ;;
        19)
            read_input "对比最近 err..alert 日志条数" "100"; local lines="$REPLY_INPUT"
            action_run logs.boot_error_diff cli --lines "${lines:-100}"
            ;;
        20) show_network_stack_panel ;;
        21) systemd_timer_menu ;;
        *)  msg_err "无效的选项" ;;
    esac
}

system_menu() {
    run_submenu "系统维护" _handle_system \
        "1:系统信息概览" \
        "2:内存信息 (dmidecode)" \
        "3:启动 btop 监控" \
        "4:启动 htop 监控" \
        "5:硬件健康检查" \
        "6:系统日志分析" \
        "7:崩溃原因分析" \
        "8:配置 OOM 防护" \
        "9:显示网络信息" \
        "---" \
        "10:CPU 详细信息" \
        "11:内存详细信息" \
        "12:磁盘信息" \
        "13:网络硬件信息" \
        "14:完整硬件检测" \
        "---" \
        "15:Ubuntu APT/重启维护" \
        "16:查看 Boot 日志" \
        "17:列出失败服务" \
        "18:诊断指定服务" \
        "19:启动错误对比" \
        "20:网络栈诊断" \
        "21:Systemd Timers ›"
}

# ============================================================
#  用户管理子菜单
# ============================================================

_handle_user_management() {
    local opt="$1"
    case $opt in
        1)  safe_run create_or_assign_user ;;
        2)  safe_run change_user_password ;;
        3)  safe_run delete_user_account ;;
        4)  safe_run rename_user_account ;;
        5)  safe_run suspend_or_enable_user ;;
        6)  safe_run modify_user_quota ;;
        7)  safe_run modify_user_resource_limits ;;
        8)  safe_run list_managed_users ;;
        *)  msg_err "无效的选项" ;;
    esac
}

user_management_menu() {
    run_submenu "用户管理" _handle_user_management \
        "1:创建/更新用户" \
        "2:修改用户密码" \
        "3:删除用户账户" \
        "4:重命名用户账户" \
        "5:暂停/恢复用户" \
        "6:调整用户配额" \
        "7:配置资源限制" \
        "8:查看托管用户"
}

# ============================================================
#  磁盘与配额管理子菜单
# ============================================================

_handle_disk_quota() {
    local opt="$1"
    case $opt in
        1)  safe_run show_disk_overview ;;
        2)  safe_run modify_user_quota ;;
        3)
            read_input "请输入用户名"; local username="$REPLY_INPUT"
            [[ -n "$username" ]] && show_single_user_resource "$username"
            ;;
        4)  safe_run modify_user_resource_limits ;;
        5)
            read_input "请输入用户名"; local username="$REPLY_INPUT"
            [[ -n "$username" ]] && show_single_user_resource "$username"
            ;;
        *)  msg_err "无效的选项" ;;
    esac
}

disk_quota_menu() {
    run_submenu "磁盘与配额管理" _handle_disk_quota \
        "1:数据盘概览" \
        "2:调整用户配额" \
        "3:查看用户配额" \
        "4:配置资源限制" \
        "5:查看资源使用"
}
# ============================================================
#  网络与安全管理子菜单
# ============================================================

_handle_network_security() {
    local opt="$1"
    case $opt in
        1)  safe_run firewall_menu ;;
        2)  safe_run dns_menu ;;
        3)  safe_run symlink_menu ;;
        4)  safe_run ssh_fail2ban_menu ;;
        5)  safe_run show_network_stack_panel ;;
        *)  msg_err "无效的选项" ;;
    esac
}

network_security_menu() {
    run_submenu "网络与安全管理" _handle_network_security \
        "1:防火墙规则 ›" \
        "2:DNS 访问控制 ›" \
        "3:符号链接与共享 ›" \
        "4:SSH 与 Fail2ban ›" \
        "5:网络栈诊断"
}

_handle_ssh_fail2ban() {
    local opt="$1"
    case $opt in
        1) security_baseline_sshd_summary ;;
        2)
            read_input "最近认证失败日志行数" "20"; local lines="$REPLY_INPUT"
            security_baseline_show_recent_auth_failures "${lines:-20}"
            ;;
        3) security_baseline_show_fail2ban_status ;;
        4)
            read_input "bantime 秒数" "600"; local bantime="$REPLY_INPUT"
            read_input "findtime 秒数" "600"; local findtime="$REPLY_INPUT"
            read_input "maxretry 次数" "5"; local maxretry="$REPLY_INPUT"
            security_baseline_configure_fail2ban_sshd_jail "${bantime:-600}" "${findtime:-600}" "${maxretry:-5}"
            ;;
        5) security_baseline_fail2ban_list_jails ;;
        6) security_baseline_fail2ban_show_nginx_status ;;
        7)
            read_input "nginx bantime 秒数" "3600"; local bantime="$REPLY_INPUT"
            read_input "nginx findtime 秒数" "600"; local findtime="$REPLY_INPUT"
            read_input "nginx maxretry 次数" "2"; local maxretry="$REPLY_INPUT"
            security_baseline_configure_fail2ban_nginx_jail "${bantime:-3600}" "${findtime:-600}" "${maxretry:-2}"
            ;;
        *) msg_err "无效的选项" ;;
    esac
}

ssh_fail2ban_menu() {
    run_submenu "SSH 与 Fail2ban" _handle_ssh_fail2ban \
        "1:SSH 安全基线摘要" \
        "2:最近认证失败" \
        "3:Fail2ban 状态" \
        "4:配置 sshd jail" \
        "5:列出全部 jails" \
        "6:查看 nginx jail 状态" \
        "7:配置 nginx jail"
}

_handle_systemd_timers() {
    local opt="$1"
    case $opt in
        1) action_run system.timers.list cli ;;
        2)
            read_input "profile (weekly-report/account-health-check)" "weekly-report"; local profile="$REPLY_INPUT"
            systemd_timer_install_profile "${profile:-weekly-report}"
            ;;
        3)
            read_input "timer 名称" "weekly-report"; local timer_name="$REPLY_INPUT"
            read_input "最近日志行数" "50"; local lines="$REPLY_INPUT"
            action_run system.timers.logs cli "${timer_name:-weekly-report}" "${lines:-50}"
            ;;
        4)
            read_input "要删除的 timer 名称" "weekly-report"; local timer_name="$REPLY_INPUT"
            [[ -n "$timer_name" ]] && systemd_timer_remove "$timer_name"
            ;;
        *) msg_err "无效的选项" ;;
    esac
}

systemd_timer_menu() {
    run_submenu "Systemd Timers" _handle_systemd_timers \
        "1:列出 timers" \
        "2:安装 timer profile" \
        "3:查看 timer 日志" \
        "4:删除 timer"
}

# ============================================================
#  报告与统计子菜单
# ============================================================

_handle_report_stats() {
    local opt="$1"
    case $opt in
        1)  safe_run report_menu ;;
        2)  safe_run job_stats_menu ;;
        3)  safe_run password_rotation_menu ;;
        *)  msg_err "无效的选项" ;;
    esac
}

report_stats_menu() {
    run_submenu "报告与统计" _handle_report_stats \
        "1:报告与分析 ›" \
        "2:作业统计 ›" \
        "3:密码轮换 ›"
}

# ============================================================
# 审计与日志菜单
# ============================================================

_handle_audit() {
    local opt="$1"
    case $opt in
        1)  view_audit_log ;;
        2)
            read_input "操作类型 (留空=全部)"; local op_type="$REPLY_INPUT"
            read_input "用户名 (留空=全部)"; local user="$REPLY_INPUT"
            read_input "日期范围 (YYYY-MM-DD 或 YYYY-MM-DD:YYYY-MM-DD, 留空=全部)"; local date_range="$REPLY_INPUT"
            audit_query "$op_type" "$user" "$date_range"
            ;;
        3)  show_audit_stats ;;
        4)  audit_rotate; msg_ok "日志轮转完成" ;;
        5)  view_journald_audit_log ;;
        *)  msg_err "无效的选项" ;;
    esac
}

audit_menu() {
    run_submenu "审计与日志" _handle_audit \
        "1:查看审计日志" \
        "2:查询审计日志" \
        "3:审计统计分析" \
        "4:手动日志轮转" \
        "5:查看 Journald 审计"
}
