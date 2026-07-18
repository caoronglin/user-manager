#!/bin/bash
# smb_core.sh - Samba/SMB account synchronization helpers

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

_smb_password_stdin() {
    local password="$1"
    printf '%s\n%s\n' "$password" "$password"
}

# Set SMB password using fallback: try existing user first, then add new
smb_set_password() {
    local username="${1:-}"
    local password="${2:-}"

    [[ -n "$username" ]] || { _smb_msg_err "SMB 用户名不能为空"; return 1; }
    [[ -n "$password" ]] || { _smb_msg_err "SMB 密码不能为空"; return 1; }

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
    [[ -n "$username" ]] || { _smb_msg_err "SMB 用户名不能为空"; return 1; }
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
    [[ -n "$username" ]] || { _smb_msg_err "SMB 用户名不能为空"; return 1; }
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
