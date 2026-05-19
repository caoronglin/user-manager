#!/bin/bash
# run.sh - 用户管理主线入口
# 默认进入 noTUI/CLI 经典界面；--tui 显式进入 TUI
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

case "${1:-}" in
    --tui)
        shift
        exec bash tui_manager.sh "$@"
        ;;
esac

exec bash user_manager.sh "$@"
