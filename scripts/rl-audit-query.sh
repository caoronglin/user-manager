#!/bin/bash
# rl-audit-query.sh - 查询审计日志
set -euo pipefail

rl_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rl_project_root="$(dirname "$rl_script_dir")"

rl_usage() { cat <<'EOF'
用法: rl-audit-query.sh [操作类型] [用户名] [日期范围]

日期范围格式: YYYY-MM-DD 或 YYYY-MM-DD:YYYY-MM-DD
选项:
  -h, --help  显示此帮助
EOF
}

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && { rl_usage; exit 0; }
cd "$rl_project_root" || exit 1
SCRIPT_DIR="$rl_project_root" LIB_DIR="$rl_project_root/lib" source "$rl_project_root/lib/bootstrap.sh"
um_load_profile full
action_register_defaults_once
rl_action_run audit.query cli "$@"
