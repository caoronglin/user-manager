#!/bin/bash
# tui_manager.sh - TUI 主线入口

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# shellcheck disable=SC1091
source "$LIB_DIR/bootstrap.sh"
um_load_profile tui || exit 1

_tui_source_module() {
    local module="$1"
    local module_path="$LIB_DIR/$module"

    if [[ -f "$module_path" ]]; then
        # shellcheck disable=SC1090
        source "$module_path"
    fi
}

_tui_load_mainline_modules() {
    local -a modules=(
        "resource_core.sh"
        "email_core.sh"
        "audit_core.sh"
        "backup_core.sh"
        "firewall_core.sh"
        "dns_core.sh"
        "symlink_core.sh"
        "report_core.sh"
        "system_core.sh"
        "vm_core.sh"
        "gpu_core.sh"
        "controller_user_workflows.sh"
        "controller_submenus.sh"
    )
    local module
    for module in "${modules[@]}"; do
        _tui_source_module "$module"
    done
}

_tui_load_mainline_modules

# 加载数据驱动菜单引擎
# shellcheck disable=SC1091
source "$LIB_DIR/tui_menus.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/tui_views_logs.sh"

if declare -F action_register_defaults_once >/dev/null 2>&1; then
    action_register_defaults_once
fi

get_tui_managed_user_count() {
    if ! declare -F get_managed_usernames >/dev/null 2>&1; then
        echo "0"
        return 0
    fi

    local users=()
    mapfile -t users < <(get_managed_usernames 2>/dev/null)
    echo "${#users[@]}"
}

draw_main_menu() {
    _tui_draw_menu "main"
}

tui_run_classic_menu() {
    local menu_func="$1"

    if ! declare -F "$menu_func" >/dev/null 2>&1; then
        tui_message "错误" "菜单未实现: $menu_func"
        return 1
    fi

    tui_cleanup
    "$menu_func"
    local rc=$?
    tui_init
    return $rc
}

tui_run_workflow_action() {
    local workflow_func="$1"

    if ! declare -F "$workflow_func" >/dev/null 2>&1; then
        tui_message "错误" "功能未实现: $workflow_func"
        return 1
    fi

    tui_cleanup
    "$workflow_func"
    local rc=$?
    tui_init
    return $rc
}

tui_run_action() {
    local action_id="$1"
    shift || true

    if ! declare -F action_run >/dev/null 2>&1; then
        tui_message "错误" "action registry 不可用"
        return 1
    fi

    tui_cleanup
    action_run "$action_id" tui "$@"
    local rc=$?
    tui_init
    return $rc
}

tui_run_prompted_username_action() {
    local prompt_text="$1"
    local action_func="$2"

    if ! declare -F "$action_func" >/dev/null 2>&1; then
        tui_message "错误" "功能未实现: $action_func"
        return 1
    fi

    local username
    while true; do
        if ! tui_prompt_input "参数输入" "$prompt_text" ""; then
            TUI_REDRAW=true
            return 1
        fi
        username="$REPLY_INPUT"

        if [[ -z "$username" ]]; then
            tui_message "错误" "用户名不能为空"
            continue
        fi
        if declare -F validate_username >/dev/null 2>&1 && ! validate_username "$username" >/dev/null 2>&1; then
            tui_message "错误" "用户名格式无效"
            continue
        fi
        if ! id "$username" &>/dev/null; then
            tui_message "错误" "用户不存在: $username"
            continue
        fi
        break
    done

    tui_cleanup
    "$action_func" "$username"
    local rc=$?
    tui_init
    return $rc
}

tui_run_prompt_sequence_action() {
    local action_func="$1"
    shift

    if ! declare -F "$action_func" >/dev/null 2>&1; then
        tui_message "错误" "功能未实现: $action_func"
        return 1
    fi

    local -a args=()
    local prompt_spec prompt_text prompt_default
    for prompt_spec in "$@"; do
        prompt_text="$prompt_spec"
        prompt_default=""
        if [[ "$prompt_spec" == *"|"* ]]; then
            prompt_text="${prompt_spec%%|*}"
            prompt_default="${prompt_spec#*|}"
        fi
        if ! tui_prompt_input "参数输入" "$prompt_text" "$prompt_default"; then
            TUI_REDRAW=true
            return 1
        fi
        args+=("$REPLY_INPUT")
    done

    tui_cleanup
    "$action_func" "${args[@]}"
    local rc=$?
    tui_init
    return $rc
}

tui_run_native_menu() {
    local draw_func="$1"
    local key_handler="$2"

    TUI_SUBMENU_EXIT=0
    TUI_REDRAW=true

    while [[ "${TUI_SUBMENU_EXIT:-0}" != "1" ]]; do
        if [[ "${TUI_REDRAW:-true}" == "true" ]]; then
            tui_clear
            "$draw_func"
            TUI_REDRAW=false
        fi

        local key
        key=$(tui_read_key 2>/dev/null) || continue
        [[ -n "$key" ]] || continue

        "$key_handler" "$key"

        if [[ "${TUI_SUBMENU_EXIT:-0}" != "1" ]]; then
            TUI_REDRAW=true
        fi
    done

    TUI_SUBMENU_EXIT=0
    TUI_REDRAW=true
    return 0
}

