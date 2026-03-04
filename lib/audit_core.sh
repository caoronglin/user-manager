#!/bin/bash
# audit_core.sh - 审计日志系统 v1.0
# 提供操作审计、日志管理和查询功能

set -uo pipefail

# ============================================================
# 配置
# ============================================================

# 审计日志目录
readonly AUDIT_LOG_DIR="${DATA_DIR:-./data}/audit"
readonly AUDIT_LOG_FILE="$AUDIT_LOG_DIR/operations.log"
# shellcheck disable=SC2034
readonly AUDIT_INDEX_FILE="$AUDIT_LOG_DIR/index.db"

# 日志轮转配置
readonly AUDIT_MAX_SIZE=$((10 * 1024 * 1024))  # 10MB
readonly AUDIT_MAX_FILES=10

# 操作类型定义
# shellcheck disable=SC2034
readonly AUDIT_OP_CREATE="CREATE"
# shellcheck disable=SC2034
readonly AUDIT_OP_UPDATE="UPDATE"
# shellcheck disable=SC2034
readonly AUDIT_OP_DELETE="DELETE"
# shellcheck disable=SC2034
readonly AUDIT_OP_READ="READ"
# shellcheck disable=SC2034
readonly AUDIT_OP_LOGIN="LOGIN"
# shellcheck disable=SC2034
readonly AUDIT_OP_LOGOUT="LOGOUT"
# shellcheck disable=SC2034
readonly AUDIT_OP_CONFIG="CONFIG"
# shellcheck disable=SC2034
readonly AUDIT_OP_BACKUP="BACKUP"
# shellcheck disable=SC2034
readonly AUDIT_OP_RESTORE="RESTORE"

# 操作结果
readonly AUDIT_RESULT_SUCCESS="SUCCESS"
readonly AUDIT_RESULT_FAILURE="FAILURE"
readonly AUDIT_RESULT_DENIED="DENIED"
readonly AUDIT_RESULT_ERROR="ERROR"

# ============================================================
# 初始化函数
# ============================================================

# 初始化审计系统
audit_init() {
    # 创建日志目录
    if [[ ! -d "$AUDIT_LOG_DIR" ]]; then
        mkdir -p "$AUDIT_LOG_DIR" 2>/dev/null || {
            if declare -F msg_err &>/dev/null; then
                msg_err "无法创建审计日志目录: $AUDIT_LOG_DIR"
            else
                echo "无法创建审计日志目录: $AUDIT_LOG_DIR" >&2
            fi
            return 1
        }
    fi
    
    # 设置适当的权限
    chmod 750 "$AUDIT_LOG_DIR" 2>/dev/null || true
    
    # 检查日志文件是否存在
    if [[ ! -f "$AUDIT_LOG_FILE" ]]; then
        touch "$AUDIT_LOG_FILE" 2>/dev/null || {
            if declare -F msg_err &>/dev/null; then
                msg_err "无法创建审计日志文件: $AUDIT_LOG_FILE"
            else
                echo "无法创建审计日志文件: $AUDIT_LOG_FILE" >&2
            fi
            return 1
        }
        chmod 640 "$AUDIT_LOG_FILE" 2>/dev/null || true
    fi
    
    return 0
}

# ============================================================
# 核心审计函数
# ============================================================

# 转义字段，避免破坏分隔符
audit_escape_field() {
    local value="$1"
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/}
    value=${value//|/\\|}
    echo "$value"
}

# 安全写入审计日志（可选 flock）
audit_write_line() {
    local line="$1"
    if command -v flock &>/dev/null; then
        local fd
        if exec {fd}>>"$AUDIT_LOG_FILE" 2>/dev/null; then
            flock -w 3 "$fd" 2>/dev/null || true
            printf '%s\n' "$line" >&"$fd"
            exec {fd}>&-
            return 0
        fi
    fi
    if printf '%s\n' "$line" >> "$AUDIT_LOG_FILE" 2>/dev/null; then
        return 0
    fi
    if declare -F priv_exec &>/dev/null; then
        printf '%s\n' "$line" | priv_exec tee -a "$AUDIT_LOG_FILE" >/dev/null 2>&1
    fi
}

# 记录审计日志
# 参数：$1=操作类型, $2=目标对象, $3=结果, $4=详情(可选), $5=用户(可选)
audit_log() {
    local op_type="${1:-UNKNOWN}"
    local target="${2:-}"
    local result="${3:-$AUDIT_RESULT_SUCCESS}"
    local details="${4:-}"
    local user="${5:-${USER:-unknown}}"
    
    # 检查日志文件大小，必要时轮转
    audit_rotate_check
    
    # 获取当前时间（Unix时间戳 + 可读格式）
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local unix_time
    unix_time=$(date +%s)
    
    # 获取主机名和进程信息
    local hostname
    hostname=$(hostname 2>/dev/null || echo "unknown")
    local pid=$$
    local ppid=${PPID:-0}
    
    local esc_hostname esc_user esc_op esc_target esc_result esc_details
    esc_hostname=$(audit_escape_field "$hostname")
    esc_user=$(audit_escape_field "$user")
    esc_op=$(audit_escape_field "$op_type")
    esc_target=$(audit_escape_field "$target")
    esc_result=$(audit_escape_field "$result")
    esc_details=$(audit_escape_field "$details")
    
    # 构建日志条目（使用 | 作为分隔符）
    # 格式: timestamp|unix_time|hostname|pid|ppid|user|op_type|target|result|details
    local log_entry="${timestamp}|${unix_time}|${esc_hostname}|${pid}|${ppid}|${esc_user}|${esc_op}|${esc_target}|${esc_result}|${esc_details}"
    
    # 写入日志文件
    audit_write_line "$log_entry"
    
    # 更新索引（异步，不阻塞主流程）
    (audit_update_index "$timestamp" "$op_type" "$target" "$result" "$user") &
    
    return 0
}

