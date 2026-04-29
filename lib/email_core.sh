#!/bin/bash
# email_core.sh - 邮件发送核心模块 v1.0.0
# 提供模板渲染、邮件发送、配置验证、队列管理功能
# 要求：jq, sendmail

# ============================================================
# 常量定义
# ============================================================

# 邮件模板目录
readonly EMAIL_TEMPLATES_DIR="${SCRIPT_DIR:-$(dirname "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")}/templates/email"

# 邮件队列文件（保留JSON作为备份）
readonly EMAIL_QUEUE_FILE="${DATA_DIR:-$SCRIPT_DIR/data}/email_queue.json"

# SQLite邮件队列数据库
readonly EMAIL_QUEUE_DB="${DATA_DIR:-$SCRIPT_DIR/data}/email_queue.db"

# 邮件日志文件
readonly EMAIL_LOG_FILE="${LOG_DIR:-$SCRIPT_DIR/logs}/email.log"

# 队列状态常量
readonly EMAIL_QUEUE_PENDING="pending"
readonly EMAIL_QUEUE_SENDING="sending"
readonly EMAIL_QUEUE_SENT="sent"
readonly EMAIL_QUEUE_FAILED="failed"

# 最大重试次数
readonly EMAIL_MAX_RETRIES=5

sanitize_mail_header_value() {
    local value="$1"
    value="${value//$'\r'/ }"
    value="${value//$'\n'/ }"
    printf '%s' "$value" | tr -s ' '
}

html_escape_text() {
    printf '%s' "$1" | sed \
        -e 's/&/\&amp;/g' \
        -e 's/</\&lt;/g' \
        -e 's/>/\&gt;/g' \
        -e 's/"/\&quot;/g' \
        -e "s/'/\&#39;/g"
}

