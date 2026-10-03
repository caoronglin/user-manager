#!/bin/bash
# controller_user_passwords.sh - 用户密码工作流聚合控制器

if [[ -z "${LIB_DIR:-}" ]]; then
    LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# shellcheck disable=SC1091
source "$LIB_DIR/controller_user_password_change.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/controller_user_notifications.sh"
