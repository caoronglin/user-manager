#!/bin/bash
# user_core.sh - 用户管理核心模块 v6.0
# 提供用户 CRUD 操作、密码管理、暂停功能、作业统计
#
# SECURITY NOTE: 本模块通过管道传递明文密码至 chpasswd。
# 密码在进程列表（/proc）中可能短暂可见。
# 生产环境建议：
#   - 使用 `chpasswd -e` 配合预加密密码
#   - 确保日志/审计不记录密码明文
#   - 密码操作完成后立即清除相关变量 (unset)

# ============================================================
# 密码池管理（每次执行使用时间戳生成新密码池）
# ============================================================

# 生成密码池（8568个8位密码），使用时间戳确保每次执行生成新池
# 格式：3位连续大写(ASDFGHJKL) + 1位小写 + 3位连续数字 + 1位特殊字符
# 用法: generate_password_pool [自定义输出路径]
#   - 无参数或默认路径时：使用时间戳命名（password_pool_YYYYMMDD_HHMMSS.txt）
#   - 自定义路径时：直接写入指定文件（向后兼容测试）
# 返回：新生成的密码池文件路径
generate_password_pool() {
    local custom_path="${1:-}"
    local pool_dir="${PASSWORD_POOL_DIR}"
    local pool_file used_file timestamp

    # 判断是否使用自定义路径
    if [[ -n "$custom_path" ]] && [[ "$custom_path" != "$PASSWORD_POOL_FILE" ]]; then
        # 自定义路径：向后兼容，直接写入
        pool_file="$custom_path"
        used_file="${pool_file}.used"
        mkdir -p "$(dirname "$pool_file")"
    else
        # 时间戳模式：每次都生成新池
        timestamp=$(date +%Y%m%d_%H%M%S)
        mkdir -p "$pool_dir"
        pool_file="${pool_dir}/password_pool_${timestamp}.txt"
        used_file="${pool_dir}/password_pool_${timestamp}.used"
    fi

    msg_info "正在生成密码池（8568 个密码）..."

    local old_umask
    old_umask=$(umask)
    umask 077

    local upper_row="ASDFGHJKL"
    local lower_chars="qwertyuiopzxcvbnm"
    local digit_row="1234567890"
    local specials='!@#$%^&*?'

    local tmp_file
    tmp_file=$(mktemp) || {
        umask "$old_umask"
        msg_err "无法创建临时文件"
        return 1
    }

    {
        local i j k m
        for (( i = 0; i <= ${#upper_row} - 3; i++ )); do
            local tri="${upper_row:i:3}"
            for (( j = 0; j < ${#lower_chars}; j++ )); do
                local lc="${lower_chars:j:1}"
                for (( k = 0; k <= ${#digit_row} - 3; k++ )); do
                    local dig="${digit_row:k:3}"
                    for (( m = 0; m < ${#specials}; m++ )); do
                        echo "${tri}${lc}${dig}${specials:m:1}"
                    done
                done
            done
        done
    } > "$tmp_file"

    # 使用时间戳作为随机种子进行洗牌，确保每次生成的池唯一
    if [[ -z "$custom_path" ]] || [[ "$custom_path" == "$PASSWORD_POOL_FILE" ]]; then
        if ! shuf --random-source=<(printf '%s' "$timestamp$RANDOM") "$tmp_file" > "$pool_file" 2>/dev/null; then
            shuf "$tmp_file" > "$pool_file" || {
                rm -f "$tmp_file"
                umask "$old_umask"
                msg_err "密码池生成失败"
                return 1
            }
        fi
    else
        shuf "$tmp_file" > "$pool_file" || {
            rm -f "$tmp_file"
            umask "$old_umask"
            msg_err "密码池生成失败"
            return 1
        }
    fi
    rm -f "$tmp_file"
    chmod 600 "$pool_file" 2>/dev/null || true

    # 创建 .used 追踪文件（仅时间戳模式）
    touch "$used_file" 2>/dev/null || true
    chmod 600 "$used_file" 2>/dev/null || true

    umask "$old_umask"

    # 更新当前活跃密码池的符号链接（仅时间戳模式）
    if [[ -z "$custom_path" ]] || [[ "$custom_path" == "$PASSWORD_POOL_FILE" ]]; then
        local latest_link="${pool_dir}/password_pool_latest.txt"
        ln -sf "$pool_file" "$latest_link" 2>/dev/null || true
    fi

    local count
    count=$(wc -l < "$pool_file")
    msg_ok "密码池已生成：${pool_file}（${count} 个密码）"

    echo "$pool_file"
}

# 从密码池中获取一个随机且未使用过的密码
# 自动生成新池（如果不存在），追踪已用密码避免重复
get_random_password() {
    local pool_dir="${PASSWORD_POOL_DIR}"
    mkdir -p "$pool_dir"

    # 查找最新的密码池文件
    local pool_file
    pool_file=$(ls -t "$pool_dir"/password_pool_*.txt 2>/dev/null | head -1)

    # 如果没有密码池或最新池为空，生成新池
    if [[ -z "$pool_file" ]] || [[ ! -f "$pool_file" ]] || [[ $(wc -l < "$pool_file" 2>/dev/null) -lt 1 ]]; then
        pool_file=$(generate_password_pool 2>/dev/null | tail -n 1) || return 1
        [[ -f "$pool_file" ]] || return 1
    fi

    local used_file="${pool_file%.txt}.used"
    touch "$used_file" 2>/dev/null || true

    local total_passwords
    total_passwords=$(wc -l < "$pool_file")

    # 获取已使用的密码数量
    local used_count
    used_count=$(wc -l < "$used_file" 2>/dev/null || echo 0)

    # 如果所有密码都已使用，生成新池
    if (( used_count >= total_passwords )); then
        msg_warn "当前密码池已耗尽，生成新密码池..." >&2
        pool_file=$(generate_password_pool 2>/dev/null | tail -n 1) || return 1
        [[ -f "$pool_file" ]] || return 1
        used_file="${pool_file%.txt}.used"
        touch "$used_file" 2>/dev/null || true
        total_passwords=$(wc -l < "$pool_file")
    fi

    # 在未使用的密码中随机选取
    local selected_password=""
    local max_attempts=200
    local attempt=0

    while [[ -z "$selected_password" ]] && (( attempt < max_attempts )); do
        local random_line
        random_line=$(shuf -i 1-"$total_passwords" -n 1)
        local candidate
        candidate=$(sed -n "${random_line}p" "$pool_file" 2>/dev/null)

        if [[ -n "$candidate" ]]; then
            # 检查是否已被使用
            if ! grep -qxF "$candidate" "$used_file" 2>/dev/null; then
                selected_password="$candidate"
                echo "$candidate" >> "$used_file"
            fi
        fi
        ((attempt++))
    done

    if [[ -z "$selected_password" ]]; then
        msg_err "无法获取未使用的密码，自动生成新密码池..." >&2
        pool_file=$(generate_password_pool 2>/dev/null | tail -n 1) || return 1
        [[ -f "$pool_file" ]] || return 1
        used_file="${pool_file%.txt}.used"
        touch "$used_file" 2>/dev/null || true
        total_passwords=$(wc -l < "$pool_file")
        random_line=$(shuf -i 1-"$total_passwords" -n 1)
        selected_password=$(sed -n "${random_line}p" "$pool_file")
        echo "$selected_password" >> "$used_file"
    fi

    echo "$selected_password"
}

# 清理旧的密码池文件，只保留最近 N 个
cleanup_old_password_pools() {
    local keep="${1:-$PASSWORD_POOL_KEEP}"
    local pool_dir="${PASSWORD_POOL_DIR}"

    [[ -d "$pool_dir" ]] || return 0

    local -a pool_files=()
    while IFS= read -r f; do
        pool_files+=("$f")
    done < <(ls -t "$pool_dir"/password_pool_*.txt 2>/dev/null)

    if (( ${#pool_files[@]} > keep )); then
        local cleaned=0
        for (( i = keep; i < ${#pool_files[@]}; i++ )); do
            local f="${pool_files[$i]}"
            local used_file="${f%.txt}.used"
            rm -f "$f" "$used_file" 2>/dev/null && ((cleaned++))
        done
        (( cleaned > 0 )) && msg_info "已清理 ${cleaned} 个旧密码池"
    fi

    return 0
}

# ============================================================
# 用户配置管理 (JSON via jq)
# ============================================================

# 初始化用户配置文件
init_user_config() {
    mkdir -p "$(dirname "$USER_CONFIG_FILE")"

    if [[ ! -f "$USER_CONFIG_FILE" ]]; then
        echo "{}" > "$USER_CONFIG_FILE"
    fi
}

# 更新用户配置（邮箱、CPU、内存等）
update_user_config() {
    local username="$1"
    local email="${2:-}"
    local cpu_quota="${3:-$DEFAULT_CPU_QUOTA}"
    local memory_limit="${4:-$DEFAULT_MEMORY_LIMIT}"

    [[ -z "$username" ]] && return 1

    init_user_config

    if command -v jq &>/dev/null; then
        local temp_file
        temp_file=$(mktemp) || { msg_err "无法创建临时文件"; return 1; }
        if jq --arg user "$username" \
           --arg mail "$email" \
           --arg cpu "$cpu_quota" \
           --arg mem "$memory_limit" \
           '.[$user] = {
               "email": $mail,
               "cpu_quota": $cpu,
               "memory_limit": $mem,
               "created": (now | strftime("%Y-%m-%d %H:%M:%S"))
           }' "$USER_CONFIG_FILE" > "$temp_file"; then
            mv "$temp_file" "$USER_CONFIG_FILE"
            return $?
        else
            rm -f "$temp_file"
            return 1
        fi
    else
        msg_warn "建议安装 jq 以更好地管理用户配置"
    fi
}

# 获取用户配置
get_user_config() {
    local username="$1"
    local field="${2:-email}"

    [[ ! -f "$USER_CONFIG_FILE" ]] && return 1

    if command -v jq &>/dev/null; then
        jq -r --arg user "$username" --arg field "$field" \
           '.[$user][$field] // empty' "$USER_CONFIG_FILE" 2>/dev/null
    fi
}

# 获取用户邮箱（兼容旧接口）
get_user_email() {
    get_user_config "$1" "email"
}

# ============================================================
# 邮箱配置管理
# ============================================================

# 初始化邮箱配置
init_email_config() {
    mkdir -p "$(dirname "$EMAIL_CONFIG_FILE")"

    if [[ ! -f "$EMAIL_CONFIG_FILE" ]]; then
        cat > "$EMAIL_CONFIG_FILE" << 'EOF'
{
  "smtp_server": "smtp.example.com",
  "smtp_port": "587",
  "smtp_user": "noreply@example.com",
  "smtp_password": "",
  "from_address": "noreply@example.com",
  "from_name": "用户管理系统",
  "use_starttls": true
}
EOF
        msg_info "已创建邮箱配置文件: $EMAIL_CONFIG_FILE"
        msg_warn "请编辑 $EMAIL_CONFIG_FILE 配置 SMTP 信息"
    fi
}

# 读取邮箱配置
get_email_config() {
    local field="$1"

    [[ ! -f "$EMAIL_CONFIG_FILE" ]] && init_email_config

    if command -v jq &>/dev/null; then
        jq -r --arg field "$field" '.[$field] // empty' "$EMAIL_CONFIG_FILE" 2>/dev/null
    fi
}


# ============================================================
# 用户事件记录
# ============================================================

# 记录用户事件（CSV 格式）
# 格式: timestamp,username,action,user_type,mountpoint,home,quota_gb
record_user_event() {
    local username="${1:-}"
    local action="${2:-}"
    local user_type="${3:-}"
    local mountpoint="${4:-}"
    local home="${5:-}"
    local quota_bytes="${6:-}"

    local timestamp quota_gb="N/A"
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    if [[ "$quota_bytes" =~ ^[0-9]+$ ]] && (( quota_bytes > 0 )); then
        quota_gb=$(bytes_to_gb "$quota_bytes")
    fi

    printf '%s,%s,%s,%s,%s,%s,%s\n' \
        "$timestamp" "$username" "$action" "$user_type" "$mountpoint" "$home" "$quota_gb" \
        >> "$USER_CREATION_LOG"
}

# ============================================================
# 用户 CRUD 操作
# ============================================================

ensure_user_proxy_function() {
    local username="$1"
    local user_home="$2"
    local proxy_url="${USER_MANAGER_PROXY_URL:-http://127.0.0.1:7890}"

    [[ -z "$username" ]] && { msg_err "用户名不能为空"; return 1; }
    [[ -z "$user_home" ]] && { msg_err "主目录不能为空"; return 1; }

    mkdir -p "$user_home" 2>/dev/null || true

    local block
    block=$(cat << EOF
# >>> user-manager proxy helper >>>
proxy() {
    local proxy_url="\${1:-$proxy_url}"
    export http_proxy="\$proxy_url"
    export https_proxy="\$proxy_url"
    export all_proxy="\$proxy_url"
    export HTTP_PROXY="\$proxy_url"
    export HTTPS_PROXY="\$proxy_url"
    export ALL_PROXY="\$proxy_url"
}
unproxy() {
    unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
}
# <<< user-manager proxy helper <<<
EOF
)

    local rc_file
    for rc_file in "$user_home/.bashrc" "$user_home/.zshrc"; do
        if [[ ! -f "$rc_file" ]]; then
            if declare -F priv_touch >/dev/null 2>&1; then
                priv_touch "$rc_file" >/dev/null 2>&1 || return 1
            else
                touch "$rc_file" 2>/dev/null || return 1
            fi
        fi
        if ! grep -q '# >>> user-manager proxy helper >>>' "$rc_file" 2>/dev/null; then
            if declare -F priv_tee >/dev/null 2>&1; then
                printf '\n%s\n' "$block" | priv_tee -a "$rc_file" >/dev/null || return 1
            else
                {
                    printf '\n%s\n' "$block"
                } >> "$rc_file" || return 1
            fi
        fi
        if id "$username" >/dev/null 2>&1; then
            priv_chown "$username:$username" "$rc_file" 2>/dev/null || true
        fi
        chmod 644 "$rc_file" 2>/dev/null || true
    done

    return 0
}

# 创建用户
create_user() {
    local username="$1"
    local password="$2"
    local home="$3"
    local install_miniforge="${4:-false}"

    # 参数验证
    [[ -z "$username" ]] && { msg_err "用户名不能为空"; return 1; }
    [[ -z "$password" ]] && { msg_err "密码不能为空"; return 1; }
    [[ -z "$home" ]] && { msg_err "主目录不能为空"; return 1; }
    
    # 路径安全验证
    if declare -f validate_path_safety &>/dev/null; then
        validate_path_safety "$home" || { msg_err "主目录路径不安全: $home"; return 1; }
    fi

    priv_useradd -d "$home" -s /bin/bash -m "$username" || return 1
    echo "$username:$password" | priv_chpasswd || return 1
    priv_cp -r /etc/skel/. "$home/" 2>/dev/null || true
    priv_deluser "$username" sudo 2>/dev/null || true
    priv_deluser "$username" adm 2>/dev/null || true
    ensure_user_proxy_function "$username" "$home" || return 1

    # 启用 Mamba/Conda 配置（如果请求）
    if [[ "$install_miniforge" == "true" ]]; then
        # 加载 miniforge_core.sh 模块
        if [[ -f "${SCRIPT_DIR}/lib/miniforge_core.sh" ]]; then
            # shellcheck source=lib/miniforge_core.sh
            source "${SCRIPT_DIR}/lib/miniforge_core.sh"
            install_miniforge_for_user "$username" "$MINIFORGE_DEFAULT_PATH" || {
                msg_warn "Mamba/Conda 配置未完成，但用户已创建"
            }
        else
            msg_warn "Miniforge 模块未找到，跳过 Mamba/Conda 配置"
        fi
    fi

    return 0
}

# 更新用户
update_user() {
    local username="$1"
    local password="$2"
    local home="$3"

    # 参数验证
    [[ -z "$username" ]] && { msg_err "用户名不能为空"; return 1; }
    [[ -z "$password" ]] && { msg_err "密码不能为空"; return 1; }
    
    # 路径安全验证（如果提供了 home）
    if [[ -n "$home" ]] && declare -f validate_path_safety &>/dev/null; then
        validate_path_safety "$home" || { msg_err "主目录路径不安全: $home"; return 1; }
    fi

    echo "$username:$password" | priv_chpasswd || return 1
    priv_deluser "$username" sudo 2>/dev/null || true
    priv_deluser "$username" adm 2>/dev/null || true

    local current_home
    current_home=$(get_user_home "$username")

    if [[ -n "$home" && "$current_home" != "$home" ]]; then
        priv_usermod -d "$home" "$username" || return 1
        if [[ -n "$current_home" && -d "$current_home" ]]; then
            priv_mv "$current_home" "$home" 2>/dev/null || true
        else
            priv_mkdir -p "$home"
            priv_cp -r /etc/skel/. "$home/" 2>/dev/null || true
        fi
        priv_chown -R "$username:$username" "$home" 2>/dev/null
    fi

    ensure_user_proxy_function "$username" "${home:-$current_home}" || return 1

    return 0
}

# 删除用户
delete_user() {
    local username="$1"
    
    # 参数验证
    [[ -z "$username" ]] && { msg_err "用户名不能为空"; return 1; }
    
    # 清理 Miniforge/Mamba 配置（如果存在）
    if [[ -f "${SCRIPT_DIR}/lib/miniforge_core.sh" ]]; then
        # shellcheck source=lib/miniforge_core.sh
        source "${SCRIPT_DIR}/lib/miniforge_core.sh"
        if has_miniforge_installed "$username"; then
            msg_step "清理用户 Miniforge..."
            uninstall_miniforge_for_user "$username" || true
        fi
    fi
    
    priv_userdel -r "$username" 2>/dev/null
    return $?
}

# ============================================================
# 暂停账户管理
# ============================================================

_um_disabled_sanitize_field() {
    local value="${1:-}"
    value="${value//$'\r'/ }"
    value="${value//$'\n'/ }"
    value="${value//$'\t'/ }"
    value="${value//,/ }"
    printf '%s' "$value"
}

_um_user_passwd_entry() {
    local username="$1"
    getent passwd "$username" 2>/dev/null || return 1
}

_um_user_uid() {
    local username="$1"
    _um_user_passwd_entry "$username" | cut -d: -f3
}

_um_user_shell() {
    local username="$1"
    _um_user_passwd_entry "$username" | cut -d: -f7
}

_um_nologin_shell() {
    if [[ -x /usr/sbin/nologin || ! -e /sbin/nologin ]]; then
        printf '/usr/sbin/nologin'
    else
        printf '/sbin/nologin'
    fi
}

is_user_disabled() {
    local username="$1"
    [[ -n "$username" && -f "$DISABLED_USERS_FILE" ]] || return 1
    grep -F -q -- "${username}"$'\t' "$DISABLED_USERS_FILE"
}

_um_write_disabled_records() {
    local content_file="$1"
    local target_dir
    target_dir="$(dirname "$DISABLED_USERS_FILE")"
    mkdir -p "$target_dir" || return 1
    local tmp_file
    tmp_file="${DISABLED_USERS_FILE}.tmp.$$"
    cp "$content_file" "$tmp_file" || return 1
    chmod 0600 "$tmp_file" 2>/dev/null || true
    mv "$tmp_file" "$DISABLED_USERS_FILE"
}

_um_append_disabled_record() {
    local username="$1" reason="$2" expiry_date="$3" original_shell="$4" original_lock_state="${5:-active}" mode="${6:-disable}"
    local temp_records
    temp_records="$(mktemp)" || return 1
    if [[ -f "$DISABLED_USERS_FILE" ]]; then
        grep -F -v -- "${username}"$'\t' "$DISABLED_USERS_FILE" > "$temp_records" || true
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(_um_disabled_sanitize_field "$username")" \
        "$(_um_disabled_sanitize_field "$reason")" \
        "$(date +%Y-%m-%d)" \
        "$(_um_disabled_sanitize_field "${expiry_date:-permanent}")" \
        "$(_um_disabled_sanitize_field "$original_shell")" \
        "$(_um_disabled_sanitize_field "$original_lock_state")" \
        "$(_um_disabled_sanitize_field "$mode")" >> "$temp_records"
    _um_write_disabled_records "$temp_records"
    local rc=$?
    rm -f "$temp_records"
    return $rc
}

_um_get_disabled_record() {
    local username="$1"
    [[ -f "$DISABLED_USERS_FILE" ]] || return 1
    grep -F -- "${username}"$'\t' "$DISABLED_USERS_FILE" | tail -n 1
}

_um_remove_disabled_record() {
    local username="$1"
    [[ -f "$DISABLED_USERS_FILE" ]] || return 0
    local temp_records
    temp_records="$(mktemp)" || return 1
    grep -F -v -- "${username}"$'\t' "$DISABLED_USERS_FILE" > "$temp_records" || true
    _um_write_disabled_records "$temp_records"
    local rc=$?
    rm -f "$temp_records"
    return $rc
}

_um_send_account_state_notice() {
    local event="$1" username="$2" reason="${3:-}" expiry_date="${4:-permanent}"
    declare -F get_user_email >/dev/null 2>&1 || return 0
    local email
    email=$(get_user_email "$username" 2>/dev/null || true)
    [[ -n "$email" ]] || return 0
    case "$event" in
        suspend)
            declare -F send_account_suspended_email >/dev/null 2>&1 && \
                send_account_suspended_email "$username" "$email" "$reason" "$expiry_date" "system" >/dev/null 2>&1 || true
            ;;
        disable)
            declare -F send_account_disabled_email >/dev/null 2>&1 && \
                send_account_disabled_email "$username" "$email" "$reason" "$expiry_date" "system" >/dev/null 2>&1 || true
            ;;
        restore)
            declare -F send_account_restored_email >/dev/null 2>&1 && \
                send_account_restored_email "$username" "$email" "system" >/dev/null 2>&1 || true
            ;;
    esac
}

disable_user_account() {
    local username="$1"
    local reason="${2:-无}"
    local expiry_date="${3:-permanent}"
    local mode="${4:-disable}"

    [[ -n "$username" ]] || { msg_err "用户名不能为空"; return 1; }
    validate_username "$username" >/dev/null 2>&1 || return 1
    [[ "$username" != "root" ]] || { msg_err "禁止禁用 root 用户"; return 1; }
    [[ "$username" != "${USER:-}" ]] || { msg_err "禁止禁用当前执行用户"; return 1; }
    id "$username" >/dev/null 2>&1 || { msg_err "用户不存在: $username"; return 1; }

    local uid original_shell
    uid="$(_um_user_uid "$username")" || return 1
    [[ "$uid" =~ ^[0-9]+$ ]] || return 1
    (( uid >= 1000 )) || { msg_err "禁止禁用系统用户: $username"; return 1; }

    if is_user_disabled "$username"; then
        msg_info "用户 $username 已处于停用状态"
        return 0
    fi

    original_shell="$(_um_user_shell "$username")" || return 1
    [[ -n "$original_shell" ]] || original_shell="/bin/bash"

    local nologin_shell
    nologin_shell="$(_um_nologin_shell)"

    priv_usermod -L "$username" || return 1
    priv_chage -E 0 "$username" || return 1
    priv_usermod -s "$nologin_shell" "$username" || return 1
    _um_append_disabled_record "$username" "$reason" "${expiry_date:-permanent}" "$original_shell" "active" "$mode" || return 1
    if [[ "$mode" == "suspend" ]]; then
        _um_send_account_state_notice suspend "$username" "$(_um_disabled_sanitize_field "$reason")" "${expiry_date:-permanent}"
    else
        _um_send_account_state_notice disable "$username" "$(_um_disabled_sanitize_field "$reason")" "${expiry_date:-permanent}"
    fi
    record_user_event "$username" "disable" "$(_um_disabled_sanitize_field "$reason") (到期:${expiry_date:-permanent})" 2>/dev/null || true
}

enable_user_account() {
    local username="$1"
    [[ -n "$username" ]] || { msg_err "用户名不能为空"; return 1; }

    local record original_shell
    record="$(_um_get_disabled_record "$username")" || return 0
    IFS=$'\t' read -r _ _ _ _ original_shell _ _ <<< "$record"
    [[ -n "$original_shell" ]] || original_shell="/bin/bash"

    priv_usermod -U "$username" || return 1
    priv_chage -E -1 "$username" || return 1
    priv_usermod -s "$original_shell" "$username" || return 1
    _um_remove_disabled_record "$username" || return 1
    _um_send_account_state_notice restore "$username"
    record_user_event "$username" "enable" "恢复停用账户" 2>/dev/null || true
}

# 检查过期的暂停账户
check_expired_suspensions() {
    [[ ! -f "$DISABLED_USERS_FILE" ]] && return 0

    local today_epoch
    today_epoch=$(date +%s)

    local expired_users=()
    local username expiry_date expiry_epoch line

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        if [[ "$line" == *$'\t'* ]]; then
            IFS=$'\t' read -r username _ _ expiry_date _ _ _ <<< "$line"
        else
            IFS=, read -r username _ _ expiry_date <<< "$line"
        fi
        [[ -z "$username" ]] && continue

        if [[ -z "$expiry_date" || "$expiry_date" == "permanent" ]]; then
            continue
        fi

        if ! expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null); then
            expiry_epoch=$(date -j -f '%Y-%m-%d' "$expiry_date" +%s 2>/dev/null || echo "")
        fi

        [[ -z "$expiry_epoch" ]] && continue

        if (( today_epoch >= expiry_epoch )); then
            if id "$username" &>/dev/null; then
                enable_user_account "$username" || continue
                expired_users+=("$username")
            fi
        fi
    done < "$DISABLED_USERS_FILE"

    if (( ${#expired_users[@]} > 0 )); then
        for username in "${expired_users[@]}"; do
            remove_file_entry "$DISABLED_USERS_FILE" "^${username},"
        done
        msg_info "已自动启用 ${#expired_users[@]} 个过期暂停账户: ${expired_users[*]}"
    fi
}

# ============================================================
# 作业统计功能
# ============================================================

# 收集指定用户的当前进程数
collect_user_jobs() {
    local username="$1"

    if [[ -z "$username" ]]; then
        msg_err "collect_user_jobs: 缺少用户名参数"
        return 1
    fi

    if ! id "$username" &>/dev/null; then
        echo "0"
        return 1
    fi

    local count
    count=$(ps -u "$username" --no-headers 2>/dev/null | wc -l)
    echo "${count:-0}"
}

# 记录用户的作业统计到 CSV 文件
# 格式: timestamp,process_count
record_job_stats() {
    local username="$1"

    if [[ -z "$username" ]]; then
        msg_err "record_job_stats: 缺少用户名参数"
        return 1
    fi

    mkdir -p "$JOB_STATS_DIR"

    local stats_file="$JOB_STATS_DIR/${username}.csv"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # 如果文件不存在，写入表头
    if [[ ! -f "$stats_file" ]]; then
        echo "timestamp,process_count" > "$stats_file"
    fi

    local process_count
    process_count=$(collect_user_jobs "$username")

    printf '%s,%s\n' "$timestamp" "$process_count" >> "$stats_file"
}

# 获取最近 7 天的作业统计摘要
get_weekly_job_stats() {
    local username="$1"

    if [[ -z "$username" ]]; then
        msg_err "get_weekly_job_stats: 缺少用户名参数"
        return 1
    fi

    local stats_file="$JOB_STATS_DIR/${username}.csv"

    if [[ ! -f "$stats_file" ]]; then
        msg_warn "用户 $username 无作业统计数据"
        return 1
    fi

    local cutoff
    cutoff=$(date -d '7 days ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
    if [[ -z "$cutoff" ]]; then
        cutoff=$(date -v-7d '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
    fi

    # Skip header, filter records within the last 7 days, compute summary
    awk -F',' -v cutoff="$cutoff" '
    NR == 1 { next }
    $1 >= cutoff {
        count++
        sum += $2
        if ($2 > max) max = $2
        if (min == "" || $2 < min) min = $2
    }
    END {
        if (count == 0) {
            print "records=0,avg=0,max=0,min=0"
        } else {
            printf "records=%d,avg=%.1f,max=%d,min=%d\n", count, sum/count, max, min
        }
    }' "$stats_file"
}

# 获取最近 30 天的作业统计摘要
get_monthly_job_stats() {
    local username="$1"

    if [[ -z "$username" ]]; then
        msg_err "get_monthly_job_stats: 缺少用户名参数"
        return 1
    fi

    local stats_file="$JOB_STATS_DIR/${username}.csv"

    if [[ ! -f "$stats_file" ]]; then
        msg_warn "用户 $username 无作业统计数据"
        return 1
    fi

    local cutoff
    cutoff=$(date -d '30 days ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
    if [[ -z "$cutoff" ]]; then
        cutoff=$(date -v-30d '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
    fi

    # Skip header, filter records within the last 30 days, compute summary
    awk -F',' -v cutoff="$cutoff" '
    NR == 1 { next }
    $1 >= cutoff {
        count++
        sum += $2
        if ($2 > max) max = $2
        if (min == "" || $2 < min) min = $2
    }
    END {
        if (count == 0) {
            print "records=0,avg=0,max=0,min=0"
        } else {
            printf "records=%d,avg=%.1f,max=%d,min=%d\n", count, sum/count, max, min
        }
    }' "$stats_file"
}

# 收集所有托管用户的作业统计
collect_all_job_stats() {
    mkdir -p "$JOB_STATS_DIR"

    local usernames=()
    mapfile -t usernames < <(get_managed_usernames)

    if (( ${#usernames[@]} == 0 )); then
        msg_warn "未找到托管用户，跳过作业统计收集"
        return 0
    fi

    msg_info "正在收集 ${#usernames[@]} 个用户的作业统计..."

    local recorded=0
    for username in "${usernames[@]}"; do
        record_job_stats "$username"
        ((recorded+=1))
    done

    msg_ok "已完成 ${recorded} 个用户的作业统计记录"
}

# ============================================================
# 定时密码轮换功能
# ============================================================

# 配置定时密码轮换
# ============================================================
# configure_password_rotation - 配置定时密码轮换
# ============================================================
# Parameters:
#   $1 - interval_days: 轮换间隔天数（可选，默认使用配置值）
# Returns:
#   0 on success, 1 on failure
# ============================================================
configure_password_rotation() {
    local interval_days="${1:-$PASSWORD_ROTATE_INTERVAL_DAYS}"

    # 参数验证
    require_param "interval_days" "$interval_days" || return 1
    if ! is_positive_int "$interval_days"; then
        msg_err "轮换间隔必须是正整数（天），当前值: ${interval_days:-<空>}"
        return 1
    fi

    local script_path="/usr/local/bin/password_rotate.sh"
    local abs_script_dir="$SCRIPT_DIR"

    draw_header "配置定时密码轮换"
    draw_info_card "轮换间隔:" "每 ${interval_days} 天"
    draw_info_card "脚本路径:" "$script_path"
    echo ""

    msg_step "创建密码轮换脚本..."

    local script_content
    script_content=$(cat << GENEOF
#!/bin/bash
# 自动密码轮换脚本
# 由用户管理系统生成于 $(date '+%Y-%m-%d %H:%M:%S')
# 间隔: ${interval_days} 天

set -euo pipefail

export SUDO_NONINTERACTIVE=1

MANAGER_DIR="$abs_script_dir"
# shellcheck disable=SC1091
source "\$MANAGER_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "\$MANAGER_DIR/lib/config.sh"
# shellcheck disable=SC1091
source "\$MANAGER_DIR/lib/access_control.sh"
# shellcheck disable=SC1091
source "\$MANAGER_DIR/lib/privilege.sh"
# shellcheck disable=SC1091
source "\$MANAGER_DIR/lib/user_core.sh"
# shellcheck disable=SC1091
source "\$MANAGER_DIR/lib/email_core.sh"
# shellcheck disable=SC1091
source "\$MANAGER_DIR/lib/quota_core.sh"

LOG_FILE="\${PASSWORD_ROTATE_LOG:-\$MANAGER_DIR/logs/password_rotate.log}"
USER_CONFIG_FILE="\${USER_CONFIG_FILE:-\$MANAGER_DIR/data/user_config.json}"
EMAIL_CONFIG_FILE="\${EMAIL_CONFIG_FILE:-\$MANAGER_DIR/data/email_config.json}"
DATA_BASE="\${DATA_BASE:-/mnt}"

mkdir -p "\$(dirname "\$LOG_FILE")"

log_msg() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$*" >> "\$LOG_FILE"; }

log_msg "=== 开始定时密码轮换 ==="

# 获取托管用户列表（复用 get_managed_usernames）
MANAGED_USERS=()
mapfile -t MANAGED_USERS < <(get_managed_usernames)

if [[ \${#MANAGED_USERS[@]} -eq 0 ]]; then
    log_msg "未找到托管用户，退出"
    exit 0
fi

log_msg "待轮换用户数: \${#MANAGED_USERS[@]}"

SUCCESS=0
FAILED=0

for username in "\${MANAGED_USERS[@]}"; do
    # 随机密码（复用密码池生成、latest 与 .used 追踪逻辑）
    NEW_PASS=\$(get_random_password 2>/dev/null || true)

    if [[ -z "\$NEW_PASS" ]]; then
        log_msg "错误: 无法获取密码 (\$username)"
        ((FAILED+=1))
        continue
    fi

    # 修改密码
    if echo "\$username:\$NEW_PASS" | priv_chpasswd 2>/dev/null; then
        log_msg "成功: \$username 密码已更新"
        ((SUCCESS+=1))

        # 尝试发送邮件通知（复用邮件模块，避免内联邮件头拼接）
        EMAIL=\$(get_user_email "\$username" 2>/dev/null || true)
        if [[ -n "\$EMAIL" ]]; then
            if send_password_email "\$username" "\$NEW_PASS" "\$EMAIL" "定时密码更新" 2>/dev/null; then
                log_msg "邮件已发送: \$username -> \$EMAIL"
            else
                log_msg "邮件发送失败: \$username -> \$EMAIL"
            fi
        fi
    else
        log_msg "失败: \$username 密码更新失败"
        ((FAILED+=1))
    fi
done

log_msg "=== 轮换完成: 成功 \$SUCCESS, 失败 \$FAILED ==="

# 日志轮转
if [[ -f "\$LOG_FILE" ]]; then
    LOG_SIZE=\$(stat -c%s "\$LOG_FILE" 2>/dev/null || echo 0)
    if [[ "\$LOG_SIZE" -gt 10485760 ]]; then
        mv "\$LOG_FILE" "\$LOG_FILE.\$(date +%Y%m%d)"
        touch "\$LOG_FILE"
        log_msg "日志已轮转"
    fi
fi
GENEOF
)

    if printf '%s' "$script_content" | write_privileged_text_file "$script_path" "0755" "root:root"; then
        priv_chmod +x "$script_path"
        msg_ok "轮换脚本创建成功"
    else
        msg_err "创建轮换脚本失败"
        return 1
    fi

    # 配置 cron（每 N 天的凌晨 3 点执行）
    msg_step "配置定时任务..."
    local cron_line="0 3 */${interval_days} * * $script_path"

    # 移除旧任务
    rewrite_root_crontab_without_literal "$script_path" >/dev/null 2>&1 || true
    if append_root_crontab_line "$cron_line"; then
        echo ""
        msg_ok "定时密码轮换已配置"
        draw_info_card "执行频率:" "每 ${interval_days} 天，凌晨 3:00"
        draw_info_card "脚本路径:" "$script_path"
        draw_info_card "日志位置:" "${LOG_DIR:-/var/log/user_manager}/password_rotate.log"
        record_user_event "system" "password_rotate" "配置定时密码轮换: 每${interval_days}天"
        return 0
    else
        msg_err "定时任务配置失败"
        return 1
    fi
}

# 移除定时密码轮换
remove_password_rotation() {
    local script_path="/usr/local/bin/password_rotate.sh"

    draw_header "移除定时密码轮换"

    # 从 crontab 移除
    rewrite_root_crontab_without_literal "$script_path" >/dev/null 2>&1 || true

    # 删除脚本
    if [[ -f "$script_path" ]]; then
        priv_rm -f "$script_path"
        msg_ok "已删除轮换脚本"
    fi

    msg_ok "定时密码轮换已移除"
    record_user_event "system" "password_rotate_remove" "移除定时密码轮换"
}

# 查看密码轮换状态
show_password_rotation_status() {
    draw_header "密码轮换状态"

    local script_path="/usr/local/bin/password_rotate.sh"

    if [[ -f "$script_path" ]]; then
        draw_info_card "脚本:" "${C_BGREEN}已创建${C_RESET}"
    else
        draw_info_card "脚本:" "${C_DIM}未配置${C_RESET}"
    fi

    # 检查 crontab
    local cron_line
    cron_line=$(find_root_crontab_line "$script_path")

    if [[ -n "$cron_line" ]]; then
        draw_info_card "定时任务:" "${C_BGREEN}已启用${C_RESET}"
        draw_info_card "计划:" "$cron_line"
    else
        draw_info_card "定时任务:" "${C_DIM}未配置${C_RESET}"
    fi

    # 显示最近的轮换日志
    local log_file="${LOG_DIR:-/var/log/user_manager}/password_rotate.log"
    if [[ -f "$log_file" ]]; then
        echo ""
        msg_info "${C_BOLD}最近轮换日志:${C_RESET}"
        draw_line 60
        tail -10 "$log_file" | while IFS= read -r line; do
            echo "  ${C_DIM}$line${C_RESET}"
        done
    fi

    echo ""
}

# 手动执行一次密码轮换
# ============================================================
# manual_password_rotation - 手动执行一次密码轮换
# ============================================================
# 无参数函数，为所有托管用户立即轮换密码
# Returns: 0 成功（即使部分失败）
# ============================================================
manual_password_rotation() {
    # 防御性检查：确保密码生成和用户管理函数可用
    if ! declare -F get_random_password &>/dev/null; then
        msg_err_ctx "manual_password_rotation" "get_random_password 函数不可用"
        return 1
    fi
    if ! declare -F get_managed_usernames &>/dev/null; then
        msg_err_ctx "manual_password_rotation" "get_managed_usernames 函数不可用"
        return 1
    fi

    draw_header "手动密码轮换"

    local managed_users=()
    mapfile -t managed_users < <(get_managed_usernames)

    if (( ${#managed_users[@]} == 0 )); then
        msg_warn "没有托管用户"
        return 0
    fi

    msg_info "将为 ${C_BOLD}${#managed_users[@]}${C_RESET} 个用户轮换密码"
    msg_warn "此操作将立即修改所有用户的密码！"

    if ! confirm_action "确认执行？"; then
        msg_info "操作已取消"
        return 0
    fi

    local success=0 failed=0
    local -a results=()
    local log_file="${LOG_DIR:-$SCRIPT_DIR/logs}/password_rotate.log"
    mkdir -p "$(dirname "$log_file")"

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] === 手动密码轮换开始 ===" >> "$log_file"

    for username in "${managed_users[@]}"; do
        local newpass
        newpass=$(get_random_password)
        if [[ -z "$newpass" ]]; then
            msg_err "  $username: 无法获取密码"
            ((failed+=1))
            continue
        fi

        if echo "$username:$newpass" | priv_chpasswd 2>/dev/null; then
            msg_ok "  $username: 密码已更新"
            results+=("$username:$newpass")
            ((success+=1))

            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 成功: $username" >> "$log_file"

            # 发送邮件
            local email
            email=$(get_user_email "$username")
            if [[ -n "$email" ]]; then
                send_password_email "$username" "$newpass" "$email" "定时密码更新" 2>/dev/null || true
            fi

            record_user_event "$username" "password_rotate" "手动密码轮换"
        else
            msg_err "  $username: 更新失败"
            ((failed+=1))
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 失败: $username" >> "$log_file"
        fi
    done

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] === 轮换完成: 成功 $success, 失败 $failed ===" >> "$log_file"

    echo ""
    draw_header "轮换完成"
    draw_info_card "成功:" "${C_BGREEN}$success${C_RESET}"
    if [[ $failed -gt 0 ]]; then
        draw_info_card "失败:" "${C_BRED}$failed${C_RESET}"
    fi

    if (( ${#results[@]} > 0 )); then
        echo ""
        msg_info "新密码清单:"
        printf "  ${C_DIM}%-18s %s${C_RESET}\n" "用户名" "新密码"
        draw_line 40
        for entry in "${results[@]}"; do
            local u="${entry%%:*}"
            local p="${entry#*:}"
            printf "  ${C_BOLD}%-18s${C_RESET} ${C_BGREEN}%s${C_RESET}\n" "$u" "$p"
        done
    fi

    echo ""
}
