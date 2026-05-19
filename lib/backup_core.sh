#!/bin/bash
# backup_core.sh - 备份管理核心模块 v5.0
# 提供用户数据备份、恢复、定时任务管理、批量备份功能
# 改进：安全的 rsync 参数构建（无 eval）、修复并行备份路径、彩色输出

# === 加载统一排除模块 ===
# shellcheck disable=SC1091
source "$LIB_DIR/backup_excludes.sh"

# ============================================================
#  1. show_backup_status  —— 显示用户备份历史
# ============================================================
show_backup_status() {
    local username="$1"

    if [[ -z "$username" ]]; then
        msg_err "用户名不能为空"
        return 1
    fi

    local user_backup_dir="$BACKUP_ROOT/$username"

    draw_header "备份状态 — $username"

    if [[ ! -d "$user_backup_dir" ]]; then
        msg_info "用户 ${C_BOLD}$username${C_RESET} 没有备份记录"
        return 0
    fi

    draw_info_card "备份目录:" "$user_backup_dir"
    echo ""

    # 表头
    printf "  ${C_DIM}%-28s %-22s %s${C_RESET}\n" "备份点" "时间" "大小"
    draw_line 60

    local backup_count=0
    while IFS= read -r -d '' backup_dir; do
        local bname
        bname=$(basename "$backup_dir")
        local btime
        btime=$(stat -c %y "$backup_dir" 2>/dev/null | cut -d'.' -f1)
        local bsize
        bsize=$(du -sh "$backup_dir" 2>/dev/null | cut -f1)

        # 根据类型上色
        local color="$C_RESET"
        [[ "$bname" == full_* ]]        && color="$C_BGREEN"
        [[ "$bname" == inc_* ]]         && color="$C_RESET"
        [[ "$bname" == pre_restore_* ]] && color="$C_RESET"

        printf "  ${color}%-28s${C_RESET} %-22s ${C_BOLD}%s${C_RESET}\n" "$bname" "$btime" "$bsize"
        ((backup_count+=1))
    done < <(find "$user_backup_dir" -maxdepth 1 -type d ! -path "$user_backup_dir" -print0 2>/dev/null | sort -z)

    echo ""
    if [[ $backup_count -eq 0 ]]; then
        msg_info "没有找到备份点"
    else
        msg_ok "共找到 ${C_BOLD}$backup_count${C_RESET} 个备份点"
    fi
}

# ============================================================
#  2. list_backup_users  —— 列出所有有备份的用户
# ============================================================
list_backup_users() {
    if [[ ! -d "$BACKUP_ROOT" ]]; then
        msg_info "备份目录不存在: $BACKUP_ROOT"
        return 0
    fi

    draw_header "已备份用户列表"

    printf "  ${C_DIM}%-24s %-10s %s${C_RESET}\n" "用户名" "备份数" "总大小"
    draw_line 50

    local user_count=0
    while IFS= read -r -d '' user_dir; do
        local uname
        uname=$(basename "$user_dir")
        # 跳过 batch 批次目录和 manual 目录
        [[ "$uname" == batch_* || "$uname" == "manual" ]] && continue

        local bcount
        bcount=$(find "$user_dir" -maxdepth 1 -type d ! -path "$user_dir" 2>/dev/null | wc -l)
        local tsize
        tsize=$(du -sh "$user_dir" 2>/dev/null | cut -f1)

        printf "  ${C_RESET}%-24s${C_RESET} ${C_BOLD}%-10d${C_RESET} ${C_BGREEN}%s${C_RESET}\n" \
            "$uname" "$bcount" "$tsize"
        ((user_count+=1))
    done < <(find "$BACKUP_ROOT" -maxdepth 1 -type d ! -path "$BACKUP_ROOT" -print0 2>/dev/null | sort -z)

    echo ""
    msg_ok "共 ${C_BOLD}$user_count${C_RESET} 个用户有备份"
}

