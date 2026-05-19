#!/bin/bash
# rl-system-overview.sh - 系统概览 (glances 包装)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

usage() {
    cat <<'EOF'
用法: rl-system-overview.sh [选项]

选项:
  --help      显示此帮助
  --web       启动 glances Web 模式 (端口 61208)
  --processes 仅显示进程列表
  --quick     快速非交互模式输出

依赖: glances (https://nicolargo.github.io/glances/)
EOF
    exit 0
}

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && usage

# 检查 glances 是否安装
if ! command -v glances &>/dev/null; then
    echo "错误: glances 未安装。请运行:" >&2
    echo "  sudo apt-get install -y glances" >&2
    exit 1
fi

case "${1:-}" in
    --web)
        echo "启动 glances Web 模式 (http://localhost:61208)..."
        exec glances -w
        ;;
    --processes)
        exec glances --disable-cpu --disable-mem --disable-swap --disable-io --disable-net --disable-disk --disable-fs --disable-sensors --disable-irq
        ;;
    --quick)
        exec glances --time 1 --quiet
        ;;
    *)
        exec glances "$@"
        ;;
esac
