#!/bin/bash
# security_baseline_core.sh - SSH 与 fail2ban 安全基线核心模块

: "${SECURITY_BASELINE_SSH_CONFIG:=/etc/ssh/sshd_config}"
: "${SECURITY_BASELINE_SSHD_DROPIN_DIR:=/etc/ssh/sshd_config.d}"
: "${SECURITY_BASELINE_FAIL2BAN_JAIL_DIR:=/etc/fail2ban/jail.d}"
: "${SECURITY_BASELINE_SYSTEMCTL_BIN:=systemctl}"
: "${SECURITY_BASELINE_FAIL2BAN_CLIENT_BIN:=fail2ban-client}"
: "${SECURITY_BASELINE_JOURNALCTL_BIN:=journalctl}"
: "${SECURITY_BASELINE_SSHD_BIN:=sshd}"
: "${SECURITY_BASELINE_AUTH_LOG:=/var/log/auth.log}"

_security_baseline_msg_info() {
    if declare -F msg_info >/dev/null 2>&1; then
        msg_info "$*"
    else
        printf '%s\n' "$*"
    fi
}

_security_baseline_msg_warn() {
    if declare -F msg_warn >/dev/null 2>&1; then
        msg_warn "$*"
    else
        printf 'WARN: %s\n' "$*" >&2
    fi
}

_security_baseline_msg_err() {
    if declare -F msg_err >/dev/null 2>&1; then
        msg_err "$*"
    else
        printf 'ERROR: %s\n' "$*" >&2
    fi
}

