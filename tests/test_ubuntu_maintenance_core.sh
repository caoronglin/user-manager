#!/bin/bash
# test_ubuntu_maintenance_core.sh - Ubuntu APT/重启维护模块测试
# shellcheck disable=SC1091

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"

test_suite_start "Ubuntu Maintenance Core"

test_start "ubuntu_maintenance_core 模块可加载并导出核心函数"
if bash -c 'set -uo pipefail; source "$1/lib/common.sh"; source "$1/lib/ubuntu_maintenance_core.sh"; declare -F ubuntu_maintenance_collect_report >/dev/null && declare -F ubuntu_maintenance_count_upgradable_from_text >/dev/null && declare -F ubuntu_maintenance_summarize_apt_history_from_text >/dev/null && declare -F ubuntu_maintenance_summarize_policy_from_text >/dev/null && declare -F show_ubuntu_maintenance_panel >/dev/null' _ "$PROJECT_ROOT" >/dev/null 2>&1; then
    test_pass
else
    test_fail "ubuntu_maintenance_core.sh 缺失或未导出预期函数"
fi

test_start "system_core 聚合加载 ubuntu maintenance 模块"
if bash -c 'set -uo pipefail; source "$1/lib/common.sh"; source "$1/lib/system_core.sh"; declare -F ubuntu_maintenance_collect_report >/dev/null && declare -F show_ubuntu_maintenance_panel >/dev/null' _ "$PROJECT_ROOT" >/dev/null 2>&1; then
    test_pass
else
    test_fail "system_core.sh 未聚合加载 ubuntu_maintenance_core.sh"
fi

test_start "ubuntu_maintenance_count_upgradable_from_text 正确忽略标题行"
upgradable_count="$(bash -c 'set -uo pipefail; source "$1/lib/common.sh"; source "$1/lib/ubuntu_maintenance_core.sh"; sample=$'"'"'Listing... Done
bash/noble-updates 5.2 amd64 [upgradable from: 5.1]
coreutils/noble-updates 9.4 amd64 [upgradable from: 9.3]

'"'"'; ubuntu_maintenance_count_upgradable_from_text "$sample"' _ "$PROJECT_ROOT")"
assert_equals "2" "$upgradable_count"

test_start "ubuntu_maintenance_summarize_apt_history_from_text 汇总最近事务"
history_summary="$(bash -c 'set -uo pipefail; source "$1/lib/common.sh"; source "$1/lib/ubuntu_maintenance_core.sh"; sample=$'"'"'Start-Date: 2026-04-19  09:00:00
Commandline: apt-get upgrade
Upgrade: openssl:amd64 (3.0.2-0ubuntu1, 3.0.2-0ubuntu1.1), curl:amd64 (7.81.0-1, 7.81.0-1.1)
End-Date: 2026-04-19  09:05:00

Start-Date: 2026-04-18  08:00:00
Commandline: apt-get install jq
Install: jq:amd64 (1.6-2.1)
Remove: nano:amd64 (6.2-1)
End-Date: 2026-04-18  08:02:00
'"'"'; ubuntu_maintenance_summarize_apt_history_from_text "$sample"' _ "$PROJECT_ROOT")"
if [[ "$history_summary" == *"transactions=2"* ]] && [[ "$history_summary" == *"upgrades=2"* ]] && [[ "$history_summary" == *"installs=1"* ]] && [[ "$history_summary" == *"removals=1"* ]] && [[ "$history_summary" == *"last_start=2026-04-19 09:00:00"* ]]; then
    test_pass
else
    test_fail "APT history summary 条件不完整: $history_summary"
fi

test_start "ubuntu_maintenance_summarize_policy_from_text 汇总 release 通道"
policy_summary="$(bash -c 'set -uo pipefail; source "$1/lib/common.sh"; source "$1/lib/ubuntu_maintenance_core.sh"; sample=$'"'"'Package files:
 100 /var/lib/dpkg/status
     release a=now
 500 http://archive.ubuntu.com/ubuntu noble-updates/main amd64 Packages
     release v=24.04,o=Ubuntu,a=noble-updates,n=noble,l=Ubuntu,c=main,b=amd64
     origin archive.ubuntu.com
 500 http://security.ubuntu.com/ubuntu noble-security/main amd64 Packages
     release v=24.04,o=Ubuntu,a=noble-security,n=noble,l=Ubuntu,c=main,b=amd64
     origin security.ubuntu.com
