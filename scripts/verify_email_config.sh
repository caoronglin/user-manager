#!/bin/bash
# verify_email_config.sh - 验证邮箱配置脚本 v1.0.0
# 用于测试邮件配置是否正确

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/user_core.sh"
source "$SCRIPT_DIR/lib/email_core.sh"

draw_header "验证邮箱配置"

if validate_email_config; then
    msg_ok "邮箱配置验证通过"
    echo ""
    read_input "输入测试邮箱地址（跳过则不发送）"
    if [[ -n "$REPLY_INPUT" ]]; then
        send_password_email "test_user" "TEST-PASS-123" "$REPLY_INPUT" "配置测试"
    fi
else
    msg_err "邮箱配置验证失败"
    exit 1
fi