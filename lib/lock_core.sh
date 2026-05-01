#!/bin/bash
# lock_core.sh - 统一锁管理模块
# 提供三级锁系统：简单实例锁、增强超时锁、细粒度用户/操作/读写锁

# ============================================================
# 1. 简单实例锁（防多实例并发）
# ============================================================

LOCK_FILE="/tmp/user_manager_${USER:-unknown}.lock"
LOCK_HELD=false

acquire_lock() {
    mkdir -p "$(dirname "$LOCK_FILE")"
    if mkdir "$LOCK_FILE" 2>/dev/null; then
        LOCK_HELD=true; return 0
    else
        msg_err "另一个实例正在运行，请稍后再试。"; return 1
    fi
}

release_lock() {
    [[ "$LOCK_HELD" != true ]] && return 0
    rmdir "$LOCK_FILE" 2>/dev/null || true
    LOCK_HELD=false
}

# ============================================================
# 2. 增强超时锁
# ============================================================

# 带超时的锁获取
acquire_lock_with_timeout() {
    local timeout="${1:-30}"
    local lock_file="/tmp/user_manager_${USER:-unknown}.lock"
    local waited=0
    
    while (( waited < timeout )); do
        # 尝试创建锁目录（原子操作）
        if mkdir "$lock_file" 2>/dev/null; then
            echo $$ > "$lock_file/pid"
            date +%s > "$lock_file/timestamp"
            return 0
        fi
        
        # 检查锁是否过期（超过 5 分钟）
        if [[ -f "$lock_file/timestamp" ]]; then
            local lock_time lock_age
            lock_time=$(cat "$lock_file/timestamp" 2>/dev/null || echo "0")
            lock_age=$(( $(date +%s) - lock_time ))
            
            if (( lock_age > 300 )); then
                local lock_pid
                lock_pid=$(cat "$lock_file/pid" 2>/dev/null || echo "unknown")
                
                # 检查进程是否还在运行
                if ! kill -0 "$lock_pid" 2>/dev/null; then
                    msg_warn "清理过期锁 (PID: $lock_pid, 年龄: ${lock_age}s)"
                    rm -rf "$lock_file"
                    continue
                fi
            fi
        fi
        
        sleep 1
        ((waited++))
    done
    
    msg_err "获取锁超时 (${timeout}s)"
    msg_info "可能有其他操作正在进行，请稍后重试"
    return 1
}

# 释放锁（增强版）
release_lock_enhanced() {
    local lock_file="/tmp/user_manager_${USER:-unknown}.lock"
    
    if [[ -d "$lock_file" ]]; then
        # 验证锁是否属于当前进程
        local lock_pid
        lock_pid=$(cat "$lock_file/pid" 2>/dev/null || echo "")
        
        if [[ "$lock_pid" == "$$" ]]; then
            rm -rf "$lock_file"
            return 0
        else
            msg_warn "锁不属于当前进程，跳过释放"
            return 1
        fi
    fi
    
    return 0
}

# 检查锁状态
check_lock_status() {
    local lock_file="/tmp/user_manager_${USER:-unknown}.lock"
    
    if [[ ! -d "$lock_file" ]]; then
        echo "unlocked"
        return 0
    fi
    
    local lock_pid lock_time lock_age
    lock_pid=$(cat "$lock_file/pid" 2>/dev/null || echo "unknown")
    lock_time=$(cat "$lock_file/timestamp" 2>/dev/null || echo "0")
    lock_age=$(( $(date +%s) - lock_time ))
    
    echo "locked (PID: $lock_pid, Age: ${lock_age}s)"
    return 1
}

# ============================================================
# 3. 细粒度锁系统（用户级、操作级）
# ============================================================

# 锁目录
readonly FINE_LOCK_DIR="/tmp/user_manager_locks"

# 初始化细粒度锁目录
_init_fine_lock_dir() {
    mkdir -p "$FINE_LOCK_DIR" 2>/dev/null || true
}

# 获取用户锁文件路径
_user_lock_file() {
    local username="$1"
    echo "$FINE_LOCK_DIR/user_${username}.lock"
}