draw_tui_user_menu() {
    _tui_draw_menu "user"
}

handle_tui_user_menu_key() {
    local key="$1"
    local result

    result=$(tui_menu_handle_key "$key")
    [[ -z "$result" ]] && return 0

    case "$result" in
        0) tui_run_create_or_assign_user_native ;;
        1) tui_run_workflow_action change_user_password ;;
        2) tui_run_workflow_action delete_user_account ;;
        3) tui_run_workflow_action rename_user_account ;;
        4) tui_run_workflow_action suspend_or_enable_user ;;
        5) tui_run_workflow_action modify_user_quota ;;
        6) tui_run_workflow_action modify_user_resource_limits ;;
        7) tui_show_managed_users_view ;;
        8|-1)
            TUI_SUBMENU_EXIT=1
            ;;
    esac

    return 0
}

tui_run_user_management_menu() {
    tui_run_native_menu draw_tui_user_menu handle_tui_user_menu_key
}

tui_show_managed_users_view() {
    local users=()
    local selected=0
    local scroll_offset=0
    local running=true

    mapfile -t users < <(get_managed_usernames 2>/dev/null)

    while $running; do
        tui_clear
        tui_draw_fill 0 0 "$TUI_COLS" 3 "$TUI_COLOR_ACCENT"
        tui_fg 0
        tui_move 1 $(( (TUI_COLS - 12) / 2 ))
        tui_bold
        echo "托管用户列表"
        tui_reset

        if (( ${#users[@]} == 0 )); then
            tui_draw_center 6 "当前无任何托管用户" "$TUI_COLOR_MUTED"
            tui_statusbar_draw $((TUI_LINES - 1)) "托管用户列表" "q 返回"
            local empty_key
            empty_key=$(tui_read_key 2>/dev/null) || continue
            [[ "$empty_key" == "q" || "$empty_key" == "ESC" || "$empty_key" == "ENTER" ]] && break
            continue
        fi

        local max_rows=$((TUI_LINES - 8))
        (( max_rows < 1 )) && max_rows=1
        local end_index=$(( scroll_offset + max_rows ))
        (( end_index > ${#users[@]} )) && end_index=${#users[@]}

        tui_move 4 2
        tui_bold
        tui_fg "$TUI_COLOR_ACCENT"
        printf "%-16s %-12s %-10s %-10s %s\n" "用户名" "挂载点" "配额GB" "使用率" "主目录"
        tui_reset

        local row=5
        local i
        for ((i = scroll_offset; i < end_index; i++)); do
            local username="${users[$i]}"
            local home mp quota_gb usage_text quota_info used_bytes limit_bytes pct
            home=$(get_user_home "$username" 2>/dev/null || echo "-")
            mp=$(get_user_mountpoint "$home" 2>/dev/null || echo "N/A")
            quota_gb="未设置"
            usage_text="-"

            if [[ "$mp" != "N/A" ]]; then
                quota_info=$(get_user_quota_info "$username" "$mp")
                used_bytes="${quota_info%:*}"
                limit_bytes="${quota_info#*:}"
                if [[ "$limit_bytes" =~ ^[0-9]+$ ]] && (( limit_bytes > 0 )); then
                    quota_gb=$(bytes_to_gb "$limit_bytes")
                    if [[ "$used_bytes" =~ ^[0-9]+$ ]]; then
                        pct=$(awk "BEGIN {printf \"%.0f\", 100 * $used_bytes / $limit_bytes}" 2>/dev/null)
                        usage_text="${pct}%"
                    fi
                fi
            fi

            tui_move "$row" 2
            if (( i == selected )); then
                tui_reverse
                tui_fg "$TUI_COLOR_HIGHLIGHT"
            else
                tui_fg "$TUI_COLOR_FG"
            fi
            printf "%-16s %-12s %-10s %-10s %s" "$username" "$mp" "$quota_gb" "$usage_text" "$home"
            tui_reset
            ((row++))
        done

        tui_statusbar_draw $((TUI_LINES - 1)) \
            "托管用户 ${selected+1}/${#users[@]}" \
            "↑/↓ 滚动  Enter 详情  q 返回"

        local key
        key=$(tui_read_key 2>/dev/null) || continue
        case "$key" in
            UP|k)
                if (( selected > 0 )); then
                    ((selected--))
                    (( selected < scroll_offset )) && scroll_offset=$selected
                fi
                ;;
            DOWN|j)
                if (( selected < ${#users[@]} - 1 )); then
                    ((selected++))
                    if (( selected >= scroll_offset + max_rows )); then
                        scroll_offset=$((selected - max_rows + 1))
                    fi
                fi
                ;;
            ENTER)
                tui_run_workflow_action show_single_user_resource "${users[$selected]}"
                ;;
            q|ESC)
                running=false
                ;;
        esac
    done

    TUI_REDRAW=true
    return 0
}

tui_run_create_or_assign_user_native() {
    local username password disk_num update_existing=false install_miniforge=false
    local target_info idx mp home quota_bytes quota_input sel_df sel_avail_b sel_avail_h
    local action password_display

    acquire_lock || return 1

    if ! tui_prompt_input "创建/更新用户" "用户名" ""; then
        release_lock
        TUI_REDRAW=true
        return 1
    fi
    username="$REPLY_INPUT"

    if [[ -z "$username" ]] || ! validate_username "$username" >/dev/null 2>&1; then
        tui_message "错误" "用户名无效"
        release_lock
        return 1
    fi

    if id "$username" &>/dev/null; then
        update_existing=true
    fi

    if ! tui_prompt_select "创建/更新用户" "密码设置方式" 0 "从密码池随机选择（推荐）" "手动输入密码"; then
        release_lock
        TUI_REDRAW=true
        return 1
    fi

    case "$TUI_PROMPT_INDEX" in
        0)
            password=$(get_random_password)
            [[ -z "$password" ]] && { tui_message "错误" "无法获取随机密码"; release_lock; return 1; }
            ;;
        1)
            if ! tui_prompt_input "创建/更新用户" "手动密码" ""; then
                release_lock
                TUI_REDRAW=true
                return 1
            fi
            password="$REPLY_INPUT"
            if (( ${#password} < 8 )); then
                tui_message "错误" "密码长度至少需要 8 位"
                release_lock
                return 1
            fi
            ;;
        *)
            release_lock
            return 1
            ;;
    esac

    if ! tui_prompt_input "创建/更新用户" "磁盘编号" "1"; then
        release_lock
        TUI_REDRAW=true
        return 1
    fi
    disk_num="$REPLY_INPUT"

    target_info=$(_resolve_provision_target "$username" "$disk_num") || {
        release_lock
        return 1
    }
    IFS='|' read -r idx mp home <<< "$target_info"

    quota_bytes=$(_resolve_provision_quota "$username" "$mp" "$update_existing")

    if ! tui_prompt_input "创建/更新用户" "配额 (留空=默认)" ""; then
        release_lock
        TUI_REDRAW=true
        return 1
    fi
    quota_input="$REPLY_INPUT"
    if [[ -n "$quota_input" ]]; then
        quota_bytes=$(parse_quota_input "$quota_input")
        if [[ -z "$quota_bytes" ]]; then
            tui_message "错误" "无效的配额格式"
            release_lock
            return 1
        fi
    fi

    sel_df=$(df -B1 "$mp" 2>/dev/null | awk 'NR==2 {print $4, $5}')
    read -r sel_avail_b _ <<< "$sel_df"
    sel_avail_h=$(bytes_to_human "$sel_avail_b")

    if ! $update_existing; then
        if tui_confirm "为新用户启用 Mamba/Conda 配置？" "n"; then
            install_miniforge=true
        fi
    fi

    if ! tui_confirm "确认提交用户 $username ?" "y"; then
        release_lock
        TUI_REDRAW=true
        return 1
    fi

    tui_cleanup

    password_display=$(format_password_display "$password")
    if $update_existing; then
        action="update"
        update_user "$username" "$password" "$home" || {
            release_lock
            tui_init
            return 1
        }
    else
        action="create"
        create_user "$username" "$password" "$home" "$install_miniforge" || {
            release_lock
            tui_init
            return 1
        }
    fi

    priv_chown "$username:$username" "$home" 2>/dev/null || true
    priv_chmod 700 "$home" 2>/dev/null || true
    priv_usermod -d "$home" "$username" 2>/dev/null || true
    set_user_quota "$username" "$quota_bytes" "$mp" || {
        release_lock
        tui_init
        return 1
    }

    if $update_existing; then
        _send_password_notification "$username" "$password" "账户更新"
    else
        _send_password_notification "$username" "$password" "账户创建"
    fi

    record_user_event "$username" "$action" "用户" "$mp" "$home" "$quota_bytes"
    release_lock
    tui_init
    TUI_REDRAW=true
    return 0
}

tui_run_modify_user_quota_native() {
    local username home mp quota_info used_bytes current_limit_bytes current_limit_gb=""
    local new_quota new_quota_bytes new_quota_gb

    if ! tui_prompt_input "调整用户配额" "请输入用户名" ""; then
        TUI_REDRAW=true
        return 1
    fi
    username="$REPLY_INPUT"

    if [[ -z "$username" ]] || ! validate_username "$username" >/dev/null 2>&1 || ! id "$username" &>/dev/null; then
        tui_message "错误" "用户不存在或用户名无效"
        return 1
    fi

    home=$(get_user_home "$username")
    mp=$(get_user_mountpoint "$home")
    if [[ -z "$home" || -z "$mp" ]]; then
        tui_message "错误" "无法确定用户主目录或挂载点"
        return 1
    fi

    quota_info=$(get_user_quota_info "$username" "$mp")
    used_bytes="${quota_info%:*}"
    current_limit_bytes="${quota_info#*:}"
    if [[ "$current_limit_bytes" =~ ^[0-9]+$ ]] && (( current_limit_bytes > 0 )); then
        current_limit_gb=$(bytes_to_gb "$current_limit_bytes")
    fi

    if ! tui_prompt_input "调整用户配额" "请输入新配额 (如: 500G, 1T)" ""; then
        TUI_REDRAW=true
        return 1
    fi
    new_quota="$REPLY_INPUT"
    new_quota_bytes=$(parse_quota_input "$new_quota")
    if [[ -z "$new_quota_bytes" ]]; then
        tui_message "错误" "无效的配额格式"
        return 1
    fi

    new_quota_gb=$(bytes_to_gb "$new_quota_bytes")
    if ! tui_confirm "确认将 $username 配额改为 ${new_quota_gb}GB ?" "y"; then
        TUI_REDRAW=true
        return 1
    fi

    tui_cleanup
    set_user_quota "$username" "$new_quota_bytes" "$mp" || {
        tui_init
        return 1
    }
    record_user_event "$username" "quota_modify" "${current_limit_gb:-未知}GB -> ${new_quota_gb}GB" "$mp" "$home"
    tui_init
    TUI_REDRAW=true
    return 0
}

draw_tui_disk_quota_menu() {
    _tui_draw_menu "disk"
}

handle_tui_disk_quota_menu_key() {
    local key="$1"
    local result

    result=$(tui_menu_handle_key "$key")
    [[ -z "$result" ]] && return 0

    case "$result" in
        0) tui_run_workflow_action show_disk_overview ;;
        1) tui_run_modify_user_quota_native ;;
        2) tui_run_prompted_username_action "请输入用户名" show_single_user_resource ;;
        3) tui_run_workflow_action modify_user_resource_limits ;;
        4) tui_run_prompted_username_action "请输入用户名" show_single_user_resource ;;
        5|-1)
            TUI_SUBMENU_EXIT=1
            ;;
    esac

    return 0
}

