#!/bin/bash
# resource_core.sh - 资源配额管理模块 v6.0
# 提供 CPU/内存配额管理（systemd cgroup + ulimit）

# ============================================================
# ulimit 常量定义
# ============================================================

# 资源限制类型映射
readonly ULIMIT_SOFT="soft"
readonly ULIMIT_HARD="hard"

# 标准 ulimit 资源类型
readonly ULIMIT_TYPES=(
    "core"      # 核心文件大小
    "data"      # 数据段大小
    "fsize"     # 文件大小
    "memlock"   # 锁定内存
    "nofile"    # 打开文件数
    "nproc"     # 进程数
    "rss"       # 驻留集大小
    "stack"     # 栈大小
    "cpu"       # CPU 时间
)

# ============================================================
# ulimit 查询和设置函数
# ============================================================

# 获取指定用户的 ulimit 值
get_user_ulimit() {
    local username="$1"
    local resource="${2:-nofile}"
    local limit_type="${3:-soft}"
    
    # 验证用户存在
    if ! id "$username" &>/dev/null; then
        msg_err "用户不存在: $username"
        return 1
    fi
    
    # 使用 sudo 获取用户 ulimit
    local cmd="ulimit -${resource}"
    [[ "$limit_type" == "hard" ]] && cmd="ulimit -H -${resource}"
    
    local result
    result=$(sudo -u "$username" bash -c "$cmd" 2>&1) || {
        msg_err "获取 ulimit 失败: $result"
        return 1
    }
    
    echo "$result"
}

# 设置指定用户的 ulimit 值（通过 limits.d 配置）
set_user_ulimit() {
    local username="$1"
    local resource="$2"
    local soft_limit="$3"
    local hard_limit="${4:-$3}"
    
    # 验证用户存在
    if ! id "$username" &>/dev/null; then
        msg_err "用户不存在: $username"
        return 1
    fi
    
    # 创建 limits.d 配置文件
    local limits_file="/etc/security/limits.d/90-user-manager-${username}.conf"
    
    # 读取现有配置
    local existing_config=""
    if [[ -f "$limits_file" ]]; then
        existing_config=$(grep -v "^#" "$limits_file" 2>/dev/null | grep -v "^${username}\s*${resource}\s*" || true)
    fi
    
    # 写入新配置
    {
        echo "# 由 user-manager 自动生成 - 用户 $username 的资源限制"
        echo "# 更新时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        # 保留其他资源类型的配置
        if [[ -n "$existing_config" ]]; then
            echo "$existing_config"
            echo ""
        fi
        # 添加新的限制
        echo "$username    ${soft_limit}    ${resource}"
        [[ "$soft_limit" != "$hard_limit" ]] && echo "$username    ${hard_limit}    ${resource}"
    } | run_privileged tee "$limits_file" > /dev/null
    
    msg_ok "ulimit 已设置: $username - $resource (soft: $soft_limit, hard: $hard_limit)"
    msg_warn "用户需要重新登录才能生效"
    
    return 0
}

# 删除用户的 ulimit 配置
remove_user_ulimit() {
    local username="$1"
    local resource="${2:-}"
    
    local limits_file="/etc/security/limits.d/90-user-manager-${username}.conf"
    
    if [[ ! -f "$limits_file" ]]; then
        msg_info "用户 $username 没有 ulimit 配置"
        return 0
    fi
    
    if [[ -n "$resource" ]]; then
        # 删除特定资源的配置
        local temp_file
        temp_file=$(mktemp)
        grep -v "^${username}\s*\(soft\|hard\)\s*${resource}\s*$" "$limits_file" > "$temp_file"
        run_privileged mv "$temp_file" "$limits_file"
        msg_ok "已移除资源 $resource 的 ulimit 配置"
    else
        # 删除整个配置文件
        run_privileged rm -f "$limits_file"
        msg_ok "已移除用户 $username 的所有 ulimit 配置"
    fi
    
    return 0
}

