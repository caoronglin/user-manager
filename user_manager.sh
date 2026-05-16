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

    controller_start
}

main "$@"
