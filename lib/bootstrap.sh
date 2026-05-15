#!/bin/bash
# bootstrap.sh - 统一模块加载引导层
# 目标：稳定 source 顺序，减少入口脚本重复加载逻辑

# 防止重复加载（无 return 模式，兼容所有执行上下文）
if [[ -z "${USER_MANAGER_BOOTSTRAP_LOADED:-}" ]]; then
USER_MANAGER_BOOTSTRAP_LOADED=1

# 兜底路径（通常由入口脚本设置）
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
LIB_DIR="${LIB_DIR:-$SCRIPT_DIR/lib}"

declare -A _UM_MODULE_CACHE=()

_um_bootstrap_err() {
    local msg="$1"
    if declare -F msg_err >/dev/null 2>&1; then
        msg_err "$msg"
    else
        echo "[bootstrap] $msg" >&2
    fi
}

_um_source_module() {
    local module="$1"
    local file_path="$LIB_DIR/$module"

    if [[ -n "${_UM_MODULE_CACHE[$module]:-}" ]]; then
        return 0
    fi

    if [[ ! -f "$file_path" ]]; then
        _um_bootstrap_err "模块不存在: $file_path"
        return 1
    fi

    # shellcheck disable=SC1090
    source "$file_path" || {
        _um_bootstrap_err "模块加载失败: $file_path"
        return 1
    }

    _UM_MODULE_CACHE[$module]=1
    return 0
}

# 用法: um_load_profile <full|tui>
um_load_profile() {
    local profile="${1:-full}"
    local -a modules=()

    case "$profile" in
        full)
            modules=(
                "common.sh"
                "ui_modern.sh"
                "config.sh"
                "env_core.sh"
                "action_registry.sh"
                "access_control.sh"
                "privilege.sh"
                "quota_core.sh"
                "user_core.sh"
                "email_core.sh"
                "audit_core.sh"
                "resource_core.sh"
                "backup_excludes.sh"
                "backup_core.sh"
                "backup_verify.sh"
                "firewall_core.sh"
                "dns_core.sh"
                "symlink_core.sh"
                "report_core.sh"
                "system_core.sh"
                "logs_core.sh"
                "vm_core.sh"
                "gpu_core.sh"
            )
            ;;
        tui)
            modules=(
                "common.sh"
                "config.sh"
                "env_core.sh"
                "action_registry.sh"
                "access_control.sh"
                "privilege.sh"
                "quota_core.sh"
                "user_core.sh"
                "tui_core.sh"
                "journalctl_core.sh"
                "systemd_timer_core.sh"
                "logs_core.sh"
            )
            ;;
        *)
            _um_bootstrap_err "未知加载配置: $profile"
            return 1
            ;;
    esac

    local module
    for module in "${modules[@]}"; do
        _um_source_module "$module" || return 1
    done

    return 0
}

fi  # end bootstrap guard
