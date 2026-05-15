#!/bin/bash
# env_core.sh - 本机环境与依赖探测
# 只做能力判断，不安装依赖，不执行业务动作。

env_has_command() {
    local cmd="${1:-}"

    [[ -n "$cmd" ]] || return 1
    command -v "$cmd" >/dev/null 2>&1 || declare -F "$cmd" >/dev/null 2>&1
}

env_has_systemd() {
    case "${ENV_FORCE_SYSTEMD:-}" in
        1|true|yes)
            return 0
            ;;
        0|false|no)
            return 1
            ;;
    esac

    env_has_command systemctl || return 1
    [[ -d /run/systemd/system || -d /sys/fs/cgroup/system.slice ]]
}

env_capability_status() {
    local capability="${1:-}"
    local name

    case "$capability" in
        systemd)
            if env_has_systemd; then
                printf '__ENV_CAPABILITY__ capability=systemd status=ok\n'
                return 0
            fi
            printf '__ENV_CAPABILITY__ capability=systemd status=missing reason=no-systemd-runtime\n'
            return 1
            ;;
        command:*)
            name="${capability#command:}"
            if env_has_command "$name"; then
                printf '__ENV_CAPABILITY__ capability=%s status=ok\n' "$capability"
                return 0
            fi
            printf '__ENV_CAPABILITY__ capability=%s status=missing reason=command-not-found\n' "$capability"
            return 1
            ;;
        journalctl|systemctl|jq|ufw|rsnapshot|nvidia-smi|virsh)
            env_capability_status "command:$capability"
            return $?
            ;;
        root)
            if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
                printf '__ENV_CAPABILITY__ capability=root status=ok\n'
                return 0
            fi
            printf '__ENV_CAPABILITY__ capability=root status=missing reason=not-root\n'
            return 1
            ;;
        "")
            printf '__ENV_CAPABILITY__ capability=unknown status=missing reason=empty-capability\n'
            return 1
            ;;
        *)
            printf '__ENV_CAPABILITY__ capability=%s status=unknown reason=not-registered\n' "$capability"
            return 1
            ;;
    esac
}

env_require_capability() {
    local capability

    for capability in "$@"; do
        [[ -n "$capability" && "$capability" != "none" ]] || continue
        env_capability_status "$capability" >/dev/null || return 1
    done

    return 0
}

_env_summary_value() {
    local capability="$1"

    if env_capability_status "$capability" >/dev/null 2>&1; then
        printf 'ok'
    else
        printf 'missing'
    fi
}

env_capability_summary() {
    printf 'journalctl=%s\n' "$(_env_summary_value journalctl)"
    printf 'systemctl=%s\n' "$(_env_summary_value systemctl)"
    printf 'systemd=%s\n' "$(_env_summary_value systemd)"
    printf 'jq=%s\n' "$(_env_summary_value jq)"
    printf 'ufw=%s\n' "$(_env_summary_value ufw)"
    printf 'rsnapshot=%s\n' "$(_env_summary_value rsnapshot)"
    printf 'nvidia-smi=%s\n' "$(_env_summary_value nvidia-smi)"
    printf 'virsh=%s\n' "$(_env_summary_value virsh)"
}
