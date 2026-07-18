#!/bin/bash
# resource_core.sh - 资源配额管理模块 v6.0
# 提供 CPU/内存配额管理（systemd cgroup + ulimit）

# ============================================================
# ulimit 常量定义
# ============================================================

# 资源限制类型映射

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

# 以指定用户身份执行命令（最小权限封装）
# 用法：as_user <username> <command> [args...]
# 使用受控 sudo -u 切换到已存在用户，不暴露通用 priv_sudo trampoline。
as_user() {
    local username="$1"
    shift
    
    # 验证参数
    [[ -z "$username" ]] && { msg_err "as_user: 用户名不能为空"; return 1; }
    [[ $# -eq 0 ]] && { msg_err "as_user: 命令不能为空"; return 1; }
    
    # 检查用户是否存在
    if ! id "$username" &>/dev/null; then
        msg_err "as_user: 用户不存在: $username"
        return 1
    fi
    
    # 执行命令
    if [[ "${SUDO_NONINTERACTIVE:-0}" == "1" ]]; then
        sudo -n -u "$username" "$@" 2>&1
    else
        sudo -u "$username" "$@" 2>&1
    fi
}

# 将资源名称映射到 ulimit 选项字母
# 标准映射：nofile->n, nproc->u, stack->s, cpu->t, etc.
_ulimit_opt_from_resource() {
    local resource="$1"
    case "$resource" in
        core)   echo "c" ;;
        data)   echo "d" ;;
        fsize)  echo "f" ;;
        memlock)echo "l" ;;
        nofile) echo "n" ;;
        nproc)  echo "u" ;;
        rss)    echo "m" ;;
        stack)  echo "s" ;;
        cpu)    echo "t" ;;
        *)      echo "n" ;; # 默认使用 nofile (n)
    esac
}

# 获取指定用户的 ulimit 值（修复版）
get_user_ulimit() {
    local username="$1"
    local resource="${2:-nofile}"
    local limit_type="${3:-soft}"
    
    # 验证用户存在
    if ! id "$username" &>/dev/null; then
        msg_err "用户不存在: $username"
        return 1
    fi
    
    # 将资源名称映射到 ulimit 选项字母
    local opt
    opt=$(_ulimit_opt_from_resource "$resource")
    
    # 构建 ulimit 命令
    local cmd="ulimit -${opt}"
    [[ "$limit_type" == "hard" ]] && cmd="ulimit -H -${opt}"
    
    # 使用最小权限封装执行（替代直接 sudo -u）
    local result
    result=$(as_user "$username" bash -c "$cmd" 2>&1) || {
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
    local rendered_config
    rendered_config=$(
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
    })

    printf '%s' "$rendered_config" | write_privileged_text_file "$limits_file" "0644" "root:root" || return 1
    
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
        local filtered_config
        filtered_config=$(grep -v "^${username}\s*\(soft\|hard\)\s*${resource}\s*$" "$limits_file" 2>/dev/null || true)
        if [[ -n "${filtered_config//[[:space:]]/}" ]]; then
            printf '%s' "$filtered_config" | write_privileged_text_file "$limits_file" "0644" "root:root" || return 1
        else
            priv_rm -f "$limits_file" || return 1
        fi
        msg_ok "已移除资源 $resource 的 ulimit 配置"
    else
        # 删除整个配置文件
        priv_rm -f "$limits_file"
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
        local soft_val hard_val
        
        soft_val=$(get_user_ulimit "$username" "$resource" "soft" 2>/dev/null || echo "N/A")
        hard_val=$(get_user_ulimit "$username" "$resource" "hard" 2>/dev/null || echo "N/A")
        
        # 格式化显示
        if [[ "$soft_val" == "unlimited" || "$soft_val" == "N/A" ]]; then
            display_soft="${C_DIM}$soft_val${C_RESET}"
        else
            display_soft="${C_RESET}$soft_val${C_RESET}"
        fi
        
        if [[ "$hard_val" == "unlimited" || "$hard_val" == "N/A" ]]; then
            display_hard="${C_DIM}$hard_val${C_RESET}"
        else
            display_hard="${C_RESET}$hard_val${C_RESET}"
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
    
    msg_info "进程总数: ${C_RESET}${total_procs}${C_RESET}  线程总数: ${C_RESET}${total_threads}${C_RESET}"
    
    return 0
}

