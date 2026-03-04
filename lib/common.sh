#!/bin/bash
# common.sh - 通用工具函数库 v0.2.1
# 提供消息输出、锁机制、输入验证、UI组件等基础功能

# === 颜色定义 ===
# shellcheck disable=SC2034
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_BLUE='\033[0;34m'
C_MAGENTA='\033[0;35m'
C_CYAN='\033[0;36m'
C_WHITE='\033[1;37m'
C_BRED='\033[1;31m'
C_BGREEN='\033[1;32m'
C_BYELLOW='\033[1;33m'
C_BBLUE='\033[1;34m'
C_BCYAN='\033[1;36m'
C_BG_RED='\033[41m'
C_BG_GREEN='\033[42m'
C_BG_YELLOW='\033[43m'

# 兼容旧变量名
# shellcheck disable=SC2034
Red="$C_RED"; Green="$C_GREEN"; Yellow="$C_YELLOW"; Color_Off="$C_RESET"

# 菜单布局常量
MENU_WIDTH=46

# === 消息函数 ===
msg()       { echo -e "$*"; }
msg_info()  { echo -e " ${C_BBLUE}●${C_RESET} $*"; }
msg_warn()  { echo -e " ${C_BYELLOW}▲${C_RESET} $*"; }
msg_err()   { echo -e " ${C_BRED}✗${C_RESET} $*" >&2; }
msg_ok()    { echo -e " ${C_BGREEN}✓${C_RESET} $*"; }
msg_step()  { echo -e " ${C_BCYAN}→${C_RESET} $*"; }
msg_debug() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        echo -e " ${C_DIM}[DEBUG] $*${C_RESET}" >&2
    fi
}

# 带上下文的错误提示
msg_err_ctx() {
    local func="${1:-}" detail="${2:-}"
    if [[ -n "$func" ]]; then
        echo -e " ${C_BRED}✗${C_RESET} ${C_DIM}[$func]${C_RESET} $detail" >&2
    else
        echo -e " ${C_BRED}✗${C_RESET} $detail" >&2
    fi
}

# === 权限辅助函数 ===

# 检查当前是否以 root 身份运行
is_root() { [[ "$(id -u)" -eq 0 ]]; }