validate_safe_hostname() {
    local host="$1"

    [[ -n "$host" ]] || return 1

    if [[ "$host" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(\.([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?))*$ ]]; then
        return 0
    fi

    if [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 0
    fi

    return 1
}

# ============================================================
# 模板渲染
# ============================================================

# ============================================================
# render_template_file - 使用 bash 参数扩展渲染 HTML 模板
# ============================================================
# Parameters:
#   $1 - template_file: 模板文件路径
#   $2 - username: 用户名
#   $3 - password: 密码
#   $4 - action: 操作类型
#   $5 - timestamp: 时间戳
# Returns:
#   0 on success, 1 on failure
# ============================================================
render_template_file() {
    local template_file="$1"
    local username="$2"
    local password="$3"
    local action="$4"
    local timestamp="$5"
    
    # 检查模板文件
    if [[ ! -f "$template_file" ]]; then
        msg_err "模板文件不存在：$template_file"
        return 1
    fi
    
    # 读取模板
    local content
    content=$(cat "$template_file") || {
        msg_err "无法读取模板文件：$template_file"
        return 1
    }
    
    local escaped_username escaped_password escaped_action escaped_timestamp
    escaped_username=$(html_escape_text "$username")
    escaped_password=$(html_escape_text "$password")
    escaped_action=$(html_escape_text "$action")
    escaped_timestamp=$(html_escape_text "$timestamp")

    content="${content//\$\{username\}/$escaped_username}"
    content="${content//\$\{password\}/$escaped_password}"
    content="${content//\$\{action\}/$escaped_action}"
    content="${content//\$\{timestamp\}/$escaped_timestamp}"
    
    echo "$content"
    return 0
}

# ============================================================
# 邮件配置验证
# ============================================================

# ============================================================
# validate_email_config - 验证邮件配置完整性
# ============================================================
# Returns:
#   0 if valid, 1 if invalid
# ============================================================
validate_email_config() {
    # 1. 检查配置文件存在
    if [[ ! -f "$EMAIL_CONFIG_FILE" ]]; then
        msg_err "邮箱配置文件不存在：$EMAIL_CONFIG_FILE"
        return 1
    fi
    
    # 2. 检查 jq 可用性
    if ! command -v jq &>/dev/null; then
        msg_err "需要 jq 命令解析 JSON 配置"
        return 1
    fi
    
    # 3. 检查 JSON 格式有效性
    if ! jq empty "$EMAIL_CONFIG_FILE" 2>/dev/null; then
        msg_err "邮箱配置文件 JSON 格式无效"
        return 1
    fi
    
    # 4. 检查必需字段
    local required_fields=("smtp_server" "smtp_port" "smtp_user" "smtp_password" "from_address" "from_name")
    local field
    for field in "${required_fields[@]}"; do
        local value
        value=$(jq -r --arg f "$field" '.[$f] // empty' "$EMAIL_CONFIG_FILE")
        if [[ -z "$value" ]]; then
            msg_err "邮箱配置缺少必需字段：$field"
            return 1
        fi
    done
    
    # 5. 验证字段格式
    local smtp_port smtp_server from_address
    smtp_port=$(get_email_config "smtp_port")
    smtp_server=$(get_email_config "smtp_server")
    from_address=$(get_email_config "from_address")
    
    # 端口范围验证
    if ! [[ "$smtp_port" =~ ^[0-9]+$ ]] || (( smtp_port < 1 || smtp_port > 65535 )); then
        msg_err "SMTP 端口无效：$smtp_port (应为 1-65535)"
        return 1
    fi
    
    # 邮箱格式验证
    if ! [[ "$from_address" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        msg_err "发件人邮箱格式无效：$from_address"
        return 1
    fi

    if ! validate_safe_hostname "$smtp_server"; then
        msg_err "SMTP 服务器地址无效或包含危险字符：$smtp_server"
        return 1
    fi
    
    # 6. 检查配置文件权限（应为 600）
    local perms
    perms=$(stat -c %a "$EMAIL_CONFIG_FILE" 2>/dev/null || echo "unknown")
    if [[ "$perms" != "600" && "$perms" != "400" && "$perms" != "700" ]]; then
        msg_warn "邮箱配置文件权限不安全：$perms (建议：600)"
    fi
    
    # 7. 可选：SMTP 服务器连通性测试（仅在 DEBUG 模式或配置测试时执行）
    if [[ "${DEBUG:-0}" == "1" ]] || [[ "${TEST_CONNECTION:-0}" == "1" ]]; then
        if command -v timeout &>/dev/null; then
            if ! timeout 5 bash -c 'cat < /dev/null > /dev/tcp/$1/$2' _ "$smtp_server" "$smtp_port" 2>/dev/null; then
                msg_warn "无法连接到 SMTP 服务器：$smtp_server:$smtp_port"
                # 不返回错误，仅警告
            fi
        fi
    fi
    
    return 0
}

# ============================================================
# 邮件日志记录
# ============================================================

# ============================================================
# log_email_event - 记录邮件发送事件（不包含敏感信息）
# ============================================================
# Parameters:
#   $1 - username: 用户名
#   $2 - email: 收件人邮箱
#   $3 - action: 操作类型
#   $4 - status: 发送状态 (sending/sent/failed)
#   $5 - message: 附加消息 (可选)
# ============================================================
log_email_event() {
    local username="${1:-unknown}"
    local email="${2:-unknown}"
    local action="${3:-unknown}"
    local status="${4:-unknown}"
    local message="${5:-}"
    
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # 确保日志目录存在
    mkdir -p "$(dirname "$EMAIL_LOG_FILE")" 2>/dev/null || true
    
    # 记录日志（不包含密码等敏感信息）
    if [[ -n "$message" ]]; then
        printf '[%s] %s | user=%s email=%s action=%s status=%s msg=%s\n' \
            "$timestamp" "$$" "$username" "$email" "$action" "$status" "$message" >> "$EMAIL_LOG_FILE"
    else
        printf '[%s] %s | user=%s email=%s action=%s status=%s\n' \
            "$timestamp" "$$" "$username" "$email" "$action" "$status" >> "$EMAIL_LOG_FILE"
    fi
}

# ============================================================
# 邮件发送核心函数
# ============================================================

# ============================================================
# send_password_email - 发送密码通知邮件（HTML 格式）
# ============================================================
# SECURITY NOTE: 此函数通过 SMTP 发送明文密码。
# 生产环境建议：
#   - 使用一次性链接代替明文密码
#   - 确保 SMTP 使用 TLS/STARTTLS 加密传输
#   - 密码邮件发送后督促用户立即修改密码
#   - 确保邮件日志不包含密码明文
# ============================================================
send_password_email() {
    local username="$1"
    local password="$2"
    local email="$3"
    local action="${4:-密码更新}"
    local max_retries="${5:-3}"
    
    # 参数验证
    if [[ -z "$username" ]]; then
        msg_err "send_password_email: 用户名不能为空"
        return 1
    fi
    if [[ -z "$password" ]]; then
        msg_err "send_password_email: 密码不能为空"
        return 1
    fi
    if [[ -z "$email" ]]; then
        msg_warn "send_password_email: 邮箱地址为空，跳过发送"
        return 0
    fi
    
    # 验证邮箱格式
    if ! [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        msg_err "邮箱地址格式不正确：$email"
        log_email_event "$username" "$email" "$action" "failed" "invalid_email_format"
        return 1
    fi
    
    # 验证邮件配置
    if ! validate_email_config; then
        msg_err "邮箱配置验证失败"
        log_email_event "$username" "$email" "$action" "failed" "config_validation_failed"
        return 1
    fi
    
    # 检查 sendmail 可用性
    if ! command -v sendmail &>/dev/null; then
        msg_warn "未安装 sendmail，无法发送密码通知"
        msg_info "提示：安装方法：sudo apt install msmtp msmtp-mta"
        log_email_event "$username" "$email" "$action" "failed" "sendmail_not_installed"
        return 1
    fi
    
    # 获取配置
    local from_name from_addr
    from_name=$(get_email_config "from_name")
    from_addr=$(get_email_config "from_address")
    [[ -z "$from_name" ]] && from_name="用户管理系统"
    [[ -z "$from_addr" ]] && from_addr="noreply@example.com"
    
    # 生成主题和时间戳
    local safe_from_name safe_from_addr safe_to safe_subject
    safe_from_name=$(sanitize_mail_header_value "${from_name:-用户管理系统}")
    safe_from_addr=$(sanitize_mail_header_value "${from_addr:-noreply@example.com}")
    safe_to=$(sanitize_mail_header_value "$email")
    safe_subject=$(sanitize_mail_header_value "【重要】${action}通知 - ${username}")

    local subject="$safe_subject"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # 选择并渲染模板
    local template_file="$EMAIL_TEMPLATES_DIR/modern_password_notify.html"
    local html_body
    
    if [[ -f "$template_file" ]]; then
        html_body=$(render_template_file "$template_file" "$username" "$password" "$action" "$timestamp") || {
            msg_err "模板渲染失败，使用备用模板"
            html_body=$(generate_fallback_template "$username" "$password" "$action" "$timestamp")
        }
    else
        msg_warn "模板文件不存在，使用备用模板"
        html_body=$(generate_fallback_template "$username" "$password" "$action" "$timestamp")
    fi
    
    # 构建邮件内容
    local mail_content
    mail_content=$(cat <<MAILEOF
From: ${safe_from_name} <${safe_from_addr}>
To: ${safe_to}
Subject: ${subject}
MIME-Version: 1.0
Content-Type: text/html; charset=UTF-8
X-Priority: 1
X-Mailer: UserManager/1.0

${html_body}
MAILEOF
)
    
    # 记录发送开始
    log_email_event "$username" "$email" "$action" "sending"
    msg_info "正在发送邮件至：$email ..."
    
    # 重试逻辑
    local attempt=0
    while (( attempt < max_retries )); do
        ((attempt+=1))
        
        # 使用 timeout 防止 sendmail 长时间阻塞
        if echo "$mail_content" | timeout 30 sendmail -t 2>/dev/null; then
            msg_ok "密码通知已成功发送至：$email"
            log_email_event "$username" "$email" "$action" "sent"
            return 0
        fi
        
        if (( attempt < max_retries )); then
            local wait_secs=$((attempt * 2))
            msg_warn "发送失败 (第 $attempt 次)，${wait_secs}s 后重试..."
            log_email_event "$username" "$email" "$action" "retry" "attempt=$attempt waiting=${wait_secs}s"
            sleep "$wait_secs"
        fi
    done
    
    # 所有重试失败
    msg_err "密码通知发送失败：$email (已尝试 $max_retries 次)"
    msg_warn "  请手动将密码通知用户"
    log_email_event "$username" "$email" "$action" "failed" "max_retries_exceeded"
    return 1
}

# ============================================================
# generate_fallback_template - 生成备用 HTML 模板
# ============================================================
# Parameters:
#   $1 - username: 用户名
#   $2 - password: 密码
#   $3 - action: 操作类型
#   $4 - timestamp: 时间戳
# Returns:
#   HTML string
# ============================================================
generate_fallback_template() {
    local username="$1"
    local password="$2"
    local action="$3"
    local timestamp="$4"
    local escaped_username escaped_password escaped_action escaped_timestamp

    escaped_username=$(html_escape_text "$username")
    escaped_password=$(html_escape_text "$password")
    escaped_action=$(html_escape_text "$action")
    escaped_timestamp=$(html_escape_text "$timestamp")
    
    cat <<HTMLEOF
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <title>${escaped_action}通知</title>
</head>
<body style="margin:0;padding:0;background-color:#f0f2f5;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0">
<tr><td align="center" style="padding:40px 0;">
<table role="presentation" width="520" cellpadding="0" cellspacing="0" style="background:#ffffff;border-radius:12px;box-shadow:0 2px 8px rgba(0,0,0,0.08);overflow:hidden;">
  <tr>
    <td style="background:#2563eb;padding:28px 36px;">
      <h1 style="margin:0;color:#ffffff;font-size:20px;font-weight:600;">${escaped_action}通知</h1>
    </td>
  </tr>
  <tr>
    <td style="padding:32px 36px;">
      <p style="margin:0 0 20px;color:#374151;font-size:15px;line-height:1.6;">
        尊敬的用户 <strong>${escaped_username}</strong>，您好！
      </p>
      <p style="margin:0 0 24px;color:#374151;font-size:15px;line-height:1.6;">
        您的账户${escaped_action}已完成。以下是您的登录凭据：
      </p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f8fafc;border:1px solid #e2e8f0;border-radius:8px;margin-bottom:28px;">
        <tr>
          <td style="padding:20px 24px;">
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
              <tr>
                <td style="padding:6px 0;color:#6b7280;font-size:13px;width:70px;">用户名</td>
                <td style="padding:6px 0;color:#111827;font-size:15px;font-weight:600;font-family:'Courier New',monospace;">${escaped_username}</td>
              </tr>
              <tr>
                <td style="padding:6px 0;color:#6b7280;font-size:13px;">密 码</td>
                <td style="padding:6px 0;color:#2563eb;font-size:15px;font-weight:600;font-family:'Courier New',monospace;">${escaped_password}</td>
              </tr>
              <tr>
                <td style="padding:6px 0;color:#6b7280;font-size:13px;">时 间</td>
                <td style="padding:6px 0;color:#111827;font-size:14px;">${escaped_timestamp}</td>
              </tr>
            </table>
          </td>
        </tr>
      </table>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fffbeb;border-left:3px solid #f59e0b;border-radius:4px;margin-bottom:8px;">
        <tr>
          <td style="padding:16px 20px;">
            <p style="margin:0 0 10px;color:#92400e;font-size:14px;font-weight:600;">安全提示</p>
            <ul style="margin:0;padding:0 0 0 18px;color:#78350f;font-size:13px;line-height:2;">
              <li>请妥善保管您的密码，不要与他人分享</li>
              <li>建议首次登录后立即修改密码</li>
              <li>使用强密码并定期更换</li>
              <li>如非本人操作，请立即联系管理员</li>
            </ul>
          </td>
        </tr>
      </table>
    </td>
  </tr>
  <tr>
    <td style="padding:20px 36px;border-top:1px solid #e5e7eb;">
      <p style="margin:0;color:#9ca3af;font-size:12px;line-height:1.6;">
        此邮件由系统自动发送，请勿直接回复。如有问题，请联系系统管理员。<br>
         — 用户管理系统 · ${escaped_timestamp}
       </p>
     </td>
   </tr>
</table>
</td></tr>
</table>
</body>
</html>
HTMLEOF
}

# ============================================================
# 邮件队列管理（可选功能）
# ============================================================

# ============================================================
# SQLite持久化队列初始化
# ============================================================
email_queue_db_init() {
    if ! command -v sqlite3 &>/dev/null; then
        msg_err "需要 sqlite3 命令管理邮件队列"
        return 1
    fi
    
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

CREATE TABLE IF NOT EXISTS email_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    queue_id INTEGER,
    email TEXT NOT NULL,
    template TEXT,
    status TEXT NOT NULL,
    error TEXT,
    duration_ms INTEGER,
    created_at TEXT NOT NULL,
    FOREIGN KEY (queue_id) REFERENCES email_queue(id)
);
EOF
    
    chmod 600 "$EMAIL_QUEUE_DB" 2>/dev/null || true
    return 0
}

# ============================================================
# email_queue_add - 添加邮件到发送队列
# ============================================================
# Parameters:
#   $1 - username: 用户名
#   $2 - email: 收件人邮箱
#   $3 - template: 模板名称
#   $4 - data: JSON 格式的模板数据
#   $5 - priority: 优先级 (可选, 1-10, 默认5)
# ============================================================
email_queue_add() {
    local username="$1"
    local email="$2"
    local template="$3"
    local data="${4:-{}}"
    local priority="${5:-5}"
    
    if ! command -v sqlite3 &>/dev/null; then
        msg_err "需要 sqlite3 命令管理邮件队列"
        return 1
    fi
    
    [[ ! -f "$EMAIL_QUEUE_DB" ]] && email_queue_db_init
    
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local escaped_data="${data//\'/\'\'}"
    
    sqlite3 "$EMAIL_QUEUE_DB" <<EOF
INSERT INTO email_queue (username, email, template, data, status, priority, created_at)
VALUES ('$username', '$email', '$template', '$escaped_data', '$EMAIL_QUEUE_PENDING', $priority, '$timestamp');
EOF
    
    local result=$?
    if [[ $result -eq 0 ]]; then
        local queue_id
        queue_id=$(sqlite3 "$EMAIL_QUEUE_DB" "SELECT last_insert_rowid();")
        log_email_event "queue" "email=$email template=$template queue_id=$queue_id"
        echo "$queue_id"
        return 0
    else
        msg_err "邮件队列添加失败"
        return 1
    fi
}

# ============================================================
# email_queue_get_next - 获取下一条待发送邮件
# ============================================================
email_queue_get_next() {
    [[ ! -f "$EMAIL_QUEUE_DB" ]] && return 1
    
    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')
    
    sqlite3 "$EMAIL_QUEUE_DB" <<EOF
SELECT id, username, email, template, data FROM email_queue 
WHERE status = '$EMAIL_QUEUE_PENDING' 
  AND (scheduled_at IS NULL OR scheduled_at <= '$now')
  AND attempts < max_retries
ORDER BY priority ASC, created_at ASC 
LIMIT 1;
EOF
}

# ============================================================
# email_queue_mark_sending - 标记邮件为发送中
# ============================================================
email_queue_mark_sending() {
    local queue_id="$1"
    [[ -z "$queue_id" ]] && return 1
    
    sqlite3 "$EMAIL_QUEUE_DB" <<EOF
UPDATE email_queue 
SET status = '$EMAIL_QUEUE_SENDING', 
    scheduled_at = datetime('now')
WHERE id = $queue_id;
EOF
}

# ============================================================
# email_queue_mark_sent - 标记邮件已发送
# ============================================================
email_queue_mark_sent() {
    local queue_id="$1"
    local message_id="${2:-}"
    [[ -z "$queue_id" ]] && return 1
    
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    sqlite3 "$EMAIL_QUEUE_DB" <<EOF
UPDATE email_queue 
SET status = '$EMAIL_QUEUE_SENT', 
    sent_at = '$timestamp',
    message_id = '$message_id'
WHERE id = $queue_id;
EOF
}

# ============================================================
# email_queue_mark_failed - 标记邮件发送失败
# ============================================================
email_queue_mark_failed() {
    local queue_id="$1"
    local error="${2:-unknown error}"
    [[ -z "$queue_id" ]] && return 1
    
    local escaped_error="${error//\'/\'\'}"
    
    sqlite3 "$EMAIL_QUEUE_DB" <<EOF
UPDATE email_queue 
SET status = '$EMAIL_QUEUE_FAILED',
    error = '$escaped_error',
    attempts = attempts + 1
WHERE id = $queue_id;
EOF
}

# ============================================================
# email_queue_retry - 重试失败的邮件
# ============================================================
email_queue_retry() {
    local queue_id="$1"
    [[ -z "$queue_id" ]] && return 1
    
    sqlite3 "$EMAIL_QUEUE_DB" <<EOF
UPDATE email_queue 
SET status = '$EMAIL_QUEUE_PENDING',
    scheduled_at = datetime('now', '+30 seconds'),
    error = NULL
WHERE id = $queue_id 
  AND attempts < max_retries;
EOF
}

# ============================================================
# email_queue_stats - 队列统计
# ============================================================
email_queue_stats() {
    [[ ! -f "$EMAIL_QUEUE_DB" ]] && { echo "pending=0 sending=0 sent=0 failed=0"; return 0; }
    
    sqlite3 "$EMAIL_QUEUE_DB" <<EOF
SELECT 'pending=' || COUNT(*) FROM email_queue WHERE status = 'pending'
UNION ALL
SELECT 'sending=' || COUNT(*) FROM email_queue WHERE status = 'sending'
UNION ALL
SELECT 'sent=' || COUNT(*) FROM email_queue WHERE status = 'sent'
UNION ALL
SELECT 'failed=' || COUNT(*) FROM email_queue WHERE status = 'failed';
EOF
}

# ============================================================
# email_queue_cleanup - 清理已发送/失败的旧邮件
# ============================================================
email_queue_cleanup() {
    local keep_days="${1:-7}"
    
    [[ ! -f "$EMAIL_QUEUE_DB" ]] && return 0
    
    sqlite3 "$EMAIL_QUEUE_DB" <<EOF
DELETE FROM email_log 
WHERE created_at < datetime('now', '-$keep_days days');

DELETE FROM email_queue 
WHERE status IN ('$EMAIL_QUEUE_SENT', '$EMAIL_QUEUE_FAILED')
  AND created_at < datetime('now', '-$keep_days days');
EOF
}

# ============================================================
# email_queue_process - 处理邮件队列中的待发送邮件
# ============================================================
# Parameters:
#   $1 - max_emails: 单次处理最大邮件数 (默认：10)
# ============================================================
email_queue_process() {
    local max_emails="${1:-10}"
    
    if ! command -v sqlite3 &>/dev/null; then
        msg_err "需要 sqlite3 命令处理邮件队列"
        return 1
    fi
    
    [[ ! -f "$EMAIL_QUEUE_DB" ]] && { msg_info "邮件队列为空"; return 0; }
    
    local processed=0 success=0 failed=0
    
    while (( processed < max_emails )); do
        local next_email
        next_email=$(email_queue_get_next)
        
        [[ -z "$next_email" ]] && break
        
        local queue_id username email template data
        IFS='|' read -r queue_id username email template data <<< "$next_email"
        
        [[ -z "$queue_id" ]] && break
        
        email_queue_mark_sending "$queue_id"
        msg_info "处理队列邮件 #$queue_id：$username -> $email (模板：$template)"
        
        local send_result=1
        local start_time end_time duration_ms
        start_time=$(date +%s%3N 2>/dev/null || date +%s)
        
        case "$template" in
            password_notify)
                local password action
                if command -v jq &>/dev/null && [[ -n "$data" ]]; then
                    password=$(echo "$data" | jq -r '.password // empty')
                    action=$(echo "$data" | jq -r '.action // "密码更新"')
                fi
                [[ -n "$password" ]] && send_password_email "$username" "$password" "$email" "$action" && send_result=0
                ;;
            quota_warning)
                if declare -F send_quota_warning_email &>/dev/null; then
                    send_quota_warning_email "$username" "$email" "$data" && send_result=0
                else
                    msg_warn "quota_warning模板处理函数未实现"
                fi
                ;;
            account_suspended)
                if declare -F send_account_suspended_email &>/dev/null; then
                    send_account_suspended_email "$username" "$email" "$data" && send_result=0
                else
                    msg_warn "account_suspended模板处理函数未实现"
                fi
                ;;
            backup_completed)
                if declare -F send_backup_notification_email &>/dev/null; then
                    send_backup_notification_email "$username" "$email" "$data" && send_result=0
                else
                    msg_warn "backup_completed模板处理函数未实现"
                fi
                ;;
            *)
                msg_warn "未知模板类型：$template"
                ;;
        esac
        
        end_time=$(date +%s%3N 2>/dev/null || date +%s)
        duration_ms=$(( end_time - start_time ))
        
        if [[ $send_result -eq 0 ]]; then
            email_queue_mark_sent "$queue_id"
            log_email_event "$username" "$email" "$template" "sent" "queue_id=$queue_id duration=${duration_ms}ms"
            ((success+=1))
        else
            email_queue_mark_failed "$queue_id" "发送失败"
            log_email_event "$username" "$email" "$template" "failed" "queue_id=$queue_id"
            ((failed+=1))
        fi
        
        ((processed+=1))
    done
    
    msg_info "邮件队列处理完成：处理=$processed, 成功=$success, 失败=$failed"
    return 0
}

