#!/bin/bash
# privilege_cache.sh - 权限缓存和自动刷新机制
# 提供高性能的权限检查结果缓存

# ============================================================
# 缓存配置
# ============================================================

# 默认缓存TTL（秒）
readonly PRIV_CACHE_TTL_DEFAULT=${PRIV_CACHE_TTL:-300}

# 权限级别缓存TTL（较长，因为变化不频繁）
# shellcheck disable=SC2034
readonly PRIV_CACHE_TTL_LEVEL=600

# 命令白名单缓存TTL（很长，因为很少变化）
# shellcheck disable=SC2034
readonly PRIV_CACHE_TTL_WHITELIST=3600

# 缓存最大条目数（防止内存泄漏）
readonly PRIV_CACHE_MAX_ENTRIES=${PRIV_CACHE_MAX_ENTRIES:-1000}

# ============================================================
# 缓存存储结构
# ============================================================

# 主缓存存储: key -> value
declare -A _PRIV_CACHE_DATA=()

# 缓存时间戳: key -> timestamp
declare -A _PRIV_CACHE_TIMES=()

# 缓存TTL: key -> ttl_seconds
declare -A _PRIV_CACHE_TTLS=()

# 访问计数（用于LRU淘汰）
declare -A _PRIV_CACHE_ACCESSES=()

# 缓存统计
declare -i _PRIV_CACHE_HITS=0
declare -i _PRIV_CACHE_MISSES=0
declare -i _PRIV_CACHE_EVICTIONS=0

# ============================================================
# 核心缓存操作函数
# ============================================================

# 生成缓存键
# 用法: priv_cache_key <type> <identifier>
# 示例: priv_cache_key "level" "username"
priv_cache_key() {
    local type="$1"
    local identifier="$2"
    echo "priv:${type}:${identifier}"
}

# 获取缓存值
# 用法: priv_cache_get <key> <output_var>
# 返回: 0 如果命中缓存且未过期，1 如果未命中或过期
priv_cache_get() {
    local key="$1"
    local -n _out="$2"
    
    # 检查键是否存在
    if [[ -z "${_PRIV_CACHE_DATA[$key]:-}" ]]; then
        (( _PRIV_CACHE_MISSES++ ))
        return 1
    fi
    
    # 检查是否过期
    local now
    now=$(date +%s)
    local stored_time="${_PRIV_CACHE_TIMES[$key]:-0}"
    local ttl="${_PRIV_CACHE_TTLS[$key]:-$PRIV_CACHE_TTL_DEFAULT}"
    local age=$((now - stored_time))
    
    if [[ $age -ge $ttl ]]; then
        # 过期，删除缓存
        priv_cache_delete "$key"
        (( _PRIV_CACHE_MISSES++ ))
        return 1
    fi
    
    # 缓存命中
    _out="${_PRIV_CACHE_DATA[$key]}"
    _PRIV_CACHE_ACCESSES[$key]=$((${_PRIV_CACHE_ACCESSES[$key]:-0} + 1))
    (( _PRIV_CACHE_HITS++ ))
    
    return 0
}

