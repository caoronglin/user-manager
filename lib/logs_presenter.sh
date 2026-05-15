#!/bin/bash
# logs_presenter.sh - CLI/TUI 日志展示适配

_logs_presenter_source_optional() {
    local module="$1"
    local module_dir="${LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
    local module_path="$module_dir/$module"

    if [[ -f "$module_path" ]]; then
        # shellcheck disable=SC1090
        source "$module_path"
    fi
}

if ! declare -F logs_get_boot_entries >/dev/null 2>&1; then
    _logs_presenter_source_optional "logs_core.sh"
fi

_logs_percent_decode() {
    local value="${1:-}"
    local decoded=""
    local ch hex i
    local LC_ALL=C
    local LANG=C

    for ((i = 0; i < ${#value}; i++)); do
        ch="${value:i:1}"
        if [[ "$ch" == "%" && $((i + 2)) -lt ${#value} ]]; then
            hex="${value:i+1:2}"
            if [[ "$hex" =~ ^[0-9A-Fa-f]{2}$ ]]; then
                printf -v ch '%b' "\\x$hex"
                decoded+="$ch"
                ((i += 2))
                continue
            fi
        fi
        decoded+="$ch"
    done

    printf '%s' "$decoded"
}

_logs_presenter_store_pairs() {
    local -n _logs_presenter_target_map="$1"
    local -n _logs_presenter_target_order="$2"
    local fields="${3:-}"
    local pair key value
    local IFS=' '

    for pair in $fields; do
        [[ -n "$pair" ]] || continue
        if [[ "$pair" == *=* ]]; then
            key="${pair%%=*}"
            value="${pair#*=}"
        else
            key="$pair"
            value="$pair"
        fi

        if [[ -z "${_logs_presenter_target_map[$key]+_}" ]]; then
            _logs_presenter_target_order+=("$key")
        fi

        _logs_presenter_target_map["$key"]="$(_logs_percent_decode "$value")"
    done
}

_logs_presenter_parse_raw() {
    local raw="${1:-}"
    local meta_map_name="$2"
    local meta_order_name="$3"
    local error_map_name="$4"
    local error_order_name="$5"
    local body_lines_name="$6"
    local -n _logs_presenter_body_lines="$body_lines_name"
    local line in_body=0 fields

    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            '__LOGS_META__'|'__LOGS_META__ '*)
                fields="${line#__LOGS_META__ }"
                [[ "$fields" == "$line" ]] && fields="${line#__LOGS_META__}"
                _logs_presenter_store_pairs "$meta_map_name" "$meta_order_name" "$fields"
                ;;
            '__LOGS_BODY__')
                in_body=1
                ;;
            '__LOGS_ERROR__'|'__LOGS_ERROR__ '*)
                fields="${line#__LOGS_ERROR__ }"
                [[ "$fields" == "$line" ]] && fields="${line#__LOGS_ERROR__}"
                _logs_presenter_store_pairs "$error_map_name" "$error_order_name" "$fields"
                ;;
            *)
                if (( in_body )); then
                    _logs_presenter_body_lines+=("$line")
                fi
                ;;
        esac
    done <<< "$raw"
}

logs_format_empty_state() {
    local reason="${1:-empty}"
    printf '没有可显示的日志（reason=%s）\n' "$reason"
}

logs_format_capability_warning() {
    local capability="${1:-unknown}"
    printf '当前环境缺少能力: %s。请安装依赖或切换到支持的系统。\n' "$capability"
}

_logs_presenter_action_dispatch() {
    local mode="${1:-cli}"
    local action_id="${2:-}"

    shift 2 || true

    if [[ "${1:-}" == "$action_id" ]]; then
        shift
    fi

    case "$mode" in
        cli)
            logs_present_cli "$action_id" "$@"
            ;;
        tui)
            logs_present_tui "$action_id" "$@"
            ;;
        *)
            printf '未知日志 mode: %s\n' "$mode" >&2
            return 1
            ;;
    esac
}

_logs_presenter_call_core() {
    local action_id="${1:-}"

    shift || true
    case "$action_id" in
        logs.boot)
            logs_get_boot_entries "$@"
            ;;
        logs.failed_services)
            logs_get_failed_units "$@"
            ;;
        logs.service_recent)
            logs_get_service_recent "$@"
            ;;
        logs.boot_error_diff)
            logs_get_boot_error_diff "$@"
            ;;
        logs.system_file_tail)
            logs_get_system_file_tail "$@"
            ;;
        logs.auth_failures)
            logs_get_auth_failures "$@"
            ;;
        logs.capabilities|logs.status)
            logs_get_capability_status "$@"
            ;;
        *)
            printf '未知日志 action: %s\n' "$action_id" >&2
            return 1
            ;;
    esac
}