Pinned packages:
'"'"'; ubuntu_maintenance_summarize_policy_from_text "$sample"' _ "$PROJECT_ROOT")"
if [[ "$policy_summary" == *"channels=2"* ]] && [[ "$policy_summary" == *"noble-security"* ]] && [[ "$policy_summary" == *"noble-updates"* ]]; then
    test_pass
else
    test_fail "APT policy summary 条件不完整: $policy_summary"
fi

test_start "ubuntu_maintenance_collect_report 支持 stub 数据源"
report_output="$(bash -c 'set -uo pipefail; source "$1/lib/common.sh"; source "$1/lib/ubuntu_maintenance_core.sh"; ubuntu_maintenance_get_upgradable_raw() { printf "%s\n" "Listing... Done" "vim/noble-updates 2:9.1 amd64 [upgradable from: 2:9.0]"; }; ubuntu_maintenance_get_held_raw() { printf "%s\n" "docker-ce" "containerd.io"; }; ubuntu_maintenance_get_needrestart_raw() { printf "%s\n" "NEEDRESTART-KSTA: 3"; }; ubuntu_maintenance_get_policy_raw() { printf "%s\n" "Package files:" " 500 http://archive.ubuntu.com/ubuntu noble-updates/main amd64 Packages" "     release o=Ubuntu,a=noble-updates,n=noble,l=Ubuntu,c=main,b=amd64"; }; temp_root="$(mktemp -d)"; trap "rm -rf \"$temp_root\"" EXIT; mkdir -p "$temp_root/sources.list.d"; printf "%s\n" "deb http://archive.ubuntu.com/ubuntu noble main" > "$temp_root/sources.list"; printf "%s\n" "deb http://security.ubuntu.com/ubuntu noble-security main" > "$temp_root/sources.list.d/security.list"; printf "%s\n" "Start-Date: 2026-04-20  07:00:00" "Upgrade: openssl:amd64 (1, 2)" "End-Date: 2026-04-20  07:01:00" > "$temp_root/history.log"; UBUNTU_MAINTENANCE_SOURCES_LIST="$temp_root/sources.list" UBUNTU_MAINTENANCE_SOURCES_DIR="$temp_root/sources.list.d" UBUNTU_MAINTENANCE_APT_HISTORY_LOG="$temp_root/history.log" UBUNTU_MAINTENANCE_REBOOT_FLAG="$temp_root/reboot-required" ubuntu_maintenance_collect_report' _ "$PROJECT_ROOT")"
if [[ "$report_output" == *"upgradable_count=1"* ]] && [[ "$report_output" == *"held_count=2"* ]] && [[ "$report_output" == *"reboot_required=no"* ]] && [[ "$report_output" == *"needrestart_status=kernel"* ]] && [[ "$report_output" == *"history_summary=transactions=1"* ]] && [[ "$report_output" == *"sources_summary=entries=2"* ]]; then
    test_pass
else
    test_fail "Ubuntu maintenance collect report 条件不完整: $report_output"
fi

test_start "show_ubuntu_maintenance_panel 输出管理员摘要"
panel_output="$(bash -c 'set -uo pipefail; source "$1/lib/common.sh"; source "$1/lib/ubuntu_maintenance_core.sh"; ubuntu_maintenance_collect_report() { cat <<'"'"'EOF'"'"'
upgradable_count=3
upgradable_preview=openssl, curl, systemd
held_count=1
held_preview=docker-ce
reboot_required=yes
needrestart_status=services
history_summary=transactions=2;upgrades=5;installs=1;removals=0;last_start=2026-04-20 08:00:00
sources_summary=entries=3;disabled=1;channels=2;channel_list=noble-updates,noble-security
EOF
}; show_ubuntu_maintenance_panel' _ "$PROJECT_ROOT")"
if [[ "$panel_output" == *"Ubuntu APT/重启维护"* ]] && [[ "$panel_output" == *"可升级包:"* ]] && [[ "$panel_output" == *"需要重启"* ]] && [[ "$panel_output" == *"noble-security"* ]]; then
    test_pass
else
    test_fail "Ubuntu maintenance panel 输出条件不完整: $panel_output"
fi

test_suite_end