# 通用特权命令执行（用于白名单外的命令）
# 用法: run_privileged command [args...]
run_privileged() {
    if [[ $# -eq 0 ]]; then
        msg_err "run_privileged: 未指定命令"
        return 1
    fi
    if is_root; then
        "$@"
    elif command -v sudo &>/dev/null; then
        sudo "$@"
    else
        msg_err "无法提升权限: 非 root 且 sudo 不可用"
        return 1
    fi
}

# === UI 组件 ===

draw_line() {
    local width="${1:-$MENU_WIDTH}"
    local line=""
    local i
    for ((i=0; i<width; i++)); do line+="─"; done
    printf "${C_DIM}%s${C_RESET}\n" "$line"
}

draw_header() {
    local title="$1"
    echo ""
    echo -e "  ${C_BOLD}${C_WHITE}${title}${C_RESET}"
    local hline=""
    local _i
    for ((_i=0; _i<MENU_WIDTH; _i++)); do hline+="─"; done
    printf "  ${C_DIM}%s${C_RESET}\n" "$hline"
}

draw_menu_item() {
    local num="$1" label="$2" icon="${3:-}"
    if [[ -n "$icon" ]]; then
        printf "  ${C_DIM}[${C_RESET}${C_BCYAN}%2s${C_RESET}${C_DIM}]${C_RESET}  %s %s\n" "$num" "$icon" "$label"
    else
        printf "  ${C_DIM}[${C_RESET}${C_BCYAN}%2s${C_RESET}${C_DIM}]${C_RESET}  %s\n" "$num" "$label"
    fi
}

draw_menu_submenu() {
    local num="$1" label="$2"
    printf "  ${C_DIM}[${C_RESET}${C_BYELLOW}%2s${C_RESET}${C_DIM}]${C_RESET}  %s ${C_DIM}›${C_RESET}\n" "$num" "$label"
}

draw_menu_exit() {
    local label="${1:-返回}"
    printf "\n  %s[ %s0%s%s]%s  %s%s%s\n" \
        "$C_DIM" "$C_RED" "$C_RESET" "$C_DIM" "$C_RESET" "$C_DIM" "$label" "$C_RESET"
}

draw_prompt() {
    echo ""
    echo -ne "  ${C_BYELLOW}❯${C_RESET} "
}

pause_continue() {
    echo ""
    read -rsp $'\n  按回车键继续...' -n1
}

# 使用率颜色
get_usage_color() {
    local pct="$1"
    if (( pct >= 90 )); then   echo "$C_BRED"
    elif (( pct >= 70 )); then echo "$C_BYELLOW"
    elif (( pct >= 50 )); then echo "$C_YELLOW"
    else                       echo "$C_BGREEN"
    fi
}

# 使用率条
draw_usage_bar() {
    local pct="$1" width="${2:-20}"
    local color
    color=$(get_usage_color "$pct")
    local filled=$((pct * width / 100))
    [[ $filled -gt $width ]] && filled=$width
    local empty=$((width - filled))
    printf "%s" "$color"
    printf '%*s' "$filled" '' | tr ' ' '▓'
    printf "%s" "$C_DIM"
    printf '%*s' "$empty" '' | tr ' ' '░'
    printf "%s %s%3d%%%s" "$C_RESET" "$color" "$pct" "$C_RESET"
}

# 确认提示
confirm_action() {
    local prompt="${1:-确认操作？}" default="${2:-N}"
    local hint
    [[ "$default" == "Y" ]] && hint="Y/n" || hint="y/N"
    read -r -p "$(echo -e " ${C_BYELLOW}?${C_RESET} ${prompt} (${hint}): ")" answer
    answer="${answer:-$default}"
    [[ "$answer" =~ ^[Yy]$ ]]
}

# 信息卡片
draw_info_card() {
    local label="$1" value="$2" color="${3:-$C_BOLD}"
    printf "  ${C_DIM}%-16s${C_RESET} ${color}%s${C_RESET}\n" "$label" "$value"
}

# === 锁机制 ===
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

# === 用户列表缓存机制 ===
# shellcheck disable=SC2034
USERNAMES_CACHE=""
USERNAMES_CACHE_TIME=0
USERNAMES_CACHE_TTL=300  # 5 分钟 TTL

# 清除用户名缓存
clear_usernames_cache() {
    USERNAMES_CACHE=""
    USERNAMES_CACHE_TIME=0
}

# === 输入验证函数 ===
USERNAME_PATTERN='^[a-zA-Z_][a-zA-Z0-9_-]{0,30}$'

validate_username() {
    local username="$1"
    [[ "$username" =~ $USERNAME_PATTERN ]] && return 0
    msg_err "用户名 '$username' 无效 (字母/数字/下划线/连字符，以字母或下划线开头)"
    return 1
}

validate_cpu_quota() {
    local value="$1"
    [[ -z "$value" ]] && return 1
    [[ "$value" =~ ^[0-9]+(\.[0-9]+)?%$ ]] && return 0
    msg_err "CPU 配额格式无效，应形如 50% 或 200%"; return 1
}

validate_memory_limit() {
    local value="$1"
    [[ -z "$value" ]] && return 1
    [[ "$value" =~ ^[0-9]+(\.[0-9]+)?[KMGTP]$ ]] && return 0
    msg_err "内存配额格式无效，应形如 512M、32G、1T"; return 1
}

# === 工具函数 ===
get_user_home() { getent passwd "$1" | cut -d: -f6; }

parse_quota_input() {
    local input="$1"
    if [[ "$input" =~ ^([0-9]+\.?[0-9]*)([GT])?$ ]]; then
        local num="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[2]}"
        case "$unit" in
            G) awk "BEGIN {printf \"%.0f\", $num * 1024^3}" ;; T) awk "BEGIN {printf \"%.0f\", $num * 1024^4}" ;;
            *) awk "BEGIN {printf \"%.0f\", $num * 1024^3}" ;; esac
        return 0
    else return 1; fi
}

