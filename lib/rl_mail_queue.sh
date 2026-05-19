#!/bin/bash
# rl_mail_queue.sh - SQLite 邮件队列模块

: "${SCRIPT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
: "${DATA_DIR:=$SCRIPT_DIR/data}"
: "${EMAIL_QUEUE_DB:=$DATA_DIR/email_queue.db}"
: "${EMAIL_QUEUE_PENDING:=pending}"
: "${EMAIL_QUEUE_SENDING:=sending}"
: "${EMAIL_QUEUE_SENT:=sent}"
: "${EMAIL_QUEUE_FAILED:=failed}"

rl_mail_sql_escape() { local rl_value="${1:-}"; printf '%s' "${rl_value//\'/\'\'}"; }
rl_mail_queue_msg() { local rl_fn="$1"; shift; declare -F "$rl_fn" >/dev/null 2>&1 && "$rl_fn" "$*" || printf '%s\n' "$*" >&2; }

rl_mail_queue_init() {
    command -v sqlite3 >/dev/null 2>&1 || { rl_mail_queue_msg msg_err "需要 sqlite3 命令管理邮件队列"; return 1; }
    mkdir -p "$(dirname "$EMAIL_QUEUE_DB")" 2>/dev/null || true
    sqlite3 "$EMAIL_QUEUE_DB" <<'EOF'
CREATE TABLE IF NOT EXISTS email_queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT NOT NULL,
    email TEXT NOT NULL,
    template TEXT NOT NULL,
    data TEXT,
    status TEXT NOT NULL DEFAULT 'pending',
    priority INTEGER DEFAULT 5,
    attempts INTEGER DEFAULT 0,
    max_retries INTEGER DEFAULT 5,
    created_at TEXT NOT NULL,
    scheduled_at TEXT,
    sent_at TEXT,
    error TEXT,
    message_id TEXT
);
CREATE INDEX IF NOT EXISTS idx_email_queue_status ON email_queue(status);
CREATE INDEX IF NOT EXISTS idx_email_queue_scheduled ON email_queue(scheduled_at);
CREATE INDEX IF NOT EXISTS idx_email_queue_created ON email_queue(created_at);
CREATE TABLE IF NOT EXISTS email_log (id INTEGER PRIMARY KEY AUTOINCREMENT, queue_id INTEGER, email TEXT NOT NULL, template TEXT, status TEXT NOT NULL, error TEXT, duration_ms INTEGER, created_at TEXT NOT NULL, FOREIGN KEY (queue_id) REFERENCES email_queue(id));
EOF
    chmod 600 "$EMAIL_QUEUE_DB" 2>/dev/null || true
}

rl_mail_queue_enqueue() {
    local rl_username="$1" rl_email="$2" rl_template="$3" rl_data="${4:-{}}" rl_priority="${5:-5}" rl_timestamp rl_escaped_data rl_id
    command -v sqlite3 >/dev/null 2>&1 || return 1
    [[ -f "$EMAIL_QUEUE_DB" ]] || rl_mail_queue_init || return 1
    rl_timestamp=$(date '+%Y-%m-%d %H:%M:%S'); rl_escaped_data=$(rl_mail_sql_escape "$rl_data")
    sqlite3 "$EMAIL_QUEUE_DB" "INSERT INTO email_queue (username,email,template,data,status,priority,created_at) VALUES ('$(rl_mail_sql_escape "$rl_username")','$(rl_mail_sql_escape "$rl_email")','$(rl_mail_sql_escape "$rl_template")','$rl_escaped_data','$EMAIL_QUEUE_PENDING',$rl_priority,'$rl_timestamp');" || return 1
    rl_id=$(sqlite3 "$EMAIL_QUEUE_DB" "SELECT last_insert_rowid();")
    declare -F rl_mail_audit_log >/dev/null 2>&1 && rl_mail_audit_log queue "$rl_email" "$rl_template" queued "queue_id=$rl_id"
    printf '%s\n' "$rl_id"
}

