#!/bin/bash
# access_control.sh - 分级权限控制系统
# 提供四级权限模型：root、admin、user、guest
# 包含权限检查、审计日志、缓存机制

# ============================================================
# 权限级别定义
# ============================================================
readonly ACL_LEVEL_ROOT=0   # 超级用户，无限制
readonly ACL_LEVEL_ADMIN=1  # 管理员，大部分特权操作
readonly ACL_LEVEL_USER=2   # 普通用户，有限操作
readonly ACL_LEVEL_GUEST=3  # 访客，只读操作

# 权限级别名称映射
# shellcheck disable=SC2004
readonly -A ACL_LEVEL_NAMES=(
    [$ACL_LEVEL_ROOT]="root"
    [$ACL_LEVEL_ADMIN]="admin"
    [$ACL_LEVEL_USER]="user"
    [$ACL_LEVEL_GUEST]="guest"
)

# 权限缓存
declare -A _ACL_CACHE=()
readonly ACL_CACHE_TTL=300  # 缓存有效期 5 分钟
declare -A _ACL_CACHE_TIMESTAMP=()

# 审计日志配置
readonly ACL_AUDIT_LOG="${ACL_AUDIT_LOG:-$DATA_BASE/logs/audit.log}"
readonly ACL_AUDIT_MAX_SIZE=$((10 * 1024 * 1024))  # 10MB 轮转

# ============================================================
# 权限检查核心函数
# ============================================================

# 获取当前用户的权限级别
# 返回值：0=root, 1=admin, 2=user, 3=guest
acl_get_current_level() {
    local user="${1:-$USER}"
    
    # 检查缓存
    local cache_key="level:$user"
    if acl_cache_get "$cache_key" level; then
        echo "$level"
        return 0
    fi
    
    # 检查是否为 root
    if [[ "$user" == "root" ]] || [[ "$(id -u "$user" 2>/dev/null)" == "0" ]]; then
        acl_cache_set "$cache_key" "$ACL_LEVEL_ROOT"
        echo "$ACL_LEVEL_ROOT"
        return 0
    fi
    
    # 检查 sudo 组（管理员）
    if groups "$user" 2>/dev/null | grep -qwE '(sudo|wheel|admin)'; then
        acl_cache_set "$cache_key" "$ACL_LEVEL_ADMIN"
        echo "$ACL_LEVEL_ADMIN"
        return 0
    fi
    
    # 检查是否为系统用户（访客）
    local uid
    uid=$(id -u "$user" 2>/dev/null)
    if [[ -n "$uid" ]] && [[ "$uid" -lt 1000 ]]; then
        acl_cache_set "$cache_key" "$ACL_LEVEL_GUEST"
        echo "$ACL_LEVEL_GUEST"
        return 0
    fi
    
    # 默认为普通用户
    acl_cache_set "$cache_key" "$ACL_LEVEL_USER"
    echo "$ACL_LEVEL_USER"
    return 0
}

# 检查用户是否具有指定权限级别
# 用法：acl_check_level <required_level> [username]
# 返回：0 如果有权限，1 如果没有
acl_check_level() {
    local required="$1"
    local user="${2:-$USER}"
    
    local current
    current=$(acl_get_current_level "$user")
    
    if [[ "$current" -le "$required" ]]; then
        return 0
    else
        return 1
    fi
}

# 检查用户是否是指定级别
# 用法：acl_is_level <level> [username]
acl_is_level() {
    local check_level="$1"
    local user="${2:-$USER}"
    local current
    current=$(acl_get_current_level "$user")
    [[ "$current" == "$check_level" ]]
}

# 检查用户是否至少达到某个级别
# 用法：acl_is_at_least <min_level> [username]
acl_is_at_least() {
    local min_level="$1"
    local user="${2:-$USER}"
    local current
    current=$(acl_get_current_level "$user")
    [[ "$current" -le "$min_level" ]]
}

# ============================================================
# 权限缓存管理
# ============================================================

