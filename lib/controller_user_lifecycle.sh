#!/bin/bash
# controller_user_lifecycle.sh - 用户生命周期工作流控制器

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
    draw_info_card "旧用户名:" "$old_username" "$C_RESET"
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
            priv_sed -i "s/${old_username}/${new_username}/g" "$old_script"
            priv_mv "$old_script" "$new_script"
            # 更新 crontab 中的引用
            read_root_crontab | sed "s|${old_script}|${new_script}|g" | install_root_crontab 2>/dev/null || true
            msg_ok "备份计划已迁移"
        fi

        # 5. 迁移 DNS 限制
        if priv_iptables -L "DNS_${old_username}" -n &>/dev/null; then
            remove_dns_restrictions "$old_username" 2>/dev/null || true
            apply_dns_restrictions "$new_username" 2>/dev/null || true
            msg_ok "DNS 限制已迁移"
        fi

        # 6. 迁移防火墙规则（重建注释中的用户名）
        if priv_ufw status numbered 2>/dev/null | grep -q "comment ${old_username}"; then
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
            [[ -n "$expiry_date" ]] && msg_info "将于 ${C_RESET}$expiry_date${C_RESET} 自动启用"
            record_user_event "$username" "suspend" "${reason:-无} (到期:${expiry_date:-永久})"
        fi
    fi
}
