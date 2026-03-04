#!/bin/bash
# config.sh - 配置管理模块 v0.2.2
#
# 环境变量覆盖机制:
#   所有配置项都支持通过环境变量覆盖默认值。
#   环境变量命名规则: USER_MANAGER_<配置项名称>
#   例如: DATA_BASE -> USER_MANAGER_DATA_BASE
#
# 使用示例:
#   export USER_MANAGER_DATA_BASE=/data
#   export USER_MANAGER_QUOTA_DEFAULT=$((1000 * 1024**3))
#   bash run.sh


# === 路径配置 ===
# shellcheck disable=SC2034
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="$SCRIPT_DIR/data"
LOG_DIR="$SCRIPT_DIR/logs"
REPORT_DIR="$DATA_DIR/report"

DATA_BASE="${USER_MANAGER_DATA_BASE:-/mnt}"
BACKUP_ROOT="${USER_MANAGER_BACKUP_ROOT:-/mnt/backup/rsnapshot}"
MANUAL_BACKUP="${USER_MANAGER_MANUAL_BACKUP:-$BACKUP_ROOT/manual}"
DISABLED_USERS_FILE="${USER_MANAGER_DISABLED_USERS_FILE:-$DATA_DIR/disabled_users.txt}"
USER_CREATION_LOG="${USER_MANAGER_USER_CREATION_LOG:-$DATA_DIR/created_users.txt}"
USER_REPORT_DIR="${USER_MANAGER_USER_REPORT_DIR:-$REPORT_DIR}"
USER_PORT_MAP_FILE="${USER_MANAGER_USER_PORT_MAP_FILE:-$DATA_DIR/user_port_map.txt}"
PASSWORD_POOL_FILE="${USER_MANAGER_PASSWORD_POOL_FILE:-$DATA_DIR/password_pool.txt}"
USER_CONFIG_FILE="${USER_MANAGER_USER_CONFIG_FILE:-$DATA_DIR/user_config.json}"
EMAIL_CONFIG_FILE="${USER_MANAGER_EMAIL_CONFIG_FILE:-$DATA_DIR/email_config.json}"
DNS_CONFIG_FILE="${USER_MANAGER_DNS_CONFIG_FILE:-$DATA_DIR/dns_whitelist.txt}"
JOB_STATS_DIR="${USER_MANAGER_JOB_STATS_DIR:-$DATA_DIR/job_stats}"
SYMLINK_LOG="${USER_MANAGER_SYMLINK_LOG:-$LOG_DIR/symlink.log}"
PASSWORD_ROTATE_LOG="${USER_MANAGER_PASSWORD_ROTATE_LOG:-$LOG_DIR/password_rotate.log}"
SYSTEM_LOG="${USER_MANAGER_SYSTEM_LOG:-$LOG_DIR/system.log}"

# === 磁盘配置 ===
ALL_DISKS=(1 2 3 4 5 6 7)

# === 资源配额配置 ===
DEFAULT_CPU_QUOTA="${USER_MANAGER_DEFAULT_CPU_QUOTA:-50%}"
DEFAULT_MEMORY_LIMIT="${USER_MANAGER_DEFAULT_MEMORY_LIMIT:-8G}"
QUOTA_DEFAULT="${USER_MANAGER_QUOTA_DEFAULT:-$((500 * 1024**3))}"  # 500GB

# === systemd 配置 ===
RESOURCE_LIMIT_FILENAME="${USER_MANAGER_RESOURCE_LIMIT_FILENAME:-90-user-manager-limits.conf}"

# === 磁盘使用率阈值 ===
DISK_WARNING_THRESHOLD="${USER_MANAGER_DISK_WARNING_THRESHOLD:-90}"

# === 密码轮换配置 ===
PASSWORD_ROTATE_INTERVAL_DAYS="${USER_MANAGER_PASSWORD_ROTATE_INTERVAL_DAYS:-90}"

# === Miniforge 配置 ===
MINIFORGE_INSTALLER="${USER_MANAGER_MINIFORGE_INSTALLER:-$SCRIPT_DIR/Miniforge.sh}"
MINIFORGE_DEFAULT_PATH="${USER_MANAGER_MINIFORGE_DEFAULT_PATH:-.miniforge}"
CONDARC_TEMPLATE="${USER_MANAGER_CONDARC_TEMPLATE:-$DATA_DIR/condarc.template}"

# === 初始化目录结构 ===
init_directories() {
    # 仅创建项目本地目录；外部系统目录（如备份根目录）由对应操作按需创建
    local dirs=("$DATA_DIR" "$REPORT_DIR" "$JOB_STATS_DIR" "$LOG_DIR")
    for dir in "${dirs[@]}"; do
        [[ -d "$dir" ]] || mkdir -p "$dir" 2>/dev/null || { msg_err "无法创建目录: $dir"; return 1; }
    done
    return 0
}

init_groups() { return 0; }

init_log_file() {
    if [[ ! -f "$USER_CREATION_LOG" ]] || [[ ! -s "$USER_CREATION_LOG" ]]; then
        printf 'timestamp,username,action,user_type,mountpoint,home,quota_gb\n' > "$USER_CREATION_LOG"
    fi
}

load_config() {
    init_directories || return 1
    init_groups || return 1
    init_log_file || return 1
    
    # 检查敏感文件权限
    if declare -f check_sensitive_file_permissions &>/dev/null; then
        check_sensitive_file_permissions \
            "$USER_CONFIG_FILE" \
            "$EMAIL_CONFIG_FILE" \
            "$PASSWORD_POOL_FILE" \
            "$DNS_CONFIG_FILE" 2>/dev/null || true
    fi
    
    return 0
}
