#!/bin/bash
# controller_user_provisioning.sh - 用户创建与更新控制器

if [[ -z "${LIB_DIR:-}" ]]; then
    LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# shellcheck disable=SC1091
source "$LIB_DIR/controller_user_provisioning_support.sh"

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
    _display_available_data_disks

    echo ""
    read_input "选择磁盘编号"; local disk_num="$REPLY_INPUT"
    local target_info
    target_info=$(_resolve_provision_target "$username" "$disk_num") || {
        release_lock; return 1
    }

    local idx mp home
    IFS='|' read -r idx mp home <<< "$target_info"

    local quota_bytes
    quota_bytes=$(_resolve_provision_quota "$username" "$mp" "$update_existing")

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
    _render_provision_confirmation "$username" "$password" "$home" "$quota_bytes" "$sel_avail_h" "$idx"

    if ! confirm_action "确认继续？"; then
        msg_info "已取消"
        release_lock; return 1
    fi

    # 询问是否启用 Mamba/Conda 配置（仅新用户）
    local install_miniforge=false
    if ! $update_existing; then
        echo ""
        if confirm_action "是否为新用户启用 Mamba/Conda 配置？"; then
            install_miniforge=true
        fi
    fi

    # 执行创建/更新
    local action
    local password_display
    password_display=$(format_password_display "$password")
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