# ============================================================
# 查询资源限制
# ============================================================

# 获取当前资源限制（通过 systemd cgroup v2 slice drop-in 配置）
rl_resource_unit_base() {
    printf '%s\n' "${USER_MANAGER_RESOURCE_LIMIT_UNIT_BASE:-${RL_RESOURCE_LIMIT_UNIT_BASE:-/etc/systemd/system}}"
}

rl_resource_slice_dir() {
    local rl_uid="$1"
    printf '%s/user-%s.slice.d\n' "$(rl_resource_unit_base)" "$rl_uid"
}

rl_resource_config_file() {
    local rl_uid="$1"
    printf '%s/%s\n' "$(rl_resource_slice_dir "$rl_uid")" "${RESOURCE_LIMIT_FILENAME:-90-user-manager-limits.conf}"
}

rl_resource_user_slice_unit() {
    local rl_uid="$1"
    [[ "$rl_uid" =~ ^[0-9]+$ ]] || return 1
    printf 'user-%s.slice\n' "$rl_uid"
}

rl_resource_apply_runtime_limits() {
    local rl_uid="$1" rl_cpu_quota="${2:-}" rl_memory_limit="${3:-}"
    local rl_unit
    rl_unit="$(rl_resource_user_slice_unit "$rl_uid")" || return 1

    local rl_memory_high rl_tasks_max rl_io_read_bandwidth_max rl_io_write_bandwidth_max
    rl_memory_high="${USER_MANAGER_RESOURCE_MEMORY_HIGH:-${RL_RESOURCE_MEMORY_HIGH:-}}"
    rl_tasks_max="${USER_MANAGER_RESOURCE_TASKS_MAX:-${RL_RESOURCE_TASKS_MAX:-4096}}"
    rl_io_read_bandwidth_max="${USER_MANAGER_RESOURCE_IO_READ_BANDWIDTH_MAX:-${RL_RESOURCE_IO_READ_BANDWIDTH_MAX:-}}"
    rl_io_write_bandwidth_max="${USER_MANAGER_RESOURCE_IO_WRITE_BANDWIDTH_MAX:-${RL_RESOURCE_IO_WRITE_BANDWIDTH_MAX:-}}"

    local -a rl_properties=(
        "CPUAccounting=yes"
        "MemoryAccounting=yes"
        "TasksAccounting=yes"
    )
    [[ -n "$rl_cpu_quota" ]] && rl_properties+=("CPUQuota=$rl_cpu_quota")
    [[ -n "$rl_memory_high" ]] && rl_properties+=("MemoryHigh=$rl_memory_high")
    [[ -n "$rl_memory_limit" ]] && rl_properties+=("MemoryMax=$rl_memory_limit")
    [[ -n "$rl_tasks_max" ]] && rl_properties+=("TasksMax=$rl_tasks_max")
    if [[ -n "$rl_io_read_bandwidth_max" || -n "$rl_io_write_bandwidth_max" ]]; then
        rl_properties+=("IOAccounting=yes")
        [[ -n "$rl_io_read_bandwidth_max" ]] && rl_properties+=("IOReadBandwidthMax=$rl_io_read_bandwidth_max")
        [[ -n "$rl_io_write_bandwidth_max" ]] && rl_properties+=("IOWriteBandwidthMax=$rl_io_write_bandwidth_max")
    fi

    if priv_systemctl set-property --runtime "$rl_unit" "${rl_properties[@]}"; then
        declare -F audit_success >/dev/null 2>&1 && \
            audit_success "RESOURCE_SET_PROPERTY" "$rl_unit" "runtime ${rl_properties[*]}" || true
        return 0
    fi

    local rl_rc=$?
    declare -F audit_failure >/dev/null 2>&1 && \
        audit_failure "RESOURCE_SET_PROPERTY" "$rl_unit" "runtime apply failed rc=$rl_rc ${rl_properties[*]}" || true
    return "$rl_rc"
}