tui_run_disk_quota_menu() {
    tui_run_native_menu draw_tui_disk_quota_menu handle_tui_disk_quota_menu_key
}

draw_tui_network_security_menu() {
    _tui_draw_menu "network"
}

# --- 防火墙子菜单 ---
draw_tui_firewall_menu() {
    _tui_draw_menu "firewall"
}

handle_tui_firewall_menu_key() {
    local key="$1"
    local result
    result=$(tui_menu_handle_key "$key")
    [[ -z "$result" ]] && return 0
    case "$result" in
        0) tui_run_prompt_sequence_action add_port_rule "用户名" "端口号" "协议 (tcp/udp)|tcp" "来源IP (可选)" ;;
        1) tui_run_prompt_sequence_action delete_port_rule "用户名" "端口号" "协议 (tcp/udp)|tcp" ;;
        2) tui_run_workflow_action list_firewall_rules ;;
        3) tui_run_prompt_sequence_action list_user_firewall_rules "用户名" ;;
        4) tui_run_workflow_action show_port_usage ;;
        5) tui_run_prompt_sequence_action add_port_range "用户名" "起始端口" "结束端口" "协议 (tcp/udp)|tcp" ;;
        6) tui_run_prompt_sequence_action apply_service_template "用户名" "服务类型 (web/database/ssh/jupyter/ml/all)" ;;
        7) tui_run_workflow_action init_ufw ;;
        8|-1) TUI_SUBMENU_EXIT=1 ;;
    esac
    return 0
}

