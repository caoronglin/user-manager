#!/bin/bash
# test_network_stack_core.sh - Ubuntu 网络栈诊断模块测试
# shellcheck disable=SC1091

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"

test_suite_start "Network Stack Core"

test_start "network_stack_core 模块可加载并导出核心函数"
if bash -c 'set -uo pipefail; source "$1/lib/common.sh"; source "$1/lib/network_stack_core.sh"; declare -F network_stack_detect_manager >/dev/null && declare -F network_stack_summarize_netplan_configs >/dev/null && declare -F network_stack_extract_default_routes_from_text >/dev/null && declare -F network_stack_extract_dns_servers_from_text >/dev/null && declare -F network_stack_collect_report >/dev/null && declare -F show_network_stack_panel >/dev/null' _ "$PROJECT_ROOT" >/dev/null 2>&1; then
    test_pass
else
    test_fail "network_stack_core.sh 缺失或未导出预期函数"
fi

test_start "network_stack_detect_manager 优先识别 netplan"
manager_output="$(bash -c 'set -uo pipefail; source "$1/lib/common.sh"; source "$1/lib/network_stack_core.sh"; temp_root="$(mktemp -d)"; trap "rm -rf \"$temp_root\"" EXIT; mkdir -p "$temp_root/netplan" "$temp_root/NetworkManager" "$temp_root/systemd-network"; printf "%s\n" "network:" "  version: 2" "  renderer: NetworkManager" > "$temp_root/netplan/01-test.yaml"; NETWORK_STACK_NETPLAN_DIR="$temp_root/netplan" NETWORK_STACK_NETWORKMANAGER_DIR="$temp_root/NetworkManager" NETWORK_STACK_NETWORKD_DIR="$temp_root/systemd-network" network_stack_detect_manager' _ "$PROJECT_ROOT")"
assert_equals "netplan" "$manager_output"

test_start "network_stack_summarize_netplan_configs 汇总文件与 renderer"
netplan_summary="$(bash -c 'set -uo pipefail; source "$1/lib/common.sh"; source "$1/lib/network_stack_core.sh"; temp_root="$(mktemp -d)"; trap "rm -rf \"$temp_root\"" EXIT; mkdir -p "$temp_root/netplan"; cat > "$temp_root/netplan/01-lan.yaml" <<'"'"'EOF'"'"'
network:
  version: 2
  renderer: networkd
  ethernets:
    enp0s3:
      dhcp4: true
EOF
cat > "$temp_root/netplan/50-wifi.yaml" <<'"'"'EOF'"'"'
network:
  version: 2
  renderer: NetworkManager
  wifis:
    wlan0:
      access-points:
        demo:
          password: secret
      dhcp4: true
EOF
NETWORK_STACK_NETPLAN_DIR="$temp_root/netplan" network_stack_summarize_netplan_configs' _ "$PROJECT_ROOT")"
if [[ "$netplan_summary" == *"files=2"* ]] && [[ "$netplan_summary" == *"renderers=NetworkManager,networkd"* ]] && [[ "$netplan_summary" == *"interfaces=enp0s3,wlan0"* ]]; then
    test_pass
else
    test_fail "netplan summary 条件不完整: $netplan_summary"
fi

test_start "network_stack_extract_default_routes_from_text 与 DNS 解析摘要"
route_dns_output="$(bash -c 'set -uo pipefail; source "$1/lib/common.sh"; source "$1/lib/network_stack_core.sh"; routes=$'"'"'default via 192.168.1.1 dev enp0s3 proto dhcp src 192.168.1.50 metric 100\ndefault via 10.0.2.2 dev wlan0 proto dhcp src 10.0.2.15 metric 600'"'"'; dns=$'"'"'Link 2 (enp0s3)\n    Current Scopes: DNS\n         DNS Servers: 1.1.1.1 8.8.8.8\n\nnameserver 9.9.9.9'"'"'; printf "routes=%s\n" "$(network_stack_extract_default_routes_from_text "$routes")"; printf "dns=%s\n" "$(network_stack_extract_dns_servers_from_text "$dns")"' _ "$PROJECT_ROOT")"
if [[ "$route_dns_output" == *"routes=enp0s3 via 192.168.1.1 metric 100; wlan0 via 10.0.2.2 metric 600"* ]] && [[ "$route_dns_output" == *"dns=1.1.1.1,8.8.8.8,9.9.9.9"* ]]; then
    test_pass
else
    test_fail "route/DNS 摘要条件不完整: $route_dns_output"
fi

test_start "network_stack_collect_report 支持 stub 数据源与状态摘要"
report_output="$(bash -c 'set -uo pipefail; source "$1/lib/common.sh"; source "$1/lib/network_stack_core.sh"; network_stack_detect_manager() { printf "%s\n" "NetworkManager"; }; network_stack_summarize_netplan_configs() { printf "%s\n" "files=1;renderers=NetworkManager;interfaces=enp0s3"; }; network_stack_get_default_route_raw() { printf "%s\n" "default via 192.168.1.1 dev enp0s3 proto dhcp metric 100"; }; network_stack_get_dns_raw() { printf "%s\n" "GENERAL.DEVICE: enp0s3" "IP4.DNS[1]: 1.1.1.1" "IP4.DNS[2]: 8.8.8.8"; }; network_stack_get_nmcli_status_raw() { printf "%s\n" "DEVICE         TYPE      STATE                   CONNECTION" "enp0s3         ethernet  connected               Wired connection 1" "wlan0          wifi      disconnected            --"; }; network_stack_get_networkctl_status_raw() { return 1; }; network_stack_get_recent_journal_raw() { printf "%s\n" "Apr 20 10:00:00 host NetworkManager[111]: <info>  [time] device enp0s3 activated" "Apr 20 10:01:00 host NetworkManager[111]: <warn>  dns update timeout" "Apr 20 10:02:00 host systemd-resolved[222]: Using degraded feature set UDP instead of TCP"; }; network_stack_collect_report' _ "$PROJECT_ROOT")"
if [[ "$report_output" == *"manager=NetworkManager"* ]] && [[ "$report_output" == *"netplan_summary=files=1;renderers=NetworkManager;interfaces=enp0s3"* ]] && [[ "$report_output" == *"default_routes=enp0s3 via 192.168.1.1 metric 100"* ]] && [[ "$report_output" == *"dns_servers=1.1.1.1,8.8.8.8"* ]] && [[ "$report_output" == *"status_summary=tool=nmcli;connected=1;disconnected=1;devices=enp0s3(ethernet:connected),wlan0(wifi:disconnected)"* ]] && [[ "$report_output" == *"journal_summary=lines=3;warnings=2;errors=0"* ]]; then
    test_pass
else
    test_fail "network collect report 条件不完整: $report_output"
fi

test_suite_end
