#!/bin/bash
# run.sh - 用户管理主线入口
# 默认进入 noTUI/CLI 经典界面；--tui 显式进入 TUI
set -Eeuo pipefail
IFS=$'\n\t'
# ERR trap：严格模式错误报告（行号 + 失败命令 + 退出码）
trap 'echo "错误: 行 $LINENO: $BASH_COMMAND (exit $?)" >&2' ERR

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

run_usage() {
    cat <<'EOF'
用法: bash run.sh [--tui|--no-tui|--cli] [user_manager.sh 参数]

  --tui       在支持全屏 ANSI 的交互终端中启动 TUI。
  --no-tui    明确选择经典 CLI（兼容别名）。
  --cli       明确选择经典 CLI（兼容别名）。
  -h, --help  显示此帮助。

若 --tui 所在会话没有交互式 stdin/stdout，脚本不会启动菜单；请改用独立 scripts/rl-*.sh 命令。
EOF
}

case "${1:-}" in
--tui)
    shift
    # shellcheck source=lib/tui_core.sh
    source "$(dirname "${BASH_SOURCE[0]}")/lib/tui_core.sh"
    if tui_terminal_supported; then
        exec bash tui_manager.sh "$@"
    fi
    if ! tui_terminal_is_interactive; then
        printf '当前终端不支持全屏 TUI（%s），且没有交互式 stdin/stdout，无法回退到经典 CLI。请改用 scripts/rl-*.sh 独立命令。\n' "$TUI_TERMINAL_REASON" >&2
        exit 3
    fi
    printf '当前终端不支持全屏 TUI（%s），已回退到经典 CLI。可使用 TERM=xterm-256color 的交互终端后重试。\n' "$TUI_TERMINAL_REASON" >&2
    exec bash user_manager.sh "$@"
    ;;
--no-tui | --cli)
    shift
    exec bash user_manager.sh "$@"
    ;;
-h | --help)
    (($# == 1)) || { run_usage >&2; exit 2; }
    run_usage
    exit 0
    ;;
esac

exec bash user_manager.sh "$@"
