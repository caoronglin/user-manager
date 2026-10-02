#!/bin/bash
# rl-remote-entry.sh - 远端部署的只读白名单入口
set -uo pipefail
IFS=$'\n\t'
umask 077
export LC_ALL=C
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
unset CDPATH ENV BASH_ENV GLOBIGNORE

rl_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
rl_project_root="$(dirname "$rl_script_dir")"

rl_usage() {
    cat <<'EOF'
用法: rl-remote-entry.sh <host.probe|gpu.summary>

这是供 SSHProvider 调用的只读白名单入口；不接受任意命令或业务参数。
EOF
}

case "${1:-}" in
-h | --help)
    (($# == 1)) || exit 2
    rl_usage
    exit 0
    ;;
host.probe | gpu.summary)
    (($# == 1)) || {
        rl_usage >&2
        exit 2
    }
    ;;
*)
    rl_usage >&2
    exit 2
    ;;
esac

# shellcheck source=lib/gpu_core.sh
source "$rl_project_root/lib/gpu_core.sh" || exit 3
# shellcheck source=lib/host_probe_core.sh
source "$rl_project_root/lib/host_probe_core.sh" || exit 3

case "$1" in
host.probe) host_probe_snapshot_kv ;;
gpu.summary) gpu_snapshot_kv ;;
esac
