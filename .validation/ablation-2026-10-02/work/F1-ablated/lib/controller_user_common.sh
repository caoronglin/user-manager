#!/bin/bash
# controller_user_common.sh - 用户工作流通用辅助函数

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