bytes_to_gb() {
    local bytes="$1"
    # 验证输入为数字
    [[ -z "$bytes" ]] && { echo "0.00"; return 1; }
    [[ "$bytes" =~ ^[0-9]+$ ]] || { echo "0.00"; return 1; }
    awk "BEGIN {printf \"%.2f\", $bytes / 1073741824}"
}

bytes_to_human() {
    local b="$1"
    # 验证输入
    [[ -z "$b" ]] && { echo "0 B"; return 1; }
    [[ "$b" =~ ^[0-9]+$ ]] || { echo "0 B"; return 1; }
    if   (( b >= 1099511627776 )); then awk "BEGIN {printf \"%.1f TB\", $b / 1099511627776}"
    elif (( b >= 1073741824 ));    then awk "BEGIN {printf \"%.1f GB\", $b / 1073741824}"
    elif (( b >= 1048576 ));       then awk "BEGIN {printf \"%.1f MB\", $b / 1048576}"
    else                                awk "BEGIN {printf \"%.1f KB\", $b / 1024}"; fi
}

remove_file_entry() {
    local file="$1" pattern="$2"
    [[ -f "$file" ]] || return 0
    local tmp
    tmp=$(mktemp) || { msg_err "无法创建临时文件"; return 1; }
    grep -v "$pattern" "$file" > "$tmp" || true
    mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

check_dependencies() {
    local missing=() required=(awk sed grep id useradd usermod userdel passwd setquota repquota)
    for cmd in "${required[@]}"; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if (( ${#missing[@]} > 0 )); then
        msg_err "缺少必要命令: ${missing[*]}"; return 1
    fi
    return 0
}

# ============================================================
# 鲁棒性增强
# ============================================================

# 全局 trap 处理器：清理锁文件和临时文件
setup_trap_handler() {
    trap '_cleanup_on_exit' EXIT
    trap '_cleanup_on_error $LINENO' ERR
    trap '_cleanup_on_signal' INT TERM HUP
}

_cleanup_on_exit() {
    release_lock 2>/dev/null || true
    # 清理可能残留的临时文件
    rm -f /tmp/backup_parallel_*.sh 2>/dev/null || true
}

_cleanup_on_error() {
    local lineno="$1"
    # 构建函数调用栈上下文
    local stack="" i
    for (( i=1; i<${#FUNCNAME[@]}; i++ )); do
        [[ "${FUNCNAME[$i]}" == "main" ]] && continue
        if [[ -n "$stack" ]]; then
            stack="${FUNCNAME[$i]} → $stack"
        else
            stack="${FUNCNAME[$i]}"
        fi
    done
    if [[ -n "$stack" ]]; then
        msg_err "错误在第 ${lineno} 行 [${stack}]" 2>/dev/null || true
    else
        msg_err "错误发生在第 ${lineno} 行" 2>/dev/null || true
    fi
    release_lock 2>/dev/null || true
}

_cleanup_on_signal() {
    echo ""
    msg_warn "操作被中断" 2>/dev/null || true
    release_lock 2>/dev/null || true
    exit 130
}

# 安全的参数校验函数
require_param() {
    local param_name="$1"
    local param_value="$2"
    if [[ -z "$param_value" ]]; then
        msg_err "必需参数缺失: ${param_name}"
        return 1
    fi
    return 0
}

# 安全的文件操作检查
require_file() {
    local filepath="$1"
    local desc="${2:-文件}"
    if [[ ! -f "$filepath" ]]; then
        msg_err "${desc}不存在: $filepath"
        return 1
    fi
    return 0
}

# 安全的目录操作检查
require_dir() {
    local dirpath="$1"
    local desc="${2:-目录}"
    if [[ ! -d "$dirpath" ]]; then
        msg_err "${desc}不存在: $dirpath"
        return 1
    fi
    return 0
}

# 安全的用户存在性检查
require_user() {
    local username="$1"
    if [[ -z "$username" ]]; then
        msg_err "用户名不能为空"
        return 1
    fi
    if ! id "$username" &>/dev/null; then
        msg_err "用户 ${C_BOLD}$username${C_RESET} 不存在"
        return 1
    fi
    return 0
}

# 安全的数值检查
is_positive_int() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+$ ]] && (( value > 0 ))
}

# 安全的挂载点检查
require_mountpoint() {
    local mp="$1"
    if [[ -z "$mp" ]]; then
        msg_err "挂载点不能为空"
        return 1
    fi
    if ! mountpoint -q "$mp" 2>/dev/null; then
        msg_err "挂载点 $mp 未挂载"
        return 1
    fi
    return 0
}

# 超时包装器：prevent 长时间阻塞的操作
run_with_timeout() {
    local timeout_secs="$1"
    shift
    if command -v timeout &>/dev/null; then
        timeout "$timeout_secs" "$@"
    else
        "$@"
    fi
}

# ============================================================
# 框架：安全执行 & 统一菜单循环
# ============================================================

# 安全执行：隔离子函数错误，防止菜单崩溃
# 用法: safe_run some_function arg1 arg2
safe_run() {
    local rc=0
    "$@" || rc=$?
    if (( rc != 0 )); then
        msg_warn "函数 '$1' 执行失败 (返回码: $rc)"
        msg_debug "函数 '$1' 参数: ${*:2}"
    fi
    return 0   # 始终返回 0，防止主循环退出
}

# 统一交互式输入（带标签和默认值）
# 用法: read_input "提示文本" [变量名] [默认值]
# 返回值通过 REPLY_INPUT 全局变量传出
REPLY_INPUT=""
read_input() {
    local prompt="$1" default="${2:-}"
    local display_default=""
    [[ -n "$default" ]] && display_default=" ${C_DIM}[${default}]${C_RESET}"
    echo -ne "  ${prompt}${display_default}: "
    read -r REPLY_INPUT
    REPLY_INPUT="${REPLY_INPUT:-$default}"
}

# 统一用户名输入（含验证）
# 成功时 REPLY_INPUT = 用户名; 失败返回 1
read_username() {
    local prompt="${1:-请输入用户名}"
    read_input "$prompt"
    if [[ -z "$REPLY_INPUT" ]]; then
        msg_err "用户名不能为空"; return 1
    fi
    validate_username "$REPLY_INPUT" || return 1
    return 0
}

# 统一用户名输入（含存在性验证）
read_existing_username() {
    local prompt="${1:-请输入用户名}"
    read_username "$prompt" || return 1
    if ! id "$REPLY_INPUT" &>/dev/null; then
        msg_err "用户 '${REPLY_INPUT}' 不存在"; return 1
    fi
    return 0
}

# 统一子菜单循环框架
# 用法: run_submenu "标题" handler_function "编号:标签" ...
# 特殊条目: "---" 画分隔线, "编号:标签 ›" 画子菜单箭头
# handler_function 接收选项编号作为参数
run_submenu() {
    local title="$1"
    shift
    local handler="$1"
    shift
    local -a items=("$@")

    while true; do
        clear
        draw_header "$title"
        local num label
        for entry in "${items[@]}"; do
            # 分隔线
            if [[ "$entry" == "---" ]]; then
                draw_line "$MENU_WIDTH"
                continue
            fi
            num="${entry%%:*}"
            label="${entry#*:}"
            if [[ "$label" == *"›" ]]; then
                draw_menu_submenu "$num" "${label% ›}"
            else
                draw_menu_item "$num" "$label"
            fi
        done
        draw_menu_exit "返回"
        draw_prompt
        read -r opt
        [[ "$opt" == "0" ]] && return 0
        safe_run "$handler" "$opt"
        pause_continue
    done
}

# ============================================================
# 网络信息函数
# ============================================================

# 获取本机 IP 地址
get_local_ip() {
    local ip=""
    
    # 尝试 ip 命令
    if command -v ip &>/dev/null; then
        ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || true)
    fi
    
    # 回退到 ifconfig
    if [[ -z "$ip" ]] && command -v ifconfig &>/dev/null; then
        ip=$(ifconfig | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | 
             grep -Eo '([0-9]*\.){3}[0-9]*' | 
             grep -v '127.0.0.1' | head -n 1 || true)
    fi
    
    # 回退到 hostname
    if [[ -z "$ip" ]]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    fi
    
    echo "$ip"
}

# 获取公网 IP 地址
get_public_ip() {
    local ip=""
    
    # 尝试多个服务以保证可用性
    local services=(
        "https://api.ipify.org"
        "https://ipinfo.io/ip"
        "https://icanhazip.com"
    )
    
    for service in "${services[@]}"; do
        ip=$(curl -fsSL --max-time 10 "$service" 2>/dev/null || true)
        if [[ -n "$ip" ]]; then
            break
        fi
    done
    
    echo "$ip"
}

# 获取 Tailscale IP 地址
get_tailscale_ip() {
    local ip=""
    
    # 检查 tailscale 命令是否可用
    if command -v tailscale &>/dev/null; then
        # 获取 Tailscale IP (100.x.x.x)
        ip=$(tailscale ip -4 2>/dev/null | head -n 1 || true)
    fi
    
    # 回退: 尝试查找 tailscale0 接口
    if [[ -z "$ip" ]] && command -v ip &>/dev/null; then
        ip=$(ip addr show tailscale0 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -n 1 || true)
    fi
    
    echo "$ip"
}

# 显示完整的网络信息
show_network_info() {
    echo ""
    draw_header "网络信息"
    
    # 本机 IP
    local local_ip
    local_ip=$(get_local_ip)
    echo ""
    msg_info "本机 IP 地址:"
    if [[ -n "$local_ip" ]]; then
        echo -e "  ${C_BGREEN}$local_ip${C_RESET}"
    else
        echo -e "  ${C_BRED}无法检测${C_RESET}"
    fi
    
    # 公网 IP
    local public_ip
    public_ip=$(get_public_ip)
    echo ""
    msg_info "公网 IP 地址:"
    if [[ -n "$public_ip" ]]; then
        echo -e "  ${C_BGREEN}$public_ip${C_RESET}"
    else
        echo -e "  ${C_BYELLOW}无法检测（可能无网络连接）${C_RESET}"
    fi
    
    # Tailscale IP
    local tailscale_ip
    tailscale_ip=$(get_tailscale_ip)
    echo ""
    msg_info "Tailscale IP 地址 (远程连接):"
    if [[ -n "$tailscale_ip" ]]; then
        echo -e "  ${C_BGREEN}$tailscale_ip${C_RESET}"
        echo -e "  ${C_CYAN}这是您的 Tailscale VPN IP，用于远程连接${C_RESET}"
    else
        echo -e "  ${C_BYELLOW}未检测到 Tailscale${C_RESET}"
    fi
    
    echo ""
    draw_line "$MENU_WIDTH"
    echo ""
}

# ============================================================
# 安全性增强
# ============================================================

# 检查敏感文件权限
check_sensitive_file_permissions() {
    local files=("$@")
    local issues=()
    
    for file in "${files[@]}"; do
        if [[ -f "$file" ]]; then
            local perms
            perms=$(stat -c %a "$file" 2>/dev/null || echo "unknown")
            
            # 检查是否为安全权限 (600, 400, 或 700)
            if [[ "$perms" != "600" && "$perms" != "400" && "$perms" != "700" ]]; then
                issues+=("$file:$perms")
                msg_warn "不安全的权限: $file (当前: $perms)"
                
                # 尝试修复权限
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
    
    # 解析绝对路径
    local real_path
    real_path=$(realpath -m "$path" 2>/dev/null || echo "")
    
    if [[ -z "$real_path" ]]; then
        msg_err "无效路径: $path"
        return 1
    fi
    
    # 检查危险模式
    if [[ "$path" =~ \.\. ]]; then
        msg_warn "路径包含相对路径符号: $path"
    fi
    
    # 检查是否在允许的目录内
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
    
    # 检查特权端口
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
    
    # 验证每个八位组
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

# ============================================================
# 增强的锁机制
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