rl_mail_queue_dequeue() {
    [[ -f "$EMAIL_QUEUE_DB" ]] || return 1
    local rl_now
    rl_now=$(date '+%Y-%m-%d %H:%M:%S')
    sqlite3 "$EMAIL_QUEUE_DB" "SELECT id, username, email, template, data FROM email_queue WHERE status = '$EMAIL_QUEUE_PENDING' AND (scheduled_at IS NULL OR scheduled_at <= '$rl_now') AND attempts < max_retries ORDER BY priority ASC, created_at ASC LIMIT 1;"
}

rl_mail_queue_mark_sending() { [[ -n "${1:-}" ]] && sqlite3 "$EMAIL_QUEUE_DB" "UPDATE email_queue SET status='$EMAIL_QUEUE_SENDING', scheduled_at=datetime('now') WHERE id=$1;"; }
rl_mail_queue_mark_sent() { [[ -n "${1:-}" ]] && sqlite3 "$EMAIL_QUEUE_DB" "UPDATE email_queue SET status='$EMAIL_QUEUE_SENT', sent_at='$(date '+%Y-%m-%d %H:%M:%S')', message_id='$(rl_mail_sql_escape "${2:-}")' WHERE id=$1;"; }
rl_mail_queue_mark_failed() { [[ -n "${1:-}" ]] && sqlite3 "$EMAIL_QUEUE_DB" "UPDATE email_queue SET status='$EMAIL_QUEUE_FAILED', error='$(rl_mail_sql_escape "${2:-unknown error}")', attempts=attempts+1 WHERE id=$1;"; }
rl_mail_queue_retry() { [[ -n "${1:-}" ]] && sqlite3 "$EMAIL_QUEUE_DB" "UPDATE email_queue SET status='$EMAIL_QUEUE_PENDING', scheduled_at=datetime('now','+30 seconds'), error=NULL WHERE id=$1 AND attempts < max_retries;"; }
rl_mail_queue_stats() { [[ -f "$EMAIL_QUEUE_DB" ]] || { echo "pending=0 sending=0 sent=0 failed=0"; return 0; }; sqlite3 "$EMAIL_QUEUE_DB" "SELECT 'pending='||COUNT(*) FROM email_queue WHERE status='pending' UNION ALL SELECT 'sending='||COUNT(*) FROM email_queue WHERE status='sending' UNION ALL SELECT 'sent='||COUNT(*) FROM email_queue WHERE status='sent' UNION ALL SELECT 'failed='||COUNT(*) FROM email_queue WHERE status='failed';"; }
rl_mail_queue_cleanup() { [[ -f "$EMAIL_QUEUE_DB" ]] && sqlite3 "$EMAIL_QUEUE_DB" "DELETE FROM email_log WHERE created_at < datetime('now','-${1:-7} days'); DELETE FROM email_queue WHERE status IN ('$EMAIL_QUEUE_SENT','$EMAIL_QUEUE_FAILED') AND created_at < datetime('now','-${1:-7} days');"; }

rl_mail_queue_json_value() {
    local rl_data="${1:-}" rl_key="$2" rl_default="${3:-}"
    if command -v jq >/dev/null 2>&1 && [[ -n "$rl_data" ]]; then
        jq -r --arg key "$rl_key" --arg default "$rl_default" '.[$key] // $default' <<<"$rl_data" 2>/dev/null || printf '%s\n' "$rl_default"
    else
        printf '%s\n' "$rl_default"
    fi
}

rl_mail_queue_dispatch_template() {
    local rl_template="$1" rl_username="$2" rl_email="$3" rl_data="${4:-{}}"
    local rl_reason rl_expiry rl_operator rl_quota
    rl_reason=$(rl_mail_queue_json_value "$rl_data" reason "")
    rl_expiry=$(rl_mail_queue_json_value "$rl_data" expiry_date "permanent")
    rl_operator=$(rl_mail_queue_json_value "$rl_data" operator "system")
    rl_quota=$(rl_mail_queue_json_value "$rl_data" quota "")
    case "$rl_template" in
        account_suspended) send_account_suspended_email "$rl_username" "$rl_email" "$rl_reason" "$rl_expiry" "$rl_operator" ;;
        account_disabled) send_account_disabled_email "$rl_username" "$rl_email" "$rl_reason" "$rl_expiry" "$rl_operator" ;;
        account_restored) send_account_restored_email "$rl_username" "$rl_email" "$rl_operator" ;;
        quota_hard_limit_set) send_quota_hard_limit_email "$rl_username" "$rl_email" "$rl_quota" "$rl_operator" ;;
        *) return 1 ;;
    esac
}

