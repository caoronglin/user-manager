#!/bin/bash
# systemd_timer_core.sh - systemd timer 管理核心模块

: "${SYSTEMD_TIMER_UNIT_DIR:=/etc/systemd/system}"
: "${SYSTEMD_TIMER_STATE_DIR:=/var/lib/systemd-timer-core}"
: "${SYSTEMD_TIMER_SYSTEMCTL_BIN:=systemctl}"
: "${SYSTEMD_TIMER_JOURNALCTL_BIN:=journalctl}"

_systemd_timer_msg_err() {
    if declare -F msg_err >/dev/null 2>&1; then
        msg_err "$*"
    else
        printf 'ERROR: %s\n' "$*" >&2
    fi
}

_systemd_timer_run_command() {
    if [[ $# -eq 0 ]]; then
        return 1
    fi

    if declare -F run_privileged >/dev/null 2>&1; then
        run_privileged "$@"
    else
        "$@"
    fi
}

_systemd_timer_systemctl() {
    if declare -F priv_systemctl >/dev/null 2>&1; then
        priv_systemctl "$@"
    else
        _systemd_timer_run_command "$SYSTEMD_TIMER_SYSTEMCTL_BIN" "$@"
    fi
}

_systemd_timer_normalize_base_name() {
    local name="${1:-}"

    if [[ -z "$name" ]]; then
        return 1
    fi

    name="${name%.timer}"
    name="${name%.service}"
    printf '%s\n' "$name"
}

_systemd_timer_require_profile() {
    case "${1:-}" in
        weekly-report|account-health-check)
            return 0
            ;;
    esac

    _systemd_timer_msg_err "不支持的 timer profile: ${1:-<empty>}"
    return 1
}

_systemd_timer_profile_service_description() {
    case "$1" in
        weekly-report) printf '%s\n' 'Managed User Weekly Report' ;;
        account-health-check) printf '%s\n' 'Managed User Account Health Check' ;;
    esac
}

_systemd_timer_profile_service_exec_start() {
    local manager_entry
    manager_entry="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/run.sh"

    case "$1" in
        weekly-report)
            printf "/bin/bash %q --weekly-report\n" "$manager_entry"
            ;;
        account-health-check)
            printf "/bin/bash %q --account-health-check\n" "$manager_entry"
            ;;
    esac
}

_systemd_timer_profile_timer_description() {
    case "$1" in
        weekly-report) printf '%s\n' 'Weekly schedule for managed user report' ;;
        account-health-check) printf '%s\n' 'Daily schedule for managed user account health check' ;;
    esac
}

_systemd_timer_profile_on_calendar() {
    case "$1" in
        weekly-report) printf '%s\n' 'weekly' ;;
        account-health-check) printf '%s\n' 'daily' ;;
    esac
}

_systemd_timer_profile_randomized_delay() {
    case "$1" in
        weekly-report) printf '%s\n' '30m' ;;
        account-health-check) printf '%s\n' '15m' ;;
    esac
}

_systemd_timer_write_unit_file() {
    local target_path="$1"
    local content="$2"

    _systemd_timer_run_command mkdir -p "$(dirname "$target_path")" || return 1
    printf '%s' "$content" | _systemd_timer_run_command tee "$target_path" >/dev/null || return 1
}

systemd_timer_generate_service_unit() {
    local unit_name="${1:-}"
    local description="${2:-}"
    local exec_start="${3:-}"

    if [[ -z "$unit_name" || -z "$description" || -z "$exec_start" ]]; then
        _systemd_timer_msg_err "生成 service unit 缺少必要参数"
        return 1
    fi

    cat <<EOF
[Unit]
Description=$description
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$exec_start

[Install]
WantedBy=multi-user.target
EOF
}

