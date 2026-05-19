#!/bin/bash
# action_registry.sh - TUI/CLI 共用动作表与分发器

declare -p _ACTION_LABEL >/dev/null 2>&1 || declare -Ag _ACTION_LABEL=()
declare -p _ACTION_GROUP >/dev/null 2>&1 || declare -Ag _ACTION_GROUP=()
declare -p _ACTION_HANDLER >/dev/null 2>&1 || declare -Ag _ACTION_HANDLER=()
declare -p _ACTION_REQUIRES >/dev/null 2>&1 || declare -Ag _ACTION_REQUIRES=()
declare -p _ACTION_MODES >/dev/null 2>&1 || declare -Ag _ACTION_MODES=()
declare -p _ACTION_RISK >/dev/null 2>&1 || declare -Ag _ACTION_RISK=()

action_registry_reset() {
    _ACTION_LABEL=()
    _ACTION_GROUP=()
    _ACTION_HANDLER=()
    _ACTION_REQUIRES=()
    _ACTION_MODES=()
    _ACTION_RISK=()
    ACTION_DEFAULTS_REGISTERED=0
}

action_register() {
    local id="${1:-}" label="${2:-}" group="${3:-}" handler="${4:-}"
    local requires="${5:-none}" modes="${6:-both}" risk="${7:-safe}"

    if [[ -z "$id" || -z "$label" || -z "$group" || -z "$handler" ]]; then
        printf 'action_register: id/label/group/handler 不能为空\n' >&2
        return 1
    fi

    _ACTION_LABEL["$id"]="$label"
    _ACTION_GROUP["$id"]="$group"
    _ACTION_HANDLER["$id"]="$handler"
    _ACTION_REQUIRES["$id"]="$requires"
    _ACTION_MODES["$id"]="$modes"
    _ACTION_RISK["$id"]="$risk"
}

action_exists() {
    local id="${1:-}"

    [[ -n "$id" ]] || return 1
    [[ -n "${_ACTION_HANDLER[$id]:-}" ]]
}

action_mode_supported() {
    local id="${1:-}" mode="${2:-cli}" modes

    [[ -n "$id" ]] || return 1
    action_exists "$id" || return 1

    modes="${_ACTION_MODES[$id]:-}"

    case "$modes" in
        both|"$mode")
            return 0
            ;;
    esac

    case ",$modes," in
        *,"$mode",*)
            return 0
            ;;
    esac

    return 1
}

action_requirements_met() {
    local id="${1:-}" requires capability

    [[ -n "$id" ]] || return 1
    action_exists "$id" || return 1

    requires="${_ACTION_REQUIRES[$id]:-none}"

    [[ -n "$requires" && "$requires" != "none" ]] || return 0

    local IFS=','
    for capability in $requires; do
        [[ -n "$capability" && "$capability" != "none" ]] || continue
        if ! env_require_capability "$capability"; then
            printf '缺少能力: %s\n' "$capability" >&2
            return 1
        fi
    done

    return 0
}

action_run() {
    local id="${1:-}" mode="${2:-cli}" handler
    local -a args=()

    if (($# > 2)); then
        args=("${@:3}")
    fi

    if ! action_exists "$id"; then
        printf '未知 action: %s\n' "$id" >&2
        return 1
    fi

    if ! action_mode_supported "$id" "$mode"; then
        printf 'action 不支持当前模式: %s mode=%s\n' "$id" "$mode" >&2
        return 1
    fi

    action_requirements_met "$id" || return 1

    handler="${_ACTION_HANDLER[$id]}"
    if ! declare -F "$handler" >/dev/null 2>&1; then
        printf 'action handler 不存在: %s -> %s\n' "$id" "$handler" >&2
        return 1
    fi

    "$handler" "${args[@]}"
}

rl_action_run() {
    action_run "$@"
}

rl_action_users_create_cli() {
    if (( $# < 3 )); then
        printf '用法: rl-user-create.sh <用户名> <密码> <主目录> [--miniforge]\n' >&2
        return 1
    fi

    local rl_username="$1" rl_password="$2" rl_home="$3" rl_install_miniforge="false"
    [[ "${4:-}" == "--miniforge" ]] && rl_install_miniforge="true"

    create_user "$rl_username" "$rl_password" "$rl_home" "$rl_install_miniforge"
}

rl_action_users_quota_cli() {
    local rl_mode="${1:-}" rl_username="${2:-}" rl_value="${3:-}" rl_mp="${4:-}"
    [[ -n "$rl_username" ]] || { printf '用法: rl-user-quota.sh --get <用户名> | --set <用户名> <配额> [挂载点]\n' >&2; return 1; }
    [[ -n "$rl_mp" ]] || rl_mp="$(get_user_mountpoint "$(get_user_home "$rl_username")")"

    case "$rl_mode" in
        --get) get_user_quota_info "$rl_username" "$rl_mp" ;;
        --set)
            local rl_bytes
            rl_bytes="$(parse_quota_input "$rl_value")"
            [[ -n "$rl_bytes" ]] || { printf '错误: 无效的配额格式\n' >&2; return 1; }
            set_user_quota "$rl_username" "$rl_bytes" "$rl_mp"
            ;;
        *) printf '用法: rl-user-quota.sh --get <用户名> | --set <用户名> <配额> [挂载点]\n' >&2; return 1 ;;
    esac
}

rl_action_users_resource_cli() {
    local rl_mode="${1:-}" rl_username="${2:-}"
    [[ -n "$rl_username" ]] || { printf '用法: rl-user-resource.sh --get <用户名> | --set <用户名> <CPU> <内存> | --remove <用户名>\n' >&2; return 1; }

    case "$rl_mode" in
        --get) get_current_resource_limits "$rl_username" ;;
        --set) configure_resource_limits "$rl_username" "${3:-}" "${4:-}" ;;
        --remove) remove_resource_limits "$(id -u "$rl_username")" ;;
        *) printf '用法: rl-user-resource.sh --get <用户名> | --set <用户名> <CPU> <内存> | --remove <用户名>\n' >&2; return 1 ;;
    esac
}

