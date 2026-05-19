#!/bin/bash
# rl-user-create.sh - 创建托管用户
set -euo pipefail

rl_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rl_project_root="$(dirname "$rl_script_dir")"

rl_usage() { cat <<'EOF'
用法: rl-user-create.sh <用户名> <密码> <主目录> [--miniforge]

选项:
  -h, --help  显示此帮助
EOF
}

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && { rl_usage; exit 0; }
cd "$rl_project_root" || exit 1
SCRIPT_DIR="$rl_project_root" LIB_DIR="$rl_project_root/lib" source "$rl_project_root/lib/bootstrap.sh"
um_load_profile full
action_register_defaults_once
rl_action_run users.create cli "$@"
