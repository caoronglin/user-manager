#!/bin/bash
# proc_manager.sh - 进程管理框架 v1.0.0
# 提供后台进程管理、状态监控、信号处理功能

set -uo pipefail

# ============================================================
# 配置常量
# ============================================================

# 进程管理目录
readonly PROC_RUN_DIR="/var/run/user_manager"
readonly PROC_PID_DIR="$PROC_RUN_DIR/pids"
readonly PROC_SOCKET_DIR="$PROC_RUN_DIR/sockets"
readonly PROC_LOG_DIR="${LOG_DIR:-./logs}/procs"

# 默认配置
readonly PROC_MAX_CHILDREN=10
readonly PROC_DEFAULT_TIMEOUT=3600
readonly PROC_HEALTH_CHECK_INTERVAL=30

# 进程状态
readonly PROC_STATUS_RUNNING="running"
readonly PROC_STATUS_STOPPED="stopped"
readonly PROC_STATUS_COMPLETED="completed"
readonly PROC_STATUS_FAILED="failed"
readonly PROC_STATUS_TIMEOUT="timeout"

# ============================================================
# 初始化函数
# ============================================================

# 初始化进程管理器
proc_init() {
    # 创建目录
    if declare -F run_privileged &>/dev/null; then
        run_privileged mkdir -p "$PROC_PID_DIR" "$PROC_SOCKET_DIR" "$PROC_LOG_DIR" 2>/dev/null || true
        run_privileged chmod 755 "$PROC_RUN_DIR" 2>/dev/null || true
    else
        mkdir -p "$PROC_PID_DIR" "$PROC_SOCKET_DIR" "$PROC_LOG_DIR" 2>/dev/null || true
    fi
    
    return 0
}

# ============================================================
# 进程注册与管理
# ============================================================

# 生成进程ID
proc_generate_id() {
    echo "proc_$(date +%Y%m%d%H%M%S)_$(( RANDOM % 10000 ))"
}