# 显示用户的所有 ulimit 设置
show_user_ulimits() {
    local username="$1"
    
    if ! id "$username" &>/dev/null; then
        msg_err "用户不存在: $username"
        return 1
    fi
    
    draw_header "用户 $username 的 ulimit 设置"
    
    printf "  ${C_BOLD}${C_WHITE}%-18s %-18s %-18s${C_RESET}\n" \
        "资源类型" "软限制" "硬限制"
    draw_line 60
    
    local resource
    for resource in "${ULIMIT_TYPES[@]}"; do
        local soft_val hard_val display_val
        
        soft_val=$(get_user_ulimit "$username" "$resource" "soft" 2>/dev/null || echo "N/A")
        hard_val=$(get_user_ulimit "$username" "$resource" "hard" 2>/dev/null || echo "N/A")
        
        # 格式化显示
        if [[ "$soft_val" == "unlimited" || "$soft_val" == "N/A" ]]; then
            display_soft="${C_DIM}$soft_val${C_RESET}"
        else
            display_soft="${C_BCYAN}$soft_val${C_RESET}"
        fi
        
        if [[ "$hard_val" == "unlimited" || "$hard_val" == "N/A" ]]; then
            display_hard="${C_DIM}$hard_val${C_RESET}"
        else
            display_hard="${C_BCYAN}$hard_val${C_RESET}"
        fi
        
        printf "  %-18s %b %b\n" "$resource" "$display_soft" "$display_hard"
    done
    
    echo ""
    
    # 显示 limits.d 配置
    local limits_file="/etc/security/limits.d/90-user-manager-${username}.conf"
    if [[ -f "$limits_file" ]]; then
        msg_info "limits.d 配置文件内容:"
        echo "${C_DIM}"
        cat "$limits_file" | sed 's/^/  /'
        echo "${C_RESET}"
    fi
    
    return 0
}

# 显示所有用户的 ulimit 概览
show_all_ulimits_overview() {
    draw_header "所有用户的 ulimit 概览"
    
    local managed_users=()
    mapfile -t managed_users < <(get_managed_usernames 2>/dev/null)
    
    if (( ${#managed_users[@]} == 0 )); then
        msg_info "暂无托管用户"
        return 0
    fi
    
    printf "  ${C_BOLD}${C_WHITE}%-18s %-15s %-15s %-15s${C_RESET}\n" \
        "用户名" "打开文件数" "进程数" "配置状态"
    draw_line 70
    
    local username
    for username in "${managed_users[@]}"; do
        local nofile nproc config_status
        
        nofile=$(get_user_ulimit "$username" "nofile" "soft" 2>/dev/null || echo "?")
        nproc=$(get_user_ulimit "$username" "nproc" "soft" 2>/dev/null || echo "?")
        
        if [[ -f "/etc/security/limits.d/90-user-manager-${username}.conf" ]]; then
            config_status="${C_BGREEN}已配置${C_RESET}"
        else
            config_status="${C_DIM}默认${C_RESET}"
        fi
        
        printf "  %-18s %-15s %-15s %b\n" "$username" "$nofile" "$nproc" "$config_status"
    done
    
    echo ""
    msg_info "共 ${#managed_users[@]} 个用户"
    
    return 0
}

# ============================================================
# 进程资源查看函数
# ============================================================

# 显示用户的进程资源使用情况
show_user_process_resources() {
    local username="$1"
    
    if ! id "$username" &>/dev/null; then
        msg_err "用户不存在: $username"
        return 1
    fi
    
    draw_header "用户 $username 的进程资源使用情况"
    
    # 获取进程信息
    local ps_output
    ps_output=$(ps -u "$username" -o pid,pcpu,pmem,nlwp,comm --sort=-pcpu 2>/dev/null | head -20)
    
    if [[ -z "$ps_output" ]]; then
        msg_info "该用户没有运行中的进程"
        return 0
    fi
    
    printf "  ${C_BOLD}${C_WHITE}%-8s %-8s %-8s %-8s %s${C_RESET}\n" \
        "PID" "CPU%" "MEM%" "线程" "命令"
    draw_line 60
    
    echo "$ps_output" | tail -n +2 | while read -r pid pcpu pmem nlwp comm; do
        printf "  %-8s %-8s %-8s %-8s %s\n" "$pid" "$pcpu" "$pmem" "$nlwp" "$comm"
    done
    
    echo ""
    
    # 汇总信息
    local total_procs total_threads
    total_procs=$(ps -u "$username" --no-headers 2>/dev/null | wc -l)
    total_threads=$(ps -u "$username" -o nlwp --no-headers 2>/dev/null | awk '{sum+=$1} END {print sum}')
    
    msg_info "进程总数: ${C_BCYAN}${total_procs}${C_RESET}  线程总数: ${C_BCYAN}${total_threads}${C_RESET}"
    
    return 0
}

# ============================================================
# 查询资源限制（保留原有函数）
# ============================================================
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
