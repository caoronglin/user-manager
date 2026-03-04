#!/bin/bash
# miniforge_core.sh - Miniforge 安装与管理模块 v0.2.1
# 提供自动安装、配置、卸载等功能

# ============================================================
# 前置检查
# ============================================================

# 检查 Miniforge 安装器是否存在
check_miniforge_installer() {
    if [[ ! -f "$MINIFORGE_INSTALLER" ]]; then
        msg_err "Miniforge 安装器不存在: $MINIFORGE_INSTALLER"
        msg_info "请将 Miniforge.sh 安装器放置到项目根目录"
        return 1
    fi

    if [[ ! -x "$MINIFORGE_INSTALLER" ]]; then
        msg_warn "安装器文件不可执行，正在添加执行权限..."
        chmod +x "$MINIFORGE_INSTALLER" || {
            msg_err "无法添加执行权限"
            return 1
        }
    fi

    # 如果是符号链接，解析真实路径
    if [[ -L "$MINIFORGE_INSTALLER" ]]; then
        MINIFORGE_INSTALLER=$(readlink -f "$MINIFORGE_INSTALLER")
        msg_debug "安装器实际路径: $MINIFORGE_INSTALLER"
    fi

    return 0
}

# 检查磁盘空间（至少 3GB）
check_disk_space_for_miniforge() {
    local path="$1"
    local required_gb=3
    
    # 获取路径所在挂载点
    local mount_point
    mount_point=$(df "$path" 2>/dev/null | awk 'NR==2 {print $NF}')
    
    if [[ -z "$mount_point" ]]; then
        msg_warn "无法确定挂载点，跳过磁盘空间检查"
        return 0
    fi
    
    # 获取可用空间（GB）
    local available_kb available_gb
    available_kb=$(df -k "$mount_point" 2>/dev/null | awk 'NR==2 {print $4}')
    available_gb=$((available_kb / 1024 / 1024))
    
    if (( available_gb < required_gb )); then
        msg_err "磁盘空间不足: 需要 ${required_gb}GB，可用 ${available_gb}GB"
        return 1
    fi
    
    msg_debug "磁盘空间检查通过: ${available_gb}GB 可用"
    return 0
}

# ============================================================
# 安装功能
# ============================================================

