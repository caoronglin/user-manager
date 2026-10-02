#!/bin/bash
# test_host_inventory.sh - 主机清单解析与安全校验测试

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"
if [[ -f "$PROJECT_ROOT/lib/host_inventory.sh" ]]; then
    # shellcheck disable=SC1091
    source "$PROJECT_ROOT/lib/host_inventory.sh"
fi

setup_test_env
test_suite_start "Host Inventory"

write_inventory() {
    local path="$1"
    shift
    {
        printf '%s\n' 'host_id|display_name|provider|address|port|user|groups|tags|enabled'
        printf '%s\n' "$@"
    } >"$path"
    chmod 600 "$path"
}

test_start "host_inventory 导出核心接口"
if declare -F host_inventory_load >/dev/null &&
    declare -F host_inventory_list >/dev/null &&
    declare -F host_inventory_resolve >/dev/null &&
    declare -F host_inventory_get >/dev/null; then
    test_pass
else
    test_fail "host_inventory 未导出预期接口"
fi

test_start "默认清单缺失时仅注册内置本机"
missing_file="$TEST_TMPDIR/missing-hosts.conf"
if declare -F host_inventory_load >/dev/null &&
    USER_MANAGER_HOSTS_FILE="$missing_file" host_inventory_load >/dev/null 2>&1 &&
    [[ "${HOST_INVENTORY_IDS[*]:-}" == "local" ]] &&
    [[ "${HOST_PROVIDER[local]:-}" == "local" ]] &&
    [[ "${HOST_ENABLED[local]:-}" == "true" ]]; then
    test_pass
else
    test_fail "默认清单缺失时未安全降级到本机"
fi

test_start "加载合法清单并读取字段"
valid_file="$TEST_TMPDIR/hosts.conf"
write_inventory "$valid_file" \
    'local|当前主机|local||||admin|env-local|yes' \
    'compute-02|计算节点 02|ssh|192.0.2.12|2222|ops|gpu,prod|rack-b|yes' \
    'compute-01|计算节点 01|ssh|compute-01.example.test|22|ops|gpu,prod|rack-a|yes' \
    'ipv6-01|IPv6 节点|ssh|2001:db8::10|22|ops|gpu|rack-v6|yes' \
    'disabled-01|停用节点|ssh|192.0.2.99|22|ops|gpu|maintenance|no'
if host_inventory_load "$valid_file" >/dev/null 2>&1 &&
    [[ "$(host_inventory_get compute-02 provider)" == "ssh" ]] &&
    [[ "$(host_inventory_get compute-02 port)" == "2222" ]] &&
    [[ "$(host_inventory_get compute-01 display_name)" == "计算节点 01" ]] &&
    [[ "$(host_inventory_get ipv6-01 address)" == "2001:db8::10" ]]; then
    test_pass
else
    test_fail "合法清单未正确加载或字段读取错误"
fi

test_start "仓库提供的主机清单示例可安全加载"
example_file="$PROJECT_ROOT/etc/hosts.conf.example"
if [[ -f "$example_file" ]] && host_inventory_load "$example_file" >/dev/null 2>&1 &&
    [[ "${HOST_INVENTORY_IDS[*]}" == "local" ]] && [[ "$(host_inventory_get local provider)" == "local" ]]; then
    test_pass
else
    test_fail "主机清单示例不存在或不符合解析契约"
fi

# 重新加载包含分组 fixture，避免示例清单覆盖后续断言。
host_inventory_load "$valid_file" >/dev/null 2>&1 || true

test_start "按主机组稳定展开且排除停用主机"
group_output="$(host_inventory_resolve group:gpu 2>/dev/null || true)"
if [[ "$group_output" == $'compute-02\ncompute-01\nipv6-01' ]] && [[ "$group_output" != *"disabled-01"* ]]; then
    test_pass
else
    test_fail "主机组展开结果异常: $group_output"
fi

test_start "all 目标保留清单顺序并仅包含启用主机"
all_output="$(host_inventory_resolve all 2>/dev/null || true)"
if [[ "$all_output" == $'local\ncompute-02\ncompute-01\nipv6-01' ]]; then
    test_pass
else
    test_fail "all 展开结果异常: $all_output"
fi

test_start "拒绝重复 host_id"
duplicate_file="$TEST_TMPDIR/duplicate.conf"
write_inventory "$duplicate_file" \
    'node-01|节点一|ssh|192.0.2.10|22|ops|||yes' \
    'node-01|节点二|ssh|192.0.2.11|22|ops|||yes'
if ! host_inventory_load "$duplicate_file" >/dev/null 2>&1; then
    test_pass
else
    test_fail "重复 host_id 未被拒绝"
fi

test_start "拒绝含 shell 元字符的 host_id"
injection_file="$TEST_TMPDIR/injection.conf"
write_inventory "$injection_file" 'node;touch_bad|危险节点|ssh|192.0.2.10|22|ops|||yes'
if ! host_inventory_load "$injection_file" >/dev/null 2>&1 && [[ ! -e "$TEST_TMPDIR/touch_bad" ]]; then
    test_pass
else
    test_fail "危险 host_id 未被拒绝"
fi