_logs_presenter_print() {
    local raw="${1:-}"
    local mode="${2:-cli}"
    local -A meta_map=()
    local -A error_map=()
    local -a meta_order=()
    local -a error_order=()
    local -a body_lines=()
    local title source status key

    if [[ -z "$raw" ]]; then
        logs_format_empty_state "empty"
        return 0
    fi

    _logs_presenter_parse_raw "$raw" meta_map meta_order error_map error_order body_lines

    title="${meta_map[title]:-Logs}"
    source="${meta_map[source]:-unknown}"
    status="${meta_map[status]:-unknown}"

    printf 'title=%s\n' "$title"
    printf 'source=%s\n' "$source"
    printf 'status=%s\n' "$status"

    for key in "${meta_order[@]}"; do
        case "$key" in
            title|source|status)
                continue
                ;;
        esac
        printf '%s=%s\n' "$key" "${meta_map[$key]}"
    done

    if ((${#error_order[@]} > 0)); then
        if [[ "${error_map[code]:-}" == missing-* ]]; then
            logs_format_capability_warning "${error_map[code]#missing-}"
        fi

        printf 'error:\n'
        for key in "${error_order[@]}"; do
            printf '%s=%s\n' "$key" "${error_map[$key]}"
        done
        return 0
    fi

    if ((${#body_lines[@]} > 0)); then
        printf 'body:\n'
        printf '%s\n' "${body_lines[@]}"
        return 0
    fi

    logs_format_empty_state "${meta_map[reason]:-$status}"
}

logs_present_cli() {
    local action_id="${1:-}"
    local raw rc

    shift || true
    if raw="$(_logs_presenter_call_core "$action_id" "$@")"; then
        rc=0
    else
        rc=$?
    fi

    if [[ -n "$raw" ]]; then
        _logs_presenter_print "$raw" cli || return 1
    elif (( rc == 0 )); then
        logs_format_empty_state "empty"
    fi

    return "$rc"
}

logs_present_tui() {
    local action_id="${1:-}"
    local raw rc

    shift || true
    if raw="$(_logs_presenter_call_core "$action_id" "$@")"; then
        rc=0
    else
        rc=$?
    fi

    if [[ -n "$raw" ]]; then
        _logs_presenter_print "$raw" tui || return 1
    elif (( rc == 0 )); then
        logs_format_empty_state "empty"
    fi

    return "$rc"
}

logs_action_cli() {
    local action_id="${1:-}"

    shift || true
    _logs_presenter_action_dispatch cli "$action_id" "$@"
}

logs_action_tui() {
    local action_id="${1:-}"

    shift || true
    _logs_presenter_action_dispatch tui "$action_id" "$@"
}

logs_action_boot_cli() {
    _logs_presenter_action_dispatch cli logs.boot "$@"
}

logs_action_boot_tui() {
    _logs_presenter_action_dispatch tui logs.boot "$@"
}

logs_action_failed_services_cli() {
    _logs_presenter_action_dispatch cli logs.failed_services "$@"
}

logs_action_failed_services_tui() {
    _logs_presenter_action_dispatch tui logs.failed_services "$@"
}

logs_action_service_recent_cli() {
    _logs_presenter_action_dispatch cli logs.service_recent "$@"
}

logs_action_service_recent_tui() {
    _logs_presenter_action_dispatch tui logs.service_recent "$@"
}

logs_action_boot_error_diff_cli() {
    _logs_presenter_action_dispatch cli logs.boot_error_diff "$@"
}

logs_action_boot_error_diff_tui() {
    _logs_presenter_action_dispatch tui logs.boot_error_diff "$@"
}

logs_action_system_file_tail_cli() {
    _logs_presenter_action_dispatch cli logs.system_file_tail "$@"
}

logs_action_system_file_tail_tui() {
    _logs_presenter_action_dispatch tui logs.system_file_tail "$@"
}

logs_action_auth_failures_cli() {
    _logs_presenter_action_dispatch cli logs.auth_failures "$@"
}

logs_action_auth_failures_tui() {
    _logs_presenter_action_dispatch tui logs.auth_failures "$@"
}