# ============================================================
#  3. manual_backup_user  —— 手动备份用户数据
# ============================================================
manual_backup_user() {
    local username="$1"

    if [[ -z "$username" ]]; then
        msg_err "用户名不能为空"
        return 1
    fi

    if ! id "$username" &>/dev/null; then
        msg_err "用户 ${C_BOLD}$username${C_RESET} 不存在"
        return 1
    fi

    local user_home
    user_home=$(get_user_home "$username")
    if [[ -z "$user_home" || ! -d "$user_home" ]]; then
        msg_err "无法获取用户 ${C_BOLD}$username${C_RESET} 的主目录"
        return 1
    fi

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)

    # 查找最近一次备份用于增量（--link-dest）
    local last_backup=""
    local backup_type="full"
    if [[ -d "$BACKUP_ROOT/$username" ]]; then
        last_backup=$(find "$BACKUP_ROOT/$username" -maxdepth 1 -type d \
            \( -name 'inc_*' -o -name 'full_*' -o -name '2*' \) 2>/dev/null | sort -r | head -n1)
    fi
    if [[ -n "$last_backup" && -d "$last_backup" ]]; then
        backup_type="incremental"
    fi

    local backup_dir="$BACKUP_ROOT/$username/inc_${timestamp}"
    [[ "$backup_type" == "full" ]] && backup_dir="$BACKUP_ROOT/$username/full_${timestamp}"

    draw_header "手动备份 — $username"
    draw_info_card "源目录:" "$user_home"
    draw_info_card "备份到:" "$backup_dir"
    if [[ "$backup_type" == "incremental" ]]; then
        draw_info_card "备份类型:" "增量 (基于 $(basename "$last_backup"))" "$C_RESET"
    else
        draw_info_card "备份类型:" "全量 (首次备份)" "$C_RESET"
    fi
    echo ""

    # 创建备份目录
    if ! priv_mkdir -p "$backup_dir"; then
        msg_err "创建备份目录失败"
        return 1
    fi

    if ! command -v rsync &>/dev/null; then
        msg_warn "rsync 未安装，使用 cp 命令备份（速度较慢）"
        if priv_cp -a "$user_home" "$backup_dir"; then
            msg_ok "备份完成"
            record_user_event "$username" "backup" "手动${backup_type}备份到 $backup_dir"
            return 0
        else
            msg_err "cp 备份失败"
            priv_rm -rf "$backup_dir"
            return 1
        fi
    fi

    msg_step "使用 rsync 进行${backup_type}备份..."

    # 构建排除参数数组 —— 使用统一排除模块
    local -a rsync_args=( -av --delete )

    # 增量备份：使用 --link-dest 引用上次备份，仅传输差异
    if [[ "$backup_type" == "incremental" ]]; then
        rsync_args+=( --link-dest="$last_backup" )
    fi

    build_rsync_exclude_args rsync_args

    rsync_args+=( "$user_home/" "$backup_dir/" )

    local start_ts
    start_ts=$(date +%s)

    if priv_rsync "${rsync_args[@]}"; then
        local end_ts elapsed bsize
        end_ts=$(date +%s)
        elapsed=$((end_ts - start_ts))
        bsize=$(du -sh "$backup_dir" 2>/dev/null | cut -f1)

        echo ""
        msg_ok "备份完成"
        draw_info_card "备份类型:" "$backup_type"
        draw_info_card "备份大小:" "$bsize"
        draw_info_card "耗时:" "${elapsed}s"
        record_user_event "$username" "backup" "手动${backup_type}备份到 $backup_dir"
        # 自动生成校验和
        if declare -f auto_checksum_after_backup &>/dev/null; then
            auto_checksum_after_backup "$backup_dir" "$username"
        fi
        # 更新备份索引
        update_backup_index "$username" "$backup_type" "$backup_dir" "${last_backup:-}"
        return 0
    else
        msg_err "rsync 备份失败"
        priv_rm -rf "$backup_dir"
        return 1
    fi
}

# ============================================================
#  4. restore_user_backup  —— 恢复用户数据
# ============================================================
restore_user_backup() {
    local username="$1"
    local backup_name="$2"

    if [[ -z "$username" ]]; then
        msg_err "用户名不能为空"
        return 1
    fi

    local user_backup_dir="$BACKUP_ROOT/$username"

    if [[ ! -d "$user_backup_dir" ]]; then
        msg_err "用户 ${C_BOLD}$username${C_RESET} 没有备份记录"
        return 1
    fi

    # 如果未指定备份点，使用最新的
    local backup_dir
    if [[ -z "$backup_name" ]]; then
        backup_dir=$(find "$user_backup_dir" -maxdepth 1 -type d ! -path "$user_backup_dir" 2>/dev/null | sort -r | head -n1)
        if [[ -z "$backup_dir" ]]; then
            msg_err "没有找到可用的备份点"
            return 1
        fi
        backup_name=$(basename "$backup_dir")
    else
        backup_dir="$user_backup_dir/$backup_name"
        if [[ ! -d "$backup_dir" ]]; then
            msg_err "备份点不存在: ${C_BOLD}$backup_name${C_RESET}"
            return 1
        fi
    fi

    if ! id "$username" &>/dev/null; then
        msg_err "用户 ${C_BOLD}$username${C_RESET} 不存在，无法恢复"
        return 1
    fi

    local user_home
    user_home=$(get_user_home "$username")
    if [[ -z "$user_home" ]]; then
        msg_err "无法获取用户 ${C_BOLD}$username${C_RESET} 的主目录"
        return 1
    fi

    draw_header "恢复备份 — $username"
    draw_info_card "备份点:" "$backup_name"
    draw_info_card "备份目录:" "$backup_dir"
    draw_info_card "恢复到:" "$user_home"
    echo ""

    msg_warn "此操作将覆盖用户 ${C_BOLD}$username${C_RESET} 当前的所有数据！"
    echo ""

    if ! confirm_action "确认要恢复吗？"; then
        msg_info "已取消恢复操作"
        return 0
    fi

    # 恢复前先备份当前数据
    local pre_restore_backup
    pre_restore_backup="$BACKUP_ROOT/$username/pre_restore_$(date +%Y%m%d_%H%M%S)"
    msg_step "先备份当前数据到: $pre_restore_backup"
    priv_mkdir -p "$pre_restore_backup"
    priv_rsync -a "$user_home/" "$pre_restore_backup/" 2>/dev/null || true

    msg_step "开始恢复..."

    if priv_rsync -av --delete "$backup_dir/" "$user_home/"; then
        # 修正所有权
        local user_uid user_gid
        user_uid=$(id -u "$username")
        user_gid=$(id -g "$username")
        priv_chown -R "${user_uid}:${user_gid}" "$user_home"

        echo ""
        msg_ok "恢复完成"
        record_user_event "$username" "restore" "从 $backup_name 恢复"
        return 0
    else
        msg_err "恢复失败"
        return 1
    fi
}

