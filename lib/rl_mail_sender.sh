#!/bin/bash
# rl_mail_sender.sh - 邮件发送后端模块

: "${SCRIPT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
: "${EMAIL_TEMPLATES_DIR:=$SCRIPT_DIR/templates/email}"

rl_mail_sender_msg() { local rl_fn="$1"; shift; declare -F "$rl_fn" >/dev/null 2>&1 && "$rl_fn" "$*" || printf '%s\n' "$*" >&2; }

rl_mail_send_raw() {
    local rl_recipient="${1:-}" rl_content="${2:-}" rl_backend="${3:-${EMAIL_SEND_BACKEND:-auto}}"
    [[ -n "$rl_recipient" ]] || { rl_mail_sender_msg msg_err "rl_mail_send: 收件人不能为空"; return 1; }
    [[ -n "$rl_content" ]] || { rl_mail_sender_msg msg_err "rl_mail_send: 邮件内容不能为空"; return 1; }
    case "$rl_backend" in
        auto)
            if command -v msmtp >/dev/null 2>&1; then printf '%s\n' "$rl_content" | timeout 30 msmtp "$rl_recipient"; return $?; fi
            if command -v mailx >/dev/null 2>&1; then printf '%s\n' "$rl_content" | timeout 30 mailx "$rl_recipient"; return $?; fi
            rl_mail_sender_msg msg_warn "未安装 msmtp/mailx，无法发送邮件"; return 1 ;;
        msmtp) printf '%s\n' "$rl_content" | timeout 30 msmtp "$rl_recipient" ;;
        mailx) printf '%s\n' "$rl_content" | timeout 30 mailx "$rl_recipient" ;;
        *) return 1 ;;
    esac
}

rl_mail_send() {
    local rl_recipient="${1:-}" rl_subject="${2:-}" rl_html_body="${3:-}" rl_max_retries="${4:-3}"
    [[ -n "$rl_recipient" ]] || { rl_mail_sender_msg msg_err "rl_mail_send: 收件人不能为空"; return 1; }
    [[ "$rl_recipient" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || return 1
    declare -F rl_mail_config_validate >/dev/null 2>&1 && rl_mail_config_validate || return 1
    local rl_from_name rl_from_addr rl_safe_from_name rl_safe_from_addr rl_safe_to rl_safe_subject rl_mail_content
    rl_from_name=$(rl_mail_config_get from_name 2>/dev/null); rl_from_addr=$(rl_mail_config_get from_address 2>/dev/null)
    rl_safe_from_name=$(sanitize_mail_header_value "${rl_from_name:-用户管理系统}")
    rl_safe_from_addr=$(sanitize_mail_header_value "${rl_from_addr:-noreply@example.com}")
    rl_safe_to=$(sanitize_mail_header_value "$rl_recipient")
    rl_safe_subject=$(sanitize_mail_header_value "${rl_subject:-系统通知}")
    rl_mail_content=$(cat <<MAILEOF
From: ${rl_safe_from_name} <${rl_safe_from_addr}>
To: ${rl_safe_to}
Subject: ${rl_safe_subject}
MIME-Version: 1.0
Content-Type: text/html; charset=UTF-8
X-Priority: 1
X-Mailer: UserManager/1.0

${rl_html_body}
MAILEOF
)
    local rl_attempt=0 rl_wait_secs
    while (( rl_attempt < rl_max_retries )); do
        ((rl_attempt+=1))
        if rl_mail_send_raw "$rl_recipient" "$rl_mail_content"; then return 0; fi
        if (( rl_attempt < rl_max_retries )); then rl_wait_secs=$((rl_attempt * 2)); sleep "$rl_wait_secs"; fi
    done
    return 1
}

send_email() { rl_mail_send "$@"; }
rl_mail_send_email() { rl_mail_send "$@"; }
