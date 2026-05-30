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
readonly AUDIT_JOURNAL_IDENTIFIER="${AUDIT_JOURNAL_IDENTIFIER:-user-manager}"

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
    if ! audit_backend_uses_file; then
        return 0
    fi

    # 创建日志目录
    if [[ ! -d "$AUDIT_LOG_DIR" ]]; then
        mkdir -p "$AUDIT_LOG_DIR" 2>/dev/null || {
            msg_err "无法创建审计日志目录: $AUDIT_LOG_DIR"
            return 1
        }
    fi
    
    # 设置适当的权限
    chmod 750 "$AUDIT_LOG_DIR" 2>/dev/null || true
    
    # 检查日志文件是否存在
    if [[ ! -f "$AUDIT_LOG_FILE" ]]; then
        touch "$AUDIT_LOG_FILE" 2>/dev/null || {
            msg_err "无法创建审计日志文件: $AUDIT_LOG_FILE"
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
    local value="${1:-}"
    [[ -z "$value" ]] && { echo ""; return 0; }
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/}
    value=${value//|/\\|}
    echo "$value"
}

audit_context_value() {
    local value="${1:-unknown}"
    value=${value//$'\n'/ }
    value=${value//$'\r'/}
    value=${value//|/ }
    value=${value//;/,}
    [[ -n "$value" ]] || value="unknown"
    printf '%s' "$value"
}

audit_source_ip() {
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        printf '%s\n' "${SSH_CONNECTION%% *}"
    elif [[ -n "${SSH_CLIENT:-}" ]]; then
        printf '%s\n' "${SSH_CLIENT%% *}"
    else
        printf 'local\n'
    fi
}

audit_collect_context() {
    local hostname="${1:-}"
    local pid="${2:-$$}"
    local ppid="${3:-${PPID:-0}}"
    local actor="${4:-${USER:-unknown}}"
    local uid euid cwd tty_name source_ip sudo_user login_user session_id shell_name

    [[ -n "$hostname" ]] || hostname=$(hostname 2>/dev/null || printf 'unknown')
    uid=$(id -u 2>/dev/null || printf 'unknown')
    euid="${EUID:-$uid}"
    cwd="${PWD:-unknown}"
    tty_name=$(tty 2>/dev/null || printf 'notty')
    source_ip=$(audit_source_ip)
    sudo_user="${SUDO_USER:-}"
    login_user="${LOGNAME:-${USER:-unknown}}"
    session_id="${XDG_SESSION_ID:-}"
    shell_name="${SHELL:-unknown}"

    printf 'host=%s;pid=%s;ppid=%s;actor=%s;uid=%s;euid=%s;sudo_user=%s;logname=%s;cwd=%s;tty=%s;source_ip=%s;session=%s;shell=%s' \
        "$(audit_context_value "$hostname")" \
        "$(audit_context_value "$pid")" \
        "$(audit_context_value "$ppid")" \
        "$(audit_context_value "$actor")" \
        "$(audit_context_value "$uid")" \
        "$(audit_context_value "$euid")" \
        "$(audit_context_value "${sudo_user:-none}")" \
        "$(audit_context_value "$login_user")" \
        "$(audit_context_value "$cwd")" \
        "$(audit_context_value "$tty_name")" \
        "$(audit_context_value "$source_ip")" \
        "$(audit_context_value "${session_id:-none}")" \
        "$(audit_context_value "$shell_name")"
}

audit_context_field() {
    local context="${1:-}" key="${2:-}" part
    [[ -n "$context" && -n "$key" ]] || return 1
    local IFS=';'
    for part in $context; do
        [[ "$part" == "$key="* ]] || continue
        printf '%s\n' "${part#*=}"
        return 0
    done
    return 1
}

audit_enrich_details() {
    local details="${1:-}" context="${2:-}"
    if [[ "${USER_MANAGER_AUDIT_DETAILED_CONTEXT:-1}" == "0" || -z "$context" ]]; then
        printf '%s\n' "$details"
    elif [[ -n "$details" ]]; then
        printf '%s | context{%s}\n' "$details" "$context"
    else
        printf 'context{%s}\n' "$context"
    fi
}

# 安全写入审计日志（可选 flock）
audit_write_line() {
    local line="${1:-}"
    [[ -z "$line" ]] && { msg_err_ctx "audit_write_line" "日志行不能为空"; return 1; }
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

audit_backend_mode() {
    local mode="${USER_MANAGER_AUDIT_BACKEND:-${AUDIT_LOG_BACKEND:-file}}"
    mode=$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')

    case "$mode" in
        file|journald|both)
            printf '%s\n' "$mode"
            ;;
        *)
            printf 'file\n'
            ;;
    esac
}

audit_backend_uses_file() {
    local mode
    mode=$(audit_backend_mode)
    [[ "$mode" == "file" || "$mode" == "both" ]]
}

audit_backend_uses_journal() {
    local mode
    mode=$(audit_backend_mode)
    [[ "$mode" == "journald" || "$mode" == "both" ]]
}

audit_priority_for_result() {
    local result="${1:-}"

    case "$result" in
        "$AUDIT_RESULT_SUCCESS") printf '6\n' ;;
        "$AUDIT_RESULT_DENIED") printf '4\n' ;;
        "$AUDIT_RESULT_FAILURE"|"$AUDIT_RESULT_ERROR") printf '3\n' ;;
        *) printf '5\n' ;;
    esac
}