# 记录操作成功
audit_success() {
    audit_log "$1" "$2" "$AUDIT_RESULT_SUCCESS" "$3"
}

# 记录操作失败
audit_failure() {
    audit_log "$1" "$2" "$AUDIT_RESULT_FAILURE" "$3"
}

# 记录操作被拒绝
audit_denied() {
    audit_log "$1" "$2" "$AUDIT_RESULT_DENIED" "$3"
}

# 记录错误
audit_error() {
    audit_log "$1" "$2" "$AUDIT_RESULT_ERROR" "$3"
}

# ============================================================
# 日志轮转和管理
# ============================================================

# 检查并执行日志轮转
audit_rotate_check() {
    # 检查日志文件大小
    if [[ ! -f "$AUDIT_LOG_FILE" ]]; then
        return 0
    fi
    
    local size
    size=$(stat -f%z "$AUDIT_LOG_FILE" 2>/dev/null || stat -c%s "$AUDIT_LOG_FILE" 2>/dev/null || echo 0)
    
    if [[ $size -gt $AUDIT_MAX_SIZE ]]; then
        audit_rotate
    fi
    
    return 0
}

# 执行日志轮转
audit_rotate() {
    local timestamp
    timestamp=$(date +%Y%m%d%H%M%S)
    local backup_file="${AUDIT_LOG_FILE}.${timestamp}"
    
    # 移动当前日志到备份
    mv "$AUDIT_LOG_FILE" "$backup_file" 2>/dev/null || {
        # 如果移动失败，尝试复制后清空
        cp "$AUDIT_LOG_FILE" "$backup_file" 2>/dev/null && 
        : > "$AUDIT_LOG_FILE" 2>/dev/null
    }
    
    # 压缩备份文件
    if command -v gzip &>/dev/null; then
        gzip "$backup_file" 2>/dev/null || true
    fi
    
    # 清理旧日志文件
    audit_cleanup_old_logs
    
    return 0
}

# 清理旧日志文件
audit_cleanup_old_logs() {
    local log_dir
    log_dir=$(dirname "$AUDIT_LOG_FILE")
    
    # 查找并删除最旧的日志文件，只保留最近的几份
    local log_files
    log_files=$(find "$log_dir" -name "$(basename "$AUDIT_LOG_FILE").*.gz" -type f 2>/dev/null | sort)
    
    local count
    count=$(echo "$log_files" | wc -l)
    
    if [[ $count -gt $AUDIT_MAX_FILES ]]; then
        local to_delete=$((count - AUDIT_MAX_FILES))
        echo "$log_files" | head -n "$to_delete" | while read -r file; do
            rm -f "$file" 2>/dev/null || true
        done
    fi
    
    return 0
}

# ============================================================
# 日志查询功能
# ============================================================

# 查询审计日志
# 参数：$1=操作类型(可选), $2=用户(可选), $3=日期范围(可选，格式: YYYY-MM-DD 或 YYYY-MM-DD:YYYY-MM-DD)
audit_query() {
    local op_type="${1:-}"
    local user="${2:-}"
    local date_range="${3:-}"
    
    # 检查日志文件是否存在
    if [[ ! -f "$AUDIT_LOG_FILE" ]]; then
        echo "审计日志文件不存在"
        return 1
    fi
    
    # 解析日期范围
    local date_start="" date_end=""
    if [[ -n "$date_range" ]]; then
        if [[ "$date_range" == *:* ]]; then
            date_start="${date_range%%:*}"
            date_end="${date_range##*:}"
        else
            # 单个日期，仅查询该天
            date_start="$date_range"
            date_end="$date_range"
        fi
    fi
    
    # 构建查询条件
    local conditions=()
    
    if [[ -n "$op_type" ]]; then
        conditions+=("$op_type")
    fi
    
    if [[ -n "$user" ]]; then
        conditions+=("$user")
    fi
    
    # 第一步：按操作类型和用户过滤
    {
        if [[ ${#conditions[@]} -gt 0 ]]; then
            local pattern
            pattern=$(IFS='|'; echo "${conditions[*]}")
            grep -E "$pattern" "$AUDIT_LOG_FILE"
        else
            cat "$AUDIT_LOG_FILE"
        fi
    } | {
        # 第二步：日期过滤
        if [[ -n "$date_start" && -n "$date_end" ]]; then
            while IFS='|' read -r ts rest; do
                local log_date="${ts%% *}"
                if [[ ! "$log_date" < "$date_start" && ! "$log_date" > "$date_end" ]]; then
                    echo "${ts}|${rest}"
                fi
            done
        else
            cat
        fi
    } | tail -n 100
    
    return 0
}

# 显示审计统计
audit_stats() {
    if [[ ! -f "$AUDIT_LOG_FILE" ]]; then
        echo "审计日志文件不存在"
        return 1
    fi
    
    local total_lines
    total_lines=$(wc -l < "$AUDIT_LOG_FILE")
    
    local today
    today=$(date +%Y-%m-%d)
    local today_count
    today_count=$(grep -c "^$today" "$AUDIT_LOG_FILE" 2>/dev/null || echo 0)
    
    echo "审计日志统计："
    echo "  总记录数：$total_lines"
    echo "  今日记录：$today_count"
    echo "  日志文件：$AUDIT_LOG_FILE"
    
    return 0
}

# ============================================================
# 模块初始化
# ============================================================

# 初始化审计模块
init_audit_module() {
    # 初始化审计系统
    audit_init || {
        echo "警告：审计系统初始化失败" >&2
        return 1
    }
    
    return 0
}

# 执行初始化
init_audit_module