tui_run_firewall_menu_native() {
    tui_run_native_menu draw_tui_firewall_menu handle_tui_firewall_menu_key
}

# --- DNS 子菜单 ---
draw_tui_dns_menu() {
    _tui_draw_menu "dns"
}

handle_tui_dns_menu_key() {
    local key="$1"
    local result
    result=$(tui_menu_handle_key "$key")
    [[ -z "$result" ]] && return 0
    case "$result" in
        0) tui_run_workflow_action show_dns_whitelist ;;
        1) tui_run_prompt_sequence_action add_dns_entry "请输入域名" ;;
        2) tui_run_prompt_sequence_action remove_dns_entry "请输入域名" ;;
        3) tui_run_prompt_sequence_action apply_dns_restrictions "请输入用户名" ;;
        4) tui_run_prompt_sequence_action remove_dns_restrictions "请输入用户名" ;;
        5) tui_run_prompt_sequence_action show_dns_status "请输入用户名" ;;
        6) tui_run_workflow_action apply_all_dns_restrictions ;;
        7) tui_run_workflow_action refresh_dns_rules ;;
        8|-1) TUI_SUBMENU_EXIT=1 ;;
    esac
    return 0
}

tui_run_dns_menu_native() {
    tui_run_native_menu draw_tui_dns_menu handle_tui_dns_menu_key
}

# --- 符号链接子菜单 ---
draw_tui_symlink_menu() {
    _tui_draw_menu "symlink"
}

