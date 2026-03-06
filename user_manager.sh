#!/bin/bash
# user_manager.sh - 用户与系统管理器 主程序
# 版本: v0.2.1
# 要求: Ubuntu/Debian, 已配置 user quota + rsnapshot + UFW

set -uo pipefail

# === 获取脚本目录 ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# === 加载所有模块 ===
# shellcheck disable=SC1091
source "$LIB_DIR/common.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/ui_modern.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/config.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/access_control.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/privilege.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/quota_core.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/user_core.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/email_core.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/audit_core.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/resource_core.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/backup_core.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/firewall_core.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/dns_core.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/symlink_core.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/report_core.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/system_core.sh"

# ============================================================
#  业务逻辑函数
# ============================================================

show_passwords_enabled() {
    [[ "${SHOW_PASSWORDS:-0}" == "1" ]]
}

format_password_display() {
    local password="$1"
    if show_passwords_enabled; then
        printf "%s" "$password"
    else
        printf "<hidden>"
    fi
}

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

# --- 创建/更新用户 ---
create_or_assign_user() {
    acquire_lock || return 1

    draw_header "创建/更新用户"

    draw_prompt
    read -r username
    if [[ -z "$username" ]] || ! validate_username "$username"; then
        release_lock; return 1
    fi

    local update_existing=false
    if id "$username" &>/dev/null; then
        msg_info "用户 ${C_BOLD}$username${C_RESET} 已存在，将更新其配额和组信息"
        update_existing=true
    fi

    # 密码选择
    echo ""
    msg_info "密码设置方式:"
    draw_menu_item 1 "从密码池随机选择（推荐）"
    draw_menu_item 2 "手动输入密码"
    draw_prompt
    read -r pass_option
    pass_option=${pass_option:-1}

    local password=""
    case $pass_option in
        1)
            password=$(get_random_password)
            if [[ -z "$password" ]]; then
                msg_err "无法从密码池获取密码"
                release_lock; return 1
            fi
            if show_passwords_enabled; then
                msg_ok "已从密码池随机选择密码: ${C_BOLD}$password${C_RESET}"
            else
                msg_ok "已从密码池随机选择密码（已隐藏输出，设置 SHOW_PASSWORDS=1 可显示）"
            fi
            ;;
        2)
            read -rsp "  请输入密码 (至少8位): " password; echo
            if (( ${#password} < 8 )); then
                msg_err "密码长度至少需要8个字符"
                release_lock; return 1
            fi
            ;;
        *)
            msg_err "无效的选项"
            release_lock; return 1
            ;;
    esac

    # 选择数据盘 —— 展示各磁盘剩余空间与用户数
    echo ""
    msg_info "${C_BOLD}可用数据盘概览:${C_RESET}"
    printf "  ${C_DIM}%-6s %-16s %-10s %-10s %-10s %-6s %-22s${C_RESET}\n" \
        "编号" "挂载点" "总容量" "已用" "可用" "用户" "使用率"
    draw_line 85

    local disk_num_iter idx_iter mp_iter
    local _all_managed_users=()
    mapfile -t _all_managed_users < <(get_managed_usernames 2>/dev/null)

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

        # 统计该磁盘上的用户数
        local user_count_on_disk=0
        for mu in "${_all_managed_users[@]}"; do
            local mh
            mh=$(get_user_home "$mu" 2>/dev/null)
            [[ "$mh" == "${mp_iter}/"* ]] && ((user_count_on_disk+=1))
        done

        local disk_color="$C_BGREEN"
        if (( pct_used >= 90 )); then
            disk_color="$C_BRED"
        elif (( pct_used >= 70 )); then
            disk_color="$C_BYELLOW"
        fi

        printf "  ${C_BCYAN}[%s]${C_RESET}  %-14s %-10s %-10s ${disk_color}%-10s${C_RESET} %-6s " \
            "$disk_num_iter" "data${idx_iter}" "$total_h" "$used_h" "$avail_h" "$user_count_on_disk"
        draw_usage_bar "$pct_used" 14
        echo ""
    done

    echo ""
    read_input "选择磁盘编号"; local disk_num="$REPLY_INPUT"
    if ! [[ " ${ALL_DISKS[*]} " =~ ${disk_num} ]]; then
        msg_err "无效的磁盘编号"
        release_lock; return 1
    fi

    local idx mp home
    idx=$(printf "%02d" "$disk_num")
    mp="$DATA_BASE/data$idx"
    home="$mp/$username"

    if ! mountpoint -q "$mp" 2>/dev/null; then
        msg_err "目标磁盘 $mp 未挂载"
        release_lock; return 1
    fi

    local quota_bytes="$QUOTA_DEFAULT"

    # 更新已有用户时保留当前配额
    if $update_existing; then
        local current_qi
        current_qi=$(get_user_quota_info "$username" "$mp" 2>/dev/null)
        local current_limit="${current_qi#*:}"
        if [[ "$current_limit" =~ ^[0-9]+$ ]] && (( current_limit > 0 )); then
            quota_bytes="$current_limit"
        fi
    fi

    # 查询选中磁盘剩余空间
    local sel_df sel_avail_b sel_avail_h
    sel_df=$(df -B1 "$mp" 2>/dev/null | awk 'NR==2 {print $4, $5}')
    read -r sel_avail_b _ <<< "$sel_df"
    sel_avail_h=$(bytes_to_human "$sel_avail_b")

    # 检查剩余空间是否足够分配默认配额
    if [[ "$sel_avail_b" =~ ^[0-9]+$ ]] && (( sel_avail_b < quota_bytes )); then
        msg_warn "磁盘 data${idx} 剩余 ${sel_avail_h}，不足默认配额 $(bytes_to_human "$quota_bytes")"
    fi

    # 确认
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
    draw_info_card "磁盘剩余:" "$sel_avail_h (data${idx})" "$C_BCYAN"
    echo ""

    if ! confirm_action "确认继续？"; then
        msg_info "已取消"
        release_lock; return 1
    fi

    # 询问是否安装 Miniforge（仅新用户）
    local install_miniforge=false
    if ! $update_existing; then
        echo ""
        if confirm_action "是否为新用户安装 Miniforge？"; then
            install_miniforge=true
        fi
    fi

    # 执行创建/更新
    local action
    if $update_existing; then
        action="update"
        update_user "$username" "$password" "$home" || {
            msg_err "更新用户失败"; release_lock; return 1
        }
    else
        action="create"
        create_user "$username" "$password" "$home" "$install_miniforge" || {
            msg_err "创建用户失败"; release_lock; return 1
        }
    fi

    priv_chown "$username:$username" "$home" 2>/dev/null
    priv_chmod 700 "$home" 2>/dev/null
    priv_usermod -d "$home" "$username"

    set_user_quota "$username" "$quota_bytes" "$mp"

    # 结果卡片
    echo ""
    draw_header "操作完成"
    draw_info_card "用户名:" "$username" "$C_BGREEN"
    if show_passwords_enabled; then
        draw_info_card "密码:" "$password_display" "$C_BOLD"
    else
        draw_info_card "密码:" "$password_display" "$C_DIM"
    fi
    draw_info_card "主目录:" "$home"
    draw_info_card "配额:" "$(bytes_to_gb "$quota_bytes") GB"
    echo ""

    # 邮件通知
    if $update_existing; then
        _send_password_notification "$username" "$password" "账户更新"
    else
        _send_password_notification "$username" "$password" "账户创建"
    fi

    record_user_event "$username" "$action" "用户" "$mp" "$home" "$quota_bytes"
    release_lock
}

# --- 修改用户密码 ---
change_user_password() {
    # 获取锁防止并发修改
    acquire_lock || return 1
    
    draw_header "修改用户密码"

    msg_info "修改方式:"
    draw_menu_item 1 "修改单个用户密码"
    draw_menu_item 2 "批量修改所有用户密码"
    draw_prompt
    read -r mode
    mode=${mode:-1}

    case "$mode" in
        1) _change_single_user_password ;;
        2) _change_all_users_password ;;
        *) msg_err "无效的选项" ;;
    esac
    
    release_lock
}


