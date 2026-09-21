#!/bin/bash
# smb_core.sh - Samba/SMB account synchronization helpers

: "${SMB_CONF:=/etc/samba/smb.conf}"
: "${SMB_SHARES_CONF:=/etc/samba/user-manager-shares.conf}"

_smb_msg_err() {
    if declare -F msg_err >/dev/null 2>&1; then
        msg_err "$*"
    else
        printf 'SMB error: %s\n' "$*" >&2
    fi
}

_smb_msg_warn() {
    if declare -F msg_warn >/dev/null 2>&1; then
        msg_warn "$*"
    else
        printf 'SMB warning: %s\n' "$*" >&2
    fi
}

smb_is_available() {
    command -v smbpasswd >/dev/null 2>&1
}

_smb_require_priv_smbpasswd() {
    if ! declare -F priv_smbpasswd >/dev/null 2>&1; then
        _smb_msg_err "SMB 同步需要 priv_smbpasswd 权限封装"
        return 1
    fi
    return 0
}

_smb_require_priv_pdbedit() {
    if ! declare -F priv_pdbedit >/dev/null 2>&1; then
        _smb_msg_err "SMB 查询需要 priv_pdbedit 权限封装"
        return 1
    fi
    return 0
}

_smb_valid_username() {
    [[ "$1" =~ ^[a-z_][a-z0-9_.-]*$ ]]
}

_smb_password_stdin() {
    local password="$1"
    printf '%s\n%s\n' "$password" "$password"
}

# Set SMB password using fallback: try existing user first, then add new
smb_set_password() {
    local username="${1:-}"
    local password="${2:-}"

    _smb_valid_username "$username" || {
        _smb_msg_err "SMB 用户名非法"
        return 1
    }
    [[ -n "$password" ]] || {
        _smb_msg_err "SMB 密码不能为空"
        return 1
    }

    smb_is_available || return 0
    _smb_require_priv_smbpasswd || return 1

    # Try existing user password change first
    if _smb_password_stdin "$password" | priv_smbpasswd -s "$username" >/dev/null 2>&1; then
        return 0
    fi

    # Fallback: add new SMB user
    if _smb_password_stdin "$password" | priv_smbpasswd -a -s "$username" >/dev/null 2>&1; then
        return 0
    fi

    _smb_msg_err "SMB 密码同步失败: $username"
    return 1
}

smb_disable_user() {
    local username="${1:-}"
    _smb_valid_username "$username" || {
        _smb_msg_err "SMB 用户名非法"
        return 1
    }
    smb_is_available || return 0
    _smb_require_priv_smbpasswd || return 1

    if priv_smbpasswd -d "$username" >/dev/null 2>&1; then
        return 0
    fi

    # User may not exist in SMB database — treat as already disabled
    return 0
}

smb_enable_existing_user() {
    local username="${1:-}"
    local output
    _smb_valid_username "$username" || {
        _smb_msg_err "SMB 用户名非法"
        return 1
    }
    smb_is_available || return 0
    _smb_require_priv_smbpasswd || return 1

    if output=$(priv_smbpasswd -e "$username" 2>&1); then
        return 0
    fi

    # User doesn't exist in SMB database — not an error
    if [[ "$output" == *"Failed to find entry"* || "$output" == *"not found"* || "$output" == *"does not exist"* ]]; then
        return 0
    fi

    _smb_msg_err "SMB 用户启用失败: $username"
    return 1
}

# Wrapper: sync password only if smb_core is loaded (reduces call-site boilerplate)
_smb_sync_password() {
    declare -F smb_set_password >/dev/null 2>&1 || return 0
    smb_set_password "$@"
}

# ============================================================
# SMB 管理扩展
# ============================================================

# 展示 SMB 服务可用性与运行状态（只读）
smb_show_status() {
    if ! smb_is_available; then
        printf 'SMB 状态: 未安装/不可用 (缺少 smbpasswd)\n'
        return 0
    fi

    printf 'SMB 状态: 可用\n'
    printf 'smbpasswd: %s\n' "$(command -v smbpasswd 2>/dev/null || printf '未找到')"

    if command -v pdbedit >/dev/null 2>&1; then
        printf 'pdbedit: %s\n' "$(command -v pdbedit 2>/dev/null || printf '未找到')"
    elif declare -F priv_pdbedit >/dev/null 2>&1; then
        printf 'pdbedit: 通过权限封装使用\n'
    else
        printf 'pdbedit: 未找到\n'
    fi

    if command -v systemctl >/dev/null 2>&1; then
        local smbd_state
        smbd_state="$(systemctl is-active smbd 2>/dev/null || printf 'unknown')"
        printf 'smbd 服务: %s\n' "$smbd_state"
    fi
    return 0
}