# 为用户安装 Miniforge
# 参数: username, install_path (相对于用户主目录)
install_miniforge_for_user() {
    local username="$1"
    local install_path="${2:-$MINIFORGE_DEFAULT_PATH}"
    
    # 验证用户存在
    if ! id "$username" &>/dev/null; then
        msg_err "用户不存在: $username"
        return 1
    fi
    
    # 获取用户主目录
    local user_home
    user_home=$(get_user_home "$username")
    
    if [[ -z "$user_home" ]]; then
        msg_err "无法获取用户主目录: $username"
        return 1
    fi
    
    # 构建完整安装路径
    local full_install_path
    if [[ "$install_path" == /* ]]; then
        # 绝对路径
        full_install_path="$install_path"
    else
        # 相对路径，相对于用户主目录
        full_install_path="${user_home}/${install_path}"
    fi
    
    # 检查安装器
    if ! check_miniforge_installer; then
        return 1
    fi
    
    # 检查磁盘空间
    if ! check_disk_space_for_miniforge "$user_home"; then
        return 1
    fi
    
    # 检查是否已存在安装
    if [[ -d "$full_install_path" ]]; then
        msg_warn "检测到已有 Miniforge 安装: $full_install_path"
        if ! confirm_action "是否覆盖安装？"; then
            msg_info "跳过 Miniforge 安装"
            return 0
        fi
        msg_step "删除旧安装..."
        rm -rf "$full_install_path"
    fi
    
    msg_step "为用户 ${C_BOLD}$username${C_RESET} 安装 Miniforge..."
    msg_info "安装路径: $full_install_path"
    
    # 执行安装器（批量模式）
    msg_info "执行安装器（这可能需要几分钟）..."
    
    if ! bash "$MINIFORGE_INSTALLER" -b -p "$full_install_path" 2>&1 | while read -r line; do
        # 只显示关键信息
        if [[ "$line" =~ (ERROR|PREFIX|installation\ finished) ]]; then
            msg_info "  $line"
        fi
    done; then
        msg_err "Miniforge 安装失败"
        rm -rf "$full_install_path"
        return 1
    fi
    
    # 验证安装
    if [[ ! -f "${full_install_path}/bin/conda" ]]; then
        msg_err "安装验证失败: conda 命令不存在"
        rm -rf "$full_install_path"
        return 1
    fi
    
    # 设置正确的所有者和权限
    priv_chown -R "$username:$username" "$full_install_path"
    msg_ok "Miniforge 安装完成"
    
    # 配置 .condarc
    configure_condarc_for_user "$username" "$full_install_path"
    
    # 设置 shell 集成
    setup_conda_shell_integration "$username" "$full_install_path" "$user_home"
    
    # 记录事件
    record_user_event "$username" "miniforge_install" "Miniforge" "" "$full_install_path"
    
    msg_ok "Miniforge 已为用户 $username 安装成功"
    msg_info "用户需要重启 shell 或运行: source ~/.bashrc"
    
    return 0
}

# 配置 .condarc 文件
configure_condarc_for_user() {
    local username="$1"
    local miniforge_path="$2"
    
    local condarc_path="${miniforge_path}/.condarc"
    
    msg_step "配置 Conda 环境..."
    
    # 检查模板文件
    if [[ ! -f "$CONDARC_TEMPLATE" ]]; then
        msg_warn "配置模板不存在: $CONDARC_TEMPLATE"
        msg_info "使用默认配置..."
        
        # 创建默认配置
        cat > "$condarc_path" << 'EOF'
channels:
  - defaults
  - conda-forge
  - bioconda
show_channel_urls: true
default_channels:
  - https://mirrors.ustc.edu.cn/anaconda/pkgs/main
  - https://mirrors.ustc.edu.cn/anaconda/pkgs/r
  - https://mirrors.ustc.edu.cn/anaconda/pkgs/msys2
custom_channels:
  conda-forge: https://mirrors.ustc.edu.cn/anaconda/cloud
  pytorch: https://mirrors.ustc.edu.cn/anaconda/cloud
  bioconda: https://mirrors.ustc.edu.cn/anaconda/cloud/bioconda
auto_activate_base: false
EOF
    else
        # 使用模板
        cp "$CONDARC_TEMPLATE" "$condarc_path"
        msg_ok "使用配置模板: $CONDARC_TEMPLATE"
    fi
    
    # 设置权限
    priv_chown "$username:$username" "$condarc_path"
    chmod 644 "$condarc_path"
    
    msg_ok "Conda 配置完成: $condarc_path"
    return 0
}

# 设置 conda shell 集成
setup_conda_shell_integration() {
    local username="$1"
    local miniforge_path="$2"
    local user_home="$3"
    
    msg_step "设置 Shell 集成..."
    
    # 检测用户的 shell
    local user_shell
    user_shell=$(getent passwd "$username" | cut -d: -f7)
    local shell_rc=""
    local shell_name=""
    
    case "${user_shell##*/}" in
        bash)
            shell_rc="${user_home}/.bashrc"
            shell_name="bash"
            ;;
        zsh)
            shell_rc="${user_home}/.zshrc"
            shell_name="zsh"
            ;;
        fish)
            shell_rc="${user_home}/.config/fish/config.fish"
            shell_name="fish"
            ;;
        *)
            msg_warn "不支持的 shell: ${user_shell##*/}"
            msg_info "用户需要手动运行: ${miniforge_path}/bin/conda init"
            return 0
            ;;
    esac
    
    # 检查是否已经初始化
    if [[ -f "$shell_rc" ]] && grep -q "conda initialize" "$shell_rc" 2>/dev/null; then
        msg_warn "Conda 已经在 $shell_rc 中初始化"
        return 0
    fi
    
    # 执行 conda init（以用户身份）
    msg_info "初始化 $shell_name..."
    
    # 创建临时脚本执行 conda init
    local init_script
    init_script=$(mktemp) || {
        msg_err "无法创建临时脚本"
        return 1
    }
    
    if ! cat > "$init_script" << EOF
#!/bin/bash
export PATH="${miniforge_path}/bin:\$PATH"
"${miniforge_path}/bin/conda" init $shell_name
EOF
    then
        rm -f "$init_script"
        msg_err "临时脚本写入失败"
        return 1
    fi
    
    chmod +x "$init_script"
    
    # 以用户身份执行
    if run_privileged -u "$username" bash "$init_script" &>/dev/null; then
        msg_ok "Shell 集成完成 ($shell_name)"
    else
        # 如果失败，尝试手动添加
        msg_warn "自动初始化失败，手动添加配置..."
        
        local conda_init_block
        conda_init_block=$(cat << EOF
# >>> conda initialize >>>
# !! Contents within this block are managed by 'conda init' !!
if [ -f "${miniforge_path}/etc/profile.d/conda.sh" ]; then
    . "${miniforge_path}/etc/profile.d/conda.sh"
else
    export PATH="${miniforge_path}/bin:\$PATH"
fi
# <<< conda initialize <<<
EOF
        )
        
        echo "" >> "$shell_rc"
        echo "$conda_init_block" >> "$shell_rc"
        priv_chown "$username:$username" "$shell_rc"
        
        msg_ok "手动添加 Shell 配置完成"
    fi
    
    rm -f "$init_script"
    return 0
}

# ============================================================
# 验证功能
# ============================================================

# 验证 Miniforge 安装
verify_miniforge_installation() {
    local username="$1"
    
    local user_home
    user_home=$(get_user_home "$username")
    
    if [[ -z "$user_home" ]]; then
        msg_err "用户不存在或无主目录: $username"
        return 1
    fi
    
    local miniforge_path="${user_home}/${MINIFORGE_DEFAULT_PATH}"
    
    echo ""
    draw_header "Miniforge 安装验证"
    draw_info_card "用户:" "$username" "$C_BOLD"
    draw_info_card "安装路径:" "$miniforge_path"
    
    local all_ok=true
    
    # 检查安装目录
    echo ""
    msg_info "检查安装目录..."
    if [[ -d "$miniforge_path" ]]; then
        msg_ok "安装目录存在"
    else
        msg_err "安装目录不存在"
        all_ok=false
    fi
    
    # 检查 conda 命令
    echo ""
    msg_info "检查 Conda 命令..."
    if [[ -x "${miniforge_path}/bin/conda" ]]; then
        local conda_version
        conda_version=$("${miniforge_path}/bin/conda" --version 2>/dev/null || echo "unknown")
        msg_ok "Conda 可执行: $conda_version"
    else
        msg_err "Conda 命令不存在或不可执行"
        all_ok=false
    fi
    
    # 检查配置文件
    echo ""
    msg_info "检查配置文件..."
    if [[ -f "${miniforge_path}/.condarc" ]]; then
        msg_ok "配置文件存在"
        local channels
        channels=$(grep -A 3 "^channels:" "${miniforge_path}/.condarc" 2>/dev/null || echo "")
        if [[ -n "$channels" ]]; then
            msg_info "配置的 channels:"
            echo "$channels" | while read -r line; do
                echo "    $line"
            done
        fi
    else
        msg_warn "配置文件不存在（使用默认配置）"
    fi
    
    # 检查 shell 集成
    echo ""
    msg_info "检查 Shell 集成..."
    local shell_rc="${user_home}/.bashrc"
    if [[ -f "$shell_rc" ]] && grep -q "conda initialize" "$shell_rc" 2>/dev/null; then
        msg_ok "Shell 集成已完成"
    else
        msg_warn "Shell 集成未完成"
        msg_info "用户需要运行: source ~/.bashrc"
    fi
    
    # 总结
    echo ""
    if [[ "$all_ok" == true ]]; then
        msg_ok "✓ Miniforge 安装验证通过"
    else
        msg_err "✗ Miniforge 安装存在问题"
    fi
    
    return 0
}

# ============================================================
# 卸载功能
# ============================================================

# 为用户卸载 Miniforge
uninstall_miniforge_for_user() {
    local username="$1"
    
    if ! id "$username" &>/dev/null; then
        msg_err "用户不存在: $username"
        return 1
    fi
    
    local user_home
    user_home=$(get_user_home "$username")
    
    if [[ -z "$user_home" ]]; then
        msg_err "无法获取用户主目录: $username"
        return 1
    fi
    
    local miniforge_path="${user_home}/${MINIFORGE_DEFAULT_PATH}"
    
    if [[ ! -d "$miniforge_path" ]]; then
        msg_warn "Miniforge 未安装: $miniforge_path"
        return 0
    fi
    
    msg_step "卸载用户 $username 的 Miniforge..."
    
    # 删除安装目录
    msg_info "删除安装目录: $miniforge_path"
    rm -rf "$miniforge_path"
    
    # 清理 shell 配置
    local shell_rc="${user_home}/.bashrc"
    if [[ -f "$shell_rc" ]]; then
        msg_info "清理 Shell 配置..."
        # 删除 conda 初始化块
        sed -i '/# >>> conda initialize >>>/,/# <<< conda initialize <<</d' "$shell_rc"
    fi
    
    # 记录事件
    record_user_event "$username" "miniforge_uninstall" "Miniforge" "" "$miniforge_path"
    
    msg_ok "Miniforge 已卸载"
    return 0
}

# ============================================================
# 信息查询
# ============================================================

# 检查用户是否安装了 Miniforge
has_miniforge_installed() {
    local username="$1"
    
    local user_home
    user_home=$(get_user_home "$username")
    
    if [[ -z "$user_home" ]]; then
        return 1
    fi
    
    local miniforge_path="${user_home}/${MINIFORGE_DEFAULT_PATH}"
    
    [[ -d "$miniforge_path" ]] && [[ -x "${miniforge_path}/bin/conda" ]]
}

# 获取用户的 Miniforge 安装路径
get_user_miniforge_path() {
    local username="$1"
    
    local user_home
    user_home=$(get_user_home "$username")
    
    if [[ -z "$user_home" ]]; then
        return 1
    fi
    
    echo "${user_home}/${MINIFORGE_DEFAULT_PATH}"
}
