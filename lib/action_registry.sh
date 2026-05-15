#!/bin/bash
# action_registry.sh - TUI/CLI 共用动作表与分发器

declare -Ag _ACTION_LABEL=()
declare -Ag _ACTION_GROUP=()
declare -Ag _ACTION_HANDLER=()
declare -Ag _ACTION_REQUIRES=()
declare -Ag _ACTION_MODES=()
declare -Ag _ACTION_RISK=()

action_registry_reset() {
    _ACTION_LABEL=()
    _ACTION_GROUP=()
    _ACTION_HANDLER=()
    _ACTION_REQUIRES=()
    _ACTION_MODES=()
    _ACTION_RISK=()
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
    [[ -n "$id" && -n "${_ACTION_HANDLER[$id]:-}" ]]
}

action_mode_supported() {
    local id="${1:-}" mode="${2:-cli}" modes
    modes="${_ACTION_MODES[$id]:-both}"

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
