#!/bin/bash
# privilege.sh - 权限操作封装层
# 提供最小权限原则的实现，所有特权操作必须通过此模块
# 包含命令白名单、权限检查、审计日志

if [[ -z "${ACL_LEVEL_ROOT:-}" || -z "${ACL_LEVEL_ADMIN:-}" || -z "${ACL_LEVEL_USER:-}" || -z "${ACL_LEVEL_GUEST:-}" ]]; then
    if declare -F msg_err &>/dev/null; then
        msg_err "privilege.sh requires access_control.sh to be sourced first"
    else
        echo "privilege.sh requires access_control.sh to be sourced first" >&2
    fi
    # shellcheck disable=SC2317
    return 1 2>/dev/null || exit 1
fi

# ============================================================
# 命令白名单配置
# ============================================================

# 允许的特权命令及其所需权限级别
readonly -A PRIV_CMD_WHITELIST=(
    # 用户管理命令 - 需要 admin 级别
    ["useradd"]="$ACL_LEVEL_ADMIN"
    ["usermod"]="$ACL_LEVEL_ADMIN"
    ["userdel"]="$ACL_LEVEL_ADMIN"
    ["groupadd"]="$ACL_LEVEL_ADMIN"
    ["groupmod"]="$ACL_LEVEL_ADMIN"
    ["groupdel"]="$ACL_LEVEL_ADMIN"
    
    # 文件权限命令 - 根据上下文需要不同级别
    ["chown"]="$ACL_LEVEL_ADMIN"
    ["chmod"]="$ACL_LEVEL_ADMIN"
    ["chgrp"]="$ACL_LEVEL_ADMIN"
    
    # 系统服务命令 - 需要 admin 级别
    ["systemctl"]="$ACL_LEVEL_ADMIN"
    ["service"]="$ACL_LEVEL_ADMIN"
    
    # 磁盘配额命令 - 需要 admin 级别
    ["setquota"]="$ACL_LEVEL_ADMIN"
    ["edquota"]="$ACL_LEVEL_ADMIN"
    ["repquota"]="$ACL_LEVEL_ADMIN"
    
    # 备份命令 - 需要 admin 级别
    ["rsnapshot"]="$ACL_LEVEL_ADMIN"
    ["tar"]="$ACL_LEVEL_ADMIN"
    ["rsync"]="$ACL_LEVEL_ADMIN"
    
    # 网络/防火墙命令 - 需要 admin 级别
    ["ufw"]="$ACL_LEVEL_ADMIN"
    ["iptables"]="$ACL_LEVEL_ADMIN"
    ["ipset"]="$ACL_LEVEL_ADMIN"
    
    # 其他特权命令
    ["mount"]="$ACL_LEVEL_ADMIN"
    ["umount"]="$ACL_LEVEL_ADMIN"
    ["kill"]="$ACL_LEVEL_ADMIN"
    ["pkill"]="$ACL_LEVEL_ADMIN"
    ["killall"]="$ACL_LEVEL_ADMIN"
    ["visudo"]="$ACL_LEVEL_ROOT"
    ["sudo"]="$ACL_LEVEL_USER"
    
    # 硬件信息命令 - 需要 admin 级别
    ["dmidecode"]="$ACL_LEVEL_ADMIN"
    ["smartctl"]="$ACL_LEVEL_ADMIN"
    ["sensors"]="$ACL_LEVEL_ADMIN"
)
# 特权命令别名映射
readonly -A PRIV_CMD_ALIASES=(
    ["adduser"]="useradd"
    ["deluser"]="userdel"
    ["moduser"]="usermod"
    ["addgroup"]="groupadd"
    ["delgroup"]="groupdel"
)

# ============================================================
# 核心特权执行函数
# ============================================================

