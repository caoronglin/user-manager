#!/bin/bash
# controller_user_notifications.sh - 用户通知辅助控制器

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