# 单用户密码修改
_change_single_user_password() {
    read_existing_username || return 1
    local username="$REPLY_INPUT"

    # 检查密码上次修改时间
    local last_change
    last_change=$(chage -l "$username" 2>/dev/null | grep 'Last password change' | cut -d: -f2 | xargs)
    if [[ -n "$last_change" && "$last_change" != "never" ]]; then
        msg_info "上次密码修改: ${C_BOLD}$last_change${C_RESET}"
    fi

    echo ""
    msg_info "密码修改方式:"
    draw_menu_item 1 "从密码池随机选择（推荐）"
    draw_menu_item 2 "手动输入密码"
    draw_prompt
    read -r pass_option

    local newpass=""
    case $pass_option in
        1)
            newpass=$(get_random_password)
            if [[ -z "$newpass" ]]; then
                msg_err "无法从密码池获取密码"; return 1
            fi
            msg_ok "已从密码池随机选择密码"
            ;;
        2)
            read -rsp "  新密码 (≥8位): " newpass; echo
            if ! _validate_password_strength "$newpass"; then
                return 1
            fi
            ;;
        *)
            msg_err "无效的选项"; return 1
            ;;
    esac

    if ! echo "$username:$newpass" | priv_chpasswd; then
        msg_err "密码更新失败"; return 1
    fi
    msg_ok "密码已更新"

    echo ""
    draw_header "密码修改结果"
    draw_info_card "用户名:" "$username" "$C_BOLD"
    local newpass_display
    newpass_display=$(format_password_display "$newpass")
    if show_passwords_enabled; then
        draw_info_card "新密码:" "$newpass_display" "$C_BGREEN"
    else
        draw_info_card "新密码:" "$newpass_display" "$C_DIM"
        msg_warn "新密码已隐藏输出，设置 SHOW_PASSWORDS=1 可显示"
    fi
    echo ""

    _send_password_notification "$username" "$newpass" "密码修改"
    record_user_event "$username" "password_change" "修改密码"
}

