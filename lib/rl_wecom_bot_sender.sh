#!/bin/bash
# rl_wecom_bot_sender.sh - 企业微信 Bot 通知预留接口（默认关闭）

rl_wecom_msg() {
    local rl_fn="$1"
    shift
    declare -F "$rl_fn" >/dev/null 2>&1 && "$rl_fn" "$*" || printf '%s\n' "$*" >&2
}

rl_wecom_is_enabled() {
    [[ "${USER_MANAGER_WECOM_ENABLED:-0}" == "1" || "${USER_MANAGER_WECOM_ENABLED:-}" == "true" ]]
}

rl_wecom_is_dry_run() {
    [[ "${USER_MANAGER_WECOM_DRY_RUN:-1}" != "0" && "${USER_MANAGER_WECOM_DRY_RUN:-}" != "false" ]]
}

rl_wecom_validate_webhook() {
    [[ "${1:-}" =~ ^https://qyapi\.weixin\.qq\.com/cgi-bin/webhook/send\?key=[A-Za-z0-9_-]+$ ]]
}

rl_wecom_mask_secret() {
    local rl_value="${1:-}"
    printf '%s' "$rl_value" | sed -E \
        -e 's/(key=)[^&[:space:]"'"'"']+/\1***/g' \
        -e 's/("(password|token|webhook|secret|key)"[[:space:]]*:[[:space:]]*")[^"]*(")/\1***\3/g'
}

rl_wecom_json_escape() {
    local rl_value="${1:-}"
    rl_value="${rl_value//\\/\\\\}"
    rl_value="${rl_value//\"/\\\"}"
    rl_value="${rl_value//$'\n'/\\n}"
    rl_value="${rl_value//$'\r'/}"
    rl_value="${rl_value//$'\t'/\\t}"
    printf '%s' "$rl_value"
}

rl_wecom_event_allowed() {
    local rl_event="${1:-}"
    local rl_events="${USER_MANAGER_WECOM_EVENTS:-}"
    [[ -n "$rl_event" ]] || return 1
    [[ -z "$rl_events" ]] && return 0
    local IFS=',' rl_allowed
    for rl_allowed in $rl_events; do
        [[ "$rl_allowed" == "$rl_event" ]] && return 0
    done
    return 1
}

rl_wecom_payload_from_text() {
    local rl_text="$1"
    printf '{"msgtype":"text","text":{"content":"%s"}}' "$(rl_wecom_json_escape "$rl_text")"
}

rl_wecom_bot_send_text() {
    local rl_event_type="$1" rl_payload_json="${2:-{}}"

    if ! rl_wecom_is_enabled; then
        rl_wecom_msg msg_info "企业微信 Bot 未启用，跳过通知"
        return 0
    fi

    if ! rl_wecom_event_allowed "$rl_event_type"; then
        rl_wecom_msg msg_info "企业微信 Bot 事件未允许，跳过: $rl_event_type"
        return 0
    fi

    local rl_webhook="${USER_MANAGER_WECOM_WEBHOOK:-}"
    if [[ -z "$rl_webhook" ]]; then
        rl_wecom_msg msg_warn "企业微信 Bot webhook 未配置，跳过通知"
        return 0
    fi

    if ! rl_wecom_validate_webhook "$rl_webhook"; then
        rl_wecom_msg msg_err "企业微信 Bot webhook 非法: $(rl_wecom_mask_secret "$rl_webhook")"
        return 1
    fi

    local rl_safe_payload rl_body
    rl_safe_payload="$(rl_wecom_mask_secret "$rl_payload_json")"
    rl_body="$(rl_wecom_payload_from_text "[$rl_event_type] $rl_safe_payload")"

    if rl_wecom_is_dry_run; then
        rl_wecom_msg msg_info "企业微信 Bot dry-run: $(rl_wecom_mask_secret "$rl_webhook")"
        return 0
    fi

    command -v curl >/dev/null 2>&1 || { rl_wecom_msg msg_err "curl 不可用，无法发送企业微信通知"; return 1; }
    curl --silent --show-error --fail --max-time 5 \
        -H 'Content-Type: application/json' \
        -d "$rl_body" \
        "$rl_webhook" >/dev/null
}

rl_notify_send() {
    local rl_channel="$1" rl_event_type="$2" rl_payload_json="${3:-{}}"
    case "$rl_channel" in
        wecom|wecom_bot) rl_wecom_bot_send_text "$rl_event_type" "$rl_payload_json" ;;
        *) return 1 ;;
    esac
}