# ============================================================
# 异步邮件发送接口（使用 async_core.sh）
# ============================================================

# 异步发送密码通知邮件
# 参数: $1=username, $2=password, $3=email, $4=action
# 返回: 任务ID
send_password_email_async() {
    local username="$1"
    local password="$2"
    local email="$3"
    local action="${4:-密码更新}"
    
    # 构建任务数据
    local data
    data=$(jq -n \
        --arg u "$username" \
        --arg p "$password" \
        --arg e "$email" \
        --arg a "$action" \
        '{"username": $u, "password": $p, "email": $e, "action": $a}')
    
    # 提交到邮件队列
    local queue_id
    queue_id=$(email_queue_add "$username" "$email" "password_notify" "$data") || return 1
    
    echo "$queue_id"
    return 0
}

# 异步发送配额警告邮件
send_quota_warning_email_async() {
    local username="$1"
    local email="$2"
    local quota_info="$3"
    
    local data
    data=$(jq -n \
        --arg u "$username" \
        --arg e "$email" \
        --arg q "$quota_info" \
        '{"username": $u, "email": $e, "quota_info": $q}')
    
    local queue_id
    queue_id=$(email_queue_add "$username" "$email" "quota_warning" "$data") || return 1
    
    echo "$queue_id"
    return 0
}

