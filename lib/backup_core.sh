#!/bin/bash
# backup_core.sh - 备份管理核心模块 v5.0
# 提供用户数据备份、恢复、定时任务管理、批量备份功能
# 改进：安全的 rsync 参数构建（无 eval）、修复并行备份路径、彩色输出

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
        local color="$C_CYAN"
        [[ "$bname" == full_* ]]        && color="$C_BGREEN"
        [[ "$bname" == inc_* ]]         && color="$C_YELLOW"
        [[ "$bname" == pre_restore_* ]] && color="$C_MAGENTA"

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

        printf "  ${C_CYAN}%-24s${C_RESET} ${C_BOLD}%-10d${C_RESET} ${C_BGREEN}%s${C_RESET}\n" \
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
        draw_info_card "备份类型:" "增量 (基于 $(basename "$last_backup"))" "$C_BCYAN"
    else
        draw_info_card "备份类型:" "全量 (首次备份)" "$C_BYELLOW"
    fi
    echo ""

    # 创建备份目录
    if ! priv_mkdir -p "$backup_dir"; then
        msg_err "创建备份目录失败"
        return 1
    fi

    if ! command -v rsync &>/dev/null; then
        msg_warn "rsync 未安装，使用 cp 命令备份（速度较慢）"
        if run_privileged cp -a "$user_home" "$backup_dir"; then
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

    # 构建排除参数数组 —— 不使用 eval
    local -a rsync_args=( -av --delete )

    # 增量备份：使用 --link-dest 引用上次备份，仅传输差异
    if [[ "$backup_type" == "incremental" ]]; then
        rsync_args+=( --link-dest="$last_backup" )
    fi

    rsync_args+=( --exclude='.cache' )
    rsync_args+=( --exclude='.local/share/Trash' )
    rsync_args+=( --exclude='*.tmp' )
    rsync_args+=( --exclude='__pycache__' )
    rsync_args+=( --exclude='.git/objects' )
    rsync_args+=( --exclude='.git/logs' )

    # 追加生物信息排除模式
    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue
        rsync_args+=( --exclude="$pattern" )
    done < <(get_bio_exclude_patterns)

    rsync_args+=( "$user_home/" "$backup_dir/" )

    local start_ts
    start_ts=$(date +%s)

    if run_privileged rsync "${rsync_args[@]}"; then
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
    run_privileged rsync -a "$user_home/" "$pre_restore_backup/" 2>/dev/null || true

    msg_step "开始恢复..."

    if run_privileged rsync -av --delete "$backup_dir/" "$user_home/"; then
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

# ── 构建排除列表 ──
EXCLUDE_FILE=\$(mktemp) || { log_msg "无法创建临时文件"; exit 1; }
trap 'rm -f "\$EXCLUDE_FILE"' EXIT
cat > "\$EXCLUDE_FILE" << 'EXCL'
.cache
.local/share/Trash
*.tmp
__pycache__
.git/objects
.git/logs
*.bam
*.bam.bai
*.cram
*.cram.crai
*.fastq
*.fastq.gz
*.fq
*.fq.gz
*.sai
*.sam
*.sam.gz
*.bcf
*.vcf
*.vcf.gz
*.vcf.bgz
*.tbi
*.csi
*.bed
*.gff
*.gff3
*.gtf
*.txt.gz
*.pileup
*.mpileup
*.wig
*.bedgraph
*.bw
*.bigwig
*.hic
*.cool
*.mcool
*.bai
*.crai
*.idx
*.sra
*.sra.lite
*.ubam
*.unmapped.bam
*.sorted.bam
*.dedup.bam
*.recall.bam
*.realigned.bam
*.trimmed.fastq.gz
*.trimmed.fq.gz
*.paired.fq.gz
*.unpaired.fq.gz
*.R1.fastq.gz
*.R2.fastq.gz
*.fasta.fai
*.dict
*.amb
*.ann
*.bwt
*.pac
*.sa
*.bt2
*.bt2l
*.hisat2
*.ht2
*.ht2l
*.stidx
*.stcoords
.samtoolscache
.gatk-cache
.picard-tmp
.bwa-cache
.snakemake
work/
tmp/
temp/
intermediate/
EXCL