rl_resource_reset_runtime_limits() {
    local rl_uid="$1"
    local rl_unit
    rl_unit="$(rl_resource_user_slice_unit "$rl_uid")" || return 1

    local -a rl_properties=(
        "CPUQuota="
        "MemoryHigh=infinity"
        "MemoryMax=infinity"
        "TasksMax=infinity"
        "IOReadBandwidthMax="
        "IOWriteBandwidthMax="
    )

    if priv_systemctl set-property --runtime "$rl_unit" "${rl_properties[@]}"; then
        declare -F audit_success >/dev/null 2>&1 && \
            audit_success "RESOURCE_RESET_PROPERTY" "$rl_unit" "runtime ${rl_properties[*]}" || true
        return 0
    fi

    local rl_rc=$?
    declare -F audit_failure >/dev/null 2>&1 && \
        audit_failure "RESOURCE_RESET_PROPERTY" "$rl_unit" "runtime reset failed rc=$rl_rc ${rl_properties[*]}" || true
    return "$rl_rc"
}

get_current_resource_limits() {
    local username="$1"
    local uid config_file
    uid=$(id -u "$username" 2>/dev/null) || return 1
    config_file="$(rl_resource_config_file "$uid")"

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

    unit_dir="$(rl_resource_slice_dir "$uid")"
    config_file="$(rl_resource_config_file "$uid")"

    if [[ -z "$cpu_quota" && -z "$memory_limit" ]]; then
        remove_resource_limits "$uid"
        return 0
    fi

    priv_mkdir -p "$unit_dir" || {
        msg_err "无法创建配置目录: $unit_dir"
        return 1
    }

    local rl_memory_high rl_tasks_max rl_io_read_bandwidth_max rl_io_write_bandwidth_max
    rl_memory_high="${USER_MANAGER_RESOURCE_MEMORY_HIGH:-${RL_RESOURCE_MEMORY_HIGH:-}}"
    rl_tasks_max="${USER_MANAGER_RESOURCE_TASKS_MAX:-${RL_RESOURCE_TASKS_MAX:-4096}}"
    rl_io_read_bandwidth_max="${USER_MANAGER_RESOURCE_IO_READ_BANDWIDTH_MAX:-${RL_RESOURCE_IO_READ_BANDWIDTH_MAX:-}}"
    rl_io_write_bandwidth_max="${USER_MANAGER_RESOURCE_IO_WRITE_BANDWIDTH_MAX:-${RL_RESOURCE_IO_WRITE_BANDWIDTH_MAX:-}}"

    if ! {
        echo "[Slice]"
        echo "CPUAccounting=yes"
        [[ -n "$cpu_quota" ]]     && echo "CPUQuota=$cpu_quota"
        echo "MemoryAccounting=yes"
        [[ -n "$rl_memory_high" ]] && echo "MemoryHigh=$rl_memory_high"
        [[ -n "$memory_limit" ]]  && echo "MemoryMax=$memory_limit"
        echo "TasksAccounting=yes"
        [[ -n "$rl_tasks_max" ]] && echo "TasksMax=$rl_tasks_max"
        if [[ -n "$rl_io_read_bandwidth_max" || -n "$rl_io_write_bandwidth_max" ]]; then
            echo "IOAccounting=yes"
            [[ -n "$rl_io_read_bandwidth_max" ]] && echo "IOReadBandwidthMax=$rl_io_read_bandwidth_max"
            [[ -n "$rl_io_write_bandwidth_max" ]] && echo "IOWriteBandwidthMax=$rl_io_write_bandwidth_max"
        fi
    } | write_privileged_text_file "$config_file" "0644" "root:root"; then
        msg_err "无法写入配置文件: $config_file"
        return 1
    fi

    priv_systemctl daemon-reload 2>/dev/null || true
    if ! rl_resource_apply_runtime_limits "$uid" "$cpu_quota" "$memory_limit" >/dev/null 2>&1; then
        msg_warn "运行时资源限制未立即生效，已保留持久配置；用户下次登录或 slice 重建后生效"
    fi

    msg_ok "资源限制已配置: ${C_BOLD}$username${C_RESET}"
    [[ -n "$cpu_quota" ]]     && msg_step "CPU 配额: ${C_RESET}$cpu_quota${C_RESET}"
    [[ -n "$memory_limit" ]]  && msg_step "内存限制: ${C_RESET}$memory_limit${C_RESET}"

    return 0
}

