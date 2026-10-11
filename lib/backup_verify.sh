#!/bin/bash
# backup_verify.sh - 备份验证模块 v1.1.0
# 提供备份校验和生成、完整性验证、自动校验、健康报告功能

set -uo pipefail

# ============================================================
# 配置常量
# ============================================================

readonly CHECKSUM_SUFFIX=".sha256"
readonly CHECKSUM_DIR="${BACKUP_ROOT}/.checksums"

# ============================================================
# 校验和生成
# ============================================================

# 生成备份校验文件
# 参数: $1=备份路径
generate_backup_checksum() {
    local backup_path="${1:-}" backup_id username checksum_dir checksum_file temp_file file_count
    [[ -n "$backup_path" && -d "$backup_path" ]] || return 1
    backup_id=$(basename "$backup_path")
    username=$(basename "$(dirname "$backup_path")")
    checksum_dir="$CHECKSUM_DIR/$username"
    mkdir -p "$checksum_dir" || return 1
    checksum_file="${checksum_dir}/${backup_id}${CHECKSUM_SUFFIX}"
    temp_file=$(mktemp "${checksum_dir}/.checksum.XXXXXXXX") || return 1

    msg_step "正在生成校验文件..."
    if ! (
        cd "$backup_path" || exit 1
        find . -type f ! -name "*${CHECKSUM_SUFFIX}" -exec sha256sum {} +
    ) >"$temp_file"; then
        rm -f "$temp_file"
        msg_err "生成校验文件失败"
        return 1
    fi
    file_count=$(grep -Ec '^[[:xdigit:]]{64} [ *]' "$temp_file" || true)
    if ((file_count == 0)); then
        rm -f "$temp_file"
        msg_err "备份中没有可校验的常规文件"
        return 1
    fi
    if ! mv -f -- "$temp_file" "$checksum_file"; then
        rm -f "$temp_file"
        return 1
    fi
    msg_ok "校验文件已生成: $checksum_file ($file_count 个文件)"
}

# ============================================================
# 完整性验证
# ============================================================

# 验证备份完整性
# 参数: $1=备份路径
verify_backup_integrity() {
    local backup_path="${1:-}" backup_id username checksum_file file_count
    [[ -n "$backup_path" && -d "$backup_path" ]] || {
        msg_err "备份路径不存在: $backup_path"
        return 1
    }
    backup_id=$(basename "$backup_path")
    username=$(basename "$(dirname "$backup_path")")
    checksum_file="$CHECKSUM_DIR/$username/${backup_id}${CHECKSUM_SUFFIX}"
    [[ -f "$checksum_file" && ! -L "$checksum_file" ]] || {
        msg_err "缺少完整校验文件: $checksum_file"
        return 1
    }
    file_count=$(grep -Ec '^[[:xdigit:]]{64} [ *]' "$checksum_file" || true)
    ((file_count > 0)) || {
        msg_err "校验文件没有有效记录"
        return 1
    }
    msg_step "正在验证备份完整性..."
    if ! (
        cd "$backup_path" || exit 1
        sha256sum -c --status "$checksum_file"
    ); then
        msg_err "备份完整性验证失败"
        return 1
    fi
    msg_ok "备份完整性验证通过 ($file_count 个文件)"
}

# ============================================================
# 快速验证（抽样）
# ============================================================

# 快速抽样验证
# 参数: $1=备份路径, $2=抽样数量(默认10)
quick_verify_backup() {
    local backup_path="$1"
    local sample_size="${2:-10}"

    if [[ -z "$backup_path" ]] || [[ ! -d "$backup_path" ]]; then
        return 1
    fi

    msg_step "快速抽样验证 (样本: $sample_size)..."

    local files=()
    while IFS= read -r f; do
        files+=("$f")
    done < <(find "$backup_path" -type f ! -name "*${CHECKSUM_SUFFIX}" 2>/dev/null | shuf | head -n "$sample_size")

    local checked=0 passed=0

    for file in "${files[@]}"; do
        [[ -f "$file" ]] || continue
        ((checked += 1))

        if sha256sum "$file" &>/dev/null; then
            ((passed += 1))
        fi
    done

    if ((checked > 0 && passed == checked)); then
        msg_ok "快速验证通过 ($passed/$checked)"
        return 0
    else
        msg_warn "快速验证: $passed/$checked 通过"
        return 1
    fi
}

