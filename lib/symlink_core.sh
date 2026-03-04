#!/bin/bash
# symlink_core.sh - 目录软连接管理模块 v6.0
# 提供用户目录软连接的创建、查看、删除功能
# 用途：跨磁盘引用、共享目录、项目快捷方式

# ============================================================
#  1. 创建用户软连接
# ============================================================
create_user_symlink() {
    local username="$1"
    local link_name="$2"
    local target_path="$3"

    if [[ -z "$username" ]]; then
        msg_err "用户名不能为空"
        return 1
    fi

    if ! id "$username" &>/dev/null; then
        msg_err "用户 ${C_BOLD}$username${C_RESET} 不存在"
        return 1
    fi

    if [[ -z "$link_name" ]]; then
        msg_err "链接名称不能为空"
        return 1
    fi

    if [[ -z "$target_path" ]]; then
        msg_err "目标路径不能为空"
        return 1
    fi

    # 检查目标路径是否存在
    if [[ ! -e "$target_path" ]]; then
        msg_err "目标路径不存在: ${C_BOLD}$target_path${C_RESET}"
        return 1
    fi

    local user_home
    user_home=$(get_user_home "$username")
    if [[ -z "$user_home" || ! -d "$user_home" ]]; then
        msg_err "无法获取用户主目录"
        return 1
    fi

    local link_path="$user_home/$link_name"

    # 防止覆盖已存在的文件/目录
    if [[ -e "$link_path" && ! -L "$link_path" ]]; then
        msg_err "路径 ${C_BOLD}$link_path${C_RESET} 已存在且不是符号链接"
        return 1
    fi

    # 安全检查：不允许链接到敏感路径
    local -a forbidden_paths=( "/etc" "/boot" "/root" "/proc" "/sys" "/dev" )
    for fp in "${forbidden_paths[@]}"; do
        if [[ "$target_path" == "$fp" || "$target_path" == "$fp/"* ]]; then
            msg_err "不允许创建指向系统关键目录的链接: $fp"
            return 1
        fi
    done

    # 如果已存在同名软连接，先移除
    if [[ -L "$link_path" ]]; then
        priv_rm "$link_path"
    fi

    # 创建软连接
    if run_privileged ln -s "$target_path" "$link_path"; then
        # 设置所有权（软连接本身）
        run_privileged chown -h "$username:$username" "$link_path" 2>/dev/null || true
        msg_ok "软连接已创建: ${C_BOLD}$link_name${C_RESET} → ${C_CYAN}$target_path${C_RESET}"
        record_user_event "$username" "symlink_create" "$link_name -> $target_path"
        return 0
    else
        msg_err "创建软连接失败"
        return 1
    fi
}

# ============================================================
#  2. 批量创建跨磁盘软连接
# ============================================================
create_cross_disk_symlink() {
    local username="$1"
    local target_disk="$2"
    local target_dir="${3:-}"

    if [[ -z "$username" ]]; then
        msg_err "用户名不能为空"
        return 1
    fi

    if ! id "$username" &>/dev/null; then
        msg_err "用户 ${C_BOLD}$username${C_RESET} 不存在"
        return 1
    fi

    if [[ -z "$target_disk" ]]; then
        msg_err "目标盘号不能为空"
        return 1
    fi

    local target_idx
    target_idx=$(printf "%02d" "$target_disk")
    local target_mp="$DATA_BASE/data${target_idx}"

    if ! mountpoint -q "$target_mp" 2>/dev/null; then
        msg_err "目标磁盘 $target_mp 未挂载"
        return 1
    fi

    local user_home
    user_home=$(get_user_home "$username")
    if [[ -z "$user_home" ]]; then
        msg_err "无法获取用户主目录"
        return 1
    fi

    # 确定目标路径
    local target_path
    if [[ -n "$target_dir" ]]; then
        target_path="$target_mp/$username/$target_dir"
    else
        target_path="$target_mp/$username"
    fi

    # 如果目标不存在，创建
    if [[ ! -d "$target_path" ]]; then
        if priv_mkdir -p "$target_path"; then
            priv_chown "$username:$username" "$target_path"
            priv_chmod 700 "$target_path"
            msg_ok "已创建目标目录: $target_path"
        else
            msg_err "创建目标目录失败"
            return 1
        fi
    fi

    # 链接名 = dataXX 或 dataXX_子目录
    local link_name
    if [[ -n "$target_dir" ]]; then
        link_name="data${target_idx}_${target_dir}"
    else
        link_name="data${target_idx}"
    fi

    create_user_symlink "$username" "$link_name" "$target_path"
}

# ============================================================
#  3. 查看用户所有软连接
# ============================================================
list_user_symlinks() {
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
        msg_err "无法获取用户主目录"
        return 1
    fi

    draw_header "用户软连接 — $username"

    printf "  ${C_BOLD}${C_WHITE}%-24s %-40s %s${C_RESET}\n" \
        "链接名称" "目标路径" "状态"
    draw_line 75

    local found=0
    while IFS= read -r -d '' link; do
        local lname target status status_color
        lname=$(basename "$link")
        target=$(readlink "$link")

        if [[ -e "$link" ]]; then
            status="有效"
            status_color="$C_BGREEN"
        else
            status="断链"
            status_color="$C_BRED"
        fi

        printf "  ${C_CYAN}%-24s${C_RESET} %-40s ${status_color}%s${C_RESET}\n" \
            "$lname" "$target" "$status"
        found=1
    done < <(find "$user_home" -maxdepth 1 -type l -print0 2>/dev/null | sort -z)

    echo ""
    if [[ $found -eq 0 ]]; then
        msg_info "用户 $username 没有软连接"
    fi
}