# 异步发送账户暂停通知
send_account_suspended_email_async() {
    local username="$1"
    local email="$2"
    local reason="${3:-}"
    
    local data
    data=$(jq -n \
        --arg u "$username" \
        --arg e "$email" \
        --arg r "$reason" \
        '{"username": $u, "email": $e, "reason": $r}')
    
    local queue_id
    queue_id=$(email_queue_add "$username" "$email" "account_suspended" "$data") || return 1
    
    echo "$queue_id"
    return 0
}

# 异步发送备份完成通知
send_backup_completed_email_async() {
    local username="$1"
    local email="$2"
    local backup_details="$3"
    
    local data
    data=$(jq -n \
        --arg u "$username" \
        --arg e "$email" \
        --argjson d "$backup_details" \
        '{"username": $u, "email": $e, "details": $d}')
    
    local queue_id
    queue_id=$(email_queue_add "$username" "$email" "backup_completed" "$data") || return 1
    
    echo "$queue_id"
    return 0
}

# 检查邮件是否已发送
check_email_sent() {
    local queue_id="$1"
    
    local status
    status=$(sqlite3 "$EMAIL_QUEUE_DB" "SELECT status FROM email_queue WHERE id = $queue_id;" 2>/dev/null)
    
    [[ "$status" == "sent" ]]
}

# 等待邮件发送完成
wait_for_email() {
    local queue_id="$1"
    local timeout="${2:-60}"
    local interval=2
    local elapsed=0
    
    while (( elapsed < timeout )); do
        local status
        status=$(sqlite3 "$EMAIL_QUEUE_DB" "SELECT status FROM email_queue WHERE id = $queue_id;" 2>/dev/null)
        
        case "$status" in
            sent) return 0 ;;
            failed) return 1 ;;
            *) sleep "$interval"; ((elapsed += interval)) ;;
        esac
    done
    
    return 1
}
