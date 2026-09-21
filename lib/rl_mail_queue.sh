#!/bin/bash
# rl_mail_queue.sh - SQLite 邮件队列模块

: "${SCRIPT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
: "${DATA_DIR:=$SCRIPT_DIR/data}"
: "${EMAIL_QUEUE_DB:=$DATA_DIR/email_queue.db}"
: "${EMAIL_QUEUE_SECRET_DIR:=$DATA_DIR/secrets}"
: "${EMAIL_QUEUE_KEY_FILE:=$EMAIL_QUEUE_SECRET_DIR/.key}"
: "${EMAIL_QUEUE_MASTER_KEY:=}"
: "${EMAIL_QUEUE_PENDING:=pending}"
: "${EMAIL_QUEUE_SENDING:=sending}"
: "${EMAIL_QUEUE_SENT:=sent}"
: "${EMAIL_QUEUE_FAILED:=failed}"

rl_mail_sql_escape() {
    local rl_value="${1:-}"
    printf '%s' "${rl_value//\'/\'\'}"
}
rl_mail_queue_msg() {
    local rl_fn="$1"
    shift
    declare -F "$rl_fn" >/dev/null 2>&1 && "$rl_fn" "$*" || printf '%s\n' "$*" >&2
}
rl_mail_is_positive_int() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }
rl_mail_is_priority() { [[ "$1" =~ ^[1-9]$|^10$ ]]; }
rl_mail_secret_token() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 16 2>/dev/null
    else
        printf 'secret_%s_%s' "$(date +%s%N)" "$RANDOM"
    fi
}

# ---------------------------------------------------------------------------
# 邮件队列 secret 文件加密与密钥管理
# ---------------------------------------------------------------------------
# secret 文件默认使用 AES-256-CBC 加密 + HMAC-SHA256 认证（encrypt-then-MAC）
# 落盘，密钥由 EMAIL_QUEUE_KEY_FILE 管理（0600 权限）。分层密钥策略：
#   * EMAIL_QUEUE_MASTER_KEY 环境变量（可选）：外部注入的父密钥（64 位 hex 或
#     任意 passphrase），用于派生文件加密密钥，便于对接外部 KMS / 密码管理；
#   * EMAIL_QUEUE_KEY_FILE 默认 $DATA_DIR/secrets/.key：由父密钥派生或自动生成，
#     0600 权限保存（32 字节 hex 数据加密密钥）；
#   * MAC 密钥由数据加密密钥经 SHA256(dek || "mac") 派生，与加密密钥分离；
#   * 每个 secret 使用独立随机 IV（16 字节），密文格式（点号分隔的 base64）：
#       v1:<b64 iv>:<b64 ciphertext>:<b64 mac>
# 无 openssl 时退化为原明文 + 0600 文件（旧行为兼容）。

# 判断一个 secret 内容是否为加密格式（v1: 前缀）。
rl_mail_secret_is_encrypted() {
    [[ "${1:-}" == v1:* ]]
}

