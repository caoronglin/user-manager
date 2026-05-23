#!/bin/bash
# controller_user_groups.sh - 用户组管理控制器

prompt_add_user_to_group() {
    read_existing_username || return 1
    local username="$REPLY_INPUT"
    read_input "请输入用户组名"
    [[ "$REPLY_INPUT" == "0" || "$REPLY_INPUT" == "q" || "$REPLY_INPUT" == "Q" ]] && return 1
    add_user_to_group "$username" "$REPLY_INPUT"
}

prompt_remove_user_from_group() {
    read_existing_username || return 1
    local username="$REPLY_INPUT"
    read_input "请输入用户组名"
    [[ "$REPLY_INPUT" == "0" || "$REPLY_INPUT" == "q" || "$REPLY_INPUT" == "Q" ]] && return 1
    remove_user_from_group "$username" "$REPLY_INPUT"
}

prompt_show_user_groups() {
    read_existing_username || return 1
    local username="$REPLY_INPUT"
    draw_header "用户组列表"
    list_user_groups "$username" | while IFS= read -r group_name; do
        printf "  ${C_BGREEN}%s${C_RESET}\n" "$group_name"
    done
}

prompt_show_group_members() {
    read_input "请输入用户组名"
    [[ "$REPLY_INPUT" == "0" || "$REPLY_INPUT" == "q" || "$REPLY_INPUT" == "Q" ]] && return 1
    local group_name="$REPLY_INPUT"
    draw_header "用户组成员"
    if ! list_group_members "$group_name" | while IFS= read -r username; do
        printf "  ${C_BOLD}%s${C_RESET}\n" "$username"
    done; then
        return 1
    fi
}

prompt_create_user_group() {
    read_input "请输入用户组名"
    [[ "$REPLY_INPUT" == "0" || "$REPLY_INPUT" == "q" || "$REPLY_INPUT" == "Q" ]] && return 1
    ensure_user_group "$REPLY_INPUT"
}

prompt_delete_user_group() {
    read_input "请输入用户组名"
    [[ "$REPLY_INPUT" == "0" || "$REPLY_INPUT" == "q" || "$REPLY_INPUT" == "Q" ]] && return 1
    local group_name="$REPLY_INPUT"
    confirm_action "确认删除用户组 $group_name ?" || return 1
    delete_user_group "$group_name"
}

_handle_user_group_menu() {
    local opt="$1"
    case "$opt" in
        1) safe_run prompt_add_user_to_group ;;
        2) safe_run prompt_remove_user_from_group ;;
        3) safe_run prompt_show_user_groups ;;
        4) safe_run prompt_show_group_members ;;
        5) safe_run prompt_create_user_group ;;
        6) safe_run prompt_delete_user_group ;;
        *) msg_err "无效的选项" ;;
    esac
}

user_group_menu() {
    run_submenu "用户组管理" _handle_user_group_menu \
        "1:将用户加入用户组" \
        "2:将用户移出用户组" \
        "3:查看用户所属组" \
        "4:查看用户组成员" \
        "5:创建用户组" \
        "6:删除用户组"
}