test_start "拒绝非法 SSH 端口"
port_file="$TEST_TMPDIR/port.conf"
write_inventory "$port_file" 'node-01|节点|ssh|192.0.2.10|70000|ops|||yes'
if ! host_inventory_load "$port_file" >/dev/null 2>&1; then
    test_pass
else
    test_fail "非法端口未被拒绝"
fi

test_start "拒绝缺少地址或用户的 SSH 主机"
missing_ssh_file="$TEST_TMPDIR/missing-ssh.conf"
write_inventory "$missing_ssh_file" 'node-01|节点|ssh||22||||yes'
if ! host_inventory_load "$missing_ssh_file" >/dev/null 2>&1; then
    test_pass
else
    test_fail "不完整 SSH 主机未被拒绝"
fi

test_start "拒绝未知 Inventory 表头"
header_file="$TEST_TMPDIR/header.conf"
printf '%s\n' 'host_id|provider|command' 'node-01|ssh|id' >"$header_file"
chmod 600 "$header_file"
if ! host_inventory_load "$header_file" >/dev/null 2>&1; then
    test_pass
else
    test_fail "未知表头未被拒绝"
fi

test_start "拒绝组或其他用户可写的清单"
wide_file="$TEST_TMPDIR/wide.conf"
write_inventory "$wide_file" 'node-01|节点|ssh|192.0.2.10|22|ops|||yes'
chmod 662 "$wide_file"
if ! host_inventory_load "$wide_file" >/dev/null 2>&1; then
    test_pass
else
    test_fail "权限过宽的清单未被拒绝"
fi

test_start "显式指定不存在清单时返回失败"
if ! host_inventory_load "$TEST_TMPDIR/not-found.conf" >/dev/null 2>&1; then
    test_pass
else
    test_fail "显式不存在清单被静默接受"
fi

test_start "拒绝未知 provider"
provider_file="$TEST_TMPDIR/provider.conf"
write_inventory "$provider_file" 'node-01|节点|docker|192.0.2.10|22|ops|||yes'
if ! host_inventory_load "$provider_file" >/dev/null 2>&1; then
    test_pass
else
    test_fail "未知 provider 未被拒绝"
fi

test_start "拒绝本机条目携带远端连接字段"
local_remote_file="$TEST_TMPDIR/local-remote.conf"
write_inventory "$local_remote_file" 'local|本机|local|127.0.0.1|22|root|||yes'
if ! host_inventory_load "$local_remote_file" >/dev/null 2>&1; then
    test_pass
else
    test_fail "本机远端连接字段未被拒绝"
fi

test_start "拒绝非法 enabled 值"
enabled_file="$TEST_TMPDIR/enabled.conf"
write_inventory "$enabled_file" 'node-01|节点|ssh|192.0.2.10|22|ops|||maybe'
if ! host_inventory_load "$enabled_file" >/dev/null 2>&1; then
    test_pass
else
    test_fail "非法 enabled 未被拒绝"
fi

test_start "拒绝符号链接清单"
link_target="$TEST_TMPDIR/link-target.conf"
link_file="$TEST_TMPDIR/link.conf"
write_inventory "$link_target" 'node-01|节点|ssh|192.0.2.10|22|ops|||yes'
ln -s "$link_target" "$link_file"
if ! host_inventory_load "$link_file" >/dev/null 2>&1; then
    test_pass
else
    test_fail "符号链接清单未被拒绝"
fi

test_start "拒绝可由其他用户替换的父目录"
wide_dir="$TEST_TMPDIR/world-writable"
mkdir -p "$wide_dir"
chmod 777 "$wide_dir"
write_inventory "$wide_dir/hosts.conf" 'node-01|节点|ssh|192.0.2.10|22|ops|||yes'
if ! host_inventory_load "$wide_dir/hosts.conf" >/dev/null 2>&1; then
    test_pass
else
    test_fail "不安全父目录中的清单未被拒绝"
fi

test_start "拒绝超过 64 KiB 的清单"
large_file="$TEST_TMPDIR/large.conf"
printf -v large_field '%*s' 66000 ''
large_field="${large_field// /A}"
write_inventory "$large_file" "node-01|$large_field|ssh|192.0.2.10|22|ops|||yes"
if ! host_inventory_load "$large_file" >/dev/null 2>&1; then
    test_pass
else
    test_fail "超大清单未被拒绝"
fi

test_start "解析失败后不保留半份 Inventory 状态"
partial_file="$TEST_TMPDIR/partial.conf"
write_inventory "$partial_file" \
    'ok-01|正常节点|ssh|192.0.2.10|22|ops|||yes' \
    'bad;id|异常节点|ssh|192.0.2.11|22|ops|||yes'
host_inventory_load "$partial_file" >/dev/null 2>&1 || true
if ((${#HOST_INVENTORY_IDS[@]} == 0)); then
    test_pass
else
    test_fail "解析失败后仍保留了主机状态: ${HOST_INVENTORY_IDS[*]:-}"
fi

test_start "不存在或停用的显式目标返回失败"
host_inventory_load "$valid_file" >/dev/null 2>&1 || true
if ! host_inventory_resolve missing-host >/dev/null 2>&1 &&
    ! host_inventory_resolve disabled-01 >/dev/null 2>&1 &&
    ! host_inventory_resolve group:missing >/dev/null 2>&1; then
    test_pass
else
    test_fail "无效目标被静默解析"
fi

cleanup_test_env
test_suite_end
