#!/bin/bash
# async_core.sh - 异步任务框架 v1.0.0
# 提供后台任务提交、执行、状态查询功能
# 依赖: sqlite3, jq

set -uo pipefail

# ============================================================
# 配置常量
# ============================================================

# 获取脚本目录
_ASYNC_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 异步任务数据库路径
readonly ASYNC_DB="${DATA_DIR:-${_ASYNC_SCRIPT_DIR}/../data}/async_tasks.db"

# 工作目录
readonly ASYNC_RUN_DIR="/var/run/user_manager"
readonly ASYNC_SOCKET_DIR="$ASYNC_RUN_DIR/sockets"
readonly ASYNC_PID_DIR="$ASYNC_RUN_DIR/workers"

# 默认配置
# shellcheck disable=SC2034
readonly ASYNC_MAX_WORKERS=3
# shellcheck disable=SC2034
readonly ASYNC_TASK_TIMEOUT=3600
# shellcheck disable=SC2034
readonly ASYNC_RETRY_DELAY=5

# 任务状态
readonly ASYNC_STATUS_PENDING="pending"
readonly ASYNC_STATUS_RUNNING="running"
readonly ASYNC_STATUS_COMPLETED="completed"
readonly ASYNC_STATUS_FAILED="failed"
readonly ASYNC_STATUS_TIMEOUT="timeout"

# ============================================================
# 初始化函数
# ============================================================

# 初始化异步任务系统
async_init() {
    # 创建数据目录
    mkdir -p "$(dirname "$ASYNC_DB")" 2>/dev/null || true
    
    # 创建运行目录
    if declare -F run_privileged &>/dev/null; then
        run_privileged mkdir -p "$ASYNC_RUN_DIR" "$ASYNC_SOCKET_DIR" "$ASYNC_PID_DIR" 2>/dev/null || true
        run_privileged chmod 755 "$ASYNC_RUN_DIR" 2>/dev/null || true
    else
        mkdir -p "$ASYNC_RUN_DIR" "$ASYNC_SOCKET_DIR" "$ASYNC_PID_DIR" 2>/dev/null || true
    fi
    
    # 初始化SQLite数据库
    if ! command -v sqlite3 &>/dev/null; then
        if declare -F msg_err &>/dev/null; then
            msg_err "async_core: 需要 sqlite3 命令"
        else
            echo "ERROR: async_core requires sqlite3" >&2
        fi
        return 1
    fi
    
    # 创建表结构
    sqlite3 "$ASYNC_DB" <<'EOF'
-- 任务队列表
CREATE TABLE IF NOT EXISTS tasks (
    id TEXT PRIMARY KEY,
    type TEXT NOT NULL,
    data TEXT,
    status TEXT NOT NULL DEFAULT 'pending',
    priority INTEGER DEFAULT 5,
    worker_pid INTEGER,
    created_at TEXT NOT NULL,
    started_at TEXT,
    completed_at TEXT,
    result TEXT,
    error TEXT,
    retry_count INTEGER DEFAULT 0,
    max_retries INTEGER DEFAULT 3
);

-- 任务日志表
CREATE TABLE IF NOT EXISTS task_logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id TEXT NOT NULL,
    timestamp TEXT NOT NULL,
    level TEXT NOT NULL,
    message TEXT,
    FOREIGN KEY (task_id) REFERENCES tasks(id)
);

-- 创建索引
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_type ON tasks(type);
CREATE INDEX IF NOT EXISTS idx_tasks_created ON tasks(created_at);
CREATE INDEX IF NOT EXISTS idx_task_logs_task ON task_logs(task_id);
EOF

    # 设置数据库权限
    chmod 600 "$ASYNC_DB" 2>/dev/null || true
    
    return 0
}

# ============================================================
# 任务提交函数
# ============================================================

# 生成任务ID
async_generate_id() {
    echo "task_$(date +%Y%m%d%H%M%S)_$(( RANDOM % 10000 ))"
}

