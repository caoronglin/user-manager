#!/bin/bash
# controller_user_listing.sh - 用户列表展示控制器

# --- 列出所有托管用户 ---
list_managed_users() {
    draw_header "托管用户列表"

    local all_managed_users=()
    mapfile -t all_managed_users < <(get_managed_usernames)

    if (( ${#all_managed_users[@]} == 0 )); then
        msg_warn "当前无任何托管用户"
        return 0
    fi

    # 表头
    printf "  ${C_BOLD}${C_WHITE}%-18s %-14s %-10s %-24s %s${C_RESET}\n" \
        "用户名" "挂载点" "配额(GB)" "使用情况" "主目录"
    draw_line 90

    for username in "${all_managed_users[@]}"; do
        local home
        home=$(get_user_home "$username")
        [[ -z "$home" ]] && continue

        local mp
        mp=$(get_user_mountpoint "$home" 2>/dev/null || echo "N/A")

        local quota_gb="未设置" usage_col="-"
        if [[ "$mp" != "N/A" ]]; then
            local quota_info
            quota_info=$(get_user_quota_info "$username" "$mp")
            local used_bytes="${quota_info%:*}"
            local limit_bytes="${quota_info#*:}"

            if [[ "$limit_bytes" =~ ^[0-9]+$ ]] && (( limit_bytes > 0 )); then
                quota_gb=$(bytes_to_gb "$limit_bytes")
                if [[ "$used_bytes" =~ ^[0-9]+$ ]]; then
                    local pct
                    pct=$(awk "BEGIN {printf \"%.0f\", 100 * $used_bytes / $limit_bytes}" 2>/dev/null)
                    usage_col=$(draw_usage_bar "$pct" 16)
                else
                    usage_col=$(draw_usage_bar 0 16)
                fi
            fi
        fi

        printf "  %-18s %-14s %-10s " "$username" "$mp" "$quota_gb"
        echo -e "${usage_col}  ${C_DIM}${home}${C_RESET}"
    done
    echo ""
}