audit_build_journal_message() {
    local op_type="${1:-}"
    local target="${2:-}"
    local result="${3:-}"
    local details="${4:-}"
    local actor="${5:-}"
    local message="${details:-action=${op_type} target=${target} result=${result} actor=${actor}}"

    printf '%s\n' "$(audit_escape_field "$message")"
}

audit_build_journal_fields() {
    local op_type="${1:-}"
    local target="${2:-}"
    local result="${3:-}"
    local details="${4:-}"
    local actor="${5:-}"
    local context="${6:-}"
    local message priority

    [[ -n "$context" ]] || context="$(audit_collect_context "" "$$" "${PPID:-0}" "$actor")"
    message=$(audit_build_journal_message "$op_type" "$target" "$result" "$details" "$actor")
    priority=$(audit_priority_for_result "$result")

    printf 'MESSAGE=%s\n' "$message"
    printf 'PRIORITY=%s\n' "$priority"
    printf 'USERMGR_ACTION=%s\n' "$(audit_escape_field "$op_type")"
    printf 'TARGET=%s\n' "$(audit_escape_field "$target")"
    printf 'RESULT=%s\n' "$(audit_escape_field "$result")"
    printf 'ACTOR=%s\n' "$(audit_escape_field "$actor")"
    printf 'USERMGR_DETAILS=%s\n' "$(audit_escape_field "$details")"
    printf 'USERMGR_CONTEXT=%s\n' "$(audit_escape_field "$context")"
    printf 'USERMGR_HOST=%s\n' "$(audit_escape_field "$(audit_context_field "$context" host || printf 'unknown')")"
    printf 'USERMGR_PID=%s\n' "$(audit_escape_field "$(audit_context_field "$context" pid || printf 'unknown')")"
    printf 'USERMGR_PPID=%s\n' "$(audit_escape_field "$(audit_context_field "$context" ppid || printf 'unknown')")"
    printf 'USERMGR_UID=%s\n' "$(audit_escape_field "$(audit_context_field "$context" uid || printf 'unknown')")"
    printf 'USERMGR_EUID=%s\n' "$(audit_escape_field "$(audit_context_field "$context" euid || printf 'unknown')")"
    printf 'USERMGR_CWD=%s\n' "$(audit_escape_field "$(audit_context_field "$context" cwd || printf 'unknown')")"
    printf 'USERMGR_TTY=%s\n' "$(audit_escape_field "$(audit_context_field "$context" tty || printf 'unknown')")"
    printf 'USERMGR_SOURCE_IP=%s\n' "$(audit_escape_field "$(audit_context_field "$context" source_ip || printf 'unknown')")"
    printf 'USERMGR_SUDO_USER=%s\n' "$(audit_escape_field "$(audit_context_field "$context" sudo_user || printf 'none')")"
    printf 'USERMGR_SESSION=%s\n' "$(audit_escape_field "$(audit_context_field "$context" session || printf 'none')")"
    printf 'SYSLOG_IDENTIFIER=%s\n' "$AUDIT_JOURNAL_IDENTIFIER"
}

audit_extract_journal_field() {
    local payload="${1:-}"
    local field_name="${2:-}"
    local line

    while IFS= read -r line; do
        [[ "$line" == "$field_name="* ]] || continue
        printf '%s\n' "${line#*=}"
        return 0
    done <<< "$payload"

    return 1
}

audit_write_journal_entry() {
    local payload="${1:-}"
    local priority

    [[ -z "$payload" ]] && { msg_err_ctx "audit_write_journal_entry" "journald payload 不能为空"; return 1; }

    if command -v logger &>/dev/null; then
        if printf '%s\n' "$payload" | logger --journald 2>/dev/null; then
            return 0
        fi
    fi

    if command -v systemd-cat &>/dev/null; then
        priority=$(audit_extract_journal_field "$payload" "PRIORITY")
        printf '%s\n' "$payload" | systemd-cat --priority="${priority:-5}" --identifier="$AUDIT_JOURNAL_IDENTIFIER" 2>/dev/null
        return $?
    fi

    return 1
}

