#!/bin/bash
# controller_user_permissions.sh - 用户权限管理控制器

prompt_show_user_permissions() {
    read_existing_username || return 1
    show_user_permissions "$REPLY_INPUT"
}

prompt_set_user_home_mode() {
    read_existing_username || return 1
    local username="$REPLY_INPUT"
    read_input "主目录权限模式 (如 700, 750)" "700"
    [[ "$REPLY_INPUT" == "0" || "$REPLY_INPUT" == "q" || "$REPLY_INPUT" == "Q" ]] && return 1
    set_user_home_mode "$username" "$REPLY_INPUT"
}

prompt_set_user_home_group() {
    read_existing_username || return 1
    local username="$REPLY_INPUT"
    read_input "主目录属组"
    [[ "$REPLY_INPUT" == "0" || "$REPLY_INPUT" == "q" || "$REPLY_INPUT" == "Q" ]] && return 1
    set_user_home_group "$username" "$REPLY_INPUT"
}

prompt_grant_admin_permission() {
    read_existing_username || return 1
    grant_user_admin_permission "$REPLY_INPUT"
}

prompt_revoke_admin_permission() {
    read_existing_username || return 1
    confirm_action "确认移除 $REPLY_INPUT 的管理员组权限？" || return 1
    revoke_user_admin_permission "$REPLY_INPUT"
}

_handle_permission_menu() {
    local opt="$1"
    case "$opt" in
        1) safe_run prompt_show_user_permissions ;;
        2) safe_run prompt_set_user_home_mode ;;
        3) safe_run prompt_set_user_home_group ;;
        4) safe_run prompt_grant_admin_permission ;;
        5) safe_run prompt_revoke_admin_permission ;;
        *) msg_err "无效的选项" ;;
    esac
}

permission_management_menu() {
    run_submenu "权限管理" _handle_permission_menu \
        "1:查看用户权限详情" \
        "2:设置主目录权限" \
        "3:设置主目录属组" \
        "4:授予管理员权限" \
        "5:移除管理员权限"
}