# 读取数据加密密钥（DEK，32 字节 hex）。不存在时派生/生成并写入密钥文件。
# 输出：32 字节 hex DEK；失败返回 1。
rl_mail_secret_key() {
    local rl_key rl_parent="${EMAIL_QUEUE_MASTER_KEY:-}"
    mkdir -p "$EMAIL_QUEUE_SECRET_DIR" 2>/dev/null || return 1
    chmod 700 "$EMAIL_QUEUE_SECRET_DIR" 2>/dev/null || true

    if [[ -f "$EMAIL_QUEUE_KEY_FILE" ]] && [[ -s "$EMAIL_QUEUE_KEY_FILE" ]]; then
        rl_key=$(tr -d '[:space:]' <"$EMAIL_QUEUE_KEY_FILE" 2>/dev/null)
        if [[ "$rl_key" =~ ^[0-9a-fA-F]{64}$ ]]; then
            chmod 600 "$EMAIL_QUEUE_KEY_FILE" 2>/dev/null || true
            printf '%s' "$rl_key"
            return 0
        fi
        # 密钥文件内容非法：忽略并重新生成。
        rl_key=""
    fi

    if [[ -n "$rl_parent" ]]; then
        if [[ "$rl_parent" =~ ^[0-9a-fA-F]{64}$ ]]; then
            rl_key=$(printf '%s' "$rl_parent" | tr 'A-F' 'a-f')
        else
            # passphrase 经 SHA256 派生 32 字节 DEK。
            rl_key=$(printf '%s' "$rl_parent" | openssl dgst -sha256 -r 2>/dev/null | awk '{print $1}')
            [[ -n "$rl_key" ]] || return 1
        fi
    else
        command -v openssl >/dev/null 2>&1 || return 1
        rl_key=$(openssl rand -hex 32 2>/dev/null)
    fi
    [[ "$rl_key" =~ ^[0-9a-f]{64}$ ]] || return 1

    umask 077
    printf '%s\n' "$rl_key" >"$EMAIL_QUEUE_KEY_FILE" 2>/dev/null || return 1
    chmod 600 "$EMAIL_QUEUE_KEY_FILE" 2>/dev/null || true
    printf '%s' "$rl_key"
}

# 由 DEK 派生 HMAC 密钥（32 字节 hex）。
rl_mail_secret_mac_key() {
    local rl_dek="$1"
    printf '%s' "${rl_dek}mac" | openssl dgst -sha256 -r 2>/dev/null | awk '{print $1}'
}

# 加密明文：输出 "v1:<b64 iv>:<b64 ciphertext>:<b64 mac>"；失败返回 1（无输出）。
rl_mail_secret_encrypt() {
    local rl_plaintext="$1" rl_dek="$2" rl_iv_hex rl_iv_b64 rl_ct_b64 rl_mac_key rl_mac_hex rl_mac_b64 rl_tmp
    command -v openssl >/dev/null 2>&1 || return 1
    rl_iv_hex=$(openssl rand -hex 16 2>/dev/null) || return 1
    rl_ct_b64=$(printf '%s' "$rl_plaintext" | openssl enc -aes-256-cbc -K "$rl_dek" -iv "$rl_iv_hex" -a -A 2>/dev/null) || return 1
    [[ -n "$rl_ct_b64" ]] || return 1
    rl_mac_key=$(rl_mail_secret_mac_key "$rl_dek") || return 1
    rl_tmp=$(mktemp 2>/dev/null) || return 1
    printf '%s' "$rl_ct_b64" | openssl base64 -d -A >"$rl_tmp" 2>/dev/null
    rl_mac_hex=$(openssl dgst -sha256 -mac HMAC -macopt "hexkey:$rl_mac_key" "$rl_tmp" 2>/dev/null | awk '{print $NF}')
    rm -f "$rl_tmp"
    [[ -n "$rl_mac_hex" ]] || return 1
    rl_iv_b64=$(printf '%s' "$rl_iv_hex" | xxd -r -p 2>/dev/null | openssl base64 -A 2>/dev/null)
    rl_mac_b64=$(printf '%s' "$rl_mac_hex" | xxd -r -p 2>/dev/null | openssl base64 -A 2>/dev/null)
    printf 'v1:%s:%s:%s' "$rl_iv_b64" "$rl_ct_b64" "$rl_mac_b64"
}