rl_mail_queue_process() {
    local rl_max="${1:-10}" rl_processed=0 rl_success=0 rl_failed=0 rl_next rl_id rl_username rl_email rl_template rl_data rl_send_result
    command -v sqlite3 >/dev/null 2>&1 || return 1
    [[ -f "$EMAIL_QUEUE_DB" ]] || return 0
    while (( rl_processed < rl_max )); do
        rl_next=$(rl_mail_queue_dequeue); [[ -n "$rl_next" ]] || break
        IFS='|' read -r rl_id rl_username rl_email rl_template rl_data <<< "$rl_next"
        [[ -n "$rl_id" ]] || break
        rl_mail_queue_mark_sending "$rl_id"; rl_send_result=1
        case "$rl_template" in
            password_notify)
                local rl_password="" rl_action="密码更新"
                if command -v jq >/dev/null 2>&1 && [[ -n "$rl_data" ]]; then rl_password=$(jq -r '.password // empty' <<<"$rl_data"); rl_action=$(jq -r '.action // "密码更新"' <<<"$rl_data"); fi
                [[ -n "$rl_password" ]] && send_password_email "$rl_username" "$rl_password" "$rl_email" "$rl_action" && rl_send_result=0 ;;
            quota_warning) declare -F send_quota_warning_email >/dev/null 2>&1 && send_quota_warning_email "$rl_username" "$rl_email" "$rl_data" && rl_send_result=0 ;;
            backup_completed) declare -F send_backup_notification_email >/dev/null 2>&1 && send_backup_notification_email "$rl_username" "$rl_email" "$rl_data" && rl_send_result=0 ;;
            account_suspended|account_disabled|account_restored|quota_hard_limit_set) rl_mail_queue_dispatch_template "$rl_template" "$rl_username" "$rl_email" "$rl_data" && rl_send_result=0 ;;
        esac
        if [[ $rl_send_result -eq 0 ]]; then rl_mail_queue_mark_sent "$rl_id"; ((rl_success+=1)); else rl_mail_queue_mark_failed "$rl_id" "发送失败"; ((rl_failed+=1)); fi
        ((rl_processed+=1))
    done
    rl_mail_queue_msg msg_info "邮件队列处理完成：处理=$rl_processed, 成功=$rl_success, 失败=$rl_failed"
}

email_queue_db_init() { rl_mail_queue_init "$@"; }
email_queue_add() { rl_mail_queue_enqueue "$@"; }
email_queue_get_next() { rl_mail_queue_dequeue "$@"; }
email_queue_mark_sending() { rl_mail_queue_mark_sending "$@"; }
email_queue_mark_sent() { rl_mail_queue_mark_sent "$@"; }
email_queue_mark_failed() { rl_mail_queue_mark_failed "$@"; }
email_queue_retry() { rl_mail_queue_retry "$@"; }
email_queue_stats() { rl_mail_queue_stats "$@"; }
email_queue_cleanup() { rl_mail_queue_cleanup "$@"; }
email_queue_process() { rl_mail_queue_process "$@"; }
check_email_sent() { [[ "$(sqlite3 "$EMAIL_QUEUE_DB" "SELECT status FROM email_queue WHERE id = $1;" 2>/dev/null)" == sent ]]; }
wait_for_email() { local rl_id="$1" rl_timeout="${2:-60}" rl_elapsed=0 rl_status; while (( rl_elapsed < rl_timeout )); do rl_status=$(sqlite3 "$EMAIL_QUEUE_DB" "SELECT status FROM email_queue WHERE id = $rl_id;" 2>/dev/null); [[ "$rl_status" == sent ]] && return 0; [[ "$rl_status" == failed ]] && return 1; sleep 2; ((rl_elapsed+=2)); done; return 1; }
