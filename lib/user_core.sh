#!/bin/bash
# user_core.sh - 用户管理核心模块 v6.0
# 提供用户 CRUD 操作、密码管理、暂停功能、作业统计

# ============================================================
# 密码池管理
# ============================================================

# 生成密码池（8568个8位密码）
# 格式：3位连续大写(ASDFGHJKL) + 1位小写 + 3位连续数字 + 1位特殊字符
generate_password_pool() {
    local pool_file="${1:-$PASSWORD_POOL_FILE}"

    mkdir -p "$(dirname "$pool_file")"

    if [[ -f "$pool_file" ]] && [[ $(wc -l < "$pool_file") -ge 8568 ]]; then
        msg_info "密码池已存在（$(wc -l < "$pool_file") 个密码）"
        return 0
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
        # Positions 1-3: 3 consecutive chars from ASDFGHJKL (7 combos)
        for (( i = 0; i <= ${#upper_row} - 3; i++ )); do
            local tri="${upper_row:i:3}"
            # Position 4: one char from lower_chars (17 chars)
            for (( j = 0; j < ${#lower_chars}; j++ )); do
                local lc="${lower_chars:j:1}"
                # Positions 5-7: 3 consecutive digits from digit_row (8 combos)
                for (( k = 0; k <= ${#digit_row} - 3; k++ )); do
                    local dig="${digit_row:k:3}"
                    # Position 8: one special char (9 chars)
                    for (( m = 0; m < ${#specials}; m++ )); do
                        echo "${tri}${lc}${dig}${specials:m:1}"
                    done
                done
            done
        done
    } > "$tmp_file"

    # Shuffle and write to pool file
    if ! shuf "$tmp_file" > "$pool_file"; then
        rm -f "$tmp_file"
        umask "$old_umask"
        msg_err "密码池生成失败"
        return 1
    fi
    rm -f "$tmp_file"
    chmod 600 "$pool_file" 2>/dev/null || true
    umask "$old_umask"

    local count
    count=$(wc -l < "$pool_file")
    msg_ok "密码池已生成：$pool_file（${count} 个密码）"
}

# 从密码池中获取一个随机密码
get_random_password() {
    if [[ ! -f "$PASSWORD_POOL_FILE" ]] || [[ $(wc -l < "$PASSWORD_POOL_FILE" 2>/dev/null) -lt 1 ]]; then
        generate_password_pool "$PASSWORD_POOL_FILE"
    fi

    local total_passwords
    total_passwords=$(wc -l < "$PASSWORD_POOL_FILE")

    local random_line
    random_line=$(shuf -i 1-"$total_passwords" -n 1)
    sed -n "${random_line}p" "$PASSWORD_POOL_FILE"
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
    run_privileged cp -r /etc/skel/. "$home/" 2>/dev/null || true
    priv_deluser "$username" sudo 2>/dev/null || true
    priv_deluser "$username" adm 2>/dev/null || true

    # 安装 Miniforge（如果请求）
    if [[ "$install_miniforge" == "true" ]]; then
        # 加载 miniforge_core.sh 模块
        if [[ -f "${SCRIPT_DIR}/lib/miniforge_core.sh" ]]; then
            # shellcheck source=lib/miniforge_core.sh
            source "${SCRIPT_DIR}/lib/miniforge_core.sh"
            install_miniforge_for_user "$username" "$MINIFORGE_DEFAULT_PATH" || {
                msg_warn "Miniforge 安装失败，但用户已创建"
            }
        else
            msg_warn "Miniforge 模块未找到，跳过安装"
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
            run_privileged cp -r /etc/skel/. "$home/" 2>/dev/null || true
        fi
        priv_chown -R "$username:$username" "$home" 2>/dev/null
    fi

    return 0
}

# 删除用户
delete_user() {
    local username="$1"
    
    # 参数验证
    [[ -z "$username" ]] && { msg_err "用户名不能为空"; return 1; }
    
    # 清理 Miniforge（如果已安装）
    if [[ -f "${SCRIPT_DIR}/lib/miniforge_core.sh" ]]; then
        # shellcheck source=lib/miniforge_core.sh
        source "${SCRIPT_DIR}/lib/miniforge_core.sh"
        if has_miniforge_installed "$username"; then
            msg_step "清理用户 Miniforge..."
            uninstall_miniforge_for_user "$username" || true
        fi
    fi
    
    run_privileged userdel -r "$username" 2>/dev/null
    return $?
}

# ============================================================
# 暂停账户管理
# ============================================================

# 检查过期的暂停账户
check_expired_suspensions() {
    [[ ! -f "$DISABLED_USERS_FILE" ]] && return 0

    local today_epoch
    today_epoch=$(date +%s)

    local expired_users=()
    local username expiry_date expiry_epoch

    while IFS=, read -r username _ _ expiry_date; do
        [[ -z "$username" ]] && continue

        if [[ -z "$expiry_date" || "$expiry_date" == "permanent" ]]; then
            continue
        fi

        if ! expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null); then
            expiry_epoch=$(date -j -f '%Y-%m-%d' "$expiry_date" +%s 2>/dev/null || echo "")
        fi

        [[ -z "$expiry_epoch" ]] && continue

        if (( today_epoch >= expiry_epoch )); then
            if id "$username" &>/dev/null && passwd -S "$username" 2>/dev/null | grep -q "LK"; then
                priv_usermod -U "$username" || continue
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
source "\$MANAGER_DIR/lib/quota_core.sh"

LOG_FILE="\${PASSWORD_ROTATE_LOG:-\$MANAGER_DIR/logs/password_rotate.log}"
PASSWORD_POOL_FILE="\${PASSWORD_POOL_FILE:-\$MANAGER_DIR/data/password_pool.txt}"
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

# 密码池
if [[ ! -f "\$PASSWORD_POOL_FILE" ]] || [[ \$(wc -l < "\$PASSWORD_POOL_FILE") -lt 1 ]]; then
    log_msg "错误: 密码池为空或不存在"
    exit 1
fi

TOTAL_PASSWORDS=\$(wc -l < "\$PASSWORD_POOL_FILE")
SUCCESS=0
FAILED=0

for username in "\${MANAGED_USERS[@]}"; do
    # 随机密码
    RAND_LINE=\$(( RANDOM % TOTAL_PASSWORDS + 1 ))
    NEW_PASS=\$(sed -n "\${RAND_LINE}p" "\$PASSWORD_POOL_FILE")

    if [[ -z "\$NEW_PASS" ]]; then
        log_msg "错误: 无法获取密码 (\$username)"
        ((FAILED+=1))
        continue
    fi

    # 修改密码
    if echo "\$username:\$NEW_PASS" | chpasswd 2>/dev/null; then
        log_msg "成功: \$username 密码已更新"
        ((SUCCESS+=1))

        # 尝试发送邮件通知
        if command -v jq &>/dev/null && [[ -f "\$USER_CONFIG_FILE" ]]; then
            EMAIL=\$(jq -r --arg u "\$username" '.[\$u].email // empty' "\$USER_CONFIG_FILE" 2>/dev/null)
            if [[ -n "\$EMAIL" ]]; then
                FROM_NAME="用户管理系统"
                FROM_ADDR="noreply@example.com"
                if [[ -f "\$EMAIL_CONFIG_FILE" ]]; then
                    FROM_NAME=\$(jq -r '.from_name // "用户管理系统"' "\$EMAIL_CONFIG_FILE" 2>/dev/null)
                    FROM_ADDR=\$(jq -r '.from_address // "noreply@example.com"' "\$EMAIL_CONFIG_FILE" 2>/dev/null)
                fi

                SUBJECT="【重要】定时密码更新通知 - \$username"
                {
                    echo "From: \$FROM_NAME <\$FROM_ADDR>"
                    echo "To: \$EMAIL"
                    echo "Subject: \$SUBJECT"
                    echo "MIME-Version: 1.0"
                    echo "Content-Type: text/html; charset=UTF-8"
                    echo ""
                    echo "<html><body style='font-family:Inter,-apple-system,sans-serif;padding:20px'>"
                    echo "<h2 style='color:#2563eb'>密码更新通知</h2>"
                    echo "<p>尊敬的 <strong>\$username</strong>，您好！</p>"
                    echo "<p>您的密码已于 \$(date '+%Y-%m-%d %H:%M:%S') 自动更新。</p>"
                    echo "<table style='border:1px solid #e2e8f0;border-radius:8px;padding:16px;background:#f8fafc'>"
                    echo "<tr><td style='color:#6b7280'>用户名</td><td style='font-weight:600'>\$username</td></tr>"
                    echo "<tr><td style='color:#6b7280'>新密码</td><td style='color:#2563eb;font-weight:600;font-family:monospace'>\$NEW_PASS</td></tr>"
                    echo "</table>"
                    echo "<p style='color:#92400e;background:#fffbeb;padding:12px;border-left:3px solid #f59e0b;margin-top:16px'>请妥善保管新密码。如非本人操作，请联系管理员。</p>"
                    echo "</body></html>"
                } | timeout 30 sendmail -t 2>/dev/null && \
                    log_msg "邮件已发送: \$username -> \$EMAIL" || \
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

    if echo "$script_content" | run_privileged tee "$script_path" > /dev/null; then
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
    run_privileged crontab -l 2>/dev/null | grep -v "$script_path" | run_privileged crontab - 2>/dev/null || true
    if ( run_privileged crontab -l 2>/dev/null; echo "$cron_line" ) | run_privileged crontab -; then
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
    run_privileged crontab -l 2>/dev/null | grep -v "$script_path" | run_privileged crontab - 2>/dev/null || true

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
    cron_line=$(run_privileged crontab -l 2>/dev/null | grep "$script_path" || true)

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