# 解密 "v1:<b64 iv>:<b64 ciphertext>:<b64 mac>" 格式密文；失败返回 1（无输出）。
rl_mail_secret_decrypt() {
    local rl_ciphertext="$1" rl_dek="$2" rl_iv_b64 rl_ct_b64 rl_mac_b64 rl_mac_key
    local rl_mac_calc rl_ct_raw rl_iv_hex rl_mac_raw
    [[ "$rl_ciphertext" == v1:* ]] || return 1
    IFS=':' read -r _ rl_iv_b64 rl_ct_b64 rl_mac_b64 <<<"$rl_ciphertext"
    [[ -n "$rl_iv_b64" && -n "$rl_ct_b64" && -n "$rl_mac_b64" ]] || return 1
    rl_mac_key=$(rl_mail_secret_mac_key "$rl_dek") || return 1
    rl_ct_raw=$(printf '%s' "$rl_ct_b64" | openssl base64 -d -A 2>/dev/null)
    rl_mac_raw=$(printf '%s' "$rl_mac_b64" | openssl base64 -d -A 2>/dev/null)
    # 校验 HMAC，防篡改。
    rl_mac_calc=$(printf '%s' "$rl_ct_raw" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$rl_mac_key" 2>/dev/null | awk '{print $NF}')
    [[ -n "$rl_mac_calc" ]] || return 1
    rl_mac_calc_raw=$(printf '%s' "$rl_mac_calc" | xxd -r -p 2>/dev/null)
    [[ "$rl_mac_calc_raw" == "$rl_mac_raw" ]] || return 1
    rl_iv_hex=$(printf '%s' "$rl_iv_b64" | openssl base64 -d -A 2>/dev/null | xxd -p -c 256 2>/dev/null)
    printf '%s' "$rl_ct_raw" | openssl enc -d -aes-256-cbc -K "$rl_dek" -iv "$rl_iv_hex" 2>/dev/null
}

rl_mail_queue_store_secret() {
    local rl_secret="$1"
    local rl_token rl_key rl_content
    rl_token=$(rl_mail_secret_token)
    [[ -n "$rl_token" ]] || return 1
    mkdir -p "$EMAIL_QUEUE_SECRET_DIR" 2>/dev/null || return 1
    chmod 700 "$EMAIL_QUEUE_SECRET_DIR" 2>/dev/null || true
    umask 077

    # 优先 AES-256-CBC + HMAC 加密落盘；openssl 缺失或无密钥时退化为明文。
    if command -v openssl >/dev/null 2>&1; then
        rl_key=$(rl_mail_secret_key 2>/dev/null) || rl_key=""
        if [[ -n "$rl_key" ]]; then
            rl_content=$(rl_mail_secret_encrypt "$rl_secret" "$rl_key" 2>/dev/null)
            if [[ -n "$rl_content" ]]; then
                printf '%s' "$rl_content" >"$EMAIL_QUEUE_SECRET_DIR/$rl_token" 2>/dev/null || return 1
                chmod 600 "$EMAIL_QUEUE_SECRET_DIR/$rl_token" 2>/dev/null || true
                printf '%s' "$rl_token"
                return 0
            fi
        fi
    fi

    # 退化：明文 + 0600（与旧版本行为一致，用于无 openssl 环境）。
    printf '%s' "$rl_secret" >"$EMAIL_QUEUE_SECRET_DIR/$rl_token" 2>/dev/null || return 1
    chmod 600 "$EMAIL_QUEUE_SECRET_DIR/$rl_token" 2>/dev/null || true
    printf '%s' "$rl_token"
}

rl_mail_queue_read_secret() {
    local rl_token="$1" rl_path rl_content rl_key
    [[ -n "$rl_token" ]] || return 1
    rl_path="$EMAIL_QUEUE_SECRET_DIR/$rl_token"
    [[ -f "$rl_path" ]] || return 1
    rl_content=$(cat "$rl_path" 2>/dev/null) || return 1
    if rl_mail_secret_is_encrypted "$rl_content"; then
        rl_key=$(rl_mail_secret_key 2>/dev/null) || return 1
        rl_mail_secret_decrypt "$rl_content" "$rl_key" 2>/dev/null
        return $?
    fi
    # 明文（旧格式或无 openssl 环境）：直接返回。
    printf '%s' "$rl_content"
}

# 将已存在的明文 secret 文件迁移为加密格式（就地重写）。
rl_mail_queue_migrate_secret() {
    local rl_token="$1" rl_path rl_content rl_key rl_enc
    [[ -n "$rl_token" ]] || return 1
    rl_path="$EMAIL_QUEUE_SECRET_DIR/$rl_token"
    [[ -f "$rl_path" ]] || return 1
    command -v openssl >/dev/null 2>&1 || return 0
    rl_content=$(cat "$rl_path" 2>/dev/null) || return 1
    rl_mail_secret_is_encrypted "$rl_content" && return 0  # 已加密，跳过。
    rl_key=$(rl_mail_secret_key 2>/dev/null) || return 1
    rl_enc=$(rl_mail_secret_encrypt "$rl_content" "$rl_key" 2>/dev/null) || return 1
    umask 077
    printf '%s' "$rl_enc" >"$rl_path" 2>/dev/null || return 1
    chmod 600 "$rl_path" 2>/dev/null || true
}

rl_mail_queue_remove_secret() {
    local rl_token="$1"
    [[ -n "$rl_token" ]] && rm -f "$EMAIL_QUEUE_SECRET_DIR/$rl_token" 2>/dev/null || true
}

rl_mail_queue_init() {
    command -v sqlite3 >/dev/null 2>&1 || {
        rl_mail_queue_msg msg_err "需要 sqlite3 命令管理邮件队列"
        return 1
    }
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
    local rl_username="$1" rl_email="$2" rl_template="$3" rl_data="${4:-{\}}" rl_priority="${5:-5}" rl_timestamp rl_escaped_data rl_id rl_secret_password rl_secret_token
    [[ -n "$rl_username" && -n "$rl_email" && -n "$rl_template" ]] || {
        rl_mail_queue_msg msg_err "邮件入队参数不能为空"
        return 1
    }
    rl_mail_is_priority "$rl_priority" || {
        rl_mail_queue_msg msg_err "邮件优先级必须是 1-10"
        return 1
    }
    command -v sqlite3 >/dev/null 2>&1 || return 1
    [[ -f "$EMAIL_QUEUE_DB" ]] || rl_mail_queue_init || return 1

    # 密码通知类邮件不在数据库中落明文密码：写入 0600 临时 secret 文件，DB 只保存 token。
    if [[ "$rl_template" == "password_notify" ]] && command -v jq >/dev/null 2>&1 && [[ -n "$rl_data" ]]; then
        rl_secret_password=$(jq -r '.password // empty' <<<"$rl_data" 2>/dev/null)
        if [[ -n "$rl_secret_password" ]]; then
            rl_secret_token=$(rl_mail_queue_store_secret "$rl_secret_password") || return 1
            rl_data=$(jq --arg token "$rl_secret_token" 'del(.password) | .secret_token=$token' <<<"$rl_data" 2>/dev/null || printf '%s' "$rl_data")
        fi
    fi

    rl_timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    rl_escaped_data=$(rl_mail_sql_escape "$rl_data")
    rl_id=$(sqlite3 "$EMAIL_QUEUE_DB" "INSERT INTO email_queue (username,email,template,data,status,priority,created_at) VALUES ('$(rl_mail_sql_escape "$rl_username")','$(rl_mail_sql_escape "$rl_email")','$(rl_mail_sql_escape "$rl_template")','$rl_escaped_data','$EMAIL_QUEUE_PENDING',$rl_priority,'$rl_timestamp'); SELECT last_insert_rowid();") || return 1
    declare -F rl_mail_audit_log >/dev/null 2>&1 && rl_mail_audit_log queue "$rl_email" "$rl_template" queued "queue_id=$rl_id"
    printf '%s\n' "$rl_id"
}

rl_mail_queue_dequeue() {
    [[ -f "$EMAIL_QUEUE_DB" ]] || return 1
    local rl_now
    rl_now=$(date '+%Y-%m-%d %H:%M:%S')
    sqlite3 "$EMAIL_QUEUE_DB" "SELECT id, username, email, template, data FROM email_queue WHERE status = '$EMAIL_QUEUE_PENDING' AND (scheduled_at IS NULL OR scheduled_at <= '$rl_now') AND attempts < max_retries ORDER BY priority ASC, created_at ASC LIMIT 1;"
}

rl_mail_queue_mark_sending() {
    rl_mail_is_positive_int "${1:-}" || return 1
    sqlite3 "$EMAIL_QUEUE_DB" "UPDATE email_queue SET status='$EMAIL_QUEUE_SENDING', scheduled_at=datetime('now') WHERE id=$1;"
}
rl_mail_queue_mark_sent() {
    rl_mail_is_positive_int "${1:-}" || return 1
    sqlite3 "$EMAIL_QUEUE_DB" "UPDATE email_queue SET status='$EMAIL_QUEUE_SENT', sent_at='$(date '+%Y-%m-%d %H:%M:%S')', message_id='$(rl_mail_sql_escape "${2:-}")' WHERE id=$1;"
}
rl_mail_queue_mark_failed() {
    rl_mail_is_positive_int "${1:-}" || return 1
    sqlite3 "$EMAIL_QUEUE_DB" "UPDATE email_queue SET status='$EMAIL_QUEUE_FAILED', error='$(rl_mail_sql_escape "${2:-unknown error}")', attempts=attempts+1 WHERE id=$1;"
}
rl_mail_queue_retry() {
    rl_mail_is_positive_int "${1:-}" || return 1
    sqlite3 "$EMAIL_QUEUE_DB" "UPDATE email_queue SET status='$EMAIL_QUEUE_PENDING', scheduled_at=datetime('now','+30 seconds'), error=NULL WHERE id=$1 AND attempts < max_retries;"
}
rl_mail_queue_stats() {
    [[ -f "$EMAIL_QUEUE_DB" ]] || {
        echo "pending=0 sending=0 sent=0 failed=0"
        return 0
    }
    sqlite3 "$EMAIL_QUEUE_DB" "SELECT 'pending='||COUNT(*) FROM email_queue WHERE status='pending' UNION ALL SELECT 'sending='||COUNT(*) FROM email_queue WHERE status='sending' UNION ALL SELECT 'sent='||COUNT(*) FROM email_queue WHERE status='sent' UNION ALL SELECT 'failed='||COUNT(*) FROM email_queue WHERE status='failed';"
}
rl_mail_queue_cleanup() {
    local rl_days="${1:-7}"
    rl_mail_is_positive_int "$rl_days" || {
        rl_mail_queue_msg msg_err "保留天数必须是正整数"
        return 1
    }
    [[ -f "$EMAIL_QUEUE_DB" ]] || return 0
    sqlite3 "$EMAIL_QUEUE_DB" "DELETE FROM email_log WHERE created_at < datetime('now','-$rl_days days'); DELETE FROM email_queue WHERE status IN ('$EMAIL_QUEUE_SENT','$EMAIL_QUEUE_FAILED') AND created_at < datetime('now','-$rl_days days');"
    # 清理长时间未消费的密码 secret 临时文件。
    if [[ -d "$EMAIL_QUEUE_SECRET_DIR" ]]; then
        find "$EMAIL_QUEUE_SECRET_DIR" -type f -mtime +"$rl_days" -delete 2>/dev/null || true
    fi
}

rl_mail_queue_json_value() {
    local rl_data="${1:-}" rl_key="$2" rl_default="${3:-}"
    if command -v jq >/dev/null 2>&1 && [[ -n "$rl_data" ]]; then
        jq -r --arg key "$rl_key" --arg default "$rl_default" '.[$key] // $default' <<<"$rl_data" 2>/dev/null || printf '%s\n' "$rl_default"
    else
        printf '%s\n' "$rl_default"
    fi
}

rl_mail_queue_dispatch_template() {
    local rl_template="$1" rl_username="$2" rl_email="$3" rl_data="${4:-{\}}"
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
    local rl_max="${1:-10}" rl_processed=0 rl_success=0 rl_failed=0 rl_next rl_id rl_username rl_email rl_template rl_data rl_send_result rl_secret_token
    rl_mail_is_positive_int "$rl_max" || {
        rl_mail_queue_msg msg_err "处理数量必须是正整数"
        return 1
    }
    command -v sqlite3 >/dev/null 2>&1 || return 1
    [[ -f "$EMAIL_QUEUE_DB" ]] || return 0
    while ((rl_processed < rl_max)); do
        rl_next=$(rl_mail_queue_dequeue)
        [[ -n "$rl_next" ]] || break
        IFS='|' read -r rl_id rl_username rl_email rl_template rl_data <<<"$rl_next"
        [[ -n "$rl_id" ]] || break
        rl_mail_queue_mark_sending "$rl_id"
        rl_send_result=1
        case "$rl_template" in
        password_notify)
            local rl_password="" rl_action="密码更新"
            rl_secret_token=""
            if command -v jq >/dev/null 2>&1 && [[ -n "$rl_data" ]]; then
                rl_password=$(jq -r '.password // empty' <<<"$rl_data")
                rl_action=$(jq -r '.action // "密码更新"' <<<"$rl_data")
                if [[ -z "$rl_password" ]]; then
                    rl_secret_token=$(jq -r '.secret_token // empty' <<<"$rl_data" 2>/dev/null)
                    [[ -n "$rl_secret_token" ]] && rl_password=$(rl_mail_queue_read_secret "$rl_secret_token")
                fi
            fi
            [[ -n "$rl_password" ]] && send_password_email "$rl_username" "$rl_password" "$rl_email" "$rl_action" && rl_send_result=0
            ;;
        quota_warning) declare -F send_quota_warning_email >/dev/null 2>&1 && send_quota_warning_email "$rl_username" "$rl_email" "$rl_data" && rl_send_result=0 ;;
        backup_completed) declare -F send_backup_notification_email >/dev/null 2>&1 && send_backup_notification_email "$rl_username" "$rl_email" "$rl_data" && rl_send_result=0 ;;
        account_suspended | account_disabled | account_restored | quota_hard_limit_set) rl_mail_queue_dispatch_template "$rl_template" "$rl_username" "$rl_email" "$rl_data" && rl_send_result=0 ;;
        esac
        if [[ $rl_send_result -eq 0 ]]; then
            [[ -n "$rl_secret_token" ]] && rl_mail_queue_remove_secret "$rl_secret_token"
            rl_mail_queue_mark_sent "$rl_id"
            ((rl_success += 1))
        else
            rl_mail_queue_mark_failed "$rl_id" "发送失败"
            ((rl_failed += 1))
        fi
        ((rl_processed += 1))
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
check_email_sent() {
    rl_mail_is_positive_int "${1:-}" || return 1
    [[ "$(sqlite3 "$EMAIL_QUEUE_DB" "SELECT status FROM email_queue WHERE id = $1;" 2>/dev/null)" == sent ]]
}
wait_for_email() {
    local rl_id="$1" rl_timeout="${2:-60}" rl_elapsed=0 rl_status
    rl_mail_is_positive_int "$rl_id" || return 1
    rl_mail_is_positive_int "$rl_timeout" || return 1
    while ((rl_elapsed < rl_timeout)); do
        rl_status=$(sqlite3 "$EMAIL_QUEUE_DB" "SELECT status FROM email_queue WHERE id = $rl_id;" 2>/dev/null)
        [[ "$rl_status" == sent ]] && return 0
        [[ "$rl_status" == failed ]] && return 1
        sleep 2
        ((rl_elapsed += 2))
    done
    return 1
}