rl_action_mail_test_cli() {
    local rl_email="${1:-}"
    [[ -n "$rl_email" ]] || { printf '用法: rl-mail-test.sh <收件邮箱>\n' >&2; return 1; }
    send_password_email "test" "TEST-PASSWORD" "$rl_email" "SMTP 测试" 1
}

rl_action_backup_run_cli() {
    local rl_username="${1:-}"
    [[ -n "$rl_username" ]] || { printf '用法: rl-backup-run.sh <用户名>\n' >&2; return 1; }
    manual_backup_user "$rl_username"
}

rl_action_audit_query_cli() {
    audit_query "${1:-}" "${2:-}" "${3:-}"
}

action_list_by_group() {
    local group="${1:-}" id

    for id in "${!_ACTION_GROUP[@]}"; do
        [[ "${_ACTION_GROUP[$id]}" == "$group" ]] && printf '%s\n' "$id"
    done | sort
}

action_describe() {
    local id="${1:-}"

    action_exists "$id" || return 1

    printf 'id=%s\n' "$id"
    printf 'label=%s\n' "${_ACTION_LABEL[$id]}"
    printf 'group=%s\n' "${_ACTION_GROUP[$id]}"
    printf 'handler=%s\n' "${_ACTION_HANDLER[$id]}"
    printf 'requires=%s\n' "${_ACTION_REQUIRES[$id]}"
    printf 'modes=%s\n' "${_ACTION_MODES[$id]}"
    printf 'risk=%s\n' "${_ACTION_RISK[$id]}"
}

action_register_defaults() {
    action_register "logs.boot" "查看 Boot 日志" "logs" logs_action_boot_cli "journalctl" "both" "safe"
    action_register "logs.failed_services" "列出失败服务" "logs" logs_action_failed_services_cli "systemctl" "both" "safe"
    action_register "logs.service_recent" "查看服务近期日志" "logs" logs_action_service_recent_cli "journalctl" "both" "safe"
    action_register "logs.boot_error_diff" "启动错误对比" "logs" logs_action_boot_error_diff_cli "journalctl" "both" "safe"
    action_register "logs.system_file_tail" "查看系统日志文件" "logs" logs_action_system_file_tail_cli "none" "both" "safe"
    action_register "logs.auth_failures" "查看认证失败" "logs" logs_action_auth_failures_cli "none" "both" "safe"
    action_register "system.timers.list" "列出 systemd timers" "system" systemd_timer_list_timers "systemctl" "both" "safe"
    action_register "system.timers.logs" "查看 timer 日志" "system" systemd_timer_show_logs "journalctl" "both" "safe"
    action_register "users.list" "查看托管用户" "users" list_managed_users "none" "both" "safe"
    action_register "users.create" "创建用户" "users" rl_action_users_create_cli "none" "cli" "dangerous"
    action_register "users.quota" "用户配额操作" "users" rl_action_users_quota_cli "none" "cli" "dangerous"
    action_register "users.resource" "用户资源限制操作" "users" rl_action_users_resource_cli "none" "cli" "dangerous"
    action_register "mail.test" "发送测试邮件" "mail" rl_action_mail_test_cli "none" "cli" "safe"
    action_register "backup.run" "执行用户备份" "backup" rl_action_backup_run_cli "none" "cli" "dangerous"
    action_register "audit.query" "查询审计日志" "audit" rl_action_audit_query_cli "none" "cli" "safe"
    action_register "audit.view" "查看审计日志" "audit" view_audit_log "none" "both" "safe"
}

action_register_defaults_once() {
    if [[ "${ACTION_DEFAULTS_REGISTERED:-0}" == "1" ]]; then
        return 0
    fi
    ACTION_DEFAULTS_REGISTERED=1
    action_register_defaults
}
