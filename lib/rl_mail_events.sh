#!/bin/bash
# rl_mail_events.sh - 邮件业务事件模块

: "${SCRIPT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
: "${EMAIL_TEMPLATES_DIR:=$SCRIPT_DIR/templates/email}"

rl_mail_event_msg() { local rl_fn="$1"; shift; declare -F "$rl_fn" >/dev/null 2>&1 && "$rl_fn" "$*" || printf '%s\n' "$*" >&2; }

rl_mail_event_valid_email() {
    [[ "${1:-}" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

rl_mail_event_subject_safe() {
    local rl_subject="${1:-}"
    rl_subject="${rl_subject//$'\r'/ }"
    rl_subject="${rl_subject//$'\n'/ }"
    printf '%s' "$rl_subject"
}

rl_mail_event_password_created() {
    local rl_username="$1" rl_password="$2" rl_email="$3" rl_action="${4:-密码更新}" rl_retries="${5:-3}"
    [[ -n "$rl_username" ]] || { rl_mail_event_msg msg_err "send_password_email: 用户名不能为空"; return 1; }
    [[ -n "$rl_password" ]] || { rl_mail_event_msg msg_err "send_password_email: 密码不能为空"; return 1; }
    [[ -n "$rl_email" ]] || { rl_mail_event_msg msg_warn "send_password_email: 邮箱地址为空，跳过发送"; return 0; }
    if ! rl_mail_event_valid_email "$rl_email"; then
        rl_mail_audit_log "$rl_username" "$rl_email" "$rl_action" failed invalid_email_format; return 1
    fi
    local rl_timestamp rl_template_file rl_html_body
    rl_timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    rl_template_file="$EMAIL_TEMPLATES_DIR/modern_password_notify.html"
    if [[ -f "$rl_template_file" ]]; then
        rl_html_body=$(rl_mail_template_render "$rl_template_file" "$rl_username" "$rl_password" "$rl_action" "$rl_timestamp") || rl_html_body=$(rl_mail_template_fallback "$rl_username" "$rl_password" "$rl_action" "$rl_timestamp")
    else
        rl_html_body=$(rl_mail_template_fallback "$rl_username" "$rl_password" "$rl_action" "$rl_timestamp")
    fi
    rl_mail_audit_log "$rl_username" "$rl_email" "$rl_action" sending
    if rl_mail_send "$rl_email" "【重要】${rl_action}通知 - ${rl_username}" "$rl_html_body" "$rl_retries"; then
        rl_mail_audit_log "$rl_username" "$rl_email" "$rl_action" sent; return 0
    fi
    rl_mail_audit_log "$rl_username" "$rl_email" "$rl_action" failed max_retries_exceeded
    return 1
}

rl_mail_event_render() {
    local rl_template_name="$1" rl_username="$2" rl_action="$3" rl_reason="${4:-}" rl_expiry="${5:-}" rl_operator="${6:-}" rl_status="${7:-}" rl_quota="${8:-}"
    local rl_timestamp rl_template_file
    rl_timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    rl_template_file="$EMAIL_TEMPLATES_DIR/${rl_template_name}.html"
    if [[ -f "$rl_template_file" ]]; then
        rl_mail_template_render "$rl_template_file" "$rl_username" "" "$rl_action" "$rl_timestamp" "$rl_reason" "$rl_expiry" "$rl_operator" "$rl_status" "$rl_quota"
    else
        rl_mail_template_fallback "$rl_username" "" "$rl_action" "$rl_timestamp"
    fi
}

rl_mail_event_account_notice() {
    local rl_template="$1" rl_action="$2" rl_username="$3" rl_email="$4" rl_reason="${5:-}" rl_expiry="${6:-}" rl_operator="${7:-system}" rl_status="${8:-}"
    [[ -n "$rl_username" ]] || { rl_mail_event_msg msg_err "account notice: 用户名不能为空"; return 1; }
    [[ -n "$rl_email" ]] || { rl_mail_event_msg msg_warn "account notice: 邮箱地址为空，跳过发送"; return 0; }
    if ! rl_mail_event_valid_email "$rl_email"; then
        rl_mail_audit_log "$rl_username" "$rl_email" "$rl_action" failed invalid_email_format
        return 1
    fi
    local rl_html_body rl_subject
    rl_html_body=$(rl_mail_event_render "$rl_template" "$rl_username" "$rl_action" "$rl_reason" "$rl_expiry" "$rl_operator" "$rl_status" "") || return 1
    rl_subject=$(rl_mail_event_subject_safe "【重要】${rl_action} - ${rl_username}")
    rl_mail_audit_log "$rl_username" "$rl_email" "$rl_action" sending
    if rl_mail_send "$rl_email" "$rl_subject" "$rl_html_body" 3; then
        rl_mail_audit_log "$rl_username" "$rl_email" "$rl_action" sent
        return 0
    fi
    rl_mail_audit_log "$rl_username" "$rl_email" "$rl_action" failed send_failed
    return 1
}

send_account_suspended_email() { rl_mail_event_account_notice account_suspended "账户已停用" "$1" "$2" "${3:-}" "${4:-permanent}" "${5:-system}" suspended; }
send_account_disabled_email() { rl_mail_event_account_notice account_disabled "账户已禁用" "$1" "$2" "${3:-}" "${4:-permanent}" "${5:-system}" disabled; }
send_account_restored_email() { rl_mail_event_account_notice account_restored "账户已恢复" "$1" "$2" "" "" "${3:-system}" restored; }

send_quota_hard_limit_email() {
    local rl_username="$1" rl_email="$2" rl_quota="$3" rl_operator="${4:-system}"
    [[ -n "$rl_username" ]] || { rl_mail_event_msg msg_err "quota notice: 用户名不能为空"; return 1; }
    [[ -n "$rl_email" ]] || { rl_mail_event_msg msg_warn "quota notice: 邮箱地址为空，跳过发送"; return 0; }
    if ! rl_mail_event_valid_email "$rl_email"; then
        rl_mail_audit_log "$rl_username" "$rl_email" "硬配额设置" failed invalid_email_format
        return 1
    fi
    local rl_html_body rl_subject
    rl_html_body=$(rl_mail_event_render quota_hard_limit_set "$rl_username" "硬配额设置" "" "" "$rl_operator" hard-limit "$rl_quota") || return 1
    rl_subject=$(rl_mail_event_subject_safe "【通知】硬配额设置 - ${rl_username}")
    if rl_mail_send "$rl_email" "$rl_subject" "$rl_html_body" 3; then
        rl_mail_audit_log "$rl_username" "$rl_email" "硬配额设置" sent
        return 0
    fi
    rl_mail_audit_log "$rl_username" "$rl_email" "硬配额设置" failed send_failed
    return 1
}

rl_mail_event_quota_warning() {
    local rl_username="$1" rl_email="$2" rl_quota_info="$3"
    rl_mail_queue_enqueue "$rl_username" "$rl_email" quota_warning "$rl_quota_info"
}

rl_mail_event_backup_complete() {
    local rl_username="$1" rl_email="$2" rl_backup_details="$3"
    rl_mail_queue_enqueue "$rl_username" "$rl_email" backup_completed "$rl_backup_details"
}

rl_mail_event_user_created() {
    rl_mail_event_password_created "$1" "$2" "$3" "账户创建"
}

send_password_email() { rl_mail_event_password_created "$@"; }
send_password_email_async() {
    local rl_data
    rl_data=$(jq -n --arg u "$1" --arg p "$2" --arg e "$3" --arg a "${4:-密码更新}" '{username:$u,password:$p,email:$e,action:$a}') || return 1
    rl_mail_queue_enqueue "$1" "$3" password_notify "$rl_data"
}
send_quota_warning_email_async() { rl_mail_event_quota_warning "$@"; }
send_backup_completed_email_async() { rl_mail_event_backup_complete "$@"; }
send_account_suspended_email_async() { rl_mail_queue_enqueue "$1" "$2" account_suspended "${3:-}"; }
send_account_disabled_email_async() { rl_mail_queue_enqueue "$1" "$2" account_disabled "${3:-}"; }
send_account_restored_email_async() { rl_mail_queue_enqueue "$1" "$2" account_restored "${3:-}"; }
send_quota_hard_limit_email_async() { rl_mail_queue_enqueue "$1" "$2" quota_hard_limit_set "${3:-}"; }