# ============================================================
#  5. configure_backup_schedule  —— 配置定时备份
# ============================================================
configure_backup_schedule() {
    local username="$1"
    local backup_hour="$2"

    if [[ -z "$username" ]]; then
        msg_err "用户名不能为空"
        return 1
    fi

    if [[ -z "$backup_hour" ]]; then
        msg_err "备份小时不能为空"
        msg_info "示例: 输入 2 表示每天凌晨2点备份"
        return 1
    fi

    if ! [[ "$backup_hour" =~ ^[0-9]+$ ]] || (( backup_hour < 0 || backup_hour > 23 )); then
        msg_err "小时必须是 0-23 之间的数字"
        return 1
    fi

    if ! id "$username" &>/dev/null; then
        msg_err "用户 ${C_BOLD}$username${C_RESET} 不存在"
        return 1
    fi

    local user_home
    user_home=$(get_user_home "$username")

    local cron_expr="0 $backup_hour * * *"
    local script_dir_target="/usr/local/bin"
    local script_path="${script_dir_target}/backup_user_${username}.sh"

    # 将 SCRIPT_DIR 在此处展开为绝对路径嵌入脚本
    local abs_script_dir="$SCRIPT_DIR"

    draw_header "配置定时备份 — $username"
    draw_info_card "备份时间:" "每天 ${backup_hour}:00"
    draw_info_card "备份策略:" "增量备份 (--link-dest)"
    draw_info_card "脚本路径:" "$script_path"
    echo ""

    # 预生成全局排除文件供 cron 脚本使用
    local global_exclude_file="$BACKUP_ROOT/.excludes/backup_excludes.txt"
    priv_mkdir -p "$(dirname "$global_exclude_file")"
    if ! generate_exclude_file "$global_exclude_file" >/dev/null; then
        msg_warn "排除文件生成失败，备份将不排除文件"
    fi

    msg_step "创建备份脚本: $script_path"

    # 生成备份脚本 —— 所有路径使用绝对值直接嵌入
    local script_content
    script_content=$(cat << GENEOF
#!/bin/bash
# 自动备份脚本 — $username
# 由用户管理系统生成于 $(date '+%Y-%m-%d %H:%M:%S')
# 备份策略：增量备份（--link-dest 引用最近备份）
# 数据保留：7天  日志保留：7天

USER="$username"
BACKUP_ROOT="$BACKUP_ROOT"
USER_HOME="$user_home"
LOG_DIR="/var/log/user_manager"
MANAGER_DIR="$abs_script_dir"

TIMESTAMP=\$(date +%Y%m%d_%H%M%S)

mkdir -p "\$LOG_DIR"
LOG_FILE="\$LOG_DIR/backup_\${USER}.log"

log_msg() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$*" >> "\$LOG_FILE"; }

# ── 判断备份类型（始终增量，无历史时全量） ──
LINK_DEST_OPT=""
LAST_BACKUP=\$(find "\$BACKUP_ROOT/\$USER" -maxdepth 1 -type d \( -name 'inc_*' -o -name 'full_*' \) 2>/dev/null | sort -r | head -n1)
if [ -n "\$LAST_BACKUP" ] && [ -d "\$LAST_BACKUP" ]; then
    BACKUP_TYPE="incremental"
    BACKUP_DIR="\$BACKUP_ROOT/\$USER/inc_\$TIMESTAMP"
    LINK_DEST_OPT="--link-dest=\$LAST_BACKUP"
    log_msg "执行增量备份（基于 \$(basename "\$LAST_BACKUP")）"
else
    BACKUP_TYPE="full"
    BACKUP_DIR="\$BACKUP_ROOT/\$USER/full_\$TIMESTAMP"
    log_msg "未找到历史备份，执行全量备份"
fi

mkdir -p "\$BACKUP_DIR"

# ── 使用预生成的排除文件 ──
EXCLUDE_FILE="$BACKUP_ROOT/.excludes/backup_excludes.txt"
if [ ! -f "\$EXCLUDE_FILE" ]; then
    log_msg "排除文件缺失，跳过排除: \$EXCLUDE_FILE"
    EXCLUDE_FILE=""
fi

# ── 执行 rsync（使用数组参数避免 eval 注入风险） ──
RSYNC_ARGS=(-a --delete)
if [ -n "\$EXCLUDE_FILE" ]; then
    RSYNC_ARGS+=(--exclude-from="\$EXCLUDE_FILE")
fi
if [ -n "\$LINK_DEST_OPT" ]; then
    RSYNC_ARGS+=(\$LINK_DEST_OPT)
fi
rsync "\${RSYNC_ARGS[@]}" --stats "\$USER_HOME/" "\$BACKUP_DIR/" >> "\$LOG_FILE" 2>&1
RC=\$?

if [ \$RC -eq 0 ]; then
    BACKUP_SIZE=\$(du -sh "\$BACKUP_DIR" 2>/dev/null | cut -f1)
    log_msg "备份成功 (类型: \$BACKUP_TYPE, 大小: \$BACKUP_SIZE)"
else
    log_msg "备份失败 (退出码: \$RC)"
fi

# ── 安全清理超过7天的旧备份（最少保留5个） ──
log_msg "开始清理旧备份..."
BACKUP_DIR_LIST=\$(find "\$BACKUP_ROOT/\$USER" -maxdepth 1 -type d \
    \( -name 'full_*' -o -name 'inc_*' -o -name 'auto_*' \) \
    -mtime +7 -print 2>/dev/null | sort -r)
if [ -n "\$BACKUP_DIR_LIST" ]; then
    TOTAL_BACKUPS=\$(find "\$BACKUP_ROOT/\$USER" -maxdepth 1 -type d \
        \( -name 'full_*' -o -name 'inc_*' -o -name 'auto_*' \) 2>/dev/null | wc -l)
    KEEP_COUNT=\$((TOTAL_BACKUPS - \$(echo "\$BACKUP_DIR_LIST" | wc -l)))
    if [ "\$KEEP_COUNT" -lt 5 ]; then
        SKIP_COUNT=\$((5 - KEEP_COUNT))
        BACKUP_DIR_LIST=\$(echo "\$BACKUP_DIR_LIST" | tail -n +\$((SKIP_COUNT + 1)))
    fi
    CLEANED=0
    while IFS= read -r bdir; do
        [ -z "\$bdir" ] && continue
        if [ "\$bdir" = "\$BACKUP_ROOT/\$USER"/* ]; then
            rm -rf "\$bdir" 2>> "\$LOG_FILE" && CLEANED=\$((CLEANED + 1))
        fi
    done <<< "\$BACKUP_DIR_LIST"
    log_msg "清理完成: \$CLEANED 个旧备份"
fi

# ── 日志轮转（超过10MB） ──
if [ -f "\$LOG_FILE" ]; then
    LOG_SIZE=\$(stat -c%s "\$LOG_FILE" 2>/dev/null || echo 0)
    if [ "\$LOG_SIZE" -gt 10485760 ]; then
        mv "\$LOG_FILE" "\$LOG_FILE.\$(date +%Y%m%d_%H%M%S)"
        touch "\$LOG_FILE"
        log_msg "日志文件已轮转"
    fi
fi
GENEOF
)

    # 写入脚本
    if printf '%s' "$script_content" | write_privileged_text_file "$script_path" "0755" "root:root"; then
        priv_chmod +x "$script_path"
        msg_ok "备份脚本创建成功"
    else
        msg_err "创建备份脚本失败"
        return 1
    fi

    # 添加到 root 的 crontab（先移除旧条目）
    msg_step "配置定时任务..."
    local cron_line="$cron_expr $script_path"

    rewrite_root_crontab_without_literal "$script_path" >/dev/null 2>&1 || true
    if append_root_crontab_line "$cron_line"; then
        echo ""
        msg_ok "定时备份任务配置成功"
        draw_info_card "备份时间:" "每天 ${backup_hour}:00"
        draw_info_card "备份策略:" "增量备份 (--link-dest)"
        draw_info_card "数据保留:" "7天"
        draw_info_card "日志位置:" "/var/log/user_manager/backup_${username}.log"
        record_user_event "$username" "schedule_backup" "配置定时备份: 每天${backup_hour}点"
        return 0
    else
        msg_err "恢复失败"
        return 1
    fi
}

# ============================================================
# 13. _safe_cleanup_backups - 安全清理旧备份
# ============================================================
_safe_cleanup_backups() {
    local user_backup_dir="$1"
    local retention_days="${2:-${BACKUP_RETENTION_DAYS:-7}}"
    local min_keep="${3:-${BACKUP_MIN_KEEP:-3}}"

    [[ -z "$user_backup_dir" ]] && return 1
    [[ ! -d "$user_backup_dir" ]] && return 2

    if [[ "$user_backup_dir" != "$BACKUP_ROOT"/* ]]; then
        msg_err "安全拒绝: 备份清理路径不在 BACKUP_ROOT 下: $user_backup_dir"
        return 1
    fi

    local cleanup_list
    cleanup_list=$(find "$user_backup_dir" -maxdepth 1 -type d \
        \( -name 'full_*' -o -name 'inc_*' -o -name 'auto_*' \) \
        -mtime "+${retention_days}" -print 2>/dev/null | sort -r)

    if [[ -z "$cleanup_list" ]]; then
        return 0
    fi

    local total_backups
    total_backups=$(find "$user_backup_dir" -maxdepth 1 -type d \
        \( -name 'full_*' -o -name 'inc_*' -o -name 'auto_*' \) 2>/dev/null | wc -l)

    local keep_count=$((total_backups - $(echo "$cleanup_list" | wc -l)))
    if (( keep_count < min_keep )); then
        cleanup_list=$(echo "$cleanup_list" | tail -n +$((min_keep - keep_count + 1)))
        [[ -z "$cleanup_list" ]] && return 0
    fi

    local cleaned=0 freed=0
    local backup_dir
    while IFS= read -r backup_dir; do
        [[ -z "$backup_dir" ]] && continue
        local bsize
        bsize=$(du -sb "$backup_dir" 2>/dev/null | cut -f1)
        freed=$((freed + ${bsize:-0}))
        if rm -rf "$backup_dir" 2>/dev/null; then
            ((cleaned+=1))
        fi
    done <<< "$cleanup_list"

    if (( cleaned > 0 )); then
        msg_ok "清理旧备份: $cleaned 个, 释放 $(bytes_to_human "$freed")"
    fi
    return 0
}

# ============================================================
# 14. update_backup_index - 更新备份元数据索引
# ============================================================
update_backup_index() {
    local username="$1"
    local backup_type="$2"
    local backup_dir="$3"
    local depends_on="${4:-}"

    [[ -z "$username" || -z "$backup_type" || -z "$backup_dir" || ! -d "$backup_dir" ]] && return 1

    local index_file="$BACKUP_ROOT/$username/.backup_index.json"
    local backup_id
    backup_id=$(basename "$backup_dir")
    local timestamp
    timestamp=$(date -Iseconds)
    local bsize
    bsize=$(du -sb "$backup_dir" 2>/dev/null | cut -f1)
    bsize=${bsize:-0}

    local checksum_status="none"
    local checksum_file="${CHECKSUM_DIR:-$BACKUP_ROOT/.checksums}/$username/${backup_id}${CHECKSUM_SUFFIX:-.sha256}"
    [[ -f "$checksum_file" ]] && checksum_status="generated"

    local depends_value="null"
    [[ -n "$depends_on" ]] && depends_value="\"$(basename "$depends_on")\""

    if command -v jq &>/dev/null; then
        local entry
        entry=$(jq -n --arg id "$backup_id" --arg type "$backup_type" \
            --arg ts "$timestamp" --arg cs "$checksum_status" \
            --argjson size "$bsize" \
            "{id: \$id, type: \$type, timestamp: \$ts, depends_on: $depends_value, size: \$size, checksum: \$cs}")

        if [[ -f "$index_file" ]]; then
            local tmp_file
            tmp_file=$(mktemp)
            jq --argjson entry "$entry" \
                '.backups += [$entry] | .backups |= sort_by(.timestamp) | .last_updated = now' \
                "$index_file" > "$tmp_file" 2>/dev/null && mv "$tmp_file" "$index_file"
        else
            mkdir -p "$(dirname "$index_file")"
            jq -n --arg user "$username" --argjson entry "$entry" \
                '{username: $user, backups: [$entry], last_updated: now}' > "$index_file"
        fi
    fi

    return 0
}

# ============================================================
# 15. show_backup_chain - 显示备份链路
# ============================================================
show_backup_chain() {
    local username="$1"

    [[ -z "$username" ]] && { msg_err "用户名不能为空"; return 1; }

    local index_file="$BACKUP_ROOT/$username/.backup_index.json"

    draw_header "备份链路 — $username"

    if [[ ! -f "$index_file" ]]; then
        msg_info "没有备份索引数据"
        return 0
    fi

    if ! command -v jq &>/dev/null; then
        msg_warn "jq 未安装，无法解析备份索引"
        return 1
    fi

    local backup_count
    backup_count=$(jq '.backups | length' "$index_file" 2>/dev/null)
    if [[ -z "$backup_count" || "$backup_count" -eq 0 ]]; then
        msg_info "索引中没有备份记录"
        return 0
    fi

    printf "  ${C_DIM}%-28s %-10s %-8s %-10s %s${C_RESET}\n" "备份ID" "类型" "大小" "校验" "依赖"
    draw_line 75

    local i
    for ((i=0; i<backup_count; i++)); do
        local bid btype bsize bcs bdep
        bid=$(jq -r ".backups[$i].id" "$index_file")
        btype=$(jq -r ".backups[$i].type" "$index_file")
        bsize=$(jq -r ".backups[$i].size" "$index_file")
        bsize=$(bytes_to_human "${bsize:-0}")
        bcs=$(jq -r ".backups[$i].checksum" "$index_file")
        bdep=$(jq -r ".backups[$i].depends_on // \"-\"" "$index_file")

        local color="$C_RESET"
        [[ "$btype" == "full" ]] && color="$C_BGREEN"
        [[ "$btype" == "incremental" ]] && color="$C_RESET"
        [[ "$btype" == "batch" ]] && color="$C_RESET"

        printf "  ${color}%-28s${C_RESET} %-10s %-8s %-10s ${C_DIM}%s${C_RESET}\n" \
            "$bid" "$btype" "$bsize" "$bcs" "$bdep"
    done

    echo ""
    msg_ok "共 ${C_BOLD}$backup_count${C_RESET} 个备份记录"
    return 0
}

# ============================================================
#  6. remove_backup_schedule  —— 移除定时备份
# ============================================================
remove_backup_schedule() {
    local username="$1"

    if [[ -z "$username" ]]; then
        msg_err "用户名不能为空"
        return 1
    fi

    local script_path="/usr/local/bin/backup_user_${username}.sh"

    draw_header "移除定时备份 — $username"

    msg_step "移除定时备份任务..."

    # 从 crontab 移除
    rewrite_root_crontab_without_literal "$script_path" >/dev/null 2>&1 || true

    # 删除备份脚本
    if [[ -f "$script_path" ]]; then
        priv_rm -f "$script_path"
        msg_ok "已删除备份脚本: $script_path"
    fi

    msg_ok "定时备份任务已移除"
    record_user_event "$username" "remove_schedule" "移除定时备份"
    return 0
}

# ============================================================
#  7. show_backup_schedules  —— 显示所有定时备份任务
# ============================================================
show_backup_schedules() {
    draw_header "定时备份任务"

    printf "  ${C_DIM}%-14s %-28s %s${C_RESET}\n" "计划时间" "脚本" "用户"
    draw_line 60

    local has_tasks=0
    while IFS= read -r line; do
        if [[ "$line" =~ backup_user_(.*)\.sh ]]; then
            local sched_user="${BASH_REMATCH[1]}"
            local cron_time
            cron_time=$(echo "$line" | awk '{print $1, $2, $3, $4, $5}')
            local sched_script
            sched_script=$(echo "$line" | awk '{print $6}')

            printf "  ${C_RESET}%-14s${C_RESET} %-28s ${C_BOLD}%s${C_RESET}\n" \
                "$cron_time" "$sched_script" "$sched_user"
            has_tasks=1
        fi
    done < <(read_root_crontab)

    echo ""
    if [[ $has_tasks -eq 0 ]]; then
        msg_info "没有配置定时备份任务"
    fi
}

# 排除模式管理已统一迁移至 lib/backup_excludes.sh
# 参见: get_base_exclude_patterns / get_bio_exclude_patterns / build_rsync_exclude_args

# ============================================================
#  9. backup_all_users  —— 批量备份（安全，无 eval）
# ============================================================
backup_all_users() {
    draw_header "一键备份所有用户数据"

    # 获取托管用户
    local -a all_users=()
    while IFS= read -r username; do
        [[ -z "$username" ]] && continue
        all_users+=("$username")
    done < <(get_managed_usernames)

    if [[ ${#all_users[@]} -eq 0 ]]; then
        msg_warn "没有找到托管用户"
        return 0
    fi

    local backup_batch_id
    backup_batch_id=$(date +%Y%m%d_%H%M%S)
    local batch_dir="$BACKUP_ROOT/batch_${backup_batch_id}"

    draw_info_card "批次ID:" "$backup_batch_id"
    draw_info_card "用户数:" "${#all_users[@]}"
    draw_info_card "批次目录:" "$batch_dir"
    echo ""

    print_exclude_summary
    echo ""

    if ! confirm_action "确认开始备份？"; then
        msg_info "已取消备份操作"
        return 0
    fi

    if ! priv_mkdir -p "$batch_dir"; then
        msg_err "无法创建批次目录: $batch_dir"
        return 1
    fi

    # 创建批次日志
    local batch_log="$batch_dir/backup_batch.log"
    {
        echo "========================================="
        echo "批量备份日志 — 批次 $backup_batch_id"
        echo "开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "用户数量: ${#all_users[@]}"
        echo "========================================="
        echo ""
    } | write_privileged_text_file "$batch_log" "0644" "root:root"

    # 预先构建排除数组（所有用户共用）
    local -a exclude_args=()
    build_rsync_exclude_args exclude_args

    local total=${#all_users[@]}
    local current=0
    local success_count=0 failed_count=0 total_bytes=0
    local -a failed_users=()

    for username in "${all_users[@]}"; do
        ((current+=1))
        echo ""
        msg_step "[${C_RESET}${current}${C_RESET}/${C_BOLD}${total}${C_RESET}] 备份用户: ${C_BOLD}$username${C_RESET}"

        # 检查用户存在
        if ! id "$username" &>/dev/null; then
            msg_warn "  用户不存在，跳过"
            echo "[$current/$total] $username — 跳过: 用户不存在" | priv_tee -a "$batch_log" > /dev/null
            ((failed_count+=1))
            failed_users+=("$username")
            continue
        fi

        # 获取主目录
        local user_home
        user_home=$(get_user_home "$username")
        if [[ -z "$user_home" || ! -d "$user_home" ]]; then
            msg_warn "  无法获取主目录，跳过"
            echo "[$current/$total] $username — 跳过: 无法获取主目录" | priv_tee -a "$batch_log" > /dev/null
            ((failed_count+=1))
            failed_users+=("$username")
            continue
        fi

        local user_backup_dir="$batch_dir/$username"
        if ! priv_mkdir -p "$user_backup_dir"; then
            msg_err "  创建备份目录失败"
            echo "[$current/$total] $username — 失败: 无法创建备份目录" | priv_tee -a "$batch_log" > /dev/null
            ((failed_count+=1))
            failed_users+=("$username")
            continue
        fi

        # 查找该用户最近的备份用于增量
        local last_user_backup=""
        if [[ -d "$BACKUP_ROOT/$username" ]]; then
            last_user_backup=$(find "$BACKUP_ROOT/$username" -maxdepth 1 -type d \
                \( -name 'inc_*' -o -name 'full_*' -o -name '2*' \) 2>/dev/null | sort -r | head -n1)
        fi

        # 构建完整 rsync 参数（不使用 eval）
        local -a rsync_args=( -a --delete )
        if [[ -n "$last_user_backup" && -d "$last_user_backup" ]]; then
            rsync_args+=( --link-dest="$last_user_backup" )
            msg_info "  增量备份 (基于 $(basename "$last_user_backup"))"
        else
            msg_info "  全量备份 (首次)"
        fi
        rsync_args+=( "${exclude_args[@]}" )
        rsync_args+=( "$user_home/" "$user_backup_dir/" )

        local backup_start
        backup_start=$(date +%s)

        msg_info "  正在备份..."

        if priv_rsync "${rsync_args[@]}" >> "$batch_log" 2>&1; then
            local backup_end elapsed bsize bsize_bytes
            backup_end=$(date +%s)
            elapsed=$((backup_end - backup_start))
            bsize=$(priv_du -sh "$user_backup_dir" 2>/dev/null | cut -f1)
            bsize_bytes=$(priv_du -sb "$user_backup_dir" 2>/dev/null | cut -f1)
            bsize_bytes=${bsize_bytes:-0}

            msg_ok "  备份完成 ${C_DIM}(大小: ${bsize}, 耗时: ${elapsed}s)${C_RESET}"
            echo "[$current/$total] $username — 成功 (大小: $bsize, 耗时: ${elapsed}s)" | \
                priv_tee -a "$batch_log" > /dev/null

            ((success_count+=1))
            total_bytes=$((total_bytes + bsize_bytes))
            # 更新备份索引
            update_backup_index "$username" "batch" "$user_backup_dir" "${last_user_backup:-}"
        else
            msg_err "  备份失败"
            echo "[$current/$total] $username — 失败: rsync 执行错误" | \
                priv_tee -a "$batch_log" > /dev/null
            ((failed_count+=1))
            failed_users+=("$username")
        fi
    done

    # ── 汇总报告 ──
    echo ""
    draw_header "备份完成汇总"

    local total_human
    total_human=$(bytes_to_human "$total_bytes")

    draw_info_card "批次ID:" "$backup_batch_id"
    draw_info_card "成功:" "${C_BGREEN}${success_count}${C_RESET} / ${total}"
    if [[ $failed_count -gt 0 ]]; then
        draw_info_card "失败:" "${C_BRED}${failed_count}${C_RESET} / ${total}"
        for u in "${failed_users[@]}"; do
            draw_info_card "" "${C_RED}• $u${C_RESET}"
        done
    fi
    draw_info_card "总大小:" "$total_human"
    draw_info_card "备份位置:" "$batch_dir"
    draw_info_card "详细日志:" "$batch_log"

    # 写入日志尾部
    {
        echo ""
        echo "========================================="
        echo "汇总: 成功 $success_count, 失败 $failed_count, 总大小 $total_human"
        echo "完成时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "========================================="
    } | priv_tee -a "$batch_log" > /dev/null

    record_user_event "system" "batch_backup" "批量备份: 成功${success_count}, 失败${failed_count}"
    return 0
}

# ============================================================
#  10. backup_all_users_parallel  —— 并行备份（修复路径问题）
# ============================================================
backup_all_users_parallel() {
    local parallel_jobs="${1:-4}"

    draw_header "并行备份所有用户数据"
    draw_info_card "并行度:" "$parallel_jobs"

    # 获取托管用户
    local -a all_users=()
    while IFS= read -r username; do
        [[ -z "$username" ]] && continue
        all_users+=("$username")
    done < <(get_managed_usernames)

    if [[ ${#all_users[@]} -eq 0 ]]; then
        msg_warn "没有找到托管用户"
        return 0
    fi

    draw_info_card "用户总数:" "${#all_users[@]}"
    echo ""

    if ! confirm_action "确认开始并行备份？"; then
        msg_info "已取消备份操作"
        return 0
    fi

    local backup_batch_id
    backup_batch_id=$(date +%Y%m%d_%H%M%S)
    local batch_dir="$BACKUP_ROOT/batch_${backup_batch_id}"
    local batch_log="$batch_dir/backup_batch_parallel.log"
    local results_dir
    results_dir=$(mktemp -d) || { msg_err "无法创建临时目录"; return 1; }

    priv_mkdir -p "$batch_dir" || { rm -rf "$results_dir"; return 1; }

    echo "并行备份开始: $(date '+%Y-%m-%d %H:%M:%S'), 并行度: $parallel_jobs" | \
        write_privileged_text_file "$batch_log" "0644" "root:root"

    # ── 生成排除列表临时文件 ──
    local exclude_file
    exclude_file=$(generate_exclude_file) || { rm -rf "$results_dir"; msg_err "无法生成排除文件"; return 1; }
    register_exclude_temp_file "$exclude_file"

    # ── 生成并行备份子脚本（嵌入绝对路径，不用 sed 替换） ──
    local backup_script
    backup_script=$(mktemp /tmp/backup_parallel_XXXXXX.sh) || {
        rm -rf "$results_dir"
        rm -f "$exclude_file"
        msg_err "无法创建临时脚本"
        return 1
    }

    # ── 注册临时文件清理 ──
    trap '_cleanup_exclude_temp_files; rm -f "$backup_script"; rm -rf "$results_dir"' EXIT INT TERM

    cat > "$backup_script" << PEOF
#!/bin/bash
# 并行备份子任务脚本 — 自动生成
# 所有路径已嵌入为绝对路径，无需 sed 替换

EXCLUDE_FILE="$exclude_file"
BATCH_DIR="$batch_dir"
BATCH_LOG="$batch_log"
RESULTS_DIR="$results_dir"

username="\$1"

if ! id "\$username" &>/dev/null; then
    echo "SKIP \$username: 用户不存在"
    echo "SKIP" > "\$RESULTS_DIR/\$username"
    exit 0
fi

user_home=\$(getent passwd "\$username" | cut -d: -f6)
if [[ -z "\$user_home" || ! -d "\$user_home" ]]; then
    echo "SKIP \$username: 主目录不存在"
    echo "SKIP" > "\$RESULTS_DIR/\$username"
    exit 0
fi

user_backup_dir="\$BATCH_DIR/\$username"
mkdir -p "\$user_backup_dir"

# 查找该用户最近的备份用于增量
LINK_DEST_OPT=""
LAST_BACKUP=\$(find "\$BACKUP_ROOT/\$username" -maxdepth 1 -type d \( -name 'inc_*' -o -name 'full_*' -o -name '2*' \) 2>/dev/null | sort -r | head -n1)
if [[ -n "\$LAST_BACKUP" && -d "\$LAST_BACKUP" ]]; then
    LINK_DEST_OPT="--link-dest=\$LAST_BACKUP"
fi

start_ts=\$(date +%s)

rsync -a --delete --exclude-from="\$EXCLUDE_FILE" \$LINK_DEST_OPT \\
    "\$user_home/" "\$user_backup_dir/" >> "\$BATCH_LOG" 2>&1
rc=\$?

end_ts=\$(date +%s)
elapsed=\$((end_ts - start_ts))

if [[ \$rc -eq 0 ]]; then
    bsize=\$(du -sh "\$user_backup_dir" 2>/dev/null | cut -f1)
    echo "OK \$username (大小: \$bsize, 耗时: \${elapsed}s)"
    echo "OK \$bsize \${elapsed}s" > "\$RESULTS_DIR/\$username"
else
    echo "FAIL \$username (退出码: \$rc)"
    echo "FAIL \$rc" > "\$RESULTS_DIR/\$username"
fi
PEOF

    chmod +x "$backup_script"

    msg_step "开始并行备份..."
    echo ""

    # ── 使用 GNU parallel 或 xargs 执行 ──
    if command -v parallel &>/dev/null; then
        msg_info "使用 GNU parallel (并行度: $parallel_jobs)"
        printf '%s\n' "${all_users[@]}" | \
            priv_parallel -j "$parallel_jobs" --line-buffer \
                bash "$backup_script" {} 2>&1 | while IFS= read -r line; do
            if [[ "$line" == OK* ]]; then
                msg_ok "  $line"
            elif [[ "$line" == FAIL* ]]; then
                msg_err "  $line"
            elif [[ "$line" == SKIP* ]]; then
                msg_warn "  $line"
            else
                msg_info "  $line"
            fi
        done
    else
        msg_info "使用 xargs -P (并行度: $parallel_jobs)"
        printf '%s\n' "${all_users[@]}" | \
            priv_xargs -P "$parallel_jobs" -I {} \
                bash "$backup_script" {} 2>&1 | while IFS= read -r line; do
            if [[ "$line" == OK* ]]; then
                msg_ok "  $line"
            elif [[ "$line" == FAIL* ]]; then
                msg_err "  $line"
            elif [[ "$line" == SKIP* ]]; then
                msg_warn "  $line"
            else
                msg_info "  $line"
            fi
        done
    fi

    # ── 汇总结果 ──
    echo ""
    draw_header "并行备份汇总"

    local ok_count=0 fail_count=0 skip_count=0
    local -a fail_list=()
    for f in "$results_dir"/*; do
        [[ -f "$f" ]] || continue
        local uname
        uname=$(basename "$f")
        local status
        status=$(head -c4 "$f")
        case "$status" in
            OK*)   ((ok_count+=1)) ;;
            FAIL)  ((fail_count+=1)); fail_list+=("$uname") ;;
            SKIP)  ((skip_count+=1)) ;;
        esac
    done

    local batch_size
    batch_size=$(priv_du -sh "$batch_dir" 2>/dev/null | cut -f1)

    draw_info_card "批次ID:" "$backup_batch_id"
    draw_info_card "成功:" "${C_BGREEN}${ok_count}${C_RESET}"
    [[ $fail_count -gt 0 ]] && draw_info_card "失败:" "${C_BRED}${fail_count}${C_RESET}"
    [[ $skip_count -gt 0 ]] && draw_info_card "跳过:" "${C_RESET}${skip_count}${C_RESET}"
    if [[ ${#fail_list[@]} -gt 0 ]]; then
        for u in "${fail_list[@]}"; do
            draw_info_card "" "${C_RED}• $u${C_RESET}"
        done
    fi
    draw_info_card "总大小:" "${batch_size:-N/A}"
    draw_info_card "备份位置:" "$batch_dir"
    draw_info_card "详细日志:" "$batch_log"

    # 清理临时文件（trap 已注册，此处显式清理并重置 trap）
    trap - EXIT INT TERM
    rm -f "$backup_script" "$exclude_file"
    rm -rf "$results_dir"

    record_user_event "system" "batch_backup_parallel" "并行备份: 成功${ok_count}, 失败${fail_count} (并行度: $parallel_jobs)"
    return 0
}

# ============================================================
#  11. show_backup_batches  —— 显示批次备份历史
# ============================================================
show_backup_batches() {
    if [[ ! -d "$BACKUP_ROOT" ]]; then
        msg_info "备份目录不存在"
        return 0
    fi

    draw_header "批量备份记录"

    printf "  ${C_DIM}%-30s %-10s %s${C_RESET}\n" "批次ID" "用户数" "总大小"
    draw_line 55

    local found=0
    while IFS= read -r -d '' batch_dir; do
        local bname
        bname=$(basename "$batch_dir")
        local ucount
        ucount=$(find "$batch_dir" -maxdepth 1 -type d ! -path "$batch_dir" ! -name '*.log' 2>/dev/null | wc -l)
        local tsize
        tsize=$(priv_du -sh "$batch_dir" 2>/dev/null | cut -f1)

        printf "  ${C_RESET}%-30s${C_RESET} ${C_BOLD}%-10d${C_RESET} ${C_BGREEN}%s${C_RESET}\n" \
            "$bname" "$ucount" "$tsize"
        found=1
    done < <(find "$BACKUP_ROOT" -maxdepth 1 -type d -name 'batch_*' -print0 2>/dev/null | sort -rz)

    echo ""
    if [[ $found -eq 0 ]]; then
        msg_info "没有批量备份记录"
    fi
}

# ============================================================
#  12. restore_from_batch  —— 从批次备份恢复单个用户
# ============================================================
restore_from_batch() {
    local batch_id="$1"
    local username="$2"

    if [[ -z "$batch_id" || -z "$username" ]]; then
        msg_err "批次ID和用户名不能为空"
        return 1
    fi

    local batch_dir="$BACKUP_ROOT/batch_${batch_id}"
    local user_backup_dir="$batch_dir/$username"

    if [[ ! -d "$user_backup_dir" ]]; then
        msg_err "无法找到备份: ${C_BOLD}${batch_id}/${username}${C_RESET}"
        return 1
    fi

    if ! id "$username" &>/dev/null; then
        msg_err "用户 ${C_BOLD}$username${C_RESET} 不存在"
        return 1
    fi

    local user_home
    user_home=$(get_user_home "$username")
    if [[ -z "$user_home" ]]; then
        msg_err "无法获取用户主目录"
        return 1
    fi

    local bsize
    bsize=$(priv_du -sh "$user_backup_dir" 2>/dev/null | cut -f1)

    draw_header "从批次恢复 — $username"
    draw_info_card "批次ID:" "$batch_id"
    draw_info_card "备份大小:" "$bsize"
    draw_info_card "备份目录:" "$user_backup_dir"
    draw_info_card "恢复到:" "$user_home"
    echo ""

    msg_warn "此操作将覆盖用户 ${C_BOLD}$username${C_RESET} 的所有数据！"
    echo ""

    if ! confirm_action "确认要恢复吗？"; then
        msg_info "已取消恢复"
        return 0
    fi

    # 先备份当前数据
    local pre_restore
    pre_restore="$BACKUP_ROOT/$username/pre_restore_$(date +%Y%m%d_%H%M%S)"
    msg_step "备份当前数据到: $pre_restore"
    priv_mkdir -p "$pre_restore"
    priv_rsync -a "$user_home/" "$pre_restore/" 2>/dev/null || true

    # 执行恢复
    msg_step "开始恢复..."
    if priv_rsync -av --delete "$user_backup_dir/" "$user_home/"; then
        local user_uid user_gid
        user_uid=$(id -u "$username")
        user_gid=$(id -g "$username")
        priv_chown -R "${user_uid}:${user_gid}" "$user_home"

        echo ""
        msg_ok "恢复完成"
        record_user_event "$username" "restore_batch" "从批次 $batch_id 恢复"
        return 0
    else
        msg_err "恢复失败"
        return 1
    fi
}
