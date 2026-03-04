#!/bin/bash
# quota_core.sh - 配额管理核心模块 v5.0
# 提供磁盘配额查询、设置、统计、可视化功能

# ---------------------------------------------------------------------------
#  get_user_mountpoint  —— 根据 home 目录路径匹配最长前缀的 /mnt/dataXX
# ---------------------------------------------------------------------------
get_user_mountpoint() {
    local home="$1"
    [[ -z "$home" ]] && return 1

    local matched_mp=""
    local disk_num idx mp_candidate
    for disk_num in "${ALL_DISKS[@]}"; do
        idx=$(printf "%02d" "$disk_num")
        mp_candidate="${DATA_BASE}/data${idx}"
        if [[ "$home" == "${mp_candidate}"/* || "$home" == "$mp_candidate" ]]; then
            if (( ${#mp_candidate} > ${#matched_mp} )); then
                matched_mp="$mp_candidate"
            fi
        fi
    done

    if [[ -n "$matched_mp" ]]; then
        echo "$matched_mp"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
#  collect_quota_users  —— 解析 repquota 输出，返回有配额条目的用户名列表
# ---------------------------------------------------------------------------
collect_quota_users() {
    local mp="$1"
    [[ -z "$mp" ]] && return 1

    priv_repquota -u "$mp" 2>/dev/null | awk '
        NR > 6 && $1 ~ /^[a-zA-Z_][a-zA-Z0-9_.-]*$/ {
            print $1
        }
    '
}

# ---------------------------------------------------------------------------
#  get_managed_usernames  —— 汇总所有磁盘上有配额的合法用户（跳过 root/dell）
# ---------------------------------------------------------------------------
get_managed_usernames() {
    local -A users_seen=()
    local disk_num idx mp candidate home

    for disk_num in "${ALL_DISKS[@]}"; do
        idx=$(printf "%02d" "$disk_num")
        mp="${DATA_BASE}/data${idx}"
        mountpoint -q "$mp" 2>/dev/null || continue

        while IFS= read -r candidate; do
            [[ -z "$candidate" ]] && continue
            [[ "$candidate" == "root" || "$candidate" == "dell" ]] && continue
            [[ "$candidate" =~ $USERNAME_PATTERN ]] && users_seen["$candidate"]=1
        done < <(collect_quota_users "$mp")
    done

    for candidate in "${!users_seen[@]}"; do
        if getent passwd "$candidate" >/dev/null 2>&1; then
            home=$(get_user_home "$candidate")
            if [[ "$home" =~ ^${DATA_BASE}/data[0-9]{2}/ ]]; then
                echo "$candidate"
            fi
        fi
    done
}

# ---------------------------------------------------------------------------
#  get_user_quota_info  —— 获取用户在指定挂载点的已用/限额字节数
#  输出格式: "used_bytes:limit_bytes"
# ---------------------------------------------------------------------------
get_user_quota_info() {
    local username="$1"
    local mp="$2"
    [[ -z "$username" || -z "$mp" ]] && { echo "0:0"; return 1; }

    local used_kb="" limit_kb=""

    # ── 优先尝试 quota 命令 ──
    if command -v quota &>/dev/null; then
        local device quota_output
        device=$(df "$mp" 2>/dev/null | awk 'NR==2 {print $1}')
        if [[ -n "$device" ]]; then
            quota_output=$(sudo quota -u "$username" 2>/dev/null \
                | grep -E "^[[:space:]]*(${device}|${mp})" || true)
            if [[ -n "$quota_output" ]]; then
                used_kb=$(echo "$quota_output" | awk '{print $2}')
                limit_kb=$(echo "$quota_output" | awk '{print $4}')
            fi
        fi
    fi

    # ── 回退到 repquota ──
    if [[ ! "$used_kb" =~ ^[0-9]+$ ]] || [[ ! "$limit_kb" =~ ^[0-9]+$ ]]; then
        local repquota_output quota_line
        repquota_output=$(priv_repquota -u "$mp" 2>/dev/null) || true
        if [[ -n "$repquota_output" ]]; then
            quota_line=$(echo "$repquota_output" | awk -v user="$username" '
                /^\*\*\*/ || /Block limits/ || /File limits/ || /^[[:space:]]*$/ || /^---/ || /用户.*已用/ { next }
                $1 == user {
                    used = $3; hard = $5
                    gsub(/[^0-9]/, "", used)
                    gsub(/[^0-9]/, "", hard)
                    if (used != "" && hard != "") print used, hard
                    exit
                }
            ')
            if [[ -n "$quota_line" ]]; then
                used_kb=$(echo "$quota_line" | awk '{print $1}')
                limit_kb=$(echo "$quota_line" | awk '{print $2}')
            fi
        fi
    fi

    # ── 转换 KB → 字节 ──
    local used_bytes=0 limit_bytes=0
    [[ "$used_kb"  =~ ^[0-9]+$ ]] && used_bytes=$((used_kb  * 1024))
    [[ "$limit_kb" =~ ^[0-9]+$ ]] && limit_bytes=$((limit_kb * 1024))

    echo "${used_bytes}:${limit_bytes}"
    return 0
}

# ---------------------------------------------------------------------------
#  set_user_quota  —— 设置用户磁盘配额（软 = 硬，inode 不限）
# ---------------------------------------------------------------------------
set_user_quota() {
    local username="${1:-}"
    local quota_bytes="${2:-}"
    local mp="${3:-}"

    # 参数验证
    if [[ -z "$username" ]]; then
        msg_err "用户名不能为空"; return 1
    fi
    if [[ -z "$quota_bytes" ]] || ! [[ "$quota_bytes" =~ ^[0-9]+$ ]]; then
        msg_err "配额值无效: ${quota_bytes:-<空>}"; return 1
    fi
    if [[ -z "$mp" ]]; then
        msg_err "挂载点不能为空"; return 1
    fi
    if ! mountpoint -q "$mp" 2>/dev/null; then
        msg_err "挂载点 ${C_BOLD}${mp}${C_RESET} 未挂载"; return 1
    fi
    if ! id "$username" &>/dev/null; then
        msg_err "用户 ${C_BOLD}${username}${C_RESET} 不存在"; return 1
    fi

    local quota_kb=$((quota_bytes / 1024))
    local human_size
    human_size=$(bytes_to_human "$quota_bytes")

    msg_step "设置配额: ${C_BOLD}${username}${C_RESET} → ${C_BCYAN}${human_size}${C_RESET}  (${mp})"

    local result
    if result=$(priv_setquota -u "$username" "$quota_kb" "$quota_kb" 0 0 "$mp" 2>&1); then
        msg_ok "配额已生效: ${C_BOLD}${username}${C_RESET} = ${C_BGREEN}${human_size}${C_RESET}"
        return 0
    else
        msg_err "配额设置失败: ${result}"
        if [[ "$result" =~ Quota\ not\ enabled|not\ found ]]; then
            msg_warn "提示: 挂载点 ${mp} 可能未启用配额系统"
            msg_warn "请检查: mount | grep ${mp}"
        fi
        return 1
    fi
}

# ---------------------------------------------------------------------------
#  show_disk_usage_warnings  —— 磁盘使用率超阈值时显示彩色告警条
# ---------------------------------------------------------------------------
show_disk_usage_warnings() {
    local warning_found=false
    local disk_num idx mp usage_pct

    for disk_num in "${ALL_DISKS[@]}"; do
        idx=$(printf "%02d" "$disk_num")
        mp="${DATA_BASE}/data${idx}"
        mountpoint -q "$mp" 2>/dev/null || continue

        usage_pct=$(df "$mp" | awk 'NR==2 {gsub(/%/,""); print $5}')
        [[ "$usage_pct" =~ ^[0-9]+$ ]] || continue

        if (( usage_pct > DISK_WARNING_THRESHOLD )); then
            if ! $warning_found; then
                echo ""
                msg_warn "${C_BOLD}磁盘使用率告警${C_RESET}  (阈值 ${DISK_WARNING_THRESHOLD}%)"
                draw_line 50
                warning_found=true
            fi
            local color
            color=$(get_usage_color "$usage_pct")
            printf "  %s⚠%s  data%s  " "$C_BRED" "$C_RESET" "$idx"
            draw_usage_bar "$usage_pct" 20
            printf "  ${color}${usage_pct}%%${C_RESET} > ${DISK_WARNING_THRESHOLD}%%\n"
        fi
    done

    $warning_found && echo ""
    return 0
}

# ---------------------------------------------------------------------------
#  show_disk_overview  —— 全部数据磁盘使用概览（彩色表格 + 进度条 + 状态徽章）
# ---------------------------------------------------------------------------
show_disk_overview() {
    draw_header "📊 数据磁盘使用概览"

    # 表头
    printf "  ${C_BOLD}${C_WHITE}%-8s  %-12s  %-12s  %-12s  %-24s  %s${C_RESET}\n" \
           "磁盘" "总容量" "已用" "可用" "使用率" "状态"
    draw_line 50

    local disk_num idx mp
    local total_size_sum=0 used_sum=0 avail_sum=0
    local disk_count=0

    for disk_num in "${ALL_DISKS[@]}"; do
        idx=$(printf "%02d" "$disk_num")
        mp="${DATA_BASE}/data${idx}"

        if ! mountpoint -q "$mp" 2>/dev/null; then
            printf "  ${C_DIM}data%-4s  %-12s  %-12s  %-12s  %-24s  ${C_RED}● 未挂载${C_RESET}\n" \
                   "$idx" "—" "—" "—" "—"
            continue
        fi

        local df_line
        df_line=$(df -B1 "$mp" | awk 'NR==2 {print $2, $3, $4, $5}')
        [[ -z "$df_line" ]] && continue

        local total_bytes used_bytes avail_bytes pct_str
        read -r total_bytes used_bytes avail_bytes pct_str <<< "$df_line"
        local pct=${pct_str//%/}
        [[ "$pct" =~ ^[0-9]+$ ]] || pct=0

        total_size_sum=$((total_size_sum + total_bytes))
        used_sum=$((used_sum + used_bytes))
        avail_sum=$((avail_sum + avail_bytes))
        disk_count=$((disk_count + 1))

        local total_h used_h avail_h
        total_h=$(bytes_to_human "$total_bytes")
        used_h=$(bytes_to_human "$used_bytes")
        avail_h=$(bytes_to_human "$avail_bytes")

        # 状态徽章
        local badge
        if (( pct >= 95 )); then
            badge="${C_BG_RED}${C_WHITE} 危险 ${C_RESET}"
        elif (( pct >= DISK_WARNING_THRESHOLD )); then
            badge="${C_BG_YELLOW}${C_BOLD} 警告 ${C_RESET}"
        elif (( pct >= 70 )); then
            badge="${C_BYELLOW}正常${C_RESET}"
        else
            badge="${C_BGREEN}良好${C_RESET}"
        fi

        local color
        color=$(get_usage_color "$pct")
        printf "  ${C_BOLD}data%-4s${C_RESET}  %-12s  ${color}%-12s${C_RESET}  ${C_BGREEN}%-12s${C_RESET}  " \
               "$idx" "$total_h" "$used_h" "$avail_h"
        draw_usage_bar "$pct" 16
        printf "  %b\n" "$badge"
    done

    draw_line 50

    # 汇总行
    if (( disk_count > 0 )); then
        local total_h_sum used_h_sum avail_h_sum overall_pct=0
        total_h_sum=$(bytes_to_human "$total_size_sum")
        used_h_sum=$(bytes_to_human "$used_sum")
        avail_h_sum=$(bytes_to_human "$avail_sum")
        (( total_size_sum > 0 )) && overall_pct=$((used_sum * 100 / total_size_sum))

        local sum_color
        sum_color=$(get_usage_color "$overall_pct")
        printf "  ${C_BOLD}${C_WHITE}合计%-4s${C_RESET}  %-12s  ${sum_color}%-12s${C_RESET}  ${C_BGREEN}%-12s${C_RESET}  " \
               "" "$total_h_sum" "$used_h_sum" "$avail_h_sum"
        draw_usage_bar "$overall_pct" 16
        printf "\n"
    fi

    echo ""
    draw_info_card "磁盘数量:" "${disk_count} / ${#ALL_DISKS[@]} 在线"
    draw_info_card "告警阈值:" "${DISK_WARNING_THRESHOLD}%"
    echo ""
}