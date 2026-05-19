#!/bin/bash
# controller_user_provisioning_support.sh - 用户创建与更新辅助控制器

_display_available_data_disks() {
    local disk_num_iter idx_iter mp_iter
    local all_managed_users=()
    mapfile -t all_managed_users < <(get_managed_usernames 2>/dev/null)

    echo ""
    msg_info "${C_BOLD}可用数据盘概览:${C_RESET}"
    printf "  ${C_DIM}%-6s %-16s %-10s %-10s %-10s %-6s %-22s${C_RESET}\n" \
        "编号" "挂载点" "总容量" "已用" "可用" "用户" "使用率"
    draw_line 85

    for disk_num_iter in "${ALL_DISKS[@]}"; do
        idx_iter=$(printf "%02d" "$disk_num_iter")
        mp_iter="$DATA_BASE/data${idx_iter}"

        if ! mountpoint -q "$mp_iter" 2>/dev/null; then
            printf "  ${C_DIM}[%s]  data%s  — 未挂载 —${C_RESET}\n" "$disk_num_iter" "$idx_iter"
            continue
        fi

        local df_out total_b used_b avail_b pct_used
        df_out=$(df -B1 "$mp_iter" 2>/dev/null | awk 'NR==2 {print $2, $3, $4, $5}')
        read -r total_b used_b avail_b pct_used <<< "$df_out"
        pct_used=${pct_used%%%}
        [[ "$pct_used" =~ ^[0-9]+$ ]] || pct_used=0

        local total_h used_h avail_h
        total_h=$(bytes_to_human "$total_b")
        used_h=$(bytes_to_human "$used_b")
        avail_h=$(bytes_to_human "$avail_b")

        local user_count_on_disk=0
        for mu in "${all_managed_users[@]}"; do
            local mh
            mh=$(get_user_home "$mu" 2>/dev/null)
            [[ "$mh" == "${mp_iter}/"* ]] && ((user_count_on_disk+=1))
        done

        local disk_color="$C_BGREEN"
        if (( pct_used >= 90 )); then
            disk_color="$C_BRED"
        elif (( pct_used >= 70 )); then
            disk_color="$C_RESET"
        fi

        printf "  ${C_RESET}[%s]${C_RESET}  %-14s %-10s %-10s ${disk_color}%-10s${C_RESET} %-6s " \
            "$disk_num_iter" "data${idx_iter}" "$total_h" "$used_h" "$avail_h" "$user_count_on_disk"
        draw_usage_bar "$pct_used" 14
        echo ""
    done
}

_resolve_provision_target() {
    local username="$1"
    local disk_num="$2"

    if ! [[ " ${ALL_DISKS[*]} " =~ ${disk_num} ]]; then
        msg_err "无效的磁盘编号"
        return 1
    fi

    local idx mp home
    idx=$(printf "%02d" "$disk_num")
    mp="$DATA_BASE/data$idx"
    home="$mp/$username"

    if ! mountpoint -q "$mp" 2>/dev/null; then
        msg_err "目标磁盘 $mp 未挂载"
        return 1
    fi

    printf '%s|%s|%s\n' "$idx" "$mp" "$home"
}

_resolve_provision_quota() {
    local username="$1"
    local mp="$2"
    local update_existing="$3"
    local quota_bytes="$QUOTA_DEFAULT"

    if [[ "$update_existing" == "true" ]]; then
        local current_qi current_limit
        current_qi=$(get_user_quota_info "$username" "$mp" 2>/dev/null)
        current_limit="${current_qi#*:}"
        if [[ "$current_limit" =~ ^[0-9]+$ ]] && (( current_limit > 0 )); then
            quota_bytes="$current_limit"
        fi
    fi

    printf '%s\n' "$quota_bytes"
}

_render_provision_confirmation() {
    local username="$1"
    local password="$2"
    local home="$3"
    local quota_bytes="$4"
    local sel_avail_h="$5"
    local idx="$6"

    echo ""
    draw_header "操作确认"
    draw_info_card "用户名:" "$username" "$C_BOLD"
    local password_display
    password_display=$(format_password_display "$password")
    if show_passwords_enabled; then
        draw_info_card "密码:" "$password_display" "$C_BOLD"
    else
        draw_info_card "密码:" "$password_display" "$C_DIM"
    fi
    draw_info_card "主目录:" "$home"
    draw_info_card "配额:" "$(bytes_to_gb "$quota_bytes") GB" "$C_BGREEN"
    draw_info_card "磁盘剩余:" "$sel_avail_h (data${idx})" "$C_RESET"
    echo ""
}
