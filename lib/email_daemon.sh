#!/bin/bash
# email_daemon.sh - 邮件发送守护进程 v1.0.0
# 后台处理邮件队列、指数退避重试、SMTP连接管理

set -uo pipefail

# ============================================================
# 配置常量
# ============================================================

# 守护进程目录
readonly DAEMON_RUN_DIR="/var/run/user_manager"
readonly DAEMON_PID_FILE="$DAEMON_RUN_DIR/email_daemon.pid"

# 邮件队列数据库
readonly EMAIL_QUEUE_DB="${DATA_DIR:-./data}/email_queue.db"

# 日志文件
readonly DAEMON_LOG_DIR="${LOG_DIR:-./logs}"
readonly DAEMON_LOG_FILE="$DAEMON_LOG_DIR/email_daemon.log"

# 重试配置
readonly INITIAL_RETRY_DELAY=60
readonly MAX_RETRY_DELAY=3600
readonly RETRY_MULTIPLIER=2

# 守护进程配置
readonly POLL_INTERVAL=5
readonly BATCH_SIZE=10


# ============================================================
# 日志函数
# ============================================================

daemon_log() {
    local level="$1"
    local message="$2"
    
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    mkdir -p "$DAEMON_LOG_DIR" 2>/dev/null || true
    
    printf '[%s] [%s] %s\n' "$timestamp" "$level" "$message" >> "$DAEMON_LOG_FILE"
    
    if [[ "$level" == "ERROR" ]]; then
        echo "[$timestamp] [$level] $message" >&2
    fi
}

# ============================================================
# 守护进程管理
# ============================================================

is_daemon_running() {
    if [[ -f "$DAEMON_PID_FILE" ]]; then
        local pid
        pid=$(cat "$DAEMON_PID_FILE" 2>/dev/null)
        if [[ -z "$pid" ]]; then
            return 1
        fi
        if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
            rm -f "$DAEMON_PID_FILE"
            return 1
        fi
        kill -0 "$pid" 2>/dev/null
    else
        return 1
    fi
}

start_daemon() {
    if is_daemon_running; then
        echo "邮件守护进程已在运行"
        return 1
    fi
    
    mkdir -p "$DAEMON_RUN_DIR" 2>/dev/null || true
    mkdir -p "$DAEMON_LOG_DIR" 2>/dev/null || true
    chmod 750 "$DAEMON_RUN_DIR" "$DAEMON_LOG_DIR" 2>/dev/null || true
    
    local lock_fd
    exec {lock_fd}>"$DAEMON_PID_FILE.lock" 2>/dev/null || true
    if [[ -n "${lock_fd:-}" ]]; then
        flock -n "$lock_fd" 2>/dev/null || {
            exec {lock_fd}>&-
            echo "无法获取守护进程锁，可能已有实例在启动"
            return 1
        }
    fi
    
    # 启动后台守护进程
    (
        email_daemon_loop
    ) &
    
    local pid=$!
    echo "$pid" > "$DAEMON_PID_FILE"
    chmod 644 "$DAEMON_PID_FILE" 2>/dev/null || true
    
    if [[ -n "${lock_fd:-}" ]]; then
        exec {lock_fd}>&-
    fi
    
    echo "邮件守护进程已启动 (PID: $pid)"
    daemon_log "INFO" "守护进程启动 (PID: $pid)"
    return 0
}

stop_daemon() {
    if ! is_daemon_running; then
        echo "邮件守护进程未运行"
        return 1
    fi
    
    local pid
    pid=$(cat "$DAEMON_PID_FILE" 2>/dev/null)
    
    if [[ -n "$pid" ]]; then
        kill -TERM "$pid" 2>/dev/null
        sleep 2
        
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null
        fi
        
        rm -f "$DAEMON_PID_FILE"
        echo "邮件守护进程已停止 (PID: $pid)"
        daemon_log "INFO" "守护进程停止 (PID: $pid)"
    fi
    
    return 0
}

daemon_status() {
    if is_daemon_running; then
        local pid
        pid=$(cat "$DAEMON_PID_FILE" 2>/dev/null)
        echo "运行中 (PID: $pid)"
        
        if [[ -f "$EMAIL_QUEUE_DB" ]]; then
            local stats
            stats=$(source lib/email_core.sh 2>/dev/null && email_queue_stats 2>/dev/null || echo "pending=0 sending=0 sent=0 failed=0")
            echo "队列状态: $stats"
        fi
    else
        echo "未运行"
    fi
}

# ============================================================
# 核心处理循环
# ============================================================

email_daemon_loop() {
    daemon_log "INFO" "守护进程主循环开始"
    
    # 加载邮件模块
    if [[ -f "${BASH_SOURCE[0]%/*}/email_core.sh" ]]; then
        source "${BASH_SOURCE[0]%/*}/email_core.sh" 2>/dev/null
    elif [[ -f "lib/email_core.sh" ]]; then
        source "lib/email_core.sh" 2>/dev/null
    fi
    
    trap 'daemon_log "INFO" "守护进程收到终止信号"; rm -f "$DAEMON_PID_FILE"; exit 0' TERM INT HUP
    
    while true; do
        # 检查数据库是否存在
        if [[ ! -f "$EMAIL_QUEUE_DB" ]]; then
            sleep "$POLL_INTERVAL"
            continue
        fi
        
        # 处理待发送邮件
        process_email_batch
        
        # 处理失败邮件重试
        retry_failed_emails
        
        sleep "$POLL_INTERVAL"
    done
}

# ============================================================
# 批量处理邮件
# ============================================================