handle_tui_symlink_menu_key() {
    local key="$1"
    local result
    result=$(tui_menu_handle_key "$key")
    [[ -z "$result" ]] && return 0
    case "$result" in
        0) tui_run_prompt_sequence_action create_user_symlink "用户名" "链接名称" "目标路径" ;;
        1) tui_run_prompt_sequence_action create_cross_disk_symlink "用户名" "目标盘号" "子目录 (可选)" ;;
        2) tui_run_prompt_sequence_action list_user_symlinks "用户名" ;;
        3) tui_run_prompt_sequence_action delete_user_symlink "用户名" "链接名称" ;;
        4) tui_run_prompt_sequence_action cleanup_broken_symlinks "用户名" ;;
        5) tui_run_prompt_sequence_action create_shared_symlink "用户名" "共享名称" "共享路径" ;;
        6) tui_run_prompt_sequence_action create_shared_for_all "共享名称" "共享路径" ;;
        7) tui_run_workflow_action show_all_symlinks_overview ;;
        8|-1) TUI_SUBMENU_EXIT=1 ;;
    esac
    return 0
}

tui_run_symlink_menu_native() {
    tui_run_native_menu draw_tui_symlink_menu handle_tui_symlink_menu_key
}

# --- SSH/Fail2ban 子菜单 ---
draw_tui_ssh_fail2ban_menu() {
    _tui_draw_menu "ssh_fail2ban"
}

handle_tui_ssh_fail2ban_menu_key() {
    local key="$1"
    local result
    result=$(tui_menu_handle_key "$key")
    [[ -z "$result" ]] && return 0
    case "$result" in
        0) tui_run_workflow_action security_baseline_sshd_summary ;;
        1) tui_run_prompt_sequence_action security_baseline_show_recent_auth_failures "最近认证失败日志行数|20" ;;
        2) tui_run_workflow_action security_baseline_show_fail2ban_status ;;
        3) tui_run_prompt_sequence_action security_baseline_configure_fail2ban_sshd_jail "bantime 秒数|600" "findtime 秒数|600" "maxretry 次数|5" ;;
        4) tui_run_workflow_action security_baseline_fail2ban_list_jails ;;
        5|-1) TUI_SUBMENU_EXIT=1 ;;
    esac
    return 0
}

tui_run_ssh_fail2ban_menu_native() {
    tui_run_native_menu draw_tui_ssh_fail2ban_menu handle_tui_ssh_fail2ban_menu_key
}

handle_tui_network_security_menu_key() {
    local key="$1"
    local result

    result=$(tui_menu_handle_key "$key")
    [[ -z "$result" ]] && return 0

    case "$result" in
        0) tui_run_firewall_menu_native ;;
        1) tui_run_dns_menu_native ;;
        2) tui_run_symlink_menu_native ;;
        3) tui_run_ssh_fail2ban_menu_native ;;
        4) tui_run_workflow_action show_network_stack_panel ;;
        5|-1)
            TUI_SUBMENU_EXIT=1
            ;;
    esac

    return 0
}

tui_run_network_security_menu() {
    tui_run_native_menu draw_tui_network_security_menu handle_tui_network_security_menu_key
}

draw_tui_backup_menu() {
    _tui_draw_menu "backup"
}

draw_tui_backup_advanced_menu() {
    _tui_draw_menu "backup_advanced"
}

handle_tui_backup_advanced_menu_key() {
    local key="$1"
    local result
    result=$(tui_menu_handle_key "$key")
    [[ -z "$result" ]] && return 0

    case "$result" in
        0) tui_run_prompt_sequence_action configure_backup_schedule "请输入用户名" "备份时间（小时，0-23）" ;;
        1) tui_run_prompt_sequence_action remove_backup_schedule "请输入用户名" ;;
        2) tui_run_workflow_action show_backup_schedules ;;
        3) tui_run_workflow_action backup_all_users ;;
        4) tui_run_workflow_action backup_all_users_parallel ;;
        5) tui_run_workflow_action show_backup_batches ;;
        6) tui_run_prompt_sequence_action restore_from_batch "批次ID (如 20251029_174643)" "要恢复的用户名" ;;
        7|-1) TUI_SUBMENU_EXIT=1 ;;
    esac

    return 0
}

tui_run_backup_advanced_menu_native() {
    tui_run_native_menu draw_tui_backup_advanced_menu handle_tui_backup_advanced_menu_key
}

handle_tui_backup_menu_key() {
    local key="$1"
    local result

    result=$(tui_menu_handle_key "$key")
    [[ -z "$result" ]] && return 0

    case "$result" in
        0) tui_run_prompt_sequence_action manual_backup_user "请输入用户名" ;;
        1) tui_run_prompt_sequence_action restore_user_backup "请输入用户名" "备份点名称 (留空=最新)" ;;
        2) tui_run_prompt_sequence_action show_backup_status "请输入用户名" ;;
        3) tui_run_workflow_action list_backup_users ;;
        4) tui_run_backup_advanced_menu_native ;;
        5|-1)
            TUI_SUBMENU_EXIT=1
            ;;
    esac

    return 0
}

tui_run_backup_menu_native() {
    tui_run_native_menu draw_tui_backup_menu handle_tui_backup_menu_key
}