# 记录审计日志
# 参数：$1=操作类型, $2=目标对象, $3=结果, $4=详情(可选), $5=用户(可选)
audit_log() {
    local op_type="${1:-}"
    local target="${2:-}"
    local result="${3:-$AUDIT_RESULT_SUCCESS}"
    local details="${4:-}"
    local user="${5:-${USER:-unknown}}"
    
    # 参数验证：操作类型必须存在
    if [[ -z "$op_type" ]]; then
        if declare -F msg_err_ctx &>/dev/null; then
            msg_err_ctx "audit_log" "操作类型 (op_type) 不能为空"
        fi
        return 1
    fi

    # 检查日志文件大小，必要时轮转
    if audit_backend_uses_file; then
        audit_rotate_check
    fi
    
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
    local audit_context enriched_details
    audit_context="$(audit_collect_context "$hostname" "$pid" "$ppid" "$user")"
    enriched_details="$(audit_enrich_details "$details" "$audit_context")"
    
    local esc_hostname esc_user esc_op esc_target esc_result esc_details
    esc_hostname=$(audit_escape_field "$hostname")
    esc_user=$(audit_escape_field "$user")
    esc_op=$(audit_escape_field "$op_type")
    esc_target=$(audit_escape_field "$target")
    esc_result=$(audit_escape_field "$result")
    esc_details=$(audit_escape_field "$enriched_details")
    
    # 构建日志条目（使用 | 作为分隔符）
    # 格式: timestamp|unix_time|hostname|pid|ppid|user|op_type|target|result|details(+context)
    local log_entry="${timestamp}|${unix_time}|${esc_hostname}|${pid}|${ppid}|${esc_user}|${esc_op}|${esc_target}|${esc_result}|${esc_details}"
    
    local journal_payload=""
    local write_status=1

    if audit_backend_uses_journal; then
        journal_payload=$(audit_build_journal_fields "$op_type" "$target" "$result" "$details" "$user" "$audit_context")
    fi

    case "$(audit_backend_mode)" in
        file)
            audit_write_line "$log_entry"
            write_status=$?
            ;;
        journald)
            audit_write_journal_entry "$journal_payload"
            write_status=$?
            ;;
        both)
            local file_status=1
            local journal_status=1
            audit_write_line "$log_entry"
            file_status=$?
            audit_write_journal_entry "$journal_payload"
            journal_status=$?
            if [[ $file_status -eq 0 || $journal_status -eq 0 ]]; then
                write_status=0
            fi
            ;;
    esac

    if [[ $write_status -ne 0 ]]; then
        return "$write_status"
    fi

    # 更新索引（异步，不阻塞主流程）
    (audit_update_index "$timestamp" "$op_type" "$target" "$result" "$user" &) 2>/dev/null
    
    return 0
}

# 记录操作成功
audit_success() {
    local op_type="${1:-}"
    local target="${2:-}"
    local details="${3:-}"
    [[ -z "$op_type" ]] && { msg_err_ctx "audit_success" "操作类型不能为空"; return 1; }
    audit_log "$op_type" "$target" "$AUDIT_RESULT_SUCCESS" "$details"
}

# 记录操作失败
audit_failure() {
    local op_type="${1:-}"
    local target="${2:-}"
    local details="${3:-}"
    [[ -z "$op_type" ]] && { msg_err_ctx "audit_failure" "操作类型不能为空"; return 1; }
    audit_log "$op_type" "$target" "$AUDIT_RESULT_FAILURE" "$details"
}

# 记录操作被拒绝
audit_denied() {
    local op_type="${1:-}"
    local target="${2:-}"
    local details="${3:-}"
    [[ -z "$op_type" ]] && { msg_err_ctx "audit_denied" "操作类型不能为空"; return 1; }
    audit_log "$op_type" "$target" "$AUDIT_RESULT_DENIED" "$details"
}

# 记录错误
audit_error() {
    local op_type="${1:-}"
    local target="${2:-}"
    local details="${3:-}"
    [[ -z "$op_type" ]] && { msg_err_ctx "audit_error" "操作类型不能为空"; return 1; }
    audit_log "$op_type" "$target" "$AUDIT_RESULT_ERROR" "$details"
}

audit_view_journald_log() {
    local lines="${1:-50}"

    if ! command -v journalctl &>/dev/null; then
        msg_warn "journalctl 不可用"
        return 1
    fi

    journalctl -t "$AUDIT_JOURNAL_IDENTIFIER" -n "$lines" --no-pager -o short-iso 2>/dev/null || {
        msg_warn "无法读取 journald 审计日志"
        return 1
    }
}

# ============================================================
# 索引更新（预留接口，当前为空操作）
# ============================================================
# Parameters:
#   $1 - timestamp: 操作时间戳
#   $2 - op_type: 操作类型
#   $3 - target: 目标对象
#   $4 - result: 操作结果
#   $5 - user: 操作用户
# Returns:
#   0 始终成功
# ============================================================
audit_update_index() {
    # DEFERRED: 索引更新逻辑（如 SQLite 索引或文件索引）
    # 当前为空操作，作为接口预留以便未来实现。
    # 如需快速检索，可在此处添加：
    #   1. 基于时间戳排序的文件索引 → echo "$timestamp|$action|$target|$result|$user" >> "$AUDIT_INDEX_FILE"
    #   2. SQLite 索引（需 sqlite3 依赖）
    # 当前审计日志已通过文本文件记录，可通过 grep/awk 检索。
    return 0
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
        msg_warn "审计系统初始化失败"
        return 1
    }
    
    return 0
}

# 执行初始化
init_audit_module