# 批量密码修改
_change_all_users_password() {
    draw_header "批量修改所有用户密码"

    local managed_users=()
    mapfile -t managed_users < <(get_managed_usernames)

    if (( ${#managed_users[@]} == 0 )); then
        msg_warn "没有托管用户"
        return 0
    fi

    msg_info "将为以下 ${C_BOLD}${#managed_users[@]}${C_RESET} 个用户重新生成密码:"
    for u in "${managed_users[@]}"; do
        echo "    ${C_CYAN}• $u${C_RESET}"
    done
    echo ""

    msg_warn "此操作将为所有用户随机分配新密码！"
    if ! confirm_action "确认继续？"; then
        msg_info "已取消"; return 0
    fi

    local success=0 failed=0
    local -a results=()

    for username in "${managed_users[@]}"; do
        local newpass
        newpass=$(get_random_password)
        if [[ -z "$newpass" ]]; then
            msg_err "用户 $username: 无法获取密码"
            ((failed+=1))
            continue
        fi

        if echo "$username:$newpass" | priv_chpasswd 2>/dev/null; then
            msg_ok "  $username: 密码已更新"
            results+=("$username:$newpass")
            ((success+=1))

            # 自动发送邮件通知
            local email
            email=$(get_user_email "$username")
            if [[ -n "$email" ]]; then
                send_password_email "$username" "$newpass" "$email" "密码更新" 2>/dev/null || true
            fi

            record_user_event "$username" "password_change" "批量修改密码"
        else
            msg_err "  $username: 密码更新失败"
            ((failed+=1))
        fi
    done

    echo ""
    draw_header "批量修改完成"
    draw_info_card "成功:" "${C_BGREEN}$success${C_RESET}"
    if [[ $failed -gt 0 ]]; then
        draw_info_card "失败:" "${C_BRED}$failed${C_RESET}"
    fi

    # 显示密码清单
    if (( ${#results[@]} > 0 )); then
        echo ""
        if show_passwords_enabled; then
            msg_info "新密码清单（请妥善保管）:"
            printf "  ${C_DIM}%-18s %s${C_RESET}\n" "用户名" "新密码"
            draw_line 40
            for entry in "${results[@]}"; do
                local u="${entry%%:*}"
                local p="${entry#*:}"
                printf "  ${C_BOLD}%-18s${C_RESET} ${C_BGREEN}%s${C_RESET}\n" "$u" "$p"
            done
            echo ""
        else
            msg_warn "新密码已隐藏输出，设置 SHOW_PASSWORDS=1 可显示"
        fi
    fi
}

# 密码强度验证
_validate_password_strength() {
    local password="$1"

    if (( ${#password} < 8 )); then
        msg_err "密码长度至少需要 8 个字符"
        return 1
    fi

    # 检查是否包含大写字母
    if ! [[ "$password" =~ [A-Z] ]]; then
        msg_warn "建议密码包含大写字母"
    fi

    # 检查是否包含数字
    if ! [[ "$password" =~ [0-9] ]]; then
        msg_warn "建议密码包含数字"
    fi

    # 检查是否包含特殊字符
    if ! [[ "$password" =~ [^a-zA-Z0-9] ]]; then
        msg_warn "建议密码包含特殊字符"
    fi

    return 0
}

# 统一的密码通知发送逻辑
_send_password_notification() {
    local username="$1"
    local password="$2"
    local action="$3"

    local user_email
    user_email=$(get_user_email "$username")

    if [[ -n "$user_email" ]]; then
        msg_info "检测到用户邮箱: ${C_BOLD}$user_email${C_RESET}"
        if confirm_action "是否将新密码发送到该邮箱？" "Y"; then
            send_password_email "$username" "$password" "$user_email" "$action"
        else
            if show_passwords_enabled; then
                msg_warn "已跳过邮件发送，请手动通知用户"
            else
                msg_warn "已跳过邮件发送，请手动通知用户（密码已隐藏，设置 SHOW_PASSWORDS=1 可显示）"
            fi
        fi
    else
        msg_warn "用户 $username 未设置邮箱"
        if confirm_action "是否现在设置邮箱并发送密码？"; then
            read_input "请输入用户邮箱地址"; user_email="$REPLY_INPUT"
            if [[ -n "$user_email" ]]; then
                if [[ "$user_email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                    update_user_config "$username" "$user_email"
                    msg_ok "邮箱已保存: $user_email"
                    send_password_email "$username" "$password" "$user_email" "$action"
                else
                    msg_err "邮箱格式不正确"
                fi
            fi
        else
            if show_passwords_enabled; then
                msg_warn "请手动将新密码通知用户: $password"
            else
                msg_warn "请手动将新密码通知用户（密码已隐藏，设置 SHOW_PASSWORDS=1 可显示）"
            fi
        fi
    fi
}

# --- 删除用户 ---
delete_user_account() {
    draw_header "删除用户"

    read_existing_username "请输入要删除的用户名" || return 1
    local username="$REPLY_INPUT"

    msg_warn "警告：此操作将永久删除用户 ${C_BOLD}$username${C_RESET} 及其主目录！"
    read_input "确认删除？输入用户名以确认"; local confirm="$REPLY_INPUT"
    if [[ "$confirm" != "$username" ]]; then
        msg_info "已取消"; return 0
    fi

    acquire_lock || return 1

    msg_step "删除用户 '$username'..."

    # 可选备份
    if confirm_action "是否在删除前备份用户数据？"; then
        manual_backup_user "$username"
    fi

    # 清理关联资源
    delete_user_all_rules "$username" 2>/dev/null || true
    remove_dns_restrictions "$username" 2>/dev/null || true

    local uid
    uid=$(id -u "$username" 2>/dev/null)
    [[ -n "$uid" ]] && remove_resource_limits "$uid"

    remove_backup_schedule "$username" 2>/dev/null || true

    delete_user "$username" || {
        msg_err "删除用户失败"; release_lock; return 1
    }

    record_user_event "$username" "delete" "删除用户"
    msg_ok "用户 ${C_BOLD}$username${C_RESET} 已删除"
    release_lock
}

# --- 重命名用户 ---
rename_user_account() {
    draw_header "重命名用户"

    read_existing_username "请输入当前用户名" || return 1
    local old_username="$REPLY_INPUT"

    read_username "请输入新用户名" || return 1
    local new_username="$REPLY_INPUT"
    if id "$new_username" &>/dev/null; then
        msg_err "用户名 '$new_username' 已被使用"; return 1
    fi

    local old_home new_home
    old_home=$(get_user_home "$old_username")
    new_home="${old_home%/*}/$new_username"

    echo ""
    draw_header "重命名确认"
    draw_info_card "旧用户名:" "$old_username" "$C_BYELLOW"
    draw_info_card "新用户名:" "$new_username" "$C_BGREEN"
    draw_info_card "旧主目录:" "$old_home"
    draw_info_card "新主目录:" "$new_home"
    echo ""

    if ! confirm_action "确认重命名？"; then
        msg_info "已取消"; return 0
    fi

    acquire_lock || return 1

    msg_step "重命名用户 ${C_BOLD}$old_username${C_RESET} → ${C_BOLD}$new_username${C_RESET}"

    # 锁定账户防止并发操作
    priv_usermod -L "$old_username"

    if priv_usermod -l "$new_username" "$old_username"; then
        msg_ok "用户名已更改"

        # 1. 移动主目录
        if [[ -d "$old_home" ]]; then
            priv_mv "$old_home" "$new_home"
            priv_usermod -d "$new_home" "$new_username"
            msg_ok "主目录已移动 → $new_home"
        fi

        # 2. 更新主组名
        if getent group "$old_username" &>/dev/null; then
            priv_groupmod -n "$new_username" "$old_username" 2>/dev/null || true
            msg_ok "主组已重命名"
        fi

        # 3. 同步 user_config.json（迁移配置条目）
        if [[ -f "$USER_CONFIG_FILE" ]] && command -v jq &>/dev/null; then
            local tmp_cfg
            tmp_cfg=$(mktemp) || {
                msg_err "无法创建临时文件"
                release_lock
                return 1
            }
            if jq --arg old "$old_username" --arg new "$new_username" \
                 'if has($old) then .[$new] = .[$old] | del(.[$old]) else . end' \
                 "$USER_CONFIG_FILE" > "$tmp_cfg" 2>/dev/null; then
                if mv "$tmp_cfg" "$USER_CONFIG_FILE"; then
                    msg_ok "用户配置已迁移"
                else
                    rm -f "$tmp_cfg"
                    msg_warn "用户配置迁移失败，请手动检查"
                fi
            else
                rm -f "$tmp_cfg"
                msg_warn "用户配置迁移失败，请手动检查"
            fi
        fi

        # 4. 迁移备份计划
        local old_script="/usr/local/bin/backup_user_${old_username}.sh"
        local new_script="/usr/local/bin/backup_user_${new_username}.sh"
        if [[ -f "$old_script" ]]; then
            run_privileged sed -i "s/${old_username}/${new_username}/g" "$old_script"
            priv_mv "$old_script" "$new_script"
            # 更新 crontab 中的引用
            run_privileged crontab -l 2>/dev/null | sed "s|${old_script}|${new_script}|g" | run_privileged crontab - 2>/dev/null || true
            msg_ok "备份计划已迁移"
        fi

        # 5. 迁移 DNS 限制
        if run_privileged iptables -L "DNS_${old_username}" -n &>/dev/null; then
            remove_dns_restrictions "$old_username" 2>/dev/null || true
            apply_dns_restrictions "$new_username" 2>/dev/null || true
            msg_ok "DNS 限制已迁移"
        fi

        # 6. 迁移防火墙规则（重建注释中的用户名）
        if run_privileged ufw status numbered 2>/dev/null | grep -q "comment ${old_username}"; then
            msg_info "提示: 防火墙规则中仍保留旧用户名注释，建议手动检查"
        fi

        # 7. 迁移作业统计文件
        if [[ -d "$JOB_STATS_DIR" ]]; then
            local old_stats="$JOB_STATS_DIR/${old_username}.csv"
            local new_stats="$JOB_STATS_DIR/${new_username}.csv"
            if [[ -f "$old_stats" ]]; then
                mv "$old_stats" "$new_stats"
                msg_ok "作业统计已迁移"
            fi
        fi

        # 8. 更新暂停用户记录
        if [[ -f "$DISABLED_USERS_FILE" ]] && grep -q "^${old_username}," "$DISABLED_USERS_FILE" 2>/dev/null; then
            sed -i "s/^${old_username},/${new_username},/" "$DISABLED_USERS_FILE"
            msg_ok "暂停记录已更新"
        fi

        # 9. 更新操作日志（追加重命名映射记录）
        priv_usermod -U "$new_username"
        record_user_event "$new_username" "rename" "从 $old_username 重命名"

        echo ""
        draw_header "重命名完成"
        draw_info_card "新用户名:" "$new_username" "$C_BGREEN"
        draw_info_card "主目录:" "$new_home"
        msg_ok "所有关联资源已同步更新"
    else
        msg_err "重命名失败"
        priv_usermod -U "$old_username"
    fi

    release_lock
}

# --- 暂停/启用用户 ---
suspend_or_enable_user() {
    draw_header "暂停/恢复用户"

    read_existing_username || return 1
    local username="$REPLY_INPUT"

    if passwd -S "$username" 2>/dev/null | grep -q "L"; then
        msg_info "用户 ${C_BOLD}$username${C_RESET} 当前状态: ${C_BRED}已暂停${C_RESET}"
        if confirm_action "是否恢复该用户？"; then
            priv_usermod -U "$username"
            if [[ -f "$DISABLED_USERS_FILE" ]]; then
                remove_file_entry "$DISABLED_USERS_FILE" "^$username,"
            fi
            msg_ok "用户 ${C_BOLD}$username${C_RESET} 已恢复"
            record_user_event "$username" "enable" "手动恢复"
        fi
    else
        msg_info "用户 ${C_BOLD}$username${C_RESET} 当前状态: ${C_BGREEN}正常${C_RESET}"
        if confirm_action "是否暂停该用户？"; then
            read_input "暂停原因"; local reason="$REPLY_INPUT"
            read_input "暂停天数 (留空=永久)"; local days="$REPLY_INPUT"

            local expiry_date=""
            if [[ -n "$days" && "$days" =~ ^[0-9]+$ ]]; then
                expiry_date=$(date -d "+${days} days" +%Y-%m-%d 2>/dev/null || date -v+"${days}"d +%Y-%m-%d 2>/dev/null)
            fi

            priv_usermod -L "$username"
            echo "$username,${reason:-无},$(date +%Y-%m-%d),${expiry_date}" >> "$DISABLED_USERS_FILE"

            msg_ok "用户 ${C_BOLD}$username${C_RESET} 已暂停"
            [[ -n "$expiry_date" ]] && msg_info "将于 ${C_BYELLOW}$expiry_date${C_RESET} 自动启用"
            record_user_event "$username" "suspend" "${reason:-无} (到期:${expiry_date:-永久})"
        fi
    fi
}

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
        draw_info_card "当前配额:" "未设置" "$C_BYELLOW"
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
    draw_info_card "原配额:" "${current_limit_gb:-未知} GB" "$C_BYELLOW"
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
        draw_info_card "CPU 配额:" "${current_cpu:-未设置}" "$C_BCYAN"
        draw_info_card "内存限制:" "${current_memory:-未设置}" "$C_BCYAN"
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

# ============================================================
#  子菜单
# ============================================================

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
        "9:显示网络信息"
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
        *)  msg_err "无效的选项" ;;
    esac
}

network_security_menu() {
    run_submenu "网络与安全管理" _handle_network_security \
        "1:防火墙规则 ›" \
        "2:DNS 访问控制 ›" \
        "3:符号链接与共享 ›"
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
        *)  msg_err "无效的选项" ;;
    esac
}

audit_menu() {
    run_submenu "审计与日志" _handle_audit \
        "1:查看审计日志" \
        "2:查询审计日志" \
        "3:审计统计分析" \
        "4:手动日志轮转"
}



# ============================================================
#  主菜单
# ============================================================

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
        read -r opt

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

# ============================================================
#  入口点
# ============================================================

main() {
    check_dependencies || exit 1
    load_config || exit 1
    setup_trap_handler
    main_menu
}

main "$@"