# 获取操作锁文件路径
_operation_lock_file() {
    local operation="$1"
    echo "$FINE_LOCK_DIR/op_${operation}.lock"
}

# 获取用户读锁文件路径
_user_read_lock_file() {
    local username="$1"
    echo "$FINE_LOCK_DIR/user_${username}.read"
}

# 获取用户写锁文件路径
_user_write_lock_file() {
    local username="$1"
    echo "$FINE_LOCK_DIR/user_${username}.write"
}

# ============================================================
# 用户级锁（防止同一用户被并发操作）
# ============================================================

# 获取用户锁
acquire_user_lock() {
    local username="$1"
    local timeout="${2:-30}"
    
    _init_fine_lock_dir
    local lock_file
    lock_file=$(_user_lock_file "$username")
    
    local waited=0
    while (( waited < timeout )); do
        if mkdir "$lock_file" 2>/dev/null; then
            echo $$ > "$lock_file/pid"
            date +%s > "$lock_file/timestamp"
            return 0
        fi
        
        # 检查锁是否过期（超过2分钟）
        if [[ -f "$lock_file/timestamp" ]]; then
            local lock_time lock_age
            lock_time=$(cat "$lock_file/timestamp" 2>/dev/null || echo "0")
            lock_age=$(( $(date +%s) - lock_time ))
            
            if (( lock_age > 120 )); then
                local lock_pid
                lock_pid=$(cat "$lock_file/pid" 2>/dev/null || echo "unknown")
                if ! kill -0 "$lock_pid" 2>/dev/null; then
                    rm -rf "$lock_file"
                    continue
                fi
            fi
        fi
        
        sleep 0.5
        ((waited++))
    done
    
    msg_err "无法获取用户 '$username' 的锁 (${timeout}s超时)"
    return 1
}

# 释放用户锁
release_user_lock() {
    local username="$1"
    local lock_file
    lock_file=$(_user_lock_file "$username")
    
    if [[ -d "$lock_file" ]]; then
        local lock_pid
        lock_pid=$(cat "$lock_file/pid" 2>/dev/null || echo "")
        if [[ "$lock_pid" == "$$" ]]; then
            rm -rf "$lock_file"
        fi
    fi
}

# ============================================================
# 读写锁分离（支持并发读取，独占写入）
# ============================================================

# 获取用户读锁（允许多个读取者）
acquire_user_read_lock() {
    local username="$1"
    local timeout="${2:-10}"
    
    _init_fine_lock_dir
    local read_lock write_lock
    read_lock=$(_user_read_lock_file "$username")
    write_lock=$(_user_write_lock_file "$username")
    
    local waited=0
    while (( waited < timeout )); do
        # 如果有写锁，等待
        if [[ -d "$write_lock" ]]; then
            sleep 0.2
            ((waited++))
            continue
        fi
        
        # 创建读锁
        mkdir -p "$read_lock" 2>/dev/null || true
        local reader_id="${read_lock}/reader_${$}"
        echo $$ > "$reader_id"
        return 0
    done
    
    return 1
}

# 释放用户读锁
release_user_read_lock() {
    local username="$1"
    local read_lock
    read_lock=$(_user_read_lock_file "$username")
    
    local reader_id="${read_lock}/reader_${$}"
    rm -f "$reader_id" 2>/dev/null
    
    # 如果没有其他读取者，删除读锁目录
    if [[ -d "$read_lock" ]]; then
        local reader_count
        reader_count=$(find "$read_lock" -name 'reader_*' 2>/dev/null | wc -l)
        (( reader_count == 0 )) && rmdir "$read_lock" 2>/dev/null || true
    fi
}