# 列出 SMB 用户（只读；依赖 pdbedit）
smb_list_users() {
    smb_is_available || return 0
    if ! command -v pdbedit >/dev/null 2>&1 && ! declare -F priv_pdbedit >/dev/null 2>&1; then
        _smb_msg_warn "pdbedit 不可用，无法列出 SMB 用户"
        return 0
    fi

    local output
    if declare -F priv_pdbedit >/dev/null 2>&1; then
        output=$(priv_pdbedit -L 2>/dev/null) || return 0
    else
        output=$(pdbedit -L 2>/dev/null) || return 0
    fi

    # pdbedit -L 输出格式: username:uid:fullname
    printf '%s\n' "$output" | awk -F: 'NF >= 2 {print $1}' | sort -u
}

# 查询单个 SMB 用户是否存在（只读）
smb_user_exists() {
    local username="${1:-}"
    _smb_valid_username "$username" || return 1
    smb_list_users | grep -Fx -- "$username" >/dev/null 2>&1
}

# 查询单个 SMB 用户状态（只读）
smb_show_user_status() {
    local username="${1:-}"
    _smb_valid_username "$username" || {
        _smb_msg_err "SMB 用户名非法"
        return 1
    }
    smb_is_available || {
        printf 'SMB 状态: 未安装/不可用\n'
        return 0
    }

    if smb_user_exists "$username"; then
        printf '用户 %s: SMB 账户存在\n' "$username"
    else
        printf '用户 %s: SMB 账户不存在\n' "$username"
    fi
    return 0
}

# 删除 SMB 用户账户
smb_delete_user() {
    local username="${1:-}"
    _smb_valid_username "$username" || {
        _smb_msg_err "SMB 用户名非法"
        return 1
    }
    smb_is_available || return 0
    _smb_require_priv_smbpasswd || return 1

    if priv_smbpasswd -x "$username" >/dev/null 2>&1; then
        return 0
    fi

    # 用户不存在时同样视为目标状态已达成
    return 0
}

# ============================================================
# SMB 共享目录管理
# ============================================================

_smb_valid_share_name() {
    [[ "$1" =~ ^[A-Za-z0-9_.-]+$ ]]
}

# 解析单个 Samba 配置文件中的 [share] 段，输出 "name|path"
_smb_parse_shares() {
    local conf="$1"
    [[ -r "$conf" ]] || return 0
    awk '
        /^[[:space:]]*\[[^]]+\]/ {
            if (in_share && share != "") print share "|" path
            share=$0
            sub(/^[[:space:]]*\[/, "", share)
            sub(/\][[:space:]]*$/, "", share)
            path=""
            in_share=1
            next
        }
        /^[[:space:]]*path[[:space:]]*=/ {
            if (in_share) {
                sub(/^[[:space:]]*path[[:space:]]*=[[:space:]]*/, "", $0)
                path=$0
            }
        }
        END {
            if (in_share && share != "") print share "|" path
        }
    ' "$conf"
}

# 列出 SMB 共享（解析 smb.conf 与托管 drop-in 配置中的 [share] 段）
smb_share_list() {
    local conf="${SMB_CONF:-/etc/samba/smb.conf}"
    local dropin="${SMB_SHARES_CONF:-/etc/samba/user-manager-shares.conf}"
    local merged

    merged="$(_smb_parse_shares "$conf"; _smb_parse_shares "$dropin")"
    # 同名共享以 drop-in 覆盖主配置；保持稳定输出顺序
    printf '%s\n' "$merged" | awk -F'|' '!seen[$1]++'
}

# 判断主配置是否已 include 托管 drop-in 配置
_smb_include_directive() {
    printf 'include = %s' "${SMB_SHARES_CONF:-/etc/samba/user-manager-shares.conf}"
}

