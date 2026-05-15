#!/bin/bash
# controller_user_password_change.sh - 用户密码变更控制器

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