systemd_timer_generate_timer_unit() {
    local unit_name="${1:-}"
    local description="${2:-}"
    local on_calendar="${3:-}"
    local service_unit="${4:-}"
    local persistent="${5:-true}"
    local randomized_delay="${6:-}"

    if [[ -z "$unit_name" || -z "$description" || -z "$on_calendar" || -z "$service_unit" ]]; then
        _systemd_timer_msg_err "生成 timer unit 缺少必要参数"
        return 1
    fi

    cat <<EOF
[Unit]
Description=$description

[Timer]
OnCalendar=$on_calendar
Unit=$service_unit
Persistent=$persistent
EOF

    if [[ -n "$randomized_delay" ]]; then
        printf 'RandomizedDelaySec=%s\n' "$randomized_delay"
    fi

    cat <<'EOF'

[Install]
WantedBy=timers.target
EOF
}

systemd_timer_render_profile_service() {
    local profile="${1:-}"

    _systemd_timer_require_profile "$profile" || return 1
    systemd_timer_generate_service_unit \
        "$profile" \
        "$(_systemd_timer_profile_service_description "$profile")" \
        "$(_systemd_timer_profile_service_exec_start "$profile")"
}

systemd_timer_render_profile_timer() {
    local profile="${1:-}"

    _systemd_timer_require_profile "$profile" || return 1
    systemd_timer_generate_timer_unit \
        "$profile" \
        "$(_systemd_timer_profile_timer_description "$profile")" \
        "$(_systemd_timer_profile_on_calendar "$profile")" \
        "$profile.service" \
        "true" \
        "$(_systemd_timer_profile_randomized_delay "$profile")"
}

systemd_timer_install_profile() {
    local profile="${1:-}"
    local service_path timer_path

    _systemd_timer_require_profile "$profile" || return 1
    _systemd_timer_run_command mkdir -p "$SYSTEMD_TIMER_STATE_DIR" || return 1

    service_path="$SYSTEMD_TIMER_UNIT_DIR/$profile.service"
    timer_path="$SYSTEMD_TIMER_UNIT_DIR/$profile.timer"

    _systemd_timer_write_unit_file "$service_path" "$(systemd_timer_render_profile_service "$profile")" || return 1
    _systemd_timer_write_unit_file "$timer_path" "$(systemd_timer_render_profile_timer "$profile")" || return 1

    _systemd_timer_systemctl daemon-reload || return 1
    _systemd_timer_systemctl enable "$profile.timer" || return 1
    _systemd_timer_systemctl start "$profile.timer" || return 1
}

systemd_timer_list_timers() {
    _systemd_timer_run_command "$SYSTEMD_TIMER_SYSTEMCTL_BIN" list-timers --all --no-pager
}

systemd_timer_show_logs() {
    local name lines base_name

    name="${1:-}"
    lines="${2:-50}"
    base_name="$(_systemd_timer_normalize_base_name "$name")" || {
        _systemd_timer_msg_err "未指定 timer 名称"
        return 1
    }

    _systemd_timer_run_command "$SYSTEMD_TIMER_JOURNALCTL_BIN" -u "$base_name.service" -n "$lines" --no-pager -o short-iso
}

systemd_timer_remove() {
    local name base_name service_path timer_path

    name="${1:-}"
    base_name="$(_systemd_timer_normalize_base_name "$name")" || {
        _systemd_timer_msg_err "未指定 timer 名称"
        return 1
    }

    service_path="$SYSTEMD_TIMER_UNIT_DIR/$base_name.service"
    timer_path="$SYSTEMD_TIMER_UNIT_DIR/$base_name.timer"

    _systemd_timer_systemctl stop "$base_name.timer" >/dev/null 2>&1 || true
    _systemd_timer_systemctl disable "$base_name.timer" >/dev/null 2>&1 || true
    _systemd_timer_systemctl stop "$base_name.service" >/dev/null 2>&1 || true

    _systemd_timer_run_command rm -f "$timer_path" "$service_path" || return 1

    _systemd_timer_systemctl daemon-reload || return 1
}
