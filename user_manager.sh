#!/bin/bash
# user_manager.sh - 用户与系统管理器 主程序
# 版本: v0.2.1
# 要求: Ubuntu/Debian, 已配置 user quota + rsnapshot + UFW

# 仅直接执行时启用严格模式；被 source（测试/复用）时不覆盖调用方的 shell 选项。
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -Eeuo pipefail
    IFS=$'\n\t'

    # ERR trap：严格模式错误报告（行号 + 失败命令 + 退出码）
    trap 'echo "错误: 行 $LINENO: $BASH_COMMAND (exit $?)" >&2' ERR
fi

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
    # set -e 下需在 || 保护中捕获返回码：2 = 无 CLI 参数，进入交互菜单
    user_manager_handle_cli "$@" || cli_status=$?
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
    --weekly-report | --send-reports)
        user_manager_cli_init || return $?
        send_all_user_reports || return $?
        return 0
        ;;
    --account-health-check)
        user_manager_cli_init || return $?
        check_expired_suspensions || return $?
        return 0
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