draw_tui_job_stats_menu() {
    _tui_draw_menu "job_stats"
}

handle_tui_job_stats_menu_key() {
    local key="$1"
    local result
    result=$(tui_menu_handle_key "$key")
    [[ -z "$result" ]] && return 0

    case "$result" in
        0) tui_run_workflow_action collect_all_job_stats ;;
        1) tui_run_prompt_sequence_action get_weekly_job_stats "请输入用户名" ;;
        2) tui_run_prompt_sequence_action get_monthly_job_stats "请输入用户名" ;;
        3) tui_run_prompt_sequence_action collect_user_jobs "请输入用户名" ;;
        4|-1) TUI_SUBMENU_EXIT=1 ;;
    esac

    return 0
}

tui_run_job_stats_menu_native() {
    tui_run_native_menu draw_tui_job_stats_menu handle_tui_job_stats_menu_key
}

draw_tui_password_rotation_menu() {
    _tui_draw_menu "password_rotation"
}

handle_tui_password_rotation_menu_key() {
    local key="$1"
    local result
    result=$(tui_menu_handle_key "$key")
    [[ -z "$result" ]] && return 0

    case "$result" in
        0) tui_run_workflow_action show_password_rotation_status ;;
        1) tui_run_prompt_sequence_action configure_password_rotation "轮换间隔（天）|${PASSWORD_ROTATE_INTERVAL_DAYS:-90}" ;;
        2) tui_run_workflow_action remove_password_rotation ;;
        3) tui_run_workflow_action manual_password_rotation ;;
        4|-1) TUI_SUBMENU_EXIT=1 ;;
    esac

    return 0
}

tui_run_password_rotation_menu_native() {
    tui_run_native_menu draw_tui_password_rotation_menu handle_tui_password_rotation_menu_key
}

draw_tui_report_menu() {
    _tui_draw_menu "report"
}

_tui_send_user_personal_report() {
    local username="$1"
    local report_file

    report_file="$REPORT_DIR/user_${username}_$(date +%Y%m%d).html"
    if generate_user_personal_report "$username" "$report_file"; then
        send_user_report_email "$username" "$report_file"
    fi
}

handle_tui_report_menu_key() {
    local key="$1"
    local result
    result=$(tui_menu_handle_key "$key")
    [[ -z "$result" ]] && return 0

    case "$result" in
        0) tui_run_workflow_action generate_html_report ;;
        1) tui_run_workflow_action generate_user_statistics ;;
        2) tui_run_workflow_action generate_quota_report ;;
        3) tui_run_workflow_action generate_resource_report ;;
        4) tui_run_workflow_action show_user_resource_usage ;;
        5) tui_run_prompted_username_action "请输入用户名" show_single_user_resource ;;
        6) tui_run_workflow_action show_user_creation_log ;;
        7) tui_run_prompted_username_action "用户名" query_user_history ;;
        8) tui_run_prompt_sequence_action query_by_date_range "开始日期 (YYYY-MM-DD)" "结束日期 (YYYY-MM-DD)" ;;
        9) tui_run_workflow_action analyze_operation_trends ;;
        10) tui_run_workflow_action analyze_anomalies ;;
        11) tui_run_workflow_action generate_log_summary ;;
        12) tui_run_prompt_sequence_action export_full_report "输出文件 (留空=自动)" ;;
        13) tui_run_prompt_sequence_action export_users_csv "输出文件 (留空=自动)" ;;
        14) tui_run_prompted_username_action "请输入用户名" _tui_send_user_personal_report ;;
        15) tui_run_workflow_action send_all_user_reports ;;
        16) tui_run_workflow_action setup_weekly_report_cron ;;
        17) tui_run_workflow_action remove_weekly_report_cron ;;
        18) tui_run_workflow_action view_weekly_report_log ;;
        19) tui_run_workflow_action view_audit_log ;;
        20) tui_run_workflow_action show_audit_stats ;;
        21|-1) TUI_SUBMENU_EXIT=1 ;;
    esac

    return 0
}

tui_run_report_menu_native() {
    tui_run_native_menu draw_tui_report_menu handle_tui_report_menu_key
}

draw_tui_report_stats_menu() {
    _tui_draw_menu "report_stats"
}

handle_tui_report_stats_menu_key() {
    local key="$1"
    local result

    result=$(tui_menu_handle_key "$key")
    [[ -z "$result" ]] && return 0

    case "$result" in
        0) tui_run_workflow_action generate_html_report ;;
        1) tui_run_workflow_action generate_user_statistics ;;
        2) tui_run_job_stats_menu_native ;;
        3) tui_run_password_rotation_menu_native ;;
        4) tui_run_report_menu_native ;;
        5|-1)
            TUI_SUBMENU_EXIT=1
            ;;
    esac

    return 0
}

tui_run_report_stats_menu_native() {
    tui_run_native_menu draw_tui_report_stats_menu handle_tui_report_stats_menu_key
}

draw_tui_systemd_timer_menu() {
    _tui_draw_menu "systemd_timer"
}