# 提交异步任务
# 参数: $1=任务类型, $2=任务数据(JSON), $3=优先级(可选, 1-10, 默认5)
# 返回: 任务ID
async_submit() {
    local task_type="$1"
    local task_data="${2:-}"
    local priority="${3:-5}"
    
    # 参数验证
    if [[ -z "$task_type" ]]; then
        if declare -F msg_err &>/dev/null; then
            msg_err "async_submit: 任务类型不能为空"
        fi
        return 1
    fi
    
    # 确保数据库已初始化
    if [[ ! -f "$ASYNC_DB" ]]; then
        async_init || return 1
    fi
    
    # 生成任务ID
    local task_id
    task_id=$(async_generate_id)
    
    # 当前时间戳
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # 转义JSON数据
    local escaped_data="${task_data//\'/\'\'}"
    
    # 插入任务
    if sqlite3 "$ASYNC_DB" <<EOF
INSERT INTO tasks (id, type, data, status, priority, created_at, max_retries)
VALUES ('$task_id', '$task_type', '$escaped_data', '$ASYNC_STATUS_PENDING', $priority, '$timestamp', $ASYNC_RETRY_MAX);
EOF
    then
        # 记录日志
        async_log "$task_id" "INFO" "任务已提交: type=$task_type"
        
        # 通知worker（通过文件存在信号）
        local notify_file="$ASYNC_RUN_DIR/.new_task"
        touch "$notify_file" 2>/dev/null || true
        
        echo "$task_id"
        return 0
    else
        return 1
    fi
}

# 批量提交任务
# 参数: $1=任务类型, $2=任务数据数组(以换行分隔)
async_submit_batch() {
    local task_type="$1"
    local tasks_data="$2"
    
    local -a task_ids=()
    local count=0
    
    while IFS= read -r task_data; do
        [[ -z "$task_data" ]] && continue
        local tid
        tid=$(async_submit "$task_type" "$task_data") && {
            task_ids+=("$tid")
            ((count+=1))
        }
    done <<< "$tasks_data"
    
    echo "${task_ids[*]}"
    return 0
}

# ============================================================
# 任务状态查询函数
# ============================================================

# 查询任务状态
# 参数: $1=任务ID
# 输出: JSON格式的任务信息
async_status() {
    local task_id="$1"
    
    if [[ ! -f "$ASYNC_DB" ]]; then
        echo '{"error": "database not found"}'
        return 1
    fi
    
    sqlite3 "$ASYNC_DB" <<EOF
SELECT json_object(
    'id', id,
    'type', type,
    'status', status,
    'priority', priority,
    'worker_pid', worker_pid,
    'created_at', created_at,
    'started_at', started_at,
    'completed_at', completed_at,
    'result', result,
    'error', error,
    'retry_count', retry_count
) FROM tasks WHERE id = '$task_id';
EOF
}

# 查询任务状态（简洁版）
# 参数: $1=任务ID
# 输出: 状态字符串
async_get_status() {
    local task_id="$1"
    
    sqlite3 "$ASYNC_DB" "SELECT status FROM tasks WHERE id = '$task_id';" 2>/dev/null || echo "unknown"
}

# 等待任务完成
# 参数: $1=任务ID, $2=超时秒数(可选, 默认60)
# 返回: 0表示成功, 1表示失败或超时
async_wait() {
    local task_id="$1"
    local timeout="${2:-60}"
    local interval=2
    local elapsed=0
    
    while (( elapsed < timeout )); do
        local status
        status=$(async_get_status "$task_id")
        
        case "$status" in
            "$ASYNC_STATUS_COMPLETED")
                return 0
                ;;
            "$ASYNC_STATUS_FAILED" | "$ASYNC_STATUS_TIMEOUT")
                return 1
                ;;
            "$ASYNC_STATUS_PENDING" | "$ASYNC_STATUS_RUNNING")
                sleep "$interval"
                ((elapsed += interval))
                ;;
            *)
                return 1
                ;;
        esac
    done
    
    return 1  # 超时
}

# 获取任务结果
# 参数: $1=任务ID
# 输出: 任务结果数据
async_result() {
    local task_id="$1"
    
    sqlite3 "$ASYNC_DB" "SELECT result FROM tasks WHERE id = '$task_id';" 2>/dev/null
}

# 列出所有任务
# 参数: $1=状态过滤(可选), $2=限制数量(可选)
async_list() {
    local status_filter="${1:-}"
    local limit="${2:-50}"
    
    local where_clause=""
    [[ -n "$status_filter" ]] && where_clause="WHERE status = '$status_filter'"
    
    sqlite3 "$ASYNC_DB" <<EOF
SELECT id, type, status, created_at, completed_at 
FROM tasks $where_clause 
ORDER BY created_at DESC 
LIMIT $limit;
EOF
}

# 统计任务
async_stats() {
    sqlite3 "$ASYNC_DB" <<EOF
SELECT 
    status,
    COUNT(*) as count
FROM tasks
GROUP BY status;
EOF
}