# ── 执行 rsync ──
rsync -a --delete --exclude-from="\$EXCLUDE_FILE" \$LINK_DEST_OPT \\
    --stats "\$USER_HOME/" "\$BACKUP_DIR/" >> "\$LOG_FILE" 2>&1
RC=\$?
rm -f "\$EXCLUDE_FILE"

if [ \$RC -eq 0 ]; then
    BACKUP_SIZE=\$(du -sh "\$BACKUP_DIR" 2>/dev/null | cut -f1)
    log_msg "备份成功 (类型: \$BACKUP_TYPE, 大小: \$BACKUP_SIZE)"
else
    log_msg "备份失败 (退出码: \$RC)"
fi

# ── 清理超过7天的旧备份 ──
log_msg "开始清理旧备份..."
find "\$BACKUP_ROOT/\$USER" -maxdepth 1 -type d \( -name 'full_*' -o -name 'inc_*' -o -name 'auto_*' \) \\
    -mtime +7 -exec rm -rf {} \; 2>> "\$LOG_FILE"

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
    if echo "$script_content" | run_privileged tee "$script_path" > /dev/null; then
        priv_chmod +x "$script_path"
        msg_ok "备份脚本创建成功"
    else
        msg_err "创建备份脚本失败"
        return 1
    fi

    # 添加到 root 的 crontab（先移除旧条目）
    msg_step "配置定时任务..."
    local cron_line="$cron_expr $script_path"

    run_privileged crontab -l 2>/dev/null | grep -v "$script_path" | run_privileged crontab - 2>/dev/null || true
    if ( run_privileged crontab -l 2>/dev/null; echo "$cron_line" ) | run_privileged crontab -; then
        echo ""
        msg_ok "定时备份任务配置成功"
        draw_info_card "备份时间:" "每天 ${backup_hour}:00"
        draw_info_card "备份策略:" "增量备份 (--link-dest)"
        draw_info_card "数据保留:" "7天"
        draw_info_card "日志位置:" "/var/log/user_manager/backup_${username}.log"
        record_user_event "$username" "schedule_backup" "配置定时备份: 每天${backup_hour}点"
        return 0
    else
        msg_err "配置定时任务失败"
        return 1
    fi
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
    run_privileged crontab -l 2>/dev/null | grep -v "$script_path" | run_privileged crontab - 2>/dev/null || true

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

            printf "  ${C_CYAN}%-14s${C_RESET} %-28s ${C_BOLD}%s${C_RESET}\n" \
                "$cron_time" "$sched_script" "$sched_user"
            has_tasks=1
        fi
    done < <(run_privileged crontab -l 2>/dev/null)

    echo ""
    if [[ $has_tasks -eq 0 ]]; then
        msg_info "没有配置定时备份任务"
    fi
}

# ============================================================
#  8. get_bio_exclude_patterns  —— 生物信息排除模式
# ============================================================
get_bio_exclude_patterns() {
    cat << 'EOF'
*.bam
*.bam.bai
*.cram
*.cram.crai
*.fastq
*.fastq.gz
*.fq
*.fq.gz
*.sai
*.sam
*.sam.gz
*.bcf
*.vcf
*.vcf.gz
*.vcf.bgz
*.tbi
*.csi
*.bed
*.gff
*.gff3
*.gtf
*.txt.gz
*.pileup
*.mpileup
*.wig
*.bedgraph
*.bw
*.bigwig
*.hic
*.cool
*.mcool
*.bai
*.crai
*.idx
*.sra
*.sra.lite
*.ubam
*.unmapped.bam
*.sorted.bam
*.dedup.bam
*.recall.bam
*.realigned.bam
*.trimmed.fastq.gz
*.trimmed.fq.gz
*.paired.fq.gz
*.unpaired.fq.gz
*.R1.fastq.gz
*.R2.fastq.gz
*.fasta.fai
*.dict
*.amb
*.ann
*.bwt
*.pac
*.sa
*.bt2
*.bt2l
*.hisat2
*.ht2
*.ht2l
*.stidx
*.stcoords
.samtoolscache
.gatk-cache
.picard-tmp
.bwa-cache
.snakemake
work/
tmp/
temp/
intermediate/
EOF
}