draw_tui_compute_menu() {
    _tui_draw_menu "compute"
}

handle_tui_compute_menu_key() {
    local key="$1"
    local result
    result=$(tui_menu_handle_key "$key")
    [[ -z "$result" ]] && return 0

    case "$result" in
        0) tui_run_workflow_action list_virtual_machines ;;
        1) tui_run_prompt_sequence_action show_virtual_machine_status "虚拟机名称" ;;
        2) tui_run_workflow_action show_gpu_status ;;
        3) tui_run_workflow_action list_gpu_devices ;;
        4) tui_run_workflow_action show_gpu_processes ;;
        5|-1) TUI_SUBMENU_EXIT=1 ;;
    esac

    return 0
}

tui_run_compute_menu_native() {
    tui_run_native_menu draw_tui_compute_menu handle_tui_compute_menu_key
}

handle_tui_systemd_timer_menu_key() {
    local key="$1"
    local result
    result=$(tui_menu_handle_key "$key")
    [[ -z "$result" ]] && return 0

    case "$result" in
        0) tui_run_action system.timers.list ;;
        1) tui_run_prompt_sequence_action systemd_timer_install_profile "profile (weekly-report/account-health-check)|weekly-report" ;;
        2)
            if tui_prompt_input "Timer 日志" "timer 名称" "weekly-report"; then
                local timer_name="$REPLY_INPUT"
                if tui_prompt_input "Timer 日志" "最近日志行数" "50"; then
                    tui_run_action system.timers.logs "$timer_name" "$REPLY_INPUT"
                fi
            fi
            ;;
        3) tui_run_prompt_sequence_action systemd_timer_remove "要删除的 timer 名称|weekly-report" ;;
        4|-1) TUI_SUBMENU_EXIT=1 ;;
    esac

    return 0
}

tui_run_systemd_timer_menu_native() {
    tui_run_native_menu draw_tui_systemd_timer_menu handle_tui_systemd_timer_menu_key
}

draw_tui_system_details_menu() {
    _tui_draw_menu "system_details"
}

handle_tui_system_details_menu_key() {
    local key="$1"
    local result
    result=$(tui_menu_handle_key "$key")
    [[ -z "$result" ]] && return 0

    case "$result" in
        0) tui_run_workflow_action show_cpu_info ;;
        1) tui_run_workflow_action show_memory_info_detailed ;;
        2) tui_run_workflow_action show_disk_info ;;
        3) tui_run_workflow_action show_network_hardware_info ;;
        4) tui_run_workflow_action run_full_hardware_check ;;
        5) tui_logs_open_action logs.boot --boot 0 --lines 100 ;;
        6) tui_logs_open_action logs.failed_services ;;
        7)
            if tui_prompt_input "服务日志" "服务名 (如 ssh / docker.service)" "ssh"; then
                tui_logs_open_action logs.service_recent "$REPLY_INPUT" --lines 80
            fi
            ;;
        8) tui_logs_open_action logs.boot_error_diff --lines 100 ;;
        9) tui_run_workflow_action launch_btop_monitor ;;
        10) tui_run_workflow_action launch_htop_monitor ;;
        11) tui_run_workflow_action analyze_crash_causes ;;
        12) tui_run_workflow_action configure_oom_protection ;;
        13) tui_run_workflow_action show_network_info ;;
        14|-1) TUI_SUBMENU_EXIT=1 ;;
    esac

    return 0
}

tui_run_system_details_menu_native() {
    tui_run_native_menu draw_tui_system_details_menu handle_tui_system_details_menu_key
}

draw_tui_system_menu() {
    _tui_draw_menu "system"
}

handle_tui_system_menu_key() {
    local key="$1"
    local result

    result=$(tui_menu_handle_key "$key")
    [[ -z "$result" ]] && return 0

    case "$result" in
        0) tui_run_workflow_action show_system_info ;;
        1) tui_run_workflow_action show_memory_info ;;
        2) tui_run_workflow_action check_hardware_health ;;
        3) tui_run_workflow_action analyze_system_logs ;;
        4) tui_run_workflow_action show_ubuntu_maintenance_panel ;;
        5) tui_run_workflow_action show_network_stack_panel ;;
        6) tui_run_systemd_timer_menu_native ;;
        7) tui_run_system_details_menu_native ;;
        8) tui_run_compute_menu_native ;;
        9|-1)
            TUI_SUBMENU_EXIT=1
            ;;
    esac

    return 0
}

tui_run_system_menu_native() {
    tui_run_native_menu draw_tui_system_menu handle_tui_system_menu_key
}

draw_tui_audit_advanced_menu() {
    _tui_draw_menu "audit_advanced"
}

handle_tui_audit_advanced_menu_key() {
    local key="$1"
    local result
    result=$(tui_menu_handle_key "$key")
    [[ -z "$result" ]] && return 0

    case "$result" in
        0) tui_run_prompt_sequence_action audit_query "操作类型 (留空=全部)" "用户名 (留空=全部)" "日期范围 (YYYY-MM-DD 或 YYYY-MM-DD:YYYY-MM-DD, 留空=全部)" ;;
        1) tui_run_workflow_action show_audit_stats ;;
        2) tui_run_workflow_action audit_rotate ;;
        3) tui_run_workflow_action view_journald_audit_log ;;
        4|-1) TUI_SUBMENU_EXIT=1 ;;
    esac

    return 0
}