# ============================================================
#  4. 删除用户软连接
# ============================================================
delete_user_symlink() {
    local username="$1"
    local link_name="$2"

    if [[ -z "$username" ]]; then
        msg_err "用户名不能为空"
        return 1
    fi

    if [[ -z "$link_name" ]]; then
        msg_err "链接名称不能为空"
        return 1
    fi

    local user_home
    user_home=$(get_user_home "$username")
    if [[ -z "$user_home" ]]; then
        msg_err "无法获取用户主目录"
        return 1
    fi

    local link_path="$user_home/$link_name"

    if [[ ! -L "$link_path" ]]; then
        msg_err "${C_BOLD}$link_name${C_RESET} 不是符号链接或不存在"
        return 1
    fi

    local target
    target=$(readlink "$link_path")

    if priv_rm "$link_path"; then
        msg_ok "已删除软连接: ${C_BOLD}$link_name${C_RESET} → $target"
        record_user_event "$username" "symlink_delete" "删除 $link_name"
        return 0
    else
        msg_err "删除软连接失败"
        return 1
    fi
}

# ============================================================
#  5. 清理断链
# ============================================================
cleanup_broken_symlinks() {
    local username="$1"

    if [[ -z "$username" ]]; then
        msg_err "用户名不能为空"
        return 1
    fi

    local user_home
    user_home=$(get_user_home "$username")
    if [[ -z "$user_home" || ! -d "$user_home" ]]; then
        msg_err "无法获取用户主目录"
        return 1
    fi

    draw_header "清理断链 — $username"

    local cleaned=0
    while IFS= read -r -d '' link; do
        if [[ ! -e "$link" ]]; then
            local lname target
            lname=$(basename "$link")
            target=$(readlink "$link")
            priv_rm "$link"
            msg_ok "已移除断链: ${C_BOLD}$lname${C_RESET} → $target"
            ((cleaned+=1))
        fi
    done < <(find "$user_home" -maxdepth 1 -type l -print0 2>/dev/null)

    echo ""
    if [[ $cleaned -eq 0 ]]; then
        msg_info "没有发现断链"
    else
        msg_ok "共清理了 ${cleaned} 个断链"
    fi
}

# ============================================================
#  6. 创建共享目录软连接
# ============================================================
create_shared_symlink() {
    local username="$1"
    local shared_name="$2"
    local shared_path="$3"

    if [[ -z "$username" || -z "$shared_name" || -z "$shared_path" ]]; then
        msg_err "参数不完整: 用户名、共享名、共享路径"
        return 1
    fi

    if [[ ! -d "$shared_path" ]]; then
        msg_warn "共享目录不存在，正在创建..."
        if priv_mkdir -p "$shared_path"; then
            priv_chmod 775 "$shared_path"
            msg_ok "共享目录已创建: $shared_path"
        else
            msg_err "创建共享目录失败"
            return 1
        fi
    fi

    create_user_symlink "$username" "shared_${shared_name}" "$shared_path"
}

# ============================================================
#  7. 批量为用户创建共享软连接
# ============================================================
create_shared_for_all() {
    local shared_name="$1"
    local shared_path="$2"

    if [[ -z "$shared_name" || -z "$shared_path" ]]; then
        msg_err "共享名和共享路径不能为空"
        return 1
    fi

    if [[ ! -d "$shared_path" ]]; then
        if priv_mkdir -p "$shared_path"; then
            priv_chmod 775 "$shared_path"
            msg_ok "共享目录已创建: $shared_path"
        else
            msg_err "创建共享目录失败"
            return 1
        fi
    fi

    local managed_users=()
    mapfile -t managed_users < <(get_managed_usernames)

    if (( ${#managed_users[@]} == 0 )); then
        msg_warn "没有受管理的用户"
        return 0
    fi

    local success=0 failed=0
    for username in "${managed_users[@]}"; do
        if create_user_symlink "$username" "shared_${shared_name}" "$shared_path" 2>/dev/null; then
            ((success+=1))
        else
            ((failed+=1))
        fi
    done

    echo ""
    msg_info "完成: ${C_BGREEN}成功 ${success}${C_RESET}, ${C_BRED}失败 ${failed}${C_RESET}"
}

# ============================================================
#  8. 显示所有用户的软连接概览
# ============================================================
show_all_symlinks_overview() {
    draw_header "所有用户软连接概览"

    local managed_users=()
    mapfile -t managed_users < <(get_managed_usernames)

    if (( ${#managed_users[@]} == 0 )); then
        msg_warn "没有受管理的用户"
        return 0
    fi

    printf "  ${C_BOLD}${C_WHITE}%-16s %-24s %-36s %s${C_RESET}\n" \
        "用户" "链接名" "目标" "状态"
    draw_line 85

    local total_links=0
    for username in "${managed_users[@]}"; do
        local user_home
        user_home=$(get_user_home "$username")
        [[ -z "$user_home" || ! -d "$user_home" ]] && continue

        while IFS= read -r -d '' link; do
            local lname target status status_color
            lname=$(basename "$link")
            target=$(readlink "$link")

            if [[ -e "$link" ]]; then
                status="有效"
                status_color="$C_BGREEN"
            else
                status="断链"
                status_color="$C_BRED"
            fi

            printf "  ${C_BOLD}%-16s${C_RESET} ${C_CYAN}%-24s${C_RESET} %-36s ${status_color}%s${C_RESET}\n" \
                "$username" "$lname" "$target" "$status"
            ((total_links+=1))
        done < <(find "$user_home" -maxdepth 1 -type l -print0 2>/dev/null | sort -z)
    done

    echo ""
    if [[ $total_links -eq 0 ]]; then
        msg_info "没有发现软连接"
    else
        msg_info "共 $total_links 个软连接"
    fi
}