# 检查主配置是否已 include 托管 drop-in 配置（只读）
smb_include_status() {
    local conf="${SMB_CONF:-/etc/samba/smb.conf}"
    local dropin="${SMB_SHARES_CONF:-/etc/samba/user-manager-shares.conf}"
    [[ -r "$conf" ]] || {
        _smb_msg_warn "无法读取 Samba 配置: $conf"
        return 1
    }
    # 匹配 include = /path/to/drop-in，容忍任意空白
    grep -Eq "^[[:space:]]*include[[:space:]]*=[[:space:]]*${dropin}([[:space:]]|$)" "$conf"
}

# 确保主配置 include 托管 drop-in 配置（幂等）
smb_ensure_include() {
    local conf="${SMB_CONF:-/etc/samba/smb.conf}"

    [[ -r "$conf" ]] || {
        _smb_msg_err "无法读取 Samba 主配置: $conf"
        return 1
    }

    # 已存在则幂等返回
    smb_include_status && return 0

    local line
    line="$(_smb_include_directive)"

    # 优先通过 priv_tee 追加，否则直接追加（测试环境无特权封装时使用）
    if declare -F priv_tee >/dev/null 2>&1; then
        printf '%s\n' "$line" | priv_tee -a "$conf" >/dev/null || {
            _smb_msg_err "写入 Samba 主配置 include 失败: $conf"
            return 1
        }
    else
        printf '%s\n' "$line" >>"$conf" || {
            _smb_msg_err "写入 Samba 主配置 include 失败: $conf"
            return 1
        }
    fi
    return 0
}

# 新增 SMB 共享（写入托管 drop-in 配置）
smb_share_add() {
    local name="$1" path="$2" readonly="${3:-no}"
    _smb_valid_share_name "$name" || {
        _smb_msg_err "共享名只能包含字母/数字/._-"
        return 1
    }
    [[ -n "$path" ]] || {
        _smb_msg_err "共享路径不能为空"
        return 1
    }
    [[ "$readonly" == "yes" || "$readonly" == "no" ]] || readonly="no"

    if [[ -f "$SMB_SHARES_CONF" ]] && grep -q "^[[:space:]]*\[$name\]" "$SMB_SHARES_CONF"; then
        _smb_msg_err "共享已存在: $name"
        return 1
    fi

    local block
    block=$(
        printf '[%s]\n' "$name"
        printf '   path = %s\n' "$path"
        printf '   browseable = yes\n'
        printf '   read only = %s\n' "$readonly"
        printf '   valid users = @users\n'
    )

    mkdir -p "$(dirname "$SMB_SHARES_CONF")" 2>/dev/null || true
    if declare -F priv_tee >/dev/null 2>&1; then
        printf '%s\n' "$block" | priv_tee -a "$SMB_SHARES_CONF" >/dev/null || return 1
    else
        printf '%s\n' "$block" >>"$SMB_SHARES_CONF" || return 1
    fi
    chmod 644 "$SMB_SHARES_CONF" 2>/dev/null || true

    # 自动确保主配置 include 该 drop-in，使共享真正生效（失败不阻断共享段写入）
    smb_ensure_include || _smb_msg_warn "共享已写入，但主配置 include 未生效，请手动检查"
    return 0
}

# 移除 SMB 共享（从托管 drop-in 配置中删除对应段）
smb_share_remove() {
    local name="$1"
    _smb_valid_share_name "$name" || {
        _smb_msg_err "共享名只能包含字母/数字/._-"
        return 1
    }
    [[ -f "$SMB_SHARES_CONF" ]] || return 0

    local tmp
    tmp=$(mktemp) || return 1
    awk -v name="$name" '
        BEGIN { skip=0 }
        /^[[:space:]]*\[[^]]+\]/ {
            if ($0 ~ "\\[" name "\\]") skip=1; else skip=0
        }
        !skip { print }
    ' "$SMB_SHARES_CONF" >"$tmp"

    if declare -F priv_tee >/dev/null 2>&1; then
        cat "$tmp" | priv_tee "$SMB_SHARES_CONF" >/dev/null || {
            rm -f "$tmp"
            return 1
        }
    else
        cat "$tmp" >"$SMB_SHARES_CONF" || {
            rm -f "$tmp"
            return 1
        }
    fi
    rm -f "$tmp"
    return 0
}