# 检查命令是否在白名单中
# 用法：priv_check_whitelist <command>
# 返回：0 如果在白名单，1 如果不在
priv_check_whitelist() {
    local cmd="$1"
    local base_cmd
    base_cmd=$(basename "$cmd")
    
    # 检查别名
    if [[ -n "${PRIV_CMD_ALIASES[$base_cmd]:-}" ]]; then
        base_cmd="${PRIV_CMD_ALIASES[$base_cmd]}"
    fi
    
    # 检查白名单
    if [[ -n "${PRIV_CMD_WHITELIST[$base_cmd]:-}" ]]; then
        return 0
    fi
    
    return 1
}

# 获取命令所需的权限级别
# 用法：priv_get_required_level <command>
priv_get_required_level() {
    local cmd="$1"
    local base_cmd
    base_cmd=$(basename "$cmd")
    
    # 检查别名
    if [[ -n "${PRIV_CMD_ALIASES[$base_cmd]:-}" ]]; then
        base_cmd="${PRIV_CMD_ALIASES[$base_cmd]}"
    fi
    
    # 返回所需级别
    echo "${PRIV_CMD_WHITELIST[$base_cmd]:-$ACL_LEVEL_ROOT}"
}

# 执行特权命令（核心函数）
# 用法：priv_exec <command> [args...]
# 返回：命令的退出状态
priv_exec() {
    local cmd="$1"
    shift
    
    # 检查命令
    if [[ -z "$cmd" ]]; then
        msg_err "No command specified for priv_exec"
        return 1
    fi
    
    # 检查白名单
    if ! priv_check_whitelist "$cmd"; then
        msg_err "Command '$cmd' is not in the privilege whitelist"
        acl_audit_log "PRIV_DENIED" "$cmd" "DENIED" "Command not in whitelist"
        return 1
    fi
    
    # 检查权限级别
    local required_level
    required_level=$(priv_get_required_level "$cmd")
    local current_level
    current_level=$(acl_get_current_level)
    
    if [[ "$current_level" -gt "$required_level" ]]; then
        msg_err "Insufficient privileges for '$cmd'. Required level: $required_level, Current: $current_level"
        acl_audit_log "PRIV_DENIED" "$cmd" "DENIED" "Insufficient privileges: required=$required_level, current=$current_level"
        return 1
    fi
    
    # 记录执行前状态快照
    local snapshot_before
    snapshot_before=$(priv_capture_state)
    
    # 执行命令
    local exit_code=0
    if is_root; then
        # 已经是 root，直接执行
        "$cmd" "$@" || exit_code=$?
    elif command -v sudo &>/dev/null; then
        # 使用 sudo
        if [[ "${SUDO_NONINTERACTIVE:-0}" == "1" ]]; then
            sudo -n "$cmd" "$@" || exit_code=$?
            if [[ $exit_code -ne 0 ]]; then
                msg_err "SUDO_NONINTERACTIVE=1: sudo returned non-zero for '$cmd' (run with TTY or unset SUDO_NONINTERACTIVE if password is required)"
            fi
        else
            sudo "$cmd" "$@" || exit_code=$?
        fi
    else
        msg_err "Cannot elevate privileges: sudo not available and not root"
        return 1
    fi
    
    # 记录执行后状态
    local snapshot_after
    snapshot_after=$(priv_capture_state)
    
    # 记录审计日志
    local result="SUCCESS"
    [[ $exit_code -ne 0 ]] && result="FAILED"
    local details="exit_code=$exit_code|before=$snapshot_before|after=$snapshot_after"
    
    acl_audit_log "PRIV_EXEC" "$cmd $*" "$result" "$details"
    
    return $exit_code
}

# 捕获当前状态快照
priv_capture_state() {
    local snapshot="{"
    snapshot="${snapshot}\"user\":\"${USER:-unknown}\","
    snapshot="${snapshot}\"uid\":${UID:-$(id -u)},"
    snapshot="${snapshot}\"pwd\":\"$(pwd)\","
    snapshot="${snapshot}\"time\":$(date +%s)"
    snapshot="${snapshot}}"
    echo "$snapshot"
}

# ============================================================
# 便利函数 - 常用特权操作封装
# ============================================================