# 从缓存获取值
acl_cache_get() {
    local key="$1"
    local -n _out="$2"
    local now
    now=$(date +%s)
    
    # 检查缓存是否存在且未过期
    if [[ -n "${_ACL_CACHE[$key]:-}" ]]; then
        local timestamp="${_ACL_CACHE_TIMESTAMP[$key]:-0}"
        local age=$((now - timestamp))
        
        if [[ $age -lt $ACL_CACHE_TTL ]]; then
            _out="${_ACL_CACHE[$key]}"
            return 0
        fi
    fi
    
    return 1
}

# 设置缓存值
acl_cache_set() {
    local key="$1"
    local value="$2"
    local now
    now=$(date +%s)
    
    _ACL_CACHE[$key]="$value"
    _ACL_CACHE_TIMESTAMP[$key]="$now"
}

# 清除所有缓存
acl_cache_clear() {
    _ACL_CACHE=()
    _ACL_CACHE_TIMESTAMP=()
}

# 刷新缓存（过期项）
acl_cache_refresh() {
    local now
    now=$(date +%s)
    local -a keys_to_remove=()
    
    for key in "${!_ACL_CACHE[@]}"; do
        local timestamp="${_ACL_CACHE_TIMESTAMP[$key]:-0}"
        local age=$((now - timestamp))
        
        if [[ $age -ge $ACL_CACHE_TTL ]]; then
            keys_to_remove+=("$key")
        fi
    done
    
    for key in "${keys_to_remove[@]}"; do
        unset '_ACL_CACHE[$key]'
        unset '_ACL_CACHE_TIMESTAMP[$key]'
    done
}

# ============================================================
# 审计日志系统
# ============================================================

# 转义审计字段，避免破坏分隔符
acl_escape_field() {
    local value="$1"
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/}
    value=${value//|/\\|}
    echo "$value"
}

# 安全写入审计日志（可选 flock）
acl_audit_write_line() {
    local line="$1"
    if command -v flock &>/dev/null; then
        local fd
        exec {fd}>>"$ACL_AUDIT_LOG" 2>/dev/null || {
            printf '%s\n' "$line" >> "$ACL_AUDIT_LOG"
            return 0
        }
        flock -w 3 "$fd" 2>/dev/null || true
        printf '%s\n' "$line" >&"$fd"
        exec {fd}>&-
        return 0
    fi
    printf '%s\n' "$line" >> "$ACL_AUDIT_LOG"
}

# 记录审计日志
# 用法：acl_audit_log <action> <target> <result> [details]
acl_audit_log() {
    local action="$1"
    local target="$2"
    local result="$3"
    local details="${4:-}"
    
    # 确保日志目录存在
    local log_dir
    log_dir=$(dirname "$ACL_AUDIT_LOG")
    [[ -d "$log_dir" ]] || priv_mkdir -p "$log_dir"
    
    # 轮转日志（如果太大）
    acl_audit_rotate
    
    # 获取状态快照
    local user="${USER:-unknown}"
    local uid="${UID:-$(id -u)}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local timestamp_ms
    timestamp_ms=$(date '+%s.%N')
    local hostname
    hostname=$(hostname)
    local pwd_dir
    pwd_dir=$(pwd)
    local ppid
    ppid=$(ps -o ppid= -p $$ 2>/dev/null || echo "$$")
    
    # 状态快照
    local snapshot="{\"user\":\"$user\",\"uid\":$uid,\"hostname\":\"$hostname\",\"pwd\":\"$pwd_dir\",\"ppid\":$ppid,\"timestamp\":$timestamp_ms}"
    
    local esc_action esc_target esc_result esc_snapshot esc_details
    esc_action=$(acl_escape_field "$action")
    esc_target=$(acl_escape_field "$target")
    esc_result=$(acl_escape_field "$result")
    esc_snapshot=$(acl_escape_field "$snapshot")
    esc_details=$(acl_escape_field "$details")
    
    # 构建日志条目
    local log_entry="$timestamp|$user($uid)|$hostname|$esc_action|$esc_target|$esc_result|$esc_snapshot"
    [[ -n "$details" ]] && log_entry="$log_entry|$esc_details"
    
    # 写入日志
    acl_audit_write_line "$log_entry"
    
    # 同步写入统一审计系统（如果可用）
    if declare -F audit_log &>/dev/null; then
        audit_log "ACL_${action}" "$target" "$result" "$details" "$user" 2>/dev/null || true
    fi
}