_security_baseline_run_command() {
    if [[ $# -eq 0 ]]; then
        return 1
    fi

    if declare -F run_privileged >/dev/null 2>&1; then
        run_privileged "$@"
    else
        "$@"
    fi
}

_security_baseline_systemctl() {
    if declare -F priv_systemctl >/dev/null 2>&1; then
        priv_systemctl "$@"
    else
        _security_baseline_run_command "$SECURITY_BASELINE_SYSTEMCTL_BIN" "$@"
    fi
}

_security_baseline_require_fail2ban_client() {
    if command -v "$SECURITY_BASELINE_FAIL2BAN_CLIENT_BIN" >/dev/null 2>&1; then
        return 0
    fi

    _security_baseline_msg_err "未找到 fail2ban-client，请先安装 fail2ban"
    return 1
}

_security_baseline_fail2ban_client() {
    _security_baseline_require_fail2ban_client || return 1
    _security_baseline_run_command "$SECURITY_BASELINE_FAIL2BAN_CLIENT_BIN" "$@"
}

_security_baseline_write_fail2ban_jail_file() {
    local jail_file="$1"
    shift

    if [[ $# -eq 0 ]]; then
        return 1
    fi

    if declare -F write_privileged_text_file >/dev/null 2>&1; then
        printf '%s\n' "$@" | write_privileged_text_file "$jail_file" "0644" "root:root" || return 1
    else
        printf '%s\n' "$@" > "$jail_file" || return 1
    fi
}

_security_baseline_enable_restart_fail2ban() {
    _security_baseline_systemctl enable fail2ban || return 1
    _security_baseline_systemctl restart fail2ban || return 1
}

_security_baseline_read_effective_lines() {
    local main_file="$SECURITY_BASELINE_SSH_CONFIG"
    local dropin_dir="$SECURITY_BASELINE_SSHD_DROPIN_DIR"
    local file

    if [[ -f "$main_file" ]]; then
        printf '%s\n' "$main_file"
    fi

    if [[ -d "$dropin_dir" ]]; then
        while IFS= read -r file; do
            printf '%s\n' "$file"
        done < <(printf '%s\n' "$dropin_dir"/*.conf 2>/dev/null | sort)
    fi
}

_security_baseline_extract_keyword_from_file() {
    local file="$1"
    local keyword="$2"

    awk -v key="$keyword" '
        /^[[:space:]]*#/ { next }
        {
            line=$0
            sub(/[[:space:]]+#.*$/, "", line)
            if (match(line, "^[[:space:]]*" key "[[:space:]]+")) {
                value=substr(line, RLENGTH + 1)
                sub(/^[[:space:]]+/, "", value)
                sub(/[[:space:]]+$/, "", value)
                if (value != "") {
                    found=value
                }
            }
        }
        END {
            if (found != "") {
                print found
            }
        }
    ' "$file"
}

security_baseline_get_sshd_effective_value() {
    local keyword="$1"
    local file
    local value=""

    if [[ -z "$keyword" ]]; then
        _security_baseline_msg_err "未指定 sshd 配置关键项"
        return 1
    fi

    while IFS= read -r file; do
        [[ -f "$file" ]] || continue
        local candidate
        candidate="$(_security_baseline_extract_keyword_from_file "$file" "$keyword")"
        if [[ -n "$candidate" ]]; then
            value="$candidate"
        fi
    done < <(_security_baseline_read_effective_lines)

    if [[ -n "$value" ]]; then
        printf '%s\n' "$value"
        return 0
    fi

    return 1
}

security_baseline_collect_sshd_settings() {
    local permit_root password_auth pubkey_auth

    permit_root="$(security_baseline_get_sshd_effective_value PermitRootLogin 2>/dev/null || true)"
    password_auth="$(security_baseline_get_sshd_effective_value PasswordAuthentication 2>/dev/null || true)"
    pubkey_auth="$(security_baseline_get_sshd_effective_value PubkeyAuthentication 2>/dev/null || true)"

    printf 'PermitRootLogin=%s\n' "${permit_root:-<unset>}"
    printf 'PasswordAuthentication=%s\n' "${password_auth:-<unset>}"
    printf 'PubkeyAuthentication=%s\n' "${pubkey_auth:-<unset>}"
}

security_baseline_sshd_summary() {
    local config_source="file-parse"

    if command -v "$SECURITY_BASELINE_SSHD_BIN" >/dev/null 2>&1; then
        if "$SECURITY_BASELINE_SSHD_BIN" -T >/dev/null 2>&1; then
            config_source="sshd -T available, showing parsed file result"
        fi
    fi

    printf 'source=%s\n' "$config_source"
    security_baseline_collect_sshd_settings
}

security_baseline_show_recent_auth_failures() {
    local lines="${1:-20}"
    local pattern='Failed password|authentication failure|Invalid user|maximum authentication attempts exceeded|Connection closed by authenticating user'

    if command -v "$SECURITY_BASELINE_JOURNALCTL_BIN" >/dev/null 2>&1; then
        local output=""
        output="$({ "$SECURITY_BASELINE_JOURNALCTL_BIN" -u ssh -u sshd -n "$lines" --no-pager 2>/dev/null || true; } | grep -E "$pattern" || true)"
        if [[ -n "$output" ]]; then
            printf '%s\n' "$output"
            return 0
        fi
    fi

    if [[ -f "$SECURITY_BASELINE_AUTH_LOG" ]]; then
        grep -E "$pattern" "$SECURITY_BASELINE_AUTH_LOG" 2>/dev/null | tail -n "$lines"
        return 0
    fi

    _security_baseline_msg_warn "未找到认证失败日志来源"
    return 1
}

security_baseline_show_fail2ban_status() {
    local service_enabled="unknown"
    local service_active="unknown"

    _security_baseline_require_fail2ban_client || return 1

    if command -v "$SECURITY_BASELINE_SYSTEMCTL_BIN" >/dev/null 2>&1; then
        service_enabled="$($SECURITY_BASELINE_SYSTEMCTL_BIN is-enabled fail2ban 2>/dev/null || true)"
        service_active="$($SECURITY_BASELINE_SYSTEMCTL_BIN is-active fail2ban 2>/dev/null || true)"
    fi

    printf 'fail2ban enabled: %s\n' "${service_enabled:-unknown}"
    printf 'fail2ban active: %s\n' "${service_active:-unknown}"
    _security_baseline_fail2ban_client status
    echo ""
    _security_baseline_fail2ban_client status sshd
}

security_baseline_fail2ban_list_jails() {
    local status_output

    status_output="$(_security_baseline_fail2ban_client status)" || return 1

    awk -F'Jail list:' '
        /Jail list:/ {
            gsub(/^[[:space:]]+/, "", $2)
            gsub(/[[:space:]]+$/, "", $2)
            n=split($2, items, /,[[:space:]]*/)
            for (i=1; i<=n; i++) {
                if (items[i] != "") {
                    print items[i]
                }
            }
        }
    ' <<< "$status_output"
}

security_baseline_fail2ban_show_jail_status() {
    local jail_name="$1"

    if [[ -z "$jail_name" ]]; then
        _security_baseline_msg_err "未指定 fail2ban jail 名称"
        return 1
    fi

    _security_baseline_fail2ban_client status "$jail_name"
}

security_baseline_fail2ban_show_sshd_status() {
    security_baseline_fail2ban_show_jail_status sshd
}

security_baseline_write_fail2ban_sshd_jail() {
    local bantime_seconds="${1:-600}"
    local findtime_seconds="${2:-600}"
    local maxretry="${3:-5}"
    local jail_dir="$SECURITY_BASELINE_FAIL2BAN_JAIL_DIR"
    local jail_file="$jail_dir/sshd.local"

    if [[ ! "$bantime_seconds" =~ ^[0-9]+$ ]] || [[ ! "$findtime_seconds" =~ ^[0-9]+$ ]]; then
        _security_baseline_msg_err "bantime 与 findtime 需要是纯秒数"
        return 1
    fi

    if [[ "$maxretry" =~ ^[0-9]+m$ ]]; then
        maxretry="${maxretry%m}"
    fi

    if [[ ! "$maxretry" =~ ^[0-9]+$ ]]; then
        _security_baseline_msg_err "maxretry 需要是整数"
        return 1
    fi

    if declare -F priv_mkdir >/dev/null 2>&1; then
        priv_mkdir -p "$jail_dir" || return 1
    else
        mkdir -p "$jail_dir" || return 1
    fi

    _security_baseline_write_fail2ban_jail_file "$jail_file" \
        '[sshd]' \
        'enabled = true' \
        'backend = systemd' \
        'port = ssh' \
        'logpath = %(sshd_log)s' \
        "maxretry = $maxretry" \
        "findtime = $findtime_seconds" \
        "bantime = $bantime_seconds" || return 1

    printf '%s\n' "$jail_file"
}

security_baseline_configure_fail2ban_sshd_jail() {
    local bantime_seconds="${1:-600}"
    local findtime_seconds="${2:-600}"
    local maxretry="${3:-5}"

    security_baseline_write_fail2ban_sshd_jail "$bantime_seconds" "$findtime_seconds" "$maxretry" >/dev/null || return 1

    _security_baseline_enable_restart_fail2ban || return 1

    return 0
}

# ============================================================
# 安全验证函数（从 common.sh 迁移）
# ============================================================

# 检查敏感文件权限
check_sensitive_file_permissions() {
    local files=("$@")
    local issues=()
    
    for file in "${files[@]}"; do
        if [[ -f "$file" ]]; then
            local perms
            perms=$(stat -c %a "$file" 2>/dev/null || echo "unknown")
            
            if [[ "$perms" != "600" && "$perms" != "400" && "$perms" != "700" ]]; then
                issues+=("$file:$perms")
                msg_warn "不安全的权限: $file (当前: $perms)"
                
                if chmod 600 "$file" 2>/dev/null; then
                    msg_ok "已修复权限为 600: $file"
                else
                    msg_err "无法修复权限: $file"
                fi
            fi
        fi
    done
    
    if (( ${#issues[@]} > 0 )); then
        msg_warn "发现 ${#issues[@]} 个文件权限问题"
        return 1
    fi
    
    return 0
}

# 验证路径安全（防止路径遍历）
validate_path_safety() {
    local path="$1"
    local allow_tmp="${2:-false}"
    
    local real_path
    real_path=$(realpath -m "$path" 2>/dev/null || echo "")
    
    if [[ -z "$real_path" ]]; then
        msg_err "无效路径: $path"
        return 1
    fi
    
    if [[ "$path" =~ \.\. ]]; then
        msg_warn "路径包含相对路径符号: $path"
    fi
    
    local allowed_dirs=("/home" "/mnt" "/opt" "/var/backups")
    if [[ "$allow_tmp" == "true" ]]; then
        allowed_dirs+=("/tmp")
    fi
    
    local in_allowed=false
    for dir in "${allowed_dirs[@]}"; do
        if [[ "$real_path" == "$dir"* ]]; then
            in_allowed=true
            break
        fi
    done
    
    if ! $in_allowed; then
        msg_err "路径不在允许的目录中: $real_path"
        msg_info "允许的目录: ${allowed_dirs[*]}"
        return 1
    fi
    
    return 0
}

# 验证端口号
validate_port() {
    local port="$1"
    
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        msg_err "无效的端口号: $port"
        return 1
    fi
    
    if (( port < 1 || port > 65535 )); then
        msg_err "端口号超出范围 (1-65535): $port"
        return 1
    fi
    
    if (( port < 1024 )); then
        msg_warn "特权端口需要 root 权限: $port"
    fi
    
    return 0
}

# 验证 IP 地址
validate_ip_address() {
    local ip="$1"
    local regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    
    if ! [[ "$ip" =~ $regex ]]; then
        msg_err "无效的 IP 地址格式: $ip"
        return 1
    fi
    
    local IFS='.'
    read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        if (( octet < 0 || octet > 255 )); then
            msg_err "IP 地址八位组超出范围: $octet"
            return 1
        fi
    done
    
    return 0
}

# 验证邮箱地址
validate_email() {
    local email="$1"
    local regex='^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'
    
    if ! [[ "$email" =~ $regex ]]; then
        msg_err "无效的邮箱地址: $email"
        return 1
    fi
    
    return 0
}

# 验证配额格式 (如 500G, 1T)
validate_quota_format() {
    local quota="$1"
    local regex='^[0-9]+[KMGT]?$'
    
    if ! [[ "$quota" =~ $regex ]]; then
        msg_err "无效的配额格式: $quota"
        msg_info "正确格式示例: 500G, 1T, 100M"
        return 1
    fi
    
    return 0
}
