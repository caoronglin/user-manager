#!/bin/bash
# controller_user_limits.sh - 用户配额与资源限制控制器

# --- 修改用户配额 ---
modify_user_quota() {
    draw_header "调整用户配额"

    read_existing_username || return 1
    local username="$REPLY_INPUT"

    local home mp
    home=$(get_user_home "$username")
    if [[ -z "$home" ]]; then
        msg_err "无法获取用户 '$username' 的主目录"; return 1
    fi
    mp=$(get_user_mountpoint "$home")
    if [[ -z "$mp" ]]; then
        msg_err "无法确定用户 '$username' 的挂载点"; return 1
    fi

    echo ""
    draw_info_card "用户名:" "$username" "$C_BOLD"
    draw_info_card "主目录:" "$home"
    draw_info_card "挂载点:" "$mp"

    local quota_info used_bytes current_limit_bytes current_limit_gb=""
    quota_info=$(get_user_quota_info "$username" "$mp")
    used_bytes="${quota_info%:*}"
    current_limit_bytes="${quota_info#*:}"

    if [[ "$current_limit_bytes" =~ ^[0-9]+$ ]] && (( current_limit_bytes > 0 )); then
        current_limit_gb=$(bytes_to_gb "$current_limit_bytes")
        local pct
        pct=$(awk "BEGIN {printf \"%.0f\", 100 * $used_bytes / $current_limit_bytes}" 2>/dev/null)
        draw_info_card "当前配额:" "${current_limit_gb} GB" "$C_BOLD"
        printf "  ${C_DIM}%-16s${C_RESET} " "使用情况:"
        draw_usage_bar "$pct" 20
        echo ""
    else
        draw_info_card "当前配额:" "未设置" "$C_RESET"
    fi

    echo ""
    read_input "请输入新配额 (如: 500G, 1T)"; local new_quota="$REPLY_INPUT"
    local new_quota_bytes
    new_quota_bytes=$(parse_quota_input "$new_quota")

    if [[ -z "$new_quota_bytes" ]]; then
        msg_err "无效的配额格式"; return 1
    fi

    local new_quota_gb
    new_quota_gb=$(bytes_to_gb "$new_quota_bytes")

    echo ""
    draw_header "配额修改确认"
    draw_info_card "用户:" "$username" "$C_BOLD"
    draw_info_card "原配额:" "${current_limit_gb:-未知} GB" "$C_RESET"
    draw_info_card "新配额:" "${new_quota_gb} GB" "$C_BGREEN"
    echo ""

    if confirm_action "确认修改？"; then
        set_user_quota "$username" "$new_quota_bytes" "$mp"
        msg_ok "配额已更新"
        record_user_event "$username" "quota_modify" "${current_limit_gb:-未知}GB -> ${new_quota_gb}GB" "$mp" "$home"
    else
        msg_info "已取消"
    fi
}

# --- 修改资源限制 ---
modify_user_resource_limits() {
    draw_header "配置资源限制"

    read_existing_username || return 1
    local username="$REPLY_INPUT"

    local current_limits
    current_limits=$(get_current_resource_limits "$username")

    if [[ -n "$current_limits" ]]; then
        local current_cpu="${current_limits%:*}"
        local current_memory="${current_limits#*:}"
        echo ""
        draw_info_card "CPU 配额:" "${current_cpu:-未设置}" "$C_RESET"
        draw_info_card "内存限制:" "${current_memory:-未设置}" "$C_RESET"
    else
        echo ""
        msg_info "当前未设置资源限制"
    fi

    echo ""
    draw_menu_item 1 "设置资源限制"
    draw_menu_item 2 "移除资源限制"
    draw_menu_item 3 "取消"
    draw_prompt
    read -r choice

    case $choice in
        1)
            read_input "CPU 配额 (如: 50%, 200%)"; local cpu_quota="$REPLY_INPUT"
            validate_cpu_quota "$cpu_quota" || return 1
            read_input "内存限制 (如: 8G, 16G)"; local memory_limit="$REPLY_INPUT"
            validate_memory_limit "$memory_limit" || return 1
            configure_resource_limits "$username" "$cpu_quota" "$memory_limit"
            msg_ok "资源限制已设置"
            record_user_event "$username" "resource_set" "CPU:$cpu_quota MEM:$memory_limit"
            ;;
        2)
            local uid
            uid=$(id -u "$username")
            remove_resource_limits "$uid"
            msg_ok "资源限制已移除"
            record_user_event "$username" "resource_remove" "移除资源限制"
            ;;
        *)
            msg_info "已取消"
            ;;
    esac
}
