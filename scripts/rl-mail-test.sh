#!/bin/bash
# rl-mail-test.sh - 通过 SMTP 配置发送测试邮件
set -euo pipefail

rl_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rl_project_root="$(dirname "$rl_script_dir")"

rl_usage() { cat <<'EOF'
用法: rl-mail-test.sh <收件邮箱>

选项:
  -h, --help  显示此帮助
EOF
}

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && { rl_usage; exit 0; }
cd "$rl_project_root" || exit 1
SCRIPT_DIR="$rl_project_root" LIB_DIR="$rl_project_root/lib" source "$rl_project_root/lib/bootstrap.sh"
um_load_profile full
action_register_defaults_once
rl_action_run mail.test cli "$@"