tui_run_audit_advanced_menu_native() {
    tui_run_native_menu draw_tui_audit_advanced_menu handle_tui_audit_advanced_menu_key
}

draw_tui_audit_menu() {
    _tui_draw_menu "audit"
}

handle_tui_audit_menu_key() {
    local key="$1"
    local result

    result=$(tui_menu_handle_key "$key")
    [[ -z "$result" ]] && return 0

    case "$result" in
        0) tui_run_workflow_action view_audit_log ;;
        1) tui_run_workflow_action show_audit_stats ;;
        2) tui_run_workflow_action view_journald_audit_log ;;
        3) tui_run_audit_advanced_menu_native ;;
        4|-1)
            TUI_SUBMENU_EXIT=1
            ;;
    esac

    return 0
}

tui_run_audit_menu_native() {
    tui_run_native_menu draw_tui_audit_menu handle_tui_audit_menu_key
}

handle_main_menu_key() {
    local key="$1"
    local result

    result=$(tui_menu_handle_key "$key")
    if [[ -z "$result" ]]; then
        return 0
    fi
    
    case "$result" in
        0) tui_run_user_management_menu ;;
        1) tui_run_disk_quota_menu ;;
        2) tui_run_network_security_menu ;;
        3) tui_run_backup_menu_native ;;
        4) tui_run_report_stats_menu_native ;;
        5) tui_run_system_menu_native ;;
        6) tui_run_audit_menu_native ;;
        7) run_monitor_view ;;
        8) run_log_viewer ;;
        9|-1) TUI_RUNNING=false ;;
    esac

    TUI_REDRAW=true
}

run_monitor_view() {
    local running=true

    while $running; do
        tui_clear

        tui_draw_fill 0 0 "$TUI_COLS" 3 39
        tui_fg 0
        tui_move 1 $(( (TUI_COLS - 20) / 2 ))
        tui_bold
        echo "实时系统监控"
        tui_reset

        local cpu_usage
        cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print int($2)}' 2>/dev/null || echo "0")
        tui_progress_draw 5 5 $((TUI_COLS - 10)) "$cpu_usage" "CPU"

        local mem_usage mem_total mem_used
        if command -v free &>/dev/null; then
            mem_usage=$(free | grep Mem | awk '{printf "%.0f", $3/$2 * 100}')
            mem_total=$(free -h | grep Mem | awk '{print $2}')
            mem_used=$(free -h | grep Mem | awk '{print $3}')
        else
            mem_usage=0
            mem_total="?"
            mem_used="?"
        fi
        tui_progress_draw 7 5 $((TUI_COLS - 10)) "$mem_usage" "内存 ($mem_used/$mem_total)"

        local disk_usage disk_total
        disk_usage=$(df -h / | awk 'END{gsub(/%/, "", $5); print $5}' 2>/dev/null || echo "0")
        disk_total=$(df -h / | awk 'END{print $2}' 2>/dev/null || echo "?")
        tui_progress_draw 9 5 $((TUI_COLS - 10)) "$disk_usage" "磁盘 ($disk_total)"

        tui_move 12 5
        tui_bold
        tui_fg "$TUI_COLOR_ACCENT"
        echo "进程状态:"
        tui_reset

        local procs
        procs=$(ps aux --sort=-%mem 2>/dev/null | sed -n '2,6p')
        tui_move 13 5
        printf "%-10s %-8s %-6s %-6s %s\n" "USER" "PID" "CPU%" "MEM%" "COMMAND"
        tui_move 14 5
        echo "$procs" | while read -r line; do
            printf "%-10s %-8s %-6s %-6s %s\n" $line
        done

        tui_move $((TUI_LINES - 2)) 5
        tui_fg "$TUI_COLOR_MUTED"
        echo "按 b 启动 btop | n 启动 ncdu | q 返回"
        tui_reset

        local key
        key=$(tui_read_key 2>/dev/null) || continue

        case "$key" in
            b|B)
                tui_cleanup
                if command -v btop &>/dev/null; then
                    btop
                elif command -v htop &>/dev/null; then
                    htop
                else
                    tui_message "错误" "未安装 btop 或 htop"
                fi
                tui_init
                ;;
            n|N)
                tui_cleanup
                if command -v ncdu &>/dev/null; then
                    ncdu /
                else
                    tui_message "错误" "未安装 ncdu"
                fi
                tui_init
                ;;
            q|ESC)
                running=false
                ;;
        esac
    done
}

main() {
    check_dependencies || exit 1
    load_config || exit 1
    setup_trap_handler

    tui_init
    tui_run draw_main_menu handle_main_menu_key
    tui_cleanup
}

if [[ "${TUI_MANAGER_NO_MAIN:-0}" != "1" && "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
