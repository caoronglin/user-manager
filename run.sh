#!/bin/bash
# run.sh - TUI 主线启动入口
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

case "${1:-}" in
    --no-tui|--cli)
        shift
        exec bash user_manager.sh "$@"
        ;;
esac

exec bash tui_manager.sh "$@"
