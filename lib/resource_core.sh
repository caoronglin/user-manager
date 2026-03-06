#!/bin/bash
# resource_core.sh - 资源配额管理模块 v5.0
# 提供 CPU/内存配额管理（systemd cgroup）

# ============================================================
# 查询资源限制
# ============================================================

get_current_resource_limits() {
    local username="$1"
    local uid config_file
    uid=$(id -u "$username" 2>/dev/null) || return 1
    config_file="/etc/systemd/system/user@${uid}.service.d/$RESOURCE_LIMIT_FILENAME"

    if [[ -f "$config_file" ]]; then
        local cpu memory
        cpu=$(awk -F= '/^CPUQuota=/ {print $2}' "$config_file")
        memory=$(awk -F= '/^MemoryMax=/ {print $2}' "$config_file")
        printf '%s:%s\n' "${cpu:-}" "${memory:-}"
    else
        printf ':\n'
    fi
}

# ============================================================
# 配置资源限制
# ============================================================

configure_resource_limits() {
    local username="$1" cpu_quota="$2" memory_limit="$3"
    local uid unit_dir config_file

    uid=$(id -u "$username" 2>/dev/null) || {
        msg_err "无法获取用户 $username 的 UID"
        return 1
    }

    unit_dir="/etc/systemd/system/user@${uid}.service.d"
    config_file="$unit_dir/$RESOURCE_LIMIT_FILENAME"

    if [[ -z "$cpu_quota" && -z "$memory_limit" ]]; then
        remove_resource_limits "$uid"
        return 0
    fi

    run_privileged mkdir -p "$unit_dir" || {
        msg_err "无法创建配置目录: $unit_dir"
        return 1
    }

    {
        echo "[Service]"
        [[ -n "$cpu_quota" ]]     && echo "CPUQuota=$cpu_quota"
        [[ -n "$memory_limit" ]]  && echo "MemoryMax=$memory_limit"
    } | run_privileged tee "$config_file" > /dev/null

    priv_systemctl daemon-reload 2>/dev/null || true

    msg_ok "资源限制已配置: ${C_BOLD}$username${C_RESET}"
    [[ -n "$cpu_quota" ]]     && msg_step "CPU 配额: ${C_BCYAN}$cpu_quota${C_RESET}"
    [[ -n "$memory_limit" ]]  && msg_step "内存限制: ${C_BCYAN}$memory_limit${C_RESET}"

    return 0
}

# ============================================================
# 移除资源限制
# ============================================================

remove_resource_limits() {
    local uid="$1"
    local unit_dir="/etc/systemd/system/user@${uid}.service.d"
    local config_file="$unit_dir/$RESOURCE_LIMIT_FILENAME"

    if [[ -f "$config_file" ]]; then
        run_privileged rm -f "$config_file"
        if [[ -d "$unit_dir" ]]; then
            local remaining
            remaining=$(find "$unit_dir" -mindepth 1 2>/dev/null | head -1)
            if [[ -z "$remaining" ]]; then
                run_privileged rmdir "$unit_dir" 2>/dev/null || true
            fi
        fi
        priv_systemctl daemon-reload 2>/dev/null || true
        msg_ok "已移除 UID=$uid 的资源限制"
    fi
    return 0
}

# ============================================================
# 资源概览（彩色表格）
# ============================================================

show_resource_overview() {
    draw_header "资源限制概览"

    local managed_users=()
    mapfile -t managed_users < <(get_managed_usernames)

    if (( ${#managed_users[@]} == 0 )); then
        msg_info "暂无托管用户"
        return 0
    fi

    printf "  ${C_BOLD}${C_WHITE}%-18s %-12s %-12s %-8s${C_RESET}\n" \
        "用户名" "CPU 配额" "内存限制" "状态"
    draw_line 52

    local configured=0
    for username in "${managed_users[@]}"; do
        local limits
        limits=$(get_current_resource_limits "$username" 2>/dev/null)

        local cpu="${limits%%:*}"
        local memory="${limits#*:}"

        local status_badge
        if [[ -n "$cpu" || -n "$memory" ]]; then
            status_badge="${C_BGREEN}已配置${C_RESET}"
            ((configured+=1))
        else
            status_badge="${C_DIM}未设置${C_RESET}"
        fi

        printf "  %-18s " "$username"
        if [[ -n "$cpu" ]]; then
            printf "${C_BCYAN}%-12s${C_RESET} " "$cpu"
        else
            printf "${C_DIM}%-12s${C_RESET} " "-"
        fi
        if [[ -n "$memory" ]]; then
            printf "${C_BCYAN}%-12s${C_RESET} " "$memory"
        else
            printf "${C_DIM}%-12s${C_RESET} " "-"
        fi
        echo -e "$status_badge"
    done

    echo ""
    msg_info "共 ${#managed_users[@]} 个用户，${configured} 个已配置资源限制"
}
