#!/bin/bash
# user_manager.sh - 用户与系统管理器 主程序
# 版本: v0.2.1
# 要求: Ubuntu/Debian, 已配置 user quota + rsnapshot + UFW

set -uo pipefail

# === 获取脚本目录 ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# === 模块引导加载 ===
# shellcheck disable=SC1091
source "$LIB_DIR/bootstrap.sh"
um_load_profile full || exit 1

# ============================================================
#  业务逻辑函数
# ============================================================

# shellcheck disable=SC1091
source "$LIB_DIR/controller_user_workflows.sh"

# ============================================================
#  子菜单（已拆分到独立控制器）
# ============================================================
# shellcheck disable=SC1091
source "$LIB_DIR/controller_submenus.sh"

# ============================================================
#  入口点
# ============================================================

# shellcheck disable=SC1091
source "$LIB_DIR/controller_main_menu.sh"

main() {
    if declare -F action_register_defaults_once >/dev/null 2>&1; then
        action_register_defaults_once
    fi

    local cli_status=0
    user_manager_handle_cli "$@"
    cli_status=$?
    if [[ $cli_status -ne 2 ]]; then
        return "$cli_status"
    fi

    controller_start
}

user_manager_cli_init() {
    check_dependencies || return 1
    load_config || return 1
    setup_trap_handler
    return 0
}

user_manager_handle_cli() {
    case "${1:-}" in
        --weekly-report|--send-reports)
            user_manager_cli_init || return $?
            send_all_user_reports
            return $?
            ;;
        --account-health-check)
            user_manager_cli_init || return $?
            check_expired_suspensions
            return $?
            ;;
        "")
            return 2
            ;;
        *)
            return 2
            ;;
    esac
}

if [[ "${USER_MANAGER_NO_MAIN:-0}" != "1" ]]; then
    main "$@"
fi