# ============================================================
# 恢复前验证
# ============================================================

# 恢复前验证
verify_before_restore() {
    local backup_path="$1"

    # 检查备份目录存在
    if [[ ! -d "$backup_path" ]]; then
        msg_err "备份目录不存在: $backup_path"
        return 1
    fi

    # 检查是否有文件
    local file_count
    file_count=$(find "$backup_path" -type f ! -name "*${CHECKSUM_SUFFIX}" 2>/dev/null | wc -l)

    if ((file_count == 0)); then
        msg_err "备份目录为空"
        return 1
    fi

    # 如果存在校验文件，进行完整验证
    local backup_id username checksum_file
    backup_id=$(basename "$backup_path")
    username=$(basename "$(dirname "$backup_path")")
    checksum_file="$CHECKSUM_DIR/$username/${backup_id}${CHECKSUM_SUFFIX}"
    if [[ -f "$checksum_file" ]]; then
        verify_backup_integrity "$backup_path"
        return $?
    fi

    # 历史备份无校验清单时，抽样计算哈希不能证明原数据完整。
    # 默认拒绝破坏性恢复；仅管理员显式接受风险后允许兼容旧备份。
    if [[ "${USER_MANAGER_ALLOW_UNVERIFIED_RESTORE:-0}" != "1" ]]; then
        msg_err "缺少备份校验清单，默认禁止覆盖恢复；历史备份需人工核验"
        return 1
    fi
    msg_warn "管理员显式允许未校验的历史备份恢复；抽样测试仅证明文件可读"
    quick_verify_backup "$backup_path" 20
}

# ============================================================
# 备份对比
# ============================================================

# 对比两个备份
compare_backups() {
    local backup1="$1"
    local backup2="$2"

    if [[ ! -d "$backup1" ]] || [[ ! -d "$backup2" ]]; then
        msg_err "备份路径无效"
        return 1
    fi

    draw_header "备份对比"

    local size1 size2 files1 files2
    size1=$(du -sh "$backup1" 2>/dev/null | cut -f1)
    size2=$(du -sh "$backup2" 2>/dev/null | cut -f1)
    files1=$(find "$backup1" -type f 2>/dev/null | wc -l)
    files2=$(find "$backup2" -type f 2>/dev/null | wc -l)

    draw_info_card "备份1大小:" "$size1"
    draw_info_card "备份2大小:" "$size2"
    draw_info_card "备份1文件数:" "$files1"
    draw_info_card "备份2文件数:" "$files2"

    return 0
}

# ============================================================
# 自动校验
# ============================================================

auto_checksum_after_backup() {
    local backup_path="$1"
    local username="${2:-}"

    if [[ "${BACKUP_AUTO_VERIFY:-true}" != "true" ]]; then
        return 0
    fi

    if [[ -z "$backup_path" || ! -d "$backup_path" ]]; then
        return 1
    fi

    msg_step "自动生成校验和..."
    if generate_backup_checksum "$backup_path"; then
        return 0
    else
        msg_warn "校验和生成失败（备份数据完整，可稍后重新生成）"
        return 1
    fi
}

# ============================================================
# 批量验证
# ============================================================

