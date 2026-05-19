#!/bin/bash
# rl-user-resource.sh - 管理用户 cgroup v2 资源限制
set -euo pipefail

rl_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rl_project_root="$(dirname "$rl_script_dir")"

rl_usage() { cat <<'EOF'
用法: rl-user-resource.sh --get <用户名>
用法: rl-user-resource.sh --set <用户名> <CPU配额> <内存限制>
用法: rl-user-resource.sh --remove <用户名>

选项:
  -h, --help  显示此帮助
EOF
}

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && { rl_usage; exit 0; }
cd "$rl_project_root" || exit 1
SCRIPT_DIR="$rl_project_root" LIB_DIR="$rl_project_root/lib" source "$rl_project_root/lib/bootstrap.sh"
um_load_profile full
action_register_defaults_once
rl_action_run users.resource cli "$@"
