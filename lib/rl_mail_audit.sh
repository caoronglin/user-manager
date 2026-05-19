#!/bin/bash
# rl_mail_audit.sh - 邮件审计模块

: "${SCRIPT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
: "${LOG_DIR:=$SCRIPT_DIR/logs}"
: "${EMAIL_LOG_FILE:=$LOG_DIR/email.log}"

rl_mail_header_sanitize() {
    local rl_value="$1"
    rl_value="${rl_value//$'\r'/ }"
    rl_value="${rl_value//$'\n'/ }"
    printf '%s' "$rl_value" | tr -s ' '
}

rl_mail_audit_sanitize_message() {
    local rl_message="${1:-}"
    rl_message="${rl_message//password=*/password=***}"
    rl_message="${rl_message//passwd=*/passwd=***}"
    rl_message="${rl_message//密码=*/密码=***}"
    printf '%s' "$rl_message"
}

rl_mail_audit_log() {
    local rl_username="${1:-unknown}" rl_email="${2:-unknown}" rl_action="${3:-unknown}" rl_status="${4:-unknown}" rl_message="${5:-}"
    local rl_timestamp
    rl_timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    mkdir -p "$(dirname "$EMAIL_LOG_FILE")" 2>/dev/null || true
    rl_username=$(rl_mail_header_sanitize "$rl_username")
    rl_email=$(rl_mail_header_sanitize "$rl_email")
    rl_action=$(rl_mail_header_sanitize "$rl_action")
    rl_status=$(rl_mail_header_sanitize "$rl_status")
    rl_message=$(rl_mail_audit_sanitize_message "$rl_message")
    if [[ -n "$rl_message" ]]; then
        printf '[%s] %s | user=%s email=%s action=%s status=%s msg=%s\n' "$rl_timestamp" "$$" "$rl_username" "$rl_email" "$rl_action" "$rl_status" "$rl_message" >> "$EMAIL_LOG_FILE"
    else
        printf '[%s] %s | user=%s email=%s action=%s status=%s\n' "$rl_timestamp" "$$" "$rl_username" "$rl_email" "$rl_action" "$rl_status" >> "$EMAIL_LOG_FILE"
    fi
}

rl_mail_audit_query() {
    local rl_pattern="${1:-}" rl_limit="${2:-50}"
    [[ -f "$EMAIL_LOG_FILE" ]] || return 0
    if [[ -n "$rl_pattern" ]]; then
        grep -F "$rl_pattern" "$EMAIL_LOG_FILE" | tail -n "$rl_limit"
    else
        tail -n "$rl_limit" "$EMAIL_LOG_FILE"
    fi
}

sanitize_mail_header_value() { rl_mail_header_sanitize "$@"; }
log_email_event() { rl_mail_audit_log "$@"; }