verify_all_user_backups() {
    local username="${1:-}"
    local results=()
    local total=0 passed=0 failed=0

    if [[ -n "$username" ]]; then
        local user_dir="$BACKUP_ROOT/$username"
        [[ ! -d "$user_dir" ]] && {
            msg_err "用户 $username 无备份"
            return 1
        }
        results=("$user_dir")
    else
        while IFS= read -r -d '' dir; do
            results+=("$dir")
        done < <(find "$BACKUP_ROOT" -maxdepth 1 -type d ! -path "$BACKUP_ROOT" \
            ! -name 'batch_*' ! -name 'manual' ! -name '.checksums' ! -name '.excludes' -print0 2>/dev/null)
    fi

    draw_header "备份完整性验证"

    for user_dir in "${results[@]}"; do
        local uname
        uname=$(basename "$user_dir")
        while IFS= read -r -d '' backup_dir; do
            ((total += 1))
            if verify_backup_integrity "$backup_dir"; then
                ((passed += 1))
            else
                ((failed += 1))
                msg_warn "  $uname/$(basename "$backup_dir") - 验证失败"
            fi
        done < <(find "$user_dir" -maxdepth 1 -type d \
            \( -name 'full_*' -o -name 'inc_*' -o -name 'pre_restore_*' \) -print0 2>/dev/null | sort -z)
    done

    echo ""
    draw_info_card "验证总数:" "$total"
    draw_info_card "通过:" "${C_BGREEN}$passed${C_RESET}"
    [[ $failed -gt 0 ]] && draw_info_card "失败:" "${C_BRED}$failed${C_RESET}"

    if ((failed == 0 && total > 0)); then
        msg_ok "所有备份验证通过"
        return 0
    elif ((failed > 0)); then
        msg_err "部分备份验证失败"
        return 1
    else
        msg_info "没有找到可验证的备份"
        return 0
    fi
}

# ============================================================
# 备份健康报告
# ============================================================

backup_health_report() {
    draw_header "备份健康报告"

    if [[ ! -d "$BACKUP_ROOT" ]]; then
        msg_err "备份目录不存在: $BACKUP_ROOT"
        return 1
    fi

    local total_users=0 total_backups=0 total_verified=0 total_failed=0 total_size=0

    while IFS= read -r -d '' user_dir; do
        local uname
        uname=$(basename "$user_dir")
        [[ "$uname" == batch_* || "$uname" == manual || "$uname" == .* ]] && continue

        ((total_users += 1))

        while IFS= read -r -d '' backup_dir; do
            ((total_backups += 1))
            local bsize
            bsize=$(du -sb "$backup_dir" 2>/dev/null | cut -f1)
            total_size=$((total_size + ${bsize:-0}))

            local cs_file
            cs_file="$CHECKSUM_DIR/$uname/$(basename "$backup_dir").sha256"
            if [[ -f "$cs_file" ]]; then
                if verify_backup_integrity "$backup_dir" &>/dev/null; then
                    ((total_verified += 1))
                else
                    ((total_failed += 1))
                fi
            fi
        done < <(find "$user_dir" -maxdepth 1 -type d \( -name 'full_*' -o -name 'inc_*' \) -print0 2>/dev/null)
    done < <(find "$BACKUP_ROOT" -maxdepth 1 -type d ! -path "$BACKUP_ROOT" -print0 2>/dev/null)

    draw_info_card "备份用户数:" "$total_users"
    draw_info_card "备份总数:" "$total_backups"
    draw_info_card "总大小:" "$(bytes_to_human $total_size)"
    draw_info_card "已验证:" "${C_BGREEN}$total_verified${C_RESET}"
    [[ $total_failed -gt 0 ]] && draw_info_card "验证失败:" "${C_BRED}$total_failed${C_RESET}"

    return 0
}

# ============================================================
# 生成缺失的校验和
# ============================================================

generate_missing_checksums() {
    local count=0 generated=0

    while IFS= read -r -d '' backup_dir; do
        local uname bname
        uname=$(basename "$(dirname "$backup_dir")")
        bname=$(basename "$backup_dir")
        local cs_file="$CHECKSUM_DIR/$uname/${bname}.sha256"

        if [[ ! -f "$cs_file" ]]; then
            ((count += 1))
            if generate_backup_checksum "$backup_dir" &>/dev/null; then
                ((generated += 1))
            fi
        fi
    done < <(find "$BACKUP_ROOT" -maxdepth 2 -type d \( -name 'full_*' -o -name 'inc_*' \) -print0 2>/dev/null)

    msg_ok "已为 $generated/$count 个备份生成校验和"
    return 0
}