# 获取用户写锁（独占）
acquire_user_write_lock() {
    local username="$1"
    local timeout="${2:-30}"
    
    _init_fine_lock_dir
    local read_lock write_lock
    read_lock=$(_user_read_lock_file "$username")
    write_lock=$(_user_write_lock_file "$username")
    
    local waited=0
    while (( waited < timeout )); do
        # 如果有其他写锁或读锁，等待
        if [[ -d "$write_lock" ]]; then
            sleep 0.2
            ((waited++))
            continue
        fi
        
        if [[ -d "$read_lock" ]]; then
            local reader_count
            reader_count=$(find "$read_lock" -name 'reader_*' 2>/dev/null | wc -l)
            (( reader_count > 0 )) && {
                sleep 0.2
                ((waited++))
                continue
            }
        fi
        
        # 创建写锁
        if mkdir "$write_lock" 2>/dev/null; then
            echo $$ > "$write_lock/pid"
            date +%s > "$write_lock/timestamp"
            return 0
        fi
        
        sleep 0.2
        ((waited++))
    done
    
    msg_err "无法获取用户 '$username' 的写锁"
    return 1
}

# 释放用户写锁
release_user_write_lock() {
    local username="$1"
    local write_lock
    write_lock=$(_user_write_lock_file "$username")
    
    if [[ -d "$write_lock" ]]; then
        local lock_pid
        lock_pid=$(cat "$write_lock/pid" 2>/dev/null || echo "")
        if [[ "$lock_pid" == "$$" ]]; then
            rm -rf "$write_lock"
        fi
    fi
}

# ============================================================
# 操作级锁（防止特定操作并发）
# ============================================================

# 获取操作锁
acquire_operation_lock() {
    local operation="$1"
    local timeout="${2:-60}"
    
    _init_fine_lock_dir
    local lock_file
    lock_file=$(_operation_lock_file "$operation")
    
    local waited=0
    while (( waited < timeout )); do
        if mkdir "$lock_file" 2>/dev/null; then
            echo $$ > "$lock_file/pid"
            date +%s > "$lock_file/timestamp"
            return 0
        fi
        
        # 检查过期（超过10分钟）
        if [[ -f "$lock_file/timestamp" ]]; then
            local lock_time lock_age
            lock_time=$(cat "$lock_file/timestamp" 2>/dev/null || echo "0")
            lock_age=$(( $(date +%s) - lock_time ))
            if (( lock_age > 600 )); then
                rm -rf "$lock_file"
                continue
            fi
        fi
        
        sleep 1
        ((waited++))
    done
    
    msg_err "无法获取操作 '$operation' 的锁"
    return 1
}

# 释放操作锁
release_operation_lock() {
    local operation="$1"
    local lock_file
    lock_file=$(_operation_lock_file "$operation")
    
    if [[ -d "$lock_file" ]]; then
        local lock_pid
        lock_pid=$(cat "$lock_file/pid" 2>/dev/null || echo "")
        if [[ "$lock_pid" == "$$" ]]; then
            rm -rf "$lock_file"
        fi
    fi
}

# ============================================================
# 交互式输入锁管理（在输入前释放，输入后重新获取）
# ============================================================

# 保存锁状态并临时释放
suspend_lock_for_input() {
    local username="$1"
    local lock_var="_LOCK_SUSPENDED_$username"
    
    # 保存当前锁状态
    local lock_file
    lock_file=$(_user_lock_file "$username")
    
    if [[ -d "$lock_file" ]]; then
        local lock_pid
        lock_pid=$(cat "$lock_file/pid" 2>/dev/null || echo "")
        if [[ "$lock_pid" == "$$" ]]; then
            # 标记为已暂停
            declare -g "$lock_var"=1
            # 不释放锁，只标记为暂停状态，允许其他操作检查
            touch "$lock_file/suspended" 2>/dev/null || true
            return 0
        fi
    fi
    
    return 1
}

# 恢复锁状态
resume_lock_after_input() {
    local username="$1"
    local lock_var="_LOCK_SUSPENDED_$username"
    local lock_file
    lock_file=$(_user_lock_file "$username")
    
    # 移除暂停标记
    rm -f "$lock_file/suspended" 2>/dev/null || true
    
    # 清除暂停状态标记
    declare -g "$lock_var"=0
}

# 检查锁是否处于暂停状态（供其他操作检查）
is_lock_suspended() {
    local username="$1"
    local lock_file
    lock_file=$(_user_lock_file "$username")
    
    [[ -f "$lock_file/suspended" ]]
}