# 轮转审计日志
acl_audit_rotate() {
    [[ -f "$ACL_AUDIT_LOG" ]] || return 0
    
    local size
    size=$(stat -f%z "$ACL_AUDIT_LOG" 2>/dev/null || stat -c%s "$ACL_AUDIT_LOG" 2>/dev/null || echo 0)
    
    if [[ $size -gt $ACL_AUDIT_MAX_SIZE ]]; then
        local backup
        backup="${ACL_AUDIT_LOG}.$(date +%Y%m%d%H%M%S).gz"
        priv_mv "$ACL_AUDIT_LOG" "$backup"
        priv_gzip "$backup"
        priv_touch "$ACL_AUDIT_LOG"
    fi
}

# 查询审计日志
# 用法：acl_audit_query [options]
acl_audit_query() {
    local user=""
    local action=""
    local target=""
    local start_date=""
    local end_date=""
    local limit=100
    
    # 解析参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user) user="$2"; shift 2 ;;
            --action) action="$2"; shift 2 ;;
            --target) target="$2"; shift 2 ;;
            --start) start_date="$2"; shift 2 ;;
            --end) end_date="$2"; shift 2 ;;
            --limit) limit="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    
    # 检查日志文件
    if [[ ! -f "$ACL_AUDIT_LOG" ]]; then
        if declare -F msg_err &>/dev/null; then
            msg_err "No audit log found"
        else
            echo "No audit log found"
        fi
        return 1
    fi
    
    if ! [[ "$limit" =~ ^[0-9]+$ ]] || (( limit < 1 )); then
        if declare -F msg_warn &>/dev/null; then
            msg_warn "无效的 limit: $limit，使用默认值 100"
        else
            echo "Invalid limit: $limit, fallback to 100"
        fi
        limit=100
    fi
    
    # 构建过滤条件
    awk -F'|' \
        -v user="$user" \
        -v action="$action" \
        -v target="$target" \
        -v start="$start_date" \
        -v end="$end_date" '
        {
            if (user != "" && index($2, user "(") != 1) next
            if (action != "" && $4 != action) next
            if (target != "" && $5 != target) next
            if (start != "" && $1 < start) next
            if (end != "" && $1 > end) next
            print
        }
    ' "$ACL_AUDIT_LOG" | tail -n "$limit"
}

# ============================================================
# 权限自检功能
# ============================================================

