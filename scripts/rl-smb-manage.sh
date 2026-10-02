#!/bin/bash
# rl-smb-manage.sh - SMB/Samba 账户管理
set -Eeuo pipefail
IFS=$'\n\t'

# ERR trap：严格模式错误报告（行号 + 失败命令 + 退出码）
trap 'echo "错误: 行 $LINENO: $BASH_COMMAND (exit $?)" >&2' ERR

rl_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rl_project_root="$(dirname "$rl_script_dir")"

rl_usage() {
    cat <<'EOF'
用法: rl-smb-manage.sh <命令> [参数]

命令:
  list                   列出 SMB 用户
  status                 SMB 服务状态
  show <用户名>           查看用户 SMB 状态
  password <用户名> [密码] 设置/创建 SMB 密码；未给密码时从 stdin 读取
  disable <用户名>        禁用 SMB 用户
  enable <用户名>         启用 SMB 用户
  remove <用户名>         移除 SMB 用户
  shares                  列出 SMB 共享
  share-add <名称> <路径> [yes|no]  新增 SMB 共享
  share-remove <名称>     移除 SMB 共享
  include status|ensure   查询/确保主配置 include 托管配置

选项:
  -h, --help             显示此帮助
EOF
}

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && {
    rl_usage
    exit 0
}
[[ $# -ge 1 ]] || {
    rl_usage >&2
    exit 1
}

cd "$rl_project_root" || exit 1
SCRIPT_DIR="$rl_project_root"
LIB_DIR="$rl_project_root/lib"
source "$rl_project_root/lib/bootstrap.sh"
um_load_profile minimal
action_register_defaults_once

rl_cmd="$1"
shift || true

case "$rl_cmd" in
list)
    rl_action_run smb.list cli "$@"
    ;;
status)
    rl_action_run smb.status cli "$@"
    ;;
show)
    rl_action_run smb.show cli "$@"
    ;;
password)
    rl_action_run smb.password cli "$@"
    ;;
disable)
    rl_action_run smb.disable cli "$@"
    ;;
enable)
    rl_action_run smb.enable cli "$@"
    ;;
remove)
    rl_action_run smb.remove cli "$@"
    ;;
shares)
    rl_action_run smb.shares cli "$@"
    ;;
share-add)
    rl_action_run smb.share.add cli "$@"
    ;;
share-remove)
    rl_action_run smb.share.remove cli "$@"
    ;;
include)
    rl_action_run smb.include cli "$@"
    ;;
*)
    rl_usage >&2
    exit 1
    ;;
esac