# ============================================================
#  内部辅助 —— 构建 rsync 排除参数数组
# ============================================================
_build_rsync_exclude_args() {
    local -n _arr=$1     # nameref
    _arr+=( --exclude='.cache' )
    _arr+=( --exclude='.local/share/Trash' )
    _arr+=( --exclude='*.tmp' )
    _arr+=( --exclude='__pycache__' )
    _arr+=( --exclude='.git/objects' )
    _arr+=( --exclude='.git/logs' )
    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue
        _arr+=( --exclude="$pattern" )
    done < <(get_bio_exclude_patterns)
}

# ============================================================
#  9. backup_all_users  —— 批量备份（安全，无 eval）
# ============================================================
backup_all_users() {
    draw_header "一键备份所有用户数据"

    # 获取受管理的用户
    local -a all_users=()
    while IFS= read -r username; do
        [[ -z "$username" ]] && continue
        all_users+=("$username")
    done < <(get_managed_usernames)

    if [[ ${#all_users[@]} -eq 0 ]]; then
        msg_warn "没有找到受管理的用户"
        return 0
    fi

    local backup_batch_id
    backup_batch_id=$(date +%Y%m%d_%H%M%S)
    local batch_dir="$BACKUP_ROOT/batch_${backup_batch_id}"

    draw_info_card "批次ID:" "$backup_batch_id"
    draw_info_card "用户数:" "${#all_users[@]}"
    draw_info_card "批次目录:" "$batch_dir"
    echo ""

    msg_info "将排除以下生物信息中间产物:"
    get_bio_exclude_patterns | head -8 | sed 's/^/    /'
    echo "    ... (共 $(get_bio_exclude_patterns | wc -l) 种模式)"
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
    } | run_privileged tee "$batch_log" > /dev/null

    # 预先构建排除数组（所有用户共用）
    local -a exclude_args=()
    _build_rsync_exclude_args exclude_args

    local total=${#all_users[@]}
    local current=0
    local success_count=0 failed_count=0 total_bytes=0
    local -a failed_users=()

    for username in "${all_users[@]}"; do
        ((current+=1))
        echo ""
        msg_step "[${C_BCYAN}${current}${C_RESET}/${C_BOLD}${total}${C_RESET}] 备份用户: ${C_BOLD}$username${C_RESET}"

        # 检查用户存在
        if ! id "$username" &>/dev/null; then
            msg_warn "  用户不存在，跳过"
            echo "[$current/$total] $username — 跳过: 用户不存在" | run_privileged tee -a "$batch_log" > /dev/null
            ((failed_count+=1))
            failed_users+=("$username")
            continue
        fi

        # 获取主目录
        local user_home
        user_home=$(get_user_home "$username")
        if [[ -z "$user_home" || ! -d "$user_home" ]]; then
            msg_warn "  无法获取主目录，跳过"
            echo "[$current/$total] $username — 跳过: 无法获取主目录" | run_privileged tee -a "$batch_log" > /dev/null
            ((failed_count+=1))
            failed_users+=("$username")
            continue
        fi

        local user_backup_dir="$batch_dir/$username"
        if ! priv_mkdir -p "$user_backup_dir"; then
            msg_err "  创建备份目录失败"
            echo "[$current/$total] $username — 失败: 无法创建备份目录" | run_privileged tee -a "$batch_log" > /dev/null
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

        if run_privileged rsync "${rsync_args[@]}" >> "$batch_log" 2>&1; then
            local backup_end elapsed bsize bsize_bytes
            backup_end=$(date +%s)
            elapsed=$((backup_end - backup_start))
            bsize=$(run_privileged du -sh "$user_backup_dir" 2>/dev/null | cut -f1)
            bsize_bytes=$(run_privileged du -sb "$user_backup_dir" 2>/dev/null | cut -f1)
            bsize_bytes=${bsize_bytes:-0}

            msg_ok "  备份完成 ${C_DIM}(大小: ${bsize}, 耗时: ${elapsed}s)${C_RESET}"
            echo "[$current/$total] $username — 成功 (大小: $bsize, 耗时: ${elapsed}s)" | \
                run_privileged tee -a "$batch_log" > /dev/null

            ((success_count+=1))
            total_bytes=$((total_bytes + bsize_bytes))
        else
            msg_err "  备份失败"
            echo "[$current/$total] $username — 失败: rsync 执行错误" | \
                run_privileged tee -a "$batch_log" > /dev/null
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
    } | run_privileged tee -a "$batch_log" > /dev/null

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

    # 获取受管理的用户
    local -a all_users=()
    while IFS= read -r username; do
        [[ -z "$username" ]] && continue
        all_users+=("$username")
    done < <(get_managed_usernames)

    if [[ ${#all_users[@]} -eq 0 ]]; then
        msg_warn "没有找到受管理的用户"
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
        run_privileged tee "$batch_log" > /dev/null

    # ── 生成排除列表临时文件 ──
    local exclude_file
    exclude_file=$(mktemp) || { rm -rf "$results_dir"; msg_err "无法创建临时文件"; return 1; }
    {
        echo ".cache"
        echo ".local/share/Trash"
        echo "*.tmp"
        echo "__pycache__"
        echo ".git/objects"
        echo ".git/logs"
        get_bio_exclude_patterns
    } > "$exclude_file"

    # ── 生成并行备份子脚本（嵌入绝对路径，不用 sed 替换） ──
    local backup_script
    backup_script=$(mktemp /tmp/backup_parallel_XXXXXX.sh) || {
        rm -rf "$results_dir"
        rm -f "$exclude_file"
        msg_err "无法创建临时脚本"
        return 1
    }

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
LAST_BACKUP=\$(find "$BACKUP_ROOT/\$username" -maxdepth 1 -type d \( -name 'inc_*' -o -name 'full_*' -o -name '2*' \) 2>/dev/null | sort -r | head -n1)
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
            run_privileged parallel -j "$parallel_jobs" --line-buffer \
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
            run_privileged xargs -P "$parallel_jobs" -I {} \
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
    batch_size=$(run_privileged du -sh "$batch_dir" 2>/dev/null | cut -f1)

    draw_info_card "批次ID:" "$backup_batch_id"
    draw_info_card "成功:" "${C_BGREEN}${ok_count}${C_RESET}"
    [[ $fail_count -gt 0 ]] && draw_info_card "失败:" "${C_BRED}${fail_count}${C_RESET}"
    [[ $skip_count -gt 0 ]] && draw_info_card "跳过:" "${C_BYELLOW}${skip_count}${C_RESET}"
    if [[ ${#fail_list[@]} -gt 0 ]]; then
        for u in "${fail_list[@]}"; do
            draw_info_card "" "${C_RED}• $u${C_RESET}"
        done
    fi
    draw_info_card "总大小:" "${batch_size:-N/A}"
    draw_info_card "备份位置:" "$batch_dir"
    draw_info_card "详细日志:" "$batch_log"

    # 清理临时文件
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
        tsize=$(run_privileged du -sh "$batch_dir" 2>/dev/null | cut -f1)

        printf "  ${C_CYAN}%-30s${C_RESET} ${C_BOLD}%-10d${C_RESET} ${C_BGREEN}%s${C_RESET}\n" \
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
    bsize=$(run_privileged du -sh "$user_backup_dir" 2>/dev/null | cut -f1)

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
    run_privileged rsync -a "$user_home/" "$pre_restore/" 2>/dev/null || true

    # 执行恢复
    msg_step "开始恢复..."
    if run_privileged rsync -av --delete "$user_backup_dir/" "$user_home/"; then
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