# 权限自检 - 检查用户是否有不必要的sudo权限
acl_privilege_audit() {
    local user="${1:-$USER}"
    
    echo "=========================================="
    echo "权限自检报告 - 用户: $user"
    echo "生成时间: $(date)"
    echo "=========================================="
    echo ""
    
    # 检查当前权限级别
    local level
    level=$(acl_get_current_level "$user")
    local level_name=${ACL_LEVEL_NAMES[$level]}
    echo "当前权限级别: $level ($level_name)"
    echo ""
    
    # 检查sudo配置
    echo "--- Sudo 权限检查 ---"
    if groups "$user" 2>/dev/null | grep -qwE '(sudo|wheel|admin)'; then
        echo "⚠️ 警告: 用户在 sudo 组中"
        
        # 检查 sudo 规则
        local sudoers_hit=false
        if [[ -d /etc/sudoers.d ]]; then
            local sudo_file
            for sudo_file in /etc/sudoers.d/*; do
                [[ -f "$sudo_file" ]] || continue
                if awk -v user="$user" '
                    $0 !~ /^[[:space:]]*#/ && index($0, user) { exit 0 }
                    END { exit 1 }
                ' "$sudo_file" 2>/dev/null; then
                    sudoers_hit=true
                    break
                fi
            done
        fi
        
        local sudoers_main=false
        if [[ -r /etc/sudoers ]]; then
            if awk -v user="$user" '
                $0 !~ /^[[:space:]]*#/ && index($0, user) { exit 0 }
                END { exit 1 }
            ' /etc/sudoers 2>/dev/null; then
                sudoers_main=true
            fi
        fi
        
        if [[ "$sudoers_hit" == "true" || "$sudoers_main" == "true" ]]; then
            echo "⚠️ 严重警告: 用户可能具有 sudo 规则"
            echo "   建议: 检查 /etc/sudoers 和 /etc/sudoers.d"
        elif [[ ! -r /etc/sudoers ]]; then
            echo "ℹ️ 无法读取 /etc/sudoers，跳过详细规则检查"
        fi
    else
        echo "✓ 用户不在 sudo 组中"
    fi
    echo ""
    
    # 检查文件权限
    echo "--- 文件权限检查 ---"
    local home_dir
    home_dir=$(getent passwd "$user" | cut -d: -f6)
    if [[ -d "$home_dir" ]]; then
        local perms
        perms=$(stat -c "%a" "$home_dir" 2>/dev/null || stat -f "%Lp" "$home_dir")
        if [[ "$perms" -le 700 ]]; then
            echo "✓ 家目录权限设置合理: $perms"
        else
            echo "⚠️ 警告: 家目录权限过于开放: $perms"
        fi
    fi
    echo ""
    
    # 权限建议
    echo "--- 权限优化建议 ---"
    case "$level" in
        "$ACL_LEVEL_ROOT")
            echo "⚠️ 当前为 root 用户"
            echo "   建议: 使用普通用户进行日常操作，仅在必要时使用 sudo"
            ;;
        "$ACL_LEVEL_ADMIN")
            echo "✓ 当前为管理员用户"
            echo "   建议: 定期检查 sudo 日志，确保权限使用合理"
            ;;
        "$ACL_LEVEL_USER")
            echo "✓ 当前为普通用户"
            echo "   建议: 这是推荐的用户类型"
            ;;
        "$ACL_LEVEL_GUEST")
            echo "ℹ️ 当前为访客用户"
            echo "   建议: 权限受限，如需更多功能请联系管理员"
            ;;
    esac
    echo ""
    
    echo "=========================================="
    echo "自检报告生成完成"
    echo "=========================================="
}

# 权限修复建议 - 自动修复不必要的权限
acl_privilege_recommend() {
    local user="${1:-$USER}"
    
    echo "正在分析权限配置并提供修复建议..."
    echo ""
    
    local -a recommendations=()
    
    # 检查 sudo 组成员
    if groups "$user" 2>/dev/null | grep -qwE '(sudo|wheel|admin)'; then
        recommendations+=("考虑将用户 '$user' 从 sudo 组移除，除非确实需要管理权限")
    fi
    
    # 检查家目录权限
    local home_dir
    home_dir=$(getent passwd "$user" | cut -d: -f6)
    if [[ -d "$home_dir" ]]; then
        local perms
        perms=$(stat -c "%a" "$home_dir" 2>/dev/null || stat -f "%Lp" "$home_dir")
        if [[ "$perms" -gt 750 ]]; then
            recommendations+=("建议将家目录权限从 $perms 改为 700: chmod 700 $home_dir")
        fi
    fi
    
    # 输出建议
    if [[ ${#recommendations[@]} -eq 0 ]]; then
        echo "✓ 未发现明显的权限问题"
    else
        echo "发现 ${#recommendations[@]} 项权限建议："
        echo ""
        local i=1
        for rec in "${recommendations[@]}"; do
            echo "$i. $rec"
            ((i++))
        done
    fi
    
    return 0
}

# ============================================================
# 初始化
# ============================================================

# 确保审计日志目录存在
acl_init() {
    local log_dir
    log_dir=$(dirname "$ACL_AUDIT_LOG")
    if [[ ! -d "$log_dir" ]]; then
        # shellcheck disable=SC2154
        priv_mkdir -p "$log_dir" 2>/dev/null || mkdir -p "$log_dir" 2>/dev/null || true
    fi
}

# 模块初始化
acl_init