# ============================================================
# 移除资源限制
# ============================================================

remove_resource_limits() {
    local uid="$1"
    local unit_dir
    local config_file
    unit_dir="$(rl_resource_slice_dir "$uid")"
    config_file="$(rl_resource_config_file "$uid")"

    if [[ -f "$config_file" ]]; then
        priv_rm -f "$config_file"
        if [[ -d "$unit_dir" ]]; then
            local remaining
            remaining=$(find "$unit_dir" -mindepth 1 2>/dev/null | head -1)
            if [[ -z "$remaining" ]]; then
                priv_rmdir "$unit_dir" 2>/dev/null || true
            fi
        fi
        priv_systemctl daemon-reload 2>/dev/null || true
        rl_resource_reset_runtime_limits "$uid" >/dev/null 2>&1 || true
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
            printf "${C_RESET}%-12s${C_RESET} " "$cpu"
        else
            printf "${C_DIM}%-12s${C_RESET} " "-"
        fi
        if [[ -n "$memory" ]]; then
            printf "${C_RESET}%-12s${C_RESET} " "$memory"
        else
            printf "${C_DIM}%-12s${C_RESET} " "-"
        fi
        echo -e "$status_badge"
    done

    echo ""
    msg_info "共 ${#managed_users[@]} 个用户，${configured} 个已配置资源限制"
}

# 列出 Linux 组成员（stub 用 getent group）
rl_resource_list_group_members() {
    local rl_group="$1"
    if [[ -z "$rl_group" ]]; then
        return 1
    fi
    getent group "$rl_group" 2>/dev/null | cut -d: -f4 | tr ',' '\n' | sort -u
}

# 对组成员逐个写入资源限制配置
# 用法：rl_resource_policy_apply_group <groupname> <cpu_quota> <memory_limit>
rl_resource_policy_apply_group() {
    local rl_group="$1"
    local rl_cpu="$2"
    local rl_memory="$3"
    if [[ -z "$rl_group" || -z "$rl_cpu" || -z "$rl_memory" ]]; then
        msg_err "rl_resource_policy_apply_group: 参数不足"
        return 1
    fi
    local rl_members
    rl_members="$(rl_resource_list_group_members "$rl_group")"
    if [[ -z "$rl_members" ]]; then
        msg_warn "组 $rl_group 没有成员"
        return 1
    fi
    local rl_applied=0
    local rl_uid
    local rl_user
    while IFS= read -r rl_user; do
        [[ -z "$rl_user" ]] && continue
        rl_uid=$(id -u "$rl_user" 2>/dev/null || echo "")
        if [[ -n "$rl_uid" ]]; then
            configure_resource_limits "$rl_user" "$rl_cpu" "$rl_memory"
            ((rl_applied++))
        fi
    done <<< "$rl_members"
    msg_ok "已为组 $rl_group 的 $rl_applied 个成员应用资源配置"
    return 0
}

# 移除组内所有成员的资源限制配置
rl_resource_policy_remove_group() {
    local rl_group="$1"
    if [[ -z "$rl_group" ]]; then
        msg_err "rl_resource_policy_remove_group: 组名不能为空"
        return 1
    fi
    local rl_members
    rl_members="$(rl_resource_list_group_members "$rl_group")"
    local rl_removed=0
    local rl_user
    while IFS= read -r rl_user; do
        [[ -z "$rl_user" ]] && continue
        local rl_uid
        rl_uid=$(id -u "$rl_user" 2>/dev/null || echo "")
        if [[ -n "$rl_uid" ]]; then
            remove_resource_limits "$rl_uid"
            ((rl_removed++))
        fi
    done <<< "$rl_members"
    msg_ok "已移除组 $rl_group 的 $rl_removed 个成员资源配置"
    return 0
}
