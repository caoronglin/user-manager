#!/bin/bash
# rl_mail_config.sh - 邮件配置模块

: "${SCRIPT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
: "${DATA_DIR:=$SCRIPT_DIR/data}"
: "${EMAIL_CONFIG_FILE:=$DATA_DIR/email_config.json}"

rl_mail_msg_err() { declare -F msg_err >/dev/null 2>&1 && msg_err "$1" || printf 'ERROR: %s\n' "$1" >&2; }
rl_mail_msg_warn() { declare -F msg_warn >/dev/null 2>&1 && msg_warn "$1" || printf 'WARN: %s\n' "$1" >&2; }

rl_mail_validate_hostname() {
    local rl_host="$1"
    [[ -n "$rl_host" ]] || return 1
    [[ "$rl_host" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(\.([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?))*$ ]] && return 0
    [[ "$rl_host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0
    return 1
}

rl_mail_config_load() {
    mkdir -p "$(dirname "$EMAIL_CONFIG_FILE")" 2>/dev/null || true
    if [[ ! -f "$EMAIL_CONFIG_FILE" ]]; then
        if declare -F init_email_config >/dev/null 2>&1; then
            init_email_config
        else
            cat > "$EMAIL_CONFIG_FILE" <<'EOF'
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
        fi
    fi
    [[ -f "$EMAIL_CONFIG_FILE" ]]
}

rl_mail_config_get() {
    local rl_field="$1"
    rl_mail_config_load || return 1
    if declare -F get_email_config >/dev/null 2>&1; then
        get_email_config "$rl_field"
    elif command -v jq >/dev/null 2>&1; then
        jq -r --arg field "$rl_field" '.[$field] // empty' "$EMAIL_CONFIG_FILE" 2>/dev/null
    fi
}

rl_mail_config_validate() {
    rl_mail_config_load || { rl_mail_msg_err "邮箱配置文件不存在：$EMAIL_CONFIG_FILE"; return 1; }
    command -v jq >/dev/null 2>&1 || { rl_mail_msg_err "需要 jq 命令解析 JSON 配置"; return 1; }
    jq empty "$EMAIL_CONFIG_FILE" 2>/dev/null || { rl_mail_msg_err "邮箱配置文件 JSON 格式无效"; return 1; }

    local rl_field rl_value
    for rl_field in smtp_server smtp_port smtp_user smtp_password from_address from_name; do
        rl_value=$(jq -r --arg f "$rl_field" '.[$f] // empty' "$EMAIL_CONFIG_FILE")
        [[ -n "$rl_value" ]] || { rl_mail_msg_err "邮箱配置缺少必需字段：$rl_field"; return 1; }
    done

    local rl_smtp_port rl_smtp_server rl_from_address rl_perms
    rl_smtp_port=$(rl_mail_config_get smtp_port)
    rl_smtp_server=$(rl_mail_config_get smtp_server)
    rl_from_address=$(rl_mail_config_get from_address)
    [[ "$rl_smtp_port" =~ ^[0-9]+$ ]] && (( rl_smtp_port >= 1 && rl_smtp_port <= 65535 )) || { rl_mail_msg_err "SMTP 端口无效：$rl_smtp_port"; return 1; }
    [[ "$rl_from_address" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || { rl_mail_msg_err "发件人邮箱格式无效：$rl_from_address"; return 1; }
    rl_mail_validate_hostname "$rl_smtp_server" || { rl_mail_msg_err "SMTP 服务器地址无效或包含危险字符：$rl_smtp_server"; return 1; }

    rl_perms=$(stat -c %a "$EMAIL_CONFIG_FILE" 2>/dev/null || echo unknown)
    [[ "$rl_perms" == 600 || "$rl_perms" == 400 || "$rl_perms" == 700 ]] || rl_mail_msg_warn "邮箱配置文件权限不安全：$rl_perms (建议：600)"
    return 0
}

validate_safe_hostname() { rl_mail_validate_hostname "$@"; }
validate_email_config() { rl_mail_config_validate "$@"; }