process_email_batch() {
    local pending_count
    pending_count=$(sqlite3 "$EMAIL_QUEUE_DB" "SELECT COUNT(*) FROM email_queue WHERE status = 'pending';" 2>/dev/null || echo "0")
    
    if (( pending_count == 0 )); then
        return 0
    fi
    
    daemon_log "INFO" "处理邮件批次 (待发送: $pending_count)"
    
    if declare -F email_queue_process &>/dev/null; then
        email_queue_process "$BATCH_SIZE"
    else
        # 直接处理
        local count=0
        while (( count < BATCH_SIZE )); do
            local next_email
            next_email=$(sqlite3 "$EMAIL_QUEUE_DB" "SELECT id, username, email, template, data FROM email_queue WHERE status = 'pending' ORDER BY priority ASC, created_at ASC LIMIT 1;" 2>/dev/null)
            
            [[ -z "$next_email" ]] && break
            
            local queue_id username email template data
            IFS='|' read -r queue_id username email template data <<< "$next_email"
            
            process_single_email "$queue_id" "$username" "$email" "$template" "$data"
            ((count+=1))
        done
        
        daemon_log "INFO" "批次处理完成: $count 封邮件"
    fi
}

# ============================================================
# 单封邮件处理
# ============================================================

process_single_email() {
    local queue_id="$1"
    local username="$2"
    local email="$3"
    local template="$4"
    local data="$5"
    
    sqlite3 "$EMAIL_QUEUE_DB" "UPDATE email_queue SET status = 'sending' WHERE id = $queue_id;" 2>/dev/null
    
    local send_result=1
    
    case "$template" in
        password_notify)
            if declare -F send_password_email &>/dev/null; then
                local password action
                password=$(echo "$data" | jq -r '.password // empty' 2>/dev/null)
                action=$(echo "$data" | jq -r '.action // "密码更新"' 2>/dev/null)
                [[ -n "$password" ]] && send_password_email "$username" "$password" "$email" "$action" && send_result=0
            fi
            ;;
        quota_warning)
            if declare -F send_quota_warning_email &>/dev/null; then
                send_quota_warning_email "$username" "$email" "$data" && send_result=0
            fi
            ;;
        account_suspended)
            if declare -F send_account_suspended_email &>/dev/null; then
                send_account_suspended_email "$username" "$email" "$data" && send_result=0
            fi
            ;;
        backup_completed)
            if declare -F send_backup_notification_email &>/dev/null; then
                send_backup_notification_email "$username" "$email" "$data" && send_result=0
            fi
            ;;
        *)
            daemon_log "WARN" "未知模板: $template"
            ;;
    esac
    
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    if [[ $send_result -eq 0 ]]; then
        sqlite3 "$EMAIL_QUEUE_DB" "UPDATE email_queue SET status = 'sent', sent_at = '$timestamp' WHERE id = $queue_id;" 2>/dev/null
        daemon_log "INFO" "邮件发送成功: #$queue_id $email"
    else
        local attempts
        attempts=$(sqlite3 "$EMAIL_QUEUE_DB" "SELECT attempts FROM email_queue WHERE id = $queue_id;" 2>/dev/null || echo "0")
        ((attempts+=1))
        
        if (( attempts >= 5 )); then
            sqlite3 "$EMAIL_QUEUE_DB" "UPDATE email_queue SET status = 'failed', attempts = $attempts, error = '超过最大重试次数' WHERE id = $queue_id;" 2>/dev/null
            daemon_log "ERROR" "邮件最终失败: #$queue_id $email (重试 $attempts 次)"
        else
            # 计算退避延迟
            local delay=$(( INITIAL_RETRY_DELAY * RETRY_MULTIPLIER ** (attempts - 1) ))
            (( delay > MAX_RETRY_DELAY )) && delay=$MAX_RETRY_DELAY
            
            local scheduled_at
            scheduled_at=$(date -d "+$delay seconds" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')
            
            sqlite3 "$EMAIL_QUEUE_DB" "UPDATE email_queue SET status = 'pending', attempts = $attempts, scheduled_at = '$scheduled_at' WHERE id = $queue_id;" 2>/dev/null
            daemon_log "WARN" "邮件发送失败，将在 ${delay}s 后重试: #$queue_id $email (第 $attempts 次)"
        fi
    fi
}

# ============================================================
# 失败邮件重试
# ============================================================

retry_failed_emails() {
    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')
    
    local retryable
    retryable=$(sqlite3 "$EMAIL_QUEUE_DB" "SELECT COUNT(*) FROM email_queue WHERE status = 'pending' AND scheduled_at IS NOT NULL AND scheduled_at <= '$now';" 2>/dev/null || echo "0")
    
    if (( retryable > 0 )); then
        daemon_log "INFO" "有 $retryable 封邮件等待重试"
    fi
}

# ============================================================
# 命令行接口
# ============================================================

case "${1:-}" in
    start)
        start_daemon
        ;;
    stop)
        stop_daemon
        ;;
    restart)
        stop_daemon
        sleep 1
        start_daemon
        ;;
    status)
        daemon_status
        ;;
    run)
        email_daemon_loop
        ;;
    *)
        echo "用法: $0 {start|stop|restart|status|run}"
        echo ""
        echo "命令:"
        echo "  start   - 启动邮件守护进程"
        echo "  stop    - 停止邮件守护进程"
        echo "  restart - 重启邮件守护进程"
        echo "  status  - 查看守护进程状态"
        echo "  run     - 前台运行（调试用）"
        exit 1
        ;;
esac