# 设置缓存值
# 用法: priv_cache_set <key> <value> [ttl]
priv_cache_set() {
    local key="$1"
    local value="$2"
    local ttl="${3:-$PRIV_CACHE_TTL_DEFAULT}"
    local now
    now=$(date +%s)
    
    # 检查是否超过最大条目数
    local current_entries=${#_PRIV_CACHE_DATA[@]}
    if [[ $current_entries -ge $PRIV_CACHE_MAX_ENTRIES ]]; then
        # 使用 LRU 淘汰策略
        priv_cache_evict_lru
    fi
    
    # 设置缓存
    _PRIV_CACHE_DATA[$key]="$value"
    _PRIV_CACHE_TIMES[$key]=$now
    _PRIV_CACHE_TTLS[$key]=$ttl
    _PRIV_CACHE_ACCESSES[$key]=0
}

# 删除缓存
# 用法: priv_cache_delete <key>
priv_cache_delete() {
    local key="$1"
    
    unset '_PRIV_CACHE_DATA[$key]'
    unset '_PRIV_CACHE_TIMES[$key]'
    unset '_PRIV_CACHE_TTLS[$key]'
    unset '_PRIV_CACHE_ACCESSES[$key]'
}

# LRU 淘汰策略
# 淘汰最近最少使用的缓存项
priv_cache_evict_lru() {
    # shellcheck disable=SC2034
    local -a sorted_keys=()
    local min_accesses=-1
    local lru_key=""
    
    # 找到访问次数最少的键
    for key in "${!_PRIV_CACHE_DATA[@]}"; do
        local accesses=${_PRIV_CACHE_ACCESSES[$key]:-0}
        if [[ $min_accesses -eq -1 || $accesses -lt $min_accesses ]]; then
            min_accesses=$accesses
            lru_key="$key"
        fi
    done
    
    # 删除 LRU 项
    if [[ -n "$lru_key" ]]; then
        priv_cache_delete "$lru_key"
        (( _PRIV_CACHE_EVICTIONS++ ))
    fi
}

# ============================================================
# 缓存管理函数
# ============================================================

# 清除所有缓存
# 用法: priv_cache_clear
priv_cache_clear() {
    _PRIV_CACHE_DATA=()
    _PRIV_CACHE_TIMES=()
    _PRIV_CACHE_TTLS=()
    _PRIV_CACHE_ACCESSES=()
    _PRIV_CACHE_HITS=0
    _PRIV_CACHE_MISSES=0
    _PRIV_CACHE_EVICTIONS=0
}

# 刷新过期缓存
# 用法: priv_cache_refresh
priv_cache_refresh() {
    local now
    now=$(date +%s)
    local -a expired_keys=()
    
    for key in "${!_PRIV_CACHE_DATA[@]}"; do
        local stored_time=${_PRIV_CACHE_TIMES[$key]:-0}
        local ttl=${_PRIV_CACHE_TTLS[$key]:-$PRIV_CACHE_TTL_DEFAULT}
        local age=$((now - stored_time))
        
        if [[ $age -ge $ttl ]]; then
            expired_keys+=("$key")
        fi
    done
    
    for key in "${expired_keys[@]}"; do
        priv_cache_delete "$key"
    done
    
    return ${#expired_keys[@]}
}

# 获取缓存统计
# 用法: priv_cache_stats
priv_cache_stats() {
    local total=${#_PRIV_CACHE_DATA[@]}
    local total_accesses=0
    
    for key in "${!_PRIV_CACHE_ACCESSES[@]}"; do
        total_accesses=$((total_accesses + ${_PRIV_CACHE_ACCESSES[$key]:-0}))
    done
    
    local hit_rate=0
    local total_requests=$((_PRIV_CACHE_HITS + _PRIV_CACHE_MISSES))
    if [[ $total_requests -gt 0 ]]; then
        hit_rate=$((_PRIV_CACHE_HITS * 100 / total_requests))
    fi
    
    echo "{
  \"total_entries\": $total,
  \"hits\": $_PRIV_CACHE_HITS,
  \"misses\": $_PRIV_CACHE_MISSES,
  \"evictions\": $_PRIV_CACHE_EVICTIONS,
  \"hit_rate\": $hit_rate,
  \"total_accesses\": $total_accesses
}"
}

# ============================================================
# 自动刷新机制
# ============================================================

# 后台刷新进程的文件标记
readonly PRIV_CACHE_REFRESH_PID_FILE="${DATA_BASE:-/tmp}/.priv_cache_refresh.pid"

# 启动自动刷新守护进程
# 用法: priv_cache_start_refresh [interval_seconds]
priv_cache_start_refresh() {
    local interval="${1:-60}"  # 默认 60 秒刷新一次
    
    # 检查是否已经在运行
    if [[ -f "$PRIV_CACHE_REFRESH_PID_FILE" ]]; then
        local pid
        pid=$(cat "$PRIV_CACHE_REFRESH_PID_FILE" 2>/dev/null)
        if kill -0 "$pid" 2>/dev/null; then
            msg_info "Cache refresh daemon already running (PID: $pid)"
            return 0
        fi
    fi
    
    # 启动后台进程
    (
        while true; do
            priv_cache_refresh >/dev/null 2>&1
            sleep "$interval"
        done
    ) &
    
    local refresh_pid=$!
    echo "$refresh_pid" > "$PRIV_CACHE_REFRESH_PID_FILE"
    
    msg_ok "Cache refresh daemon started (PID: $refresh_pid, Interval: ${interval}s)"
    return 0
}

# 停止自动刷新守护进程
# 用法: priv_cache_stop_refresh
priv_cache_stop_refresh() {
    if [[ ! -f "$PRIV_CACHE_REFRESH_PID_FILE" ]]; then
        msg_warn "Cache refresh daemon not running"
        return 1
    fi
    
    local pid
    pid=$(cat "$PRIV_CACHE_REFRESH_PID_FILE" 2>/dev/null)
    
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        msg_ok "Cache refresh daemon stopped (PID: $pid)"
    else
        msg_warn "Cache refresh daemon not running (PID: $pid)"
    fi
    
    rm -f "$PRIV_CACHE_REFRESH_PID_FILE"
    return 0
}

# 检查刷新守护进程状态
# 用法: priv_cache_refresh_status
priv_cache_refresh_status() {
    if [[ ! -f "$PRIV_CACHE_REFRESH_PID_FILE" ]]; then
        echo "stopped"
        return 1
    fi
    
    local pid
    pid=$(cat "$PRIV_CACHE_REFRESH_PID_FILE" 2>/dev/null)
    
    if kill -0 "$pid" 2>/dev/null; then
        echo "running (PID: $pid)"
        return 0
    else
        echo "stopped (stale PID file)"
        return 1
    fi
}

# ============================================================
# 初始化
# ============================================================

# 模块初始化
priv_cache_init() {
    # 清理过期缓存
    priv_cache_refresh >/dev/null 2>&1 || true
}

# 执行初始化
priv_cache_init
