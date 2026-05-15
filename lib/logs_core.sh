#!/bin/bash
# logs_core.sh - 统一日志读取服务
# 输出简单文本协议，presenter 负责格式化。

: "${LOGS_SYSTEM_LOG:=${SYSTEM_LOG:-./logs/system.log}}"
: "${LOGS_AUTH_LOG:=/var/log/auth.log}"
: "${JOURNALCTL_BIN:=journalctl}"
: "${SYSTEMCTL_BIN:=systemctl}"

_logs_core_source_optional() {
    local module="$1"
    local module_dir="${LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
    local module_path="$module_dir/$module"

    if [[ -f "$module_path" ]]; then
        # shellcheck disable=SC1090
        source "$module_path"
    fi
}

if ! declare -F env_has_command >/dev/null 2>&1; then
    _logs_core_source_optional "env_core.sh"
fi

if ! declare -F journalctl_normalize_unit_name >/dev/null 2>&1; then
    _logs_core_source_optional "journalctl_core.sh"
fi

logs_meta() {
    local status="${1:-ok}"
    local source_name="${2:-unknown}"
    local title="${3:-Logs}"
    local pair

    printf '__LOGS_META__ status=%s source=%s title=%s' "$status" "$source_name" "$title"

    if (($# > 3)); then
        shift 3
        for pair in "$@"; do
            [[ -n "$pair" ]] || continue
            printf ' %s' "$pair"
        done
    fi

    printf '\n'
}

logs_body_marker() {
    printf '__LOGS_BODY__\n'
}

logs_error() {
    local code="${1:-error}"
    local message="${2:-unknown error}"

    printf '__LOGS_META__ status=error source=none title=Log error\n'
    printf '__LOGS_ERROR__ code=%s message=%s\n' "$code" "$message"
    return 1
}

_logs_arg_value() {
    local name="${1:-}"
    local current

    shift || true
    while (($# > 0)); do
        current="$1"
        if [[ "$current" == "$name" ]]; then
            if (($# < 2)); then
                return 1
            fi
            printf '%s\n' "${2:-}"
            return 0
        fi
        if [[ "$current" == "$name="* ]]; then
            printf '%s\n' "${current#*=}"
            return 0
        fi
        shift
    done

    return 1
}

_logs_tail_file() {
    local file="${1:-}"
    local lines="${2:-80}"

    [[ -n "$file" && -f "$file" ]] || return 1
    tail -n "$lines" "$file" 2>/dev/null
}

logs_get_capability_status() {
    logs_meta ok env "Log capabilities"
    logs_body_marker
    env_capability_summary
}

logs_get_boot_entries() {
    local boot_ref lines

    boot_ref="$(_logs_arg_value --boot "$@" || printf '0')"
    lines="$(_logs_arg_value --lines "$@" || printf '100')"
    boot_ref="${boot_ref:-0}"
    lines="${lines:-100}"

    if ! env_has_command "$JOURNALCTL_BIN"; then
        logs_error missing-journalctl "journalctl is not available"
        return 1
    fi

    logs_meta ok journalctl "Boot logs" "boot=$boot_ref" "lines=$lines"
    logs_body_marker
    "$JOURNALCTL_BIN" -b "$boot_ref" -n "$lines" --no-pager -o short-iso 2>&1
}

logs_get_failed_units() {
    if ! env_has_command "$SYSTEMCTL_BIN"; then
        logs_error missing-systemctl "systemctl is not available"
        return 1
    fi

    logs_meta ok systemctl "Failed systemd units"
    logs_body_marker
    "$SYSTEMCTL_BIN" --failed --type=service --no-pager --plain 2>&1
}

logs_get_service_recent() {
    local unit="${1:-}"
    local lines normalized_unit

    shift || true
    lines="$(_logs_arg_value --lines "$@" || printf '80')"
    lines="${lines:-80}"

    if [[ -z "$unit" || "$unit" == -* ]]; then
        logs_error invalid-input "service unit is required"
        return 1
    fi

    normalized_unit="$(journalctl_normalize_unit_name "$unit")" || {
        logs_error invalid-input "service unit is required"
        return 1
    }

    if ! env_has_command "$JOURNALCTL_BIN"; then
        logs_error missing-journalctl "journalctl is not available"
        return 1
    fi

    logs_meta ok journalctl "Service recent logs" "unit=$normalized_unit" "lines=$lines"
    logs_body_marker
    "$JOURNALCTL_BIN" -u "$normalized_unit" -n "$lines" --no-pager -o short-iso 2>&1
}

logs_get_boot_error_diff() {
    local lines current_errors previous_errors summary

    lines="$(_logs_arg_value --lines "$@" || printf '100')"
    lines="${lines:-100}"

    if ! env_has_command "$JOURNALCTL_BIN"; then
        logs_error missing-journalctl "journalctl is not available"
        return 1
    fi

    current_errors="$(journalctl_collect_boot_errors 0 "$lines")" || current_errors=""
    previous_errors="$(journalctl_collect_boot_errors -1 "$lines")" || previous_errors=""
    summary="$(journalctl_summarize_error_diff "$current_errors" "$previous_errors")" || return 1

    logs_meta ok journalctl "Boot error diff" "lines=$lines"
    logs_body_marker
    printf '%s\n' "$summary"
}

logs_get_system_file_tail() {
    local file lines candidate

    file="$(_logs_arg_value --file "$@" || printf '%s' "$LOGS_SYSTEM_LOG")"
    lines="$(_logs_arg_value --lines "$@" || printf '120')"
    file="${file:-$LOGS_SYSTEM_LOG}"
    lines="${lines:-120}"

    for candidate in "$file" /var/log/syslog /var/log/messages /var/log/kern.log "${SYSTEM_LOG:-}"; do
        [[ -n "$candidate" ]] || continue
        if [[ -f "$candidate" ]]; then
            logs_meta ok file "System log file" "file=$candidate" "lines=$lines"
            logs_body_marker
            _logs_tail_file "$candidate" "$lines"
            return 0
        fi
    done

    logs_meta empty file "System log file" "reason=no-readable-log-file"
    logs_body_marker
    printf '没有找到可读取的系统日志文件。\n'
    return 0
}

logs_get_auth_failures() {
    local lines candidate

    lines="$(_logs_arg_value --lines "$@" || printf '50')"
    lines="${lines:-50}"

    if env_has_command "$JOURNALCTL_BIN"; then
        logs_meta ok journalctl "Authentication failures" "lines=$lines"
        logs_body_marker
        "$JOURNALCTL_BIN" -u ssh -u sshd -n "$lines" --no-pager -o short-iso 2>/dev/null | grep -F 'Failed password' || true
        return 0
    fi

    for candidate in "$LOGS_AUTH_LOG" /var/log/auth.log /var/log/secure "${LOG_DIR:-./logs}/security.log"; do
        [[ -n "$candidate" ]] || continue
        if [[ -f "$candidate" ]]; then
            logs_meta ok file "Authentication failures" "file=$candidate" "lines=$lines"
            logs_body_marker
            _logs_tail_file "$candidate" "$lines" | grep -F 'Failed password' || true
            return 0
        fi
    done

    logs_meta empty file "Authentication failures" "reason=no-auth-log"
    logs_body_marker
    printf '没有找到可读取的认证失败日志。\n'
    return 0
}