priv_useradd() { priv_exec useradd "$@"; }
priv_usermod() { priv_exec usermod "$@"; }
priv_userdel() { priv_exec userdel "$@"; }
priv_groupadd() { priv_exec groupadd "$@"; }
priv_groupmod() { priv_exec groupmod "$@"; }
priv_groupdel() { priv_exec groupdel "$@"; }
priv_chown() { priv_exec chown "$@"; }
priv_chmod() { priv_exec chmod "$@"; }
priv_chgrp() { priv_exec chgrp "$@"; }
priv_mkdir() { priv_exec mkdir "$@"; }
priv_rmdir() { priv_exec rmdir "$@"; }
priv_rm() { priv_exec rm "$@"; }
priv_mv() { priv_exec mv "$@"; }
priv_cp() { priv_exec cp "$@"; }
priv_ln() { priv_exec ln "$@"; }
priv_touch() { priv_exec touch "$@"; }
priv_mount() { priv_exec mount "$@"; }
priv_umount() { priv_exec umount "$@"; }
priv_systemctl() { priv_exec systemctl "$@"; }
priv_service() { priv_exec service "$@"; }
priv_ufw() { priv_exec ufw "$@"; }
priv_iptables() { priv_exec iptables "$@"; }
priv_kill() { priv_exec kill "$@"; }
priv_pkill() { priv_exec pkill "$@"; }
priv_killall() { priv_exec killall "$@"; }
priv_setquota() { priv_exec setquota "$@"; }
priv_edquota() { priv_exec edquota "$@"; }
priv_repquota() { priv_exec repquota "$@"; }
priv_tar() { priv_exec tar "$@"; }
priv_rsync() { priv_exec rsync "$@"; }
priv_gzip() { priv_exec gzip "$@"; }
priv_gunzip() { priv_exec gunzip "$@"; }
priv_chpasswd() { priv_exec chpasswd "$@"; }
priv_passwd() { priv_exec passwd "$@"; }
priv_visudo() { priv_exec visudo "$@"; }
priv_sudo() { priv_exec sudo "$@"; }

# 硬件信息命令封装
priv_dmidecode() { priv_exec dmidecode "$@"; }
priv_smartctl() { priv_exec smartctl "$@"; }
priv_sudo() { priv_exec sudo "$@"; }

# ============================================================
# 权限自检主函数
# ============================================================

# 完整的权限自检和修复建议
priv_self_check() {
    local user="${1:-$USER}"
    
    echo "🔍 开始权限自检..."
    echo ""
    
    # 运行权限审计
    acl_privilege_audit "$user"
    
    echo ""
    echo "📋 生成权限修复建议..."
    echo ""
    
    # 生成修复建议
    acl_privilege_recommend "$user"
    
    echo ""
    echo "✅ 权限自检完成"
    
    # 记录审计日志
    acl_audit_log "SELF_CHECK" "privilege_audit" "SUCCESS" "user=$user"
}

# 模块初始化 - 权限系统自检
priv_init() {
    # 检查关键命令是否在白名单中
    local -a critical_cmds=("useradd" "usermod" "userdel" "chown" "chmod")
    local missing_cmds=()
    
    for cmd in "${critical_cmds[@]}"; do
        if ! priv_check_whitelist "$cmd" 2>/dev/null; then
            missing_cmds+=("$cmd")
        fi
    done
    
    if [[ ${#missing_cmds[@]} -gt 0 ]]; then
        msg_warn "以下关键命令未在白名单中: ${missing_cmds[*]}"
    fi
    
    # 确保审计日志目录存在
    local log_dir
    log_dir=$(dirname "$ACL_AUDIT_LOG")
    if [[ ! -d "$log_dir" ]]; then
        # 尝试创建目录
        if is_root; then
            mkdir -p "$log_dir" 2>/dev/null || true
        elif command -v sudo &>/dev/null; then
            sudo mkdir -p "$log_dir" 2>/dev/null || true
        fi
    fi
}

# 执行初始化
priv_init
