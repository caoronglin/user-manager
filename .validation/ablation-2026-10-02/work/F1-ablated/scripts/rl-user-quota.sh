#!/bin/bash
# rl-user-quota.sh - 查询或设置用户磁盘配额
set -Eeuo pipefail
IFS=$'\n\t'

# ERR trap：严格模式错误报告（行号 + 失败命令 + 退出码）
trap 'echo "错误: 行 $LINENO: $BASH_COMMAND (exit $?)" >&2' ERR

rl_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rl_project_root="$(dirname "$rl_script_dir")"

rl_usage() {
    cat <<'EOF'
用法: rl-user-quota.sh --get <用户名>
用法: rl-user-quota.sh --set <用户名> <配额> [挂载点]

选项:
  -h, --help  显示此帮助
EOF
}

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && {
    rl_usage
    exit 0
}
cd "$rl_project_root" || exit 1
SCRIPT_DIR="$rl_project_root"
LIB_DIR="$rl_project_root/lib"
source "$rl_project_root/lib/bootstrap.sh"
um_load_profile full
action_register_defaults_once
rl_action_run users.quota cli "$@"