# 注册后台进程
# 参数: $1=进程名称, $2=PID, $3=描述(可选), $4=超时(可选)
proc_register() {
    local name="$1"
    local pid="$2"
    local description="${3:-}"
    local timeout="${4:-$PROC_DEFAULT_TIMEOUT}"
    
    proc_init
    
    local proc_id
    proc_id=$(proc_generate_id)
    
    # 创建进程信息文件
    local pid_file="$PROC_PID_DIR/${proc_id}.json"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local timeout_at
    timeout_at=$(date -d "+${timeout} seconds" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')
    
    cat > "$pid_file" <<EOF
{
    "id": "$proc_id",
    "name": "$name",
    "pid": $pid,
    "description": "$description",
    "status": "$PROC_STATUS_RUNNING",
    "started_at": "$timestamp",
    "timeout_at": "$timeout_at",
    "parent_pid": $$
}
EOF
    
    echo "$proc_id"
    return 0
}

# 更新进程状态
proc_update_status() {
    local proc_id="$1"
    local status="$2"
    local extra="${3:-}"
    
    local pid_file="$PROC_PID_DIR/${proc_id}.json"
    
    if [[ ! -f "$pid_file" ]]; then
        return 1
    fi
    
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # 读取现有信息
    local name pid description started_at timeout_at parent_pid
    eval $(cat "$pid_file" | sed 's/"//g' | awk -F: '{gsub(/[,{}]/, "", $2); print $1 "=" $2}')
    
    # 更新文件
    cat > "$pid_file" <<EOF
{
    "id": "$proc_id",
    "name": "$name",
    "pid": $pid,
    "description": "$description",
    "status": "$status",
    "started_at": "$started_at",
    "completed_at": "$timestamp",
    "timeout_at": "$timeout_at",
    "parent_pid": $parent_pid,
    "extra": "$extra"
}
EOF
    
    return 0
}

# 注销进程
proc_unregister() {
    local proc_id="$1"
    local pid_file="$PROC_PID_DIR/${proc_id}.json"
    
    rm -f "$pid_file" 2>/dev/null || true
}

# ============================================================
# 进程启动与管理
# ============================================================

# 启动后台进程
# 参数: $1=进程名称, $2=命令, $3=超时(可选)
# 返回: 进程ID
proc_start() {
    local name="$1"
    local command="$2"
    local timeout="${3:-$PROC_DEFAULT_TIMEOUT}"
    
    # 启动后台进程
    eval "$command &"
    local pid=$!
    
    # 注册进程
    local proc_id
    proc_id=$(proc_register "$name" "$pid" "$command" "$timeout")
    
    # 设置清理trap
    # shellcheck disable=SC2064
    trap "proc_cleanup '$proc_id'" EXIT
    
    echo "$proc_id"
    return 0
}

# 启动带日志的后台进程
# 参数: $1=进程名称, $2=命令, $3=日志文件(可选)
proc_start_with_log() {
    local name="$1"
    local command="$2"
    local log_file="${3:-$PROC_LOG_DIR/${name}_$(date +%Y%m%d_%H%M%S).log}"
    
    mkdir -p "$(dirname "$log_file")" 2>/dev/null || true
    
    # 启动进程并重定向输出
    eval "$command >> '$log_file' 2>&1 &"
    local pid=$!
    
    # 注册进程
    local proc_id
    proc_id=$(proc_register "$name" "$pid" "$command")
    
    echo "$proc_id|$log_file"
    return 0
}

# 停止进程
# 参数: $1=进程ID, $2=信号(可选, 默认TERM)
proc_stop() {
    local proc_id="$1"
    local signal="${2:-TERM}"
    
    local pid_file="$PROC_PID_DIR/${proc_id}.json"
    
    if [[ ! -f "$pid_file" ]]; then
        return 1
    fi
    
    # 获取PID
    local pid
    pid=$(grep -o '"pid": [0-9]*' "$pid_file" | grep -o '[0-9]*')
    
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill -"$signal" "$pid" 2>/dev/null
        proc_update_status "$proc_id" "$PROC_STATUS_STOPPED" "Signal: $signal"
        return 0
    fi
    
    return 1
}

# 强制终止进程
proc_kill() {
    local proc_id="$1"
    proc_stop "$proc_id" "KILL"
}

# 等待进程完成
# 参数: $1=进程ID, $2=超时(可选)
# 返回: 0=成功完成, 1=超时或失败
proc_wait() {
    local proc_id="$1"
    local timeout="${2:-60}"
    local interval=2
    local elapsed=0
    
    local pid_file="$PROC_PID_DIR/${proc_id}.json"
    
    if [[ ! -f "$pid_file" ]]; then
        return 1
    fi
    
    local pid
    pid=$(grep -o '"pid": [0-9]*' "$pid_file" | grep -o '[0-9]*')
    
    while (( elapsed < timeout )); do
        if ! kill -0 "$pid" 2>/dev/null; then
            # 进程已结束
            local exit_status
            wait "$pid" 2>/dev/null
            exit_status=$?
            
            if [[ $exit_status -eq 0 ]]; then
                proc_update_status "$proc_id" "$PROC_STATUS_COMPLETED"
            else
                proc_update_status "$proc_id" "$PROC_STATUS_FAILED" "Exit code: $exit_status"
            fi
            
            return $([[ $exit_status -eq 0 ]] && echo 0 || echo 1)
        fi
        
        sleep "$interval"
        ((elapsed += interval))
    done
    
    # 超时
    proc_update_status "$proc_id" "$PROC_STATUS_TIMEOUT"
    return 1
}

# ============================================================
# 进程状态查询
# ============================================================

# 获取进程信息
proc_info() {
    local proc_id="$1"
    local pid_file="$PROC_PID_DIR/${proc_id}.json"
    
    if [[ -f "$pid_file" ]]; then
        cat "$pid_file"
        return 0
    fi
    
    return 1
}

# 获取进程状态
proc_get_status() {
    local proc_id="$1"
    local pid_file="$PROC_PID_DIR/${proc_id}.json"
    
    if [[ ! -f "$pid_file" ]]; then
        echo "unknown"
        return 1
    fi
    
    grep -o '"status": "[^"]*"' "$pid_file" | cut -d'"' -f4
}

# 检查进程是否存活
proc_is_alive() {
    local proc_id="$1"
    local pid_file="$PROC_PID_DIR/${proc_id}.json"
    
    if [[ ! -f "$pid_file" ]]; then
        return 1
    fi
    
    local pid
    pid=$(grep -o '"pid": [0-9]*' "$pid_file" | grep -o '[0-9]*')
    
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# 列出所有进程
proc_list() {
    local status_filter="${1:-}"
    
    for pid_file in "$PROC_PID_DIR"/*.json; do
        [[ -f "$pid_file" ]] || continue
        
        local proc_id name pid status
        proc_id=$(basename "$pid_file" .json)
        name=$(grep -o '"name": "[^"]*"' "$pid_file" | cut -d'"' -f4)
        pid=$(grep -o '"pid": [0-9]*' "$pid_file" | grep -o '[0-9]*')
        status=$(grep -o '"status": "[^"]*"' "$pid_file" | cut -d'"' -f4)
        
        if [[ -z "$status_filter" ]] || [[ "$status" == "$status_filter" ]]; then
            echo "$proc_id|$name|$pid|$status"
        fi
    done
}

# ============================================================
# 进程池管理
# ============================================================

# 进程池结构
declare -A PROC_POOL=()
declare -i PROC_POOL_SIZE=0

# 初始化进程池
proc_pool_init() {
    local max_size="${1:-$PROC_MAX_CHILDREN}"
    
    PROC_POOL=()
    PROC_POOL_SIZE=$max_size
    
    proc_init
}

# 向进程池添加任务
# 参数: $1=进程名称, $2=命令, $3=超时(可选)
# 返回: 进程ID或空（池已满）
proc_pool_submit() {
    local name="$1"
    local command="$2"
    local timeout="${3:-$PROC_DEFAULT_TIMEOUT}"
    
    # 检查池容量
    local running=0
    for proc_id in "${!PROC_POOL[@]}"; do
        if proc_is_alive "$proc_id"; then
            ((running++))
        else
            # 清理已完成进程
            unset "PROC_POOL[$proc_id]"
        fi
    done
    
    if (( running >= PROC_POOL_SIZE )); then
        return 1
    fi
    
    # 启动进程
    local proc_id
    proc_id=$(proc_start "$name" "$command" "$timeout")
    
    PROC_POOL["$proc_id"]="$name"
    
    echo "$proc_id"
    return 0
}

# 等待进程池中所有进程完成
# 参数: $1=超时(可选)
proc_pool_wait_all() {
    local timeout="${1:-300}"
    local elapsed=0
    local interval=2
    
    while (( elapsed < timeout )); do
        local all_done=true
        
        for proc_id in "${!PROC_POOL[@]}"; do
            if proc_is_alive "$proc_id"; then
                all_done=false
                break
            else
                unset "PROC_POOL[$proc_id]"
            fi
        done
        
        if $all_done; then
            return 0
        fi
        
        sleep "$interval"
        ((elapsed += interval))
    done
    
    return 1
}

# 终止进程池中所有进程
proc_pool_kill_all() {
    for proc_id in "${!PROC_POOL[@]}"; do
        proc_stop "$proc_id" "TERM" 2>/dev/null || true
    done
    
    sleep 2
    
    # 强制清理
    for proc_id in "${!PROC_POOL[@]}"; do
        proc_kill "$proc_id" 2>/dev/null || true
        unset "PROC_POOL[$proc_id]"
    done
}

# ============================================================
# 进程健康检查
# ============================================================

# 检查超时进程
proc_check_timeouts() {
    local now
    now=$(date +%s)
    
    for pid_file in "$PROC_PID_DIR"/*.json; do
        [[ -f "$pid_file" ]] || continue
        
        local status timeout_at
        status=$(grep -o '"status": "[^"]*"' "$pid_file" | cut -d'"' -f4)
        
        [[ "$status" == "$PROC_STATUS_RUNNING" ]] || continue
        
        timeout_at=$(grep -o '"timeout_at": "[^"]*"' "$pid_file" | cut -d'"' -f4)
        
        if [[ -n "$timeout_at" ]]; then
            local timeout_ts
            timeout_ts=$(date -d "$timeout_at" +%s 2>/dev/null || echo "0")
            
            if (( now > timeout_ts )); then
                local proc_id
                proc_id=$(basename "$pid_file" .json)
                local pid
                pid=$(grep -o '"pid": [0-9]*' "$pid_file" | grep -o '[0-9]*')
                
                if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                    kill -TERM "$pid" 2>/dev/null
                    proc_update_status "$proc_id" "$PROC_STATUS_TIMEOUT"
                    
                    if declare -F msg_warn &>/dev/null; then
                        msg_warn "进程 $proc_id 超时已终止"
                    fi
                fi
            fi
        fi
    done
}

# 清理僵尸进程记录
proc_cleanup_zombies() {
    for pid_file in "$PROC_PID_DIR"/*.json; do
        [[ -f "$pid_file" ]] || continue
        
        local pid status
        pid=$(grep -o '"pid": [0-9]*' "$pid_file" | grep -o '[0-9]*')
        status=$(grep -o '"status": "[^"]*"' "$pid_file" | cut -d'"' -f4)
        
        if [[ "$status" == "$PROC_STATUS_RUNNING" ]]; then
            if ! kill -0 "$pid" 2>/dev/null; then
                # 进程已不存在，标记为失败
                local proc_id
                proc_id=$(basename "$pid_file" .json)
                proc_update_status "$proc_id" "$PROC_STATUS_FAILED" "Process died unexpectedly"
            fi
        fi
    done
}

# 启动健康检查守护进程
proc_start_health_daemon() {
    (
        while true; do
            proc_check_timeouts
            proc_cleanup_zombies
            sleep "$PROC_HEALTH_CHECK_INTERVAL"
        done
    ) &
    
    echo $!
}

# ============================================================
# 信号处理
# ============================================================

# 设置信号处理器
proc_setup_signal_handlers() {
    local cleanup_func="${1:-proc_default_cleanup}"
    
    # shellcheck disable=SC2064
    trap "$cleanup_func" EXIT INT TERM HUP
}

# 默认清理函数
proc_default_cleanup() {
    proc_pool_kill_all 2>/dev/null || true
}

# ============================================================
# 清理函数
# ============================================================

# 清理单个进程
proc_cleanup() {
    local proc_id="$1"
    
    proc_stop "$proc_id" 2>/dev/null || true
    proc_unregister "$proc_id"
}

# 清理所有进程
proc_cleanup_all() {
    for pid_file in "$PROC_PID_DIR"/*.json; do
        [[ -f "$pid_file" ]] || continue
        
        local proc_id
        proc_id=$(basename "$pid_file" .json)
        proc_cleanup "$proc_id"
    done
}

# 初始化
proc_init 2>/dev/null || true