# ============================================================
# 任务执行器
# ============================================================

# 记录任务日志
async_log() {
    local task_id="$1"
    local level="$2"
    local message="$3"
    
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    local escaped_message="${message//\'/\'\'}"
    
    sqlite3 "$ASYNC_DB" <<EOF
INSERT INTO task_logs (task_id, timestamp, level, message)
VALUES ('$task_id', '$timestamp', '$level', '$escaped_message');
EOF
}

# 标记任务开始
async_start_task() {
    local task_id="$1"
    local worker_pid="$2"
    
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    sqlite3 "$ASYNC_DB" <<EOF
UPDATE tasks 
SET status = '$ASYNC_STATUS_RUNNING', 
    worker_pid = $worker_pid,
    started_at = '$timestamp'
WHERE id = '$task_id';
EOF
}

# 标记任务完成
async_complete_task() {
    local task_id="$1"
    local result="${2:-}"
    local status="${3:-$ASYNC_STATUS_COMPLETED}"
    
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    local escaped_result="${result//\'/\'\'}"
    
    sqlite3 "$ASYNC_DB" <<EOF
UPDATE tasks 
SET status = '$status',
    completed_at = '$timestamp',
    result = '$escaped_result'
WHERE id = '$task_id';
EOF
}

# 标记任务失败
async_fail_task() {
    local task_id="$1"
    local error="${2:-}"
    
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    local escaped_error="${error//\'/\'\'}"
    
    # 获取当前重试次数
    local retry_count
    retry_count=$(sqlite3 "$ASYNC_DB" "SELECT retry_count FROM tasks WHERE id = '$task_id';")
    local max_retries
    max_retries=$(sqlite3 "$ASYNC_DB" "SELECT max_retries FROM tasks WHERE id = '$task_id';")
    
    if (( retry_count < max_retries )); then
        # 可以重试
        ((retry_count+=1))
        sqlite3 "$ASYNC_DB" <<EOF
UPDATE tasks 
SET status = '$ASYNC_STATUS_PENDING',
    retry_count = $retry_count,
    error = '$escaped_error',
    worker_pid = NULL
WHERE id = '$task_id';
EOF
        async_log "$task_id" "WARN" "任务失败，将重试 ($retry_count/$max_retries): $error"
    else
        # 达到最大重试次数
        sqlite3 "$ASYNC_DB" <<EOF
UPDATE tasks 
SET status = '$ASYNC_STATUS_FAILED',
    completed_at = '$timestamp',
    error = '$escaped_error'
WHERE id = '$task_id';
EOF
        async_log "$task_id" "ERROR" "任务最终失败: $error"
    fi
}

# 任务执行器主循环
# 参数: $1=worker_id
async_worker_loop() {
    local worker_id="${1:-1}"
    local worker_pid=$$
    
    # 写入PID文件
    echo "$worker_pid" > "$ASYNC_PID_DIR/worker_$worker_id.pid" 2>/dev/null || true
    
    if declare -F msg_info &>/dev/null; then
        msg_info "Async worker #$worker_id started (PID: $worker_pid)"
    fi
    
    while true; do
        # 获取下一个待处理任务（按优先级）
        local task_info
        task_info=$(sqlite3 "$ASYNC_DB" <<EOF
SELECT id, type, data FROM tasks 
WHERE status = '$ASYNC_STATUS_PENDING'
ORDER BY priority ASC, created_at ASC
LIMIT 1;
EOF
        )
        
        if [[ -z "$task_info" ]]; then
            sleep 2
            continue
        fi
        
        # 解析任务信息
        local task_id task_type task_data
        IFS='|' read -r task_id task_type task_data <<< "$task_info"
        
        async_log "$task_id" "INFO" "Worker #$worker_id 开始处理任务"
        async_start_task "$task_id" "$worker_pid"
        
        # 执行任务（调用对应的处理函数）
        local result=""
        local exit_code=0
        
        case "$task_type" in
            email)
                # 邮件发送任务
                if declare -F async_handle_email &>/dev/null; then
                    result=$(async_handle_email "$task_data" 2>&1) || exit_code=$?
                else
                    result="No email handler registered"
                    exit_code=1
                fi
                ;;
            backup)
                # 备份任务
                if declare -F async_handle_backup &>/dev/null; then
                    result=$(async_handle_backup "$task_data" 2>&1) || exit_code=$?
                else
                    result="No backup handler registered"
                    exit_code=1
                fi
                ;;
            *)
                # 自定义任务类型
                local handler_func="async_handle_$task_type"
                if declare -F "$handler_func" &>/dev/null; then
                    result=$("$handler_func" "$task_data" 2>&1) || exit_code=$?
                else
                    result="Unknown task type: $task_type"
                    exit_code=1
                fi
                ;;
        esac
        
        # 更新任务状态
        if [[ $exit_code -eq 0 ]]; then
            async_complete_task "$task_id" "$result"
            async_log "$task_id" "INFO" "任务完成"
        else
            async_fail_task "$task_id" "$result"
        fi
        
        sleep 1
    done
}

