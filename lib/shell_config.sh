#!/bin/bash
# shell_config.sh - Shell配置管理模块 v1.0.0
# 提供模块化的shell配置模板系统

set -uo pipefail

# ============================================================
# 配置常量
# ============================================================

# 模板目录
readonly SHELL_TEMPLATES_DIR="${SCRIPT_DIR:-.}/templates/shell"

# ============================================================
# 主函数
# ============================================================

# 初始化Shell配置
# 参数: $1=用户名, $2=shell类型(bash/zsh/fish), $3=选项JSON
init_shell_config() {
    local username="$1"
    local shell_type="${2:-bash}"
    local options="${3:-{}}"
    
    # 验证用户存在
    if ! id "$username" &>/dev/null; then
        msg_err "用户不存在: $username"
        return 1
    fi
    
    # 获取用户home目录
    local user_home
    user_home=$(getent passwd "$username" | cut -d: -f6)
    
    if [[ -z "$user_home" ]]; then
        msg_err "无法获取用户主目录"
        return 1
    fi
    
    # 确定配置文件
    local config_file
    case "$shell_type" in
        bash) config_file="$user_home/.bashrc" ;;
        zsh)  config_file="$user_home/.zshrc" ;;
        fish) config_file="$user_home/.config/fish/config.fish" ;;
        *)
            msg_err "不支持的shell类型: $shell_type"
            return 1
            ;;
    esac
    
    # 应用基础模板
    apply_base_template "$shell_type" "$config_file" "$username"
    
    # 解析选项
    if command -v jq &>/dev/null && [[ "$options" != "{}" ]]; then
        # Miniforge
        if [[ "$(echo "$options" | jq -r '.miniforge // false')" == "true" ]]; then
            local miniforge_path
            miniforge_path=$(echo "$options" | jq -r '.miniforge_path // ".miniforge"')
            apply_miniforge_config "$shell_type" "$config_file" "$user_home" "$miniforge_path"
        fi
    fi
    
    # 设置权限
    priv_chown "$username:$username" "$config_file"
    
    msg_ok "Shell配置初始化完成: $shell_type"
    return 0
}

# ============================================================
# 模板应用
# ============================================================

# 应用基础模板
apply_base_template() {
    local shell_type="$1"
    local config_file="$2"
    local username="$3"
    
    local template_file="$SHELL_TEMPLATES_DIR/${shell_type}/base.${shell_type}rc"
    
    # 如果模板不存在，使用默认配置
    if [[ ! -f "$template_file" ]]; then
        generate_default_config "$shell_type" "$config_file" "$username"
        return 0
    fi
    
    # 读取并渲染模板
    local content
    content=$(cat "$template_file")
    content="${content//\{\{USERNAME\}\}/$username}"
    content="${content//\{\{HOME\}\}/$(dirname "$config_file")}"
    
    # 追加到配置文件（不覆盖现有配置）
    {
        echo ""
        echo "# === User Manager Configuration ==="
        echo "$content"
        echo "# === End User Manager Configuration ==="
    } >> "$config_file"
}

# 生成默认配置
generate_default_config() {
    local shell_type="$1"
    local config_file="$2"
    local username="$3"
    
    local default_config
    case "$shell_type" in
        bash)
            default_config='
# User aliases
alias ll="ls -lah"
alias la="ls -A"
alias l="ls -CF"
alias ..="cd .."
alias ...="cd ../.."
alias grep="grep --color=auto"

# Prompt
PS1="\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ "

# History
HISTSIZE=10000
HISTFILESIZE=20000
HISTCONTROL=ignoreboth
shopt -s histappend
'
            ;;
        zsh)
            default_config='
# User aliases
alias ll="ls -lah"
alias la="ls -A"
alias l="ls -CF"
alias ..="cd .."
alias ...="cd ../.."

# History
HISTSIZE=10000
SAVEHIST=10000
setopt HIST_IGNORE_DUPS
setopt SHARE_HISTORY
'
            ;;
        fish)
            default_config='
# User aliases
alias ll "ls -lah"
alias la "ls -A"
alias l "ls -CF"
alias .. "cd .."
alias ... "cd ../.."
'
            ;;
    esac
    
    {
        echo ""
        echo "# === User Manager Configuration ==="
        echo "$default_config"
        echo "# === End User Manager Configuration ==="
    } >> "$config_file"
}

# 应用Miniforge配置
apply_miniforge_config() {
    local shell_type="$1"
    local config_file="$2"
    local user_home="$3"
    local miniforge_path="$4"
    
    local conda_init_block
    case "$shell_type" in
        bash|zsh)
            conda_init_block="
# >>> conda initialize >>>
# !! Contents within this block are managed by 'conda init' !!
if [ -f \"$user_home/$miniforge_path/etc/profile.d/conda.sh\" ]; then
    . \"$user_home/$miniforge_path/etc/profile.d/conda.sh\"
else
    export PATH=\"$user_home/$miniforge_path/bin:\$PATH\"
fi
# <<< conda initialize <<<
"
            ;;
        fish)
            conda_init_block="
# >>> conda initialize >>>
if test -f \"$user_home/$miniforge_path/etc/fish/conf.d/conda.fish\"
    source \"$user_home/$miniforge_path/etc/fish/conf.d/conda.fish\"
else
    set -gx PATH \"$user_home/$miniforge_path/bin\" \$PATH
end
# <<< conda initialize <<<
"
            ;;
    esac
    
    echo "$conda_init_block" >> "$config_file"
}

# ============================================================
# 验证函数
# ============================================================

# 验证Shell配置
verify_shell_config() {
    local username="$1"
    
    if ! id "$username" &>/dev/null; then
        return 1
    fi
    
    local user_home
    user_home=$(getent passwd "$username" | cut -d: -f6)
    if [[ -z "$user_home" ]]; then
        return 1
    fi
    
    # 检查配置文件
    [[ -f "$user_home/.bashrc" ]] || \
        [[ -f "$user_home/.zshrc" ]] || \
        [[ -f "$user_home/.config/fish/config.fish" ]]
}
