#!/bin/bash
# rl-action-list.sh - 列出/导出 Action 注册表，并可校验 handler 是否存在
set -Eeuo pipefail
IFS=$'\n\t'

trap 'echo "错误: 行 $LINENO: $BASH_COMMAND (exit $?)" >&2' ERR

rl_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rl_project_root="$(dirname "$rl_script_dir")"

rl_usage() {
    cat <<'EOF'
用法: rl-action-list.sh [--plain|--markdown|--check]

选项:
  --plain     输出纯文本表格（默认）
  --markdown  输出 Markdown 表格
  --check     校验所有注册 action 的 handler 是否存在（加载 full profile）
  -h, --help  显示此帮助
EOF
}

rl_mode="${1:-plain}"
case "$rl_mode" in
-h | --help)
    rl_usage
    exit 0
    ;;
--plain | -p) rl_mode="plain" ;;
--markdown | -m) rl_mode="markdown" ;;
--check | -c) rl_mode="check" ;;
*)
    rl_usage >&2
    exit 1
    ;;
esac

cd "$rl_project_root" || exit 1
SCRIPT_DIR="$rl_project_root"
LIB_DIR="$rl_project_root/lib"
source "$rl_project_root/lib/bootstrap.sh"

if [[ "$rl_mode" == "check" ]]; then
    um_load_profile full
else
    um_load_profile minimal
fi
action_register_defaults_once

# check 模式需要加载控制器以解析用户列表/审计视图等 handler。
if [[ "$rl_mode" == "check" ]]; then
    # shellcheck source=lib/controller_user_workflows.sh
    source "$LIB_DIR/controller_user_workflows.sh"
    # shellcheck source=lib/controller_submenus.sh
    source "$LIB_DIR/controller_submenus.sh"
fi

# 排序输出 action id
mapfile -t rl_ids < <(printf '%s\n' "${!_ACTION_LABEL[@]}" | sort)

case "$rl_mode" in
plain)
    printf '%-24s %-28s %-10s %-8s %-10s\n' "ID" "LABEL" "GROUP" "MODE" "RISK"
    for id in "${rl_ids[@]}"; do
        printf '%-24s %-28s %-10s %-8s %-10s\n' \
            "$id" "${_ACTION_LABEL[$id]}" "${_ACTION_GROUP[$id]}" "${_ACTION_MODES[$id]}" "${_ACTION_RISK[$id]}"
    done
    ;;
markdown)
    printf '| Action ID | 说明 | 模式 | 风险 |\n'
    printf '| --- | --- | --- | --- |\n'
    for id in "${rl_ids[@]}"; do
        printf '| `%s` | %s | %s | %s |\n' \
            "$id" "${_ACTION_LABEL[$id]}" "${_ACTION_MODES[$id]}" "${_ACTION_RISK[$id]}"
    done
    ;;
check)
    rc=0
    for id in "${rl_ids[@]}"; do
        if ! declare -F "${_ACTION_HANDLER[$id]}" >/dev/null 2>&1; then
            echo "MISSING_HANDLER $id -> ${_ACTION_HANDLER[$id]}" >&2
            rc=1
        fi
    done
    if ((rc == 0)); then
        echo "All action handlers exist: ${#rl_ids[@]} actions"
    fi
    exit "$rc"
    ;;
esac