# 启动后台worker
# 参数: $1=worker数量(可选, 默认1)
async_start_workers() {
    local num_workers="${1:-1}"
    
    mkdir -p "$ASYNC_PID_DIR" 2>/dev/null || true
    
    local i
    for ((i = 1; i <= num_workers; i++)); do
        # 检查是否已有worker在运行
        local pid_file="$ASYNC_PID_DIR/worker_$i.pid"
        if [[ -f "$pid_file" ]]; then
            local old_pid
            old_pid=$(cat "$pid_file" 2>/dev/null)
            if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
                if declare -F msg_warn &>/dev/null; then
                    msg_warn "Worker #$i already running (PID: $old_pid)"
                fi
                continue
            fi
        fi
        
        # 启动后台worker
        (
            source "${BASH_SOURCE[0]}"
            async_worker_loop "$i"
        ) &
        
        if declare -F msg_ok &>/dev/null; then
            msg_ok "Started async worker #$i"
        fi
    done
}

# 停止所有worker
async_stop_workers() {
    if [[ ! -d "$ASYNC_PID_DIR" ]]; then
        return 0
    fi
    
    local pid_file
    for pid_file in "$ASYNC_PID_DIR"/*.pid; do
        [[ -f "$pid_file" ]] || continue
        local pid
        pid=$(cat "$pid_file" 2>/dev/null)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null && {
                if declare -F msg_info &>/dev/null; then
                    msg_info "Stopped worker (PID: $pid)"
                fi
            }
        fi
        rm -f "$pid_file" 2>/dev/null
    done
}

# ============================================================
# 任务管理
# ============================================================

# 取消任务
async_cancel() {
    local task_id="$1"
    
    local status
    status=$(async_get_status "$task_id")
    
    case "$status" in
        "$ASYNC_STATUS_PENDING")
            sqlite3 "$ASYNC_DB" "UPDATE tasks SET status = 'cancelled' WHERE id = '$task_id';"
            return 0
            ;;
        "$ASYNC_STATUS_RUNNING")
            # 需要终止worker
            local worker_pid
            worker_pid=$(sqlite3 "$ASYNC_DB" "SELECT worker_pid FROM tasks WHERE id = '$task_id';")
            if [[ -n "$worker_pid" ]] && kill -0 "$worker_pid" 2>/dev/null; then
                kill "$worker_pid" 2>/dev/null || true
            fi
            sqlite3 "$ASYNC_DB" "UPDATE tasks SET status = 'cancelled' WHERE id = '$task_id';"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# 清理已完成任务
# 参数: $1=保留天数(可选, 默认7)
async_cleanup() {
    local keep_days="${1:-7}"
    
    sqlite3 "$ASYNC_DB" <<EOF
DELETE FROM task_logs 
WHERE task_id IN (
    SELECT id FROM tasks 
    WHERE status IN ('$ASYNC_STATUS_COMPLETED', '$ASYNC_STATUS_FAILED', 'cancelled')
    AND datetime(completed_at) < datetime('now', '-$keep_days days')
);

DELETE FROM tasks 
WHERE status IN ('$ASYNC_STATUS_COMPLETED', '$ASYNC_STATUS_FAILED', 'cancelled')
AND datetime(completed_at) < datetime('now', '-$keep_days days');
EOF
}

# 重试失败任务
async_retry_failed() {
    sqlite3 "$ASYNC_DB" <<EOF
UPDATE tasks 
SET status = '$ASYNC_STATUS_PENDING',
    retry_count = 0,
    error = NULL,
    worker_pid = NULL
WHERE status = '$ASYNC_STATUS_FAILED';
EOF
}

# ============================================================
# 初始化检查
# ============================================================

# 确保初始化
async_ensure_init() {
    if [[ ! -f "$ASYNC_DB" ]]; then
        async_init
    fi
}

# 模块加载时自动初始化
async_ensure_init 2>/dev/null || true