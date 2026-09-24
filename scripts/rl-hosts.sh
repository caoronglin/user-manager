#!/bin/bash
# rl-hosts.sh - Inventory、dry-run 与本机/SSH 只读探测
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
export LC_ALL=C
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
unset CDPATH ENV BASH_ENV GLOBIGNORE

rl_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
rl_project_root="$(dirname "$rl_script_dir")"
rl_inventory=''
rl_known_hosts=''

rl_usage() {
    cat <<'EOF'
用法: rl-hosts.sh [全局选项] <命令> [参数]

全局选项:
  --inventory <文件>    显式指定主机清单
  --known-hosts <文件>  指定工具专用 known_hosts
  -h, --help            显示帮助

命令:
  list                              列出主机清单
  validate                          校验主机清单
  probe [host-id|group:组|all] [--dry-run]
                                    系统能力探测
  gpu [host-id|group:组|all] [--dry-run]
                                    GPU 只读摘要

退出码: 0=成功，1=部分失败，2=参数/计划错误，4=不支持，5/6=Provider 错误。
EOF
}

while (($# > 0)); do
    case "$1" in
    --inventory)
        (($# >= 2)) || {
            rl_usage >&2
            exit 2
        }
        rl_inventory="$2"
        shift 2
        ;;
    --known-hosts)
        (($# >= 2)) || {
            rl_usage >&2
            exit 2
        }
        rl_known_hosts="$2"
        shift 2
        ;;
    -h | --help)
        rl_usage
        exit 0
        ;;
    --)
        shift
        break
        ;;
    -*)
        rl_usage >&2
        exit 2
        ;;
    *) break ;;
    esac
done

(($# > 0)) || {
    rl_usage >&2
    exit 2
}
rl_command="$1"
shift

cd "$rl_project_root" || exit 1
SCRIPT_DIR="$rl_project_root"
LIB_DIR="$rl_project_root/lib"
# shellcheck source=lib/bootstrap.sh
source "$LIB_DIR/bootstrap.sh"
um_load_profile remote
[[ -z "$rl_known_hosts" ]] || USER_MANAGER_SSH_KNOWN_HOSTS_FILE="$rl_known_hosts"

if [[ -n "$rl_inventory" ]]; then
    host_inventory_load "$rl_inventory"
else host_inventory_load; fi

action_register_defaults_once
case "$rl_command" in
list)
    (($# == 0)) || {
        rl_usage >&2
        exit 2
    }
    host_inventory_list
    ;;
validate)
    (($# == 0)) || {
        rl_usage >&2
        exit 2
    }
    printf 'inventory.valid=true\ninventory.host_count=%s\n' "${#HOST_INVENTORY_IDS[@]}"
    ;;
probe | gpu)
    rl_target='local'
    rl_mode='execute'
    rl_target_seen=0
    while (($# > 0)); do
        case "$1" in
        --dry-run)
            [[ "$rl_mode" == execute ]] || {
                rl_usage >&2
                exit 2
            }
            rl_mode='dry-run'
            ;;
        -*)
            rl_usage >&2
            exit 2
            ;;
        *)
            ((rl_target_seen == 0)) || {
                rl_usage >&2
                exit 2
            }
            rl_target="$1"
            rl_target_seen=1
            ;;
        esac
        shift
    done
    if [[ "$rl_mode" == execute ]]; then _um_source_module audit_core.sh; fi
    if [[ "$rl_command" == probe ]]; then rl_action='host.probe'; else rl_action='gpu.summary'; fi
    execution_plan_run "$rl_action" "$rl_target" "$rl_mode"
    ;;
*)
    rl_usage >&2
    exit 2
    ;;
esac
