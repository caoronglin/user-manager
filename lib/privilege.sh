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
else

# ============================================================
# 命令白名单配置
# ============================================================

# 允许的特权命令及其所需权限级别
readonly -A PRIV_CMD_WHITELIST=(
    # 用户管理命令 - 需要 admin 级别
    ["useradd"]="$ACL_LEVEL_ADMIN"
    ["usermod"]="$ACL_LEVEL_ADMIN"
    ["userdel"]="$ACL_LEVEL_ADMIN"
    ["deluser"]="$ACL_LEVEL_ADMIN"
    ["chpasswd"]="$ACL_LEVEL_ADMIN"
    ["passwd"]="$ACL_LEVEL_ADMIN"
    ["groupadd"]="$ACL_LEVEL_ADMIN"
    ["groupmod"]="$ACL_LEVEL_ADMIN"
    ["groupdel"]="$ACL_LEVEL_ADMIN"
    
    # 文件权限命令 - 根据上下文需要不同级别
    ["apt-get"]="$ACL_LEVEL_ADMIN"
    ["mkdir"]="$ACL_LEVEL_ADMIN"
    ["rmdir"]="$ACL_LEVEL_ADMIN"
    ["rm"]="$ACL_LEVEL_ADMIN"
    ["mv"]="$ACL_LEVEL_ADMIN"
    ["cp"]="$ACL_LEVEL_ADMIN"
    ["ln"]="$ACL_LEVEL_ADMIN"
    ["sed"]="$ACL_LEVEL_ADMIN"
    ["touch"]="$ACL_LEVEL_ADMIN"
    ["tee"]="$ACL_LEVEL_ADMIN"
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
    ["gzip"]="$ACL_LEVEL_ADMIN"
    ["gunzip"]="$ACL_LEVEL_ADMIN"
    ["rsync"]="$ACL_LEVEL_ADMIN"
    
    # 网络/防火墙命令 - 需要 admin 级别
    ["ufw"]="$ACL_LEVEL_ADMIN"
    ["iptables"]="$ACL_LEVEL_ADMIN"
    ["ipset"]="$ACL_LEVEL_ADMIN"
    
    # 其他特权命令
    ["crontab"]="$ACL_LEVEL_ADMIN"
    ["du"]="$ACL_LEVEL_ADMIN"
    ["parallel"]="$ACL_LEVEL_ADMIN"
    ["quota"]="$ACL_LEVEL_ADMIN"
    ["virsh"]="$ACL_LEVEL_ADMIN"
    ["xargs"]="$ACL_LEVEL_ADMIN"
    ["mount"]="$ACL_LEVEL_ADMIN"
    ["umount"]="$ACL_LEVEL_ADMIN"
    ["kill"]="$ACL_LEVEL_ADMIN"
    ["pkill"]="$ACL_LEVEL_ADMIN"
    ["killall"]="$ACL_LEVEL_ADMIN"
    ["visudo"]="$ACL_LEVEL_ROOT"
    
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
    local safe_user safe_pwd
    safe_user="${USER:-unknown}"
    safe_pwd="$(pwd)"
    safe_user="${safe_user//\"/\\\"}"
    safe_pwd="${safe_pwd//\"/\\\"}"
    local snapshot="{"
    snapshot="${snapshot}\"user\":\"${safe_user}\","
    snapshot="${snapshot}\"uid\":${UID:-$(id -u)},"
    snapshot="${snapshot}\"pwd\":\"${safe_pwd}\","
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
priv_deluser() { priv_exec deluser "$@"; }
priv_groupadd() { priv_exec groupadd "$@"; }
priv_groupmod() { priv_exec groupmod "$@"; }
priv_groupdel() { priv_exec groupdel "$@"; }
priv_apt_get() { priv_exec apt-get "$@"; }
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
priv_sed() { priv_exec sed "$@"; }
priv_tee() { priv_exec tee "$@"; }
priv_crontab() { priv_exec crontab "$@"; }
priv_du() { priv_exec du "$@"; }
priv_parallel() { priv_exec parallel "$@"; }
priv_xargs() { priv_exec xargs "$@"; }
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
priv_quota() { priv_exec quota "$@"; }
priv_virsh() { priv_exec virsh "$@"; }
priv_edquota() { priv_exec edquota "$@"; }
priv_repquota() { priv_exec repquota "$@"; }
priv_tar() { priv_exec tar "$@"; }
priv_rsync() { priv_exec rsync "$@"; }
priv_gzip() { priv_exec gzip "$@"; }
priv_gunzip() { priv_exec gunzip "$@"; }
priv_chpasswd() { priv_exec chpasswd "$@"; }
priv_passwd() { priv_exec passwd "$@"; }
priv_visudo() { priv_exec visudo "$@"; }

# 硬件信息命令封装
priv_dmidecode() { priv_exec dmidecode "$@"; }
priv_smartctl() { priv_exec smartctl "$@"; }

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

# ============================================================
# 统一权限检查入口（新增）
# ============================================================

# 权限矩阵定义
declare -A PERMISSION_MATRIX=(
    ["user:create"]="$ACL_LEVEL_ADMIN"
    ["user:delete"]="$ACL_LEVEL_ADMIN"
    ["user:update"]="$ACL_LEVEL_USER"
    ["user:read"]="$ACL_LEVEL_GUEST"
    ["quota:set"]="$ACL_LEVEL_ADMIN"
    ["quota:read"]="$ACL_LEVEL_USER"
    ["firewall:add"]="$ACL_LEVEL_ADMIN"
    ["firewall:delete"]="$ACL_LEVEL_ADMIN"
    ["firewall:list"]="$ACL_LEVEL_USER"
    ["backup:create"]="$ACL_LEVEL_USER"
    ["backup:restore"]="$ACL_LEVEL_ADMIN"
    ["backup:delete"]="$ACL_LEVEL_ADMIN"
    ["email:send"]="$ACL_LEVEL_USER"
    ["system:modify"]="$ACL_LEVEL_ADMIN"
    ["system:read"]="$ACL_LEVEL_GUEST"
)

# 权限检查统一入口
check_permission() {
    local resource="$1"
    local action="$2"
    local context="${3:-}"
    
    local key="${resource}:${action}"
    local required_level="${PERMISSION_MATRIX[$key]:-$ACL_LEVEL_ADMIN}"
    local current_level
    current_level=$(get_current_permission_level)
    
    if (( current_level <= required_level )); then
        return 0
    fi
    
    return 1
}

# 需要权限执行
require_permission() {
    local resource="$1"
    local action="$2"
    local context="${3:-}"
    
    if ! check_permission "$resource" "$action" "$context"; then
        if declare -F msg_err &>/dev/null; then
            msg_err "权限不足: 需要 ${resource}:${action} 权限"
        fi
        return 1
    fi
    return 0
}

# 带权限检查的执行
run_with_permission() {
    local resource="$1"
    local action="$2"
    shift 2
    
    require_permission "$resource" "$action" || return 1
    "$@"
}

# 获取当前权限级别
get_current_permission_level() {
    if is_root; then
        echo "$ACL_LEVEL_ROOT"
    elif declare -F acl_get_current_level &>/dev/null; then
        acl_get_current_level
    elif declare -F get_acl_level &>/dev/null; then
        get_acl_level
    else
        echo "$ACL_LEVEL_GUEST"
    fi
}

# ============================================================
# 统一 rl_ 前缀权限封装层（新增 v2）
# ============================================================

# 检查 sudo 是否可用（非 root 时）
rl_priv_can_sudo() {
    if is_root; then
        return 0
    fi
    command -v sudo &>/dev/null || return 1
}

# 统一特权执行入口（兼容现有 priv_exec）
rl_priv_exec() {
    priv_exec "$@"
}

# 安全写系统文件（通过 tee）
# 用法：rl_priv_write_file <path> <content>
rl_priv_write_file() {
    local rl_target="$1"
    local rl_content="$2"
    if [[ -z "$rl_target" ]]; then
        msg_err "rl_priv_write_file: 目标路径不能为空"
        return 1
    fi
    printf '%s\n' "$rl_content" | priv_exec tee "$rl_target" >/dev/null
}

# 统一 systemctl 封装
rl_priv_systemctl() {
    priv_exec systemctl "$@"
}

# 统一 setquota 封装
rl_priv_setquota() {
    priv_exec setquota "$@"
}

# 统一 repquota 封装
rl_priv_repquota() {
    priv_exec repquota "$@"
}
fi
