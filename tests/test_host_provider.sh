#!/bin/bash
# test_host_provider.sh - Local/SSH Provider 安全边界测试

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/test_framework.sh"
for module in host_inventory gpu_core host_probe_core host_provider; do
    [[ -f "$PROJECT_ROOT/lib/$module.sh" ]] && source "$PROJECT_ROOT/lib/$module.sh"
done

setup_test_env
test_suite_start "Host Provider"

write_inventory() {
    local path="$1"
    {
        printf '%s\n' 'host_id|display_name|provider|address|port|user|groups|tags|enabled'
        printf '%s\n' 'local|当前主机|local||||local||yes'
        printf '%s\n' 'compute-01|$(touch /tmp/provider-display-injection)|ssh|192.0.2.10|2222|ops|gpu|test|yes'
    } >"$path"
    chmod 600 "$path"
}

stub_bin="$TEST_TMPDIR/bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/ssh" <<'STUB'
#!/bin/bash
printf '%s\0' "$@" >"$SSH_ARGV_FILE"
printf 'called\n' >>"$SSH_CALL_FILE"
[[ -z "${SSH_SLEEP_SECONDS:-}" ]] || sleep "$SSH_SLEEP_SECONDS"
[[ ! -f "${SSH_STDOUT_FILE:-}" ]] || /bin/cat "$SSH_STDOUT_FILE"
[[ -z "${SSH_STDERR_TEXT:-}" ]] || printf '%s\n' "$SSH_STDERR_TEXT" >&2
exit "${SSH_EXIT_CODE:-0}"
STUB
chmod 700 "$stub_bin/ssh"
export PATH="$stub_bin:$PATH"
export SSH_ARGV_FILE="$TEST_TMPDIR/ssh.argv" SSH_CALL_FILE="$TEST_TMPDIR/ssh.calls"
: >"$SSH_CALL_FILE"

inventory_file="$TEST_TMPDIR/hosts.conf"
known_hosts_file="$TEST_TMPDIR/known_hosts"
write_inventory "$inventory_file"
printf 'compute-01 ssh-ed25519 AAAAC3NzaFixtureOnly\n' >"$known_hosts_file"
chmod 600 "$known_hosts_file"
export USER_MANAGER_SSH_KNOWN_HOSTS_FILE="$known_hosts_file"

host_payload="$TEST_TMPDIR/host.payload"
cat >"$host_payload" <<'PAYLOAD'
protocol=user-manager-readonly-v1
action=host.probe
status=success
code=OK
os_id=ubuntu
os_version=24.04
arch=x86_64
bash_version=5.2
systemd=available
cgroup=v2
project_version=dev
gpu_backend=none
end=1
PAYLOAD
export SSH_STDOUT_FILE="$host_payload" SSH_EXIT_CODE=0 SSH_STDERR_TEXT=''

if declare -F host_inventory_load >/dev/null; then host_inventory_load "$inventory_file" >/dev/null 2>&1 || true; fi

test_start "Provider 导出统一执行接口"
if declare -F host_provider_execute >/dev/null && declare -F host_provider_action_allowed >/dev/null; then
    test_pass
else
    test_fail "Provider 接口缺失"
fi

test_start "主机清单限制拒绝非十进制值并保留默认值"
default_limits="$(env -u USER_MANAGER_HOSTS_MAX_BYTES -u USER_MANAGER_HOSTS_MAX_ROWS \
    -u USER_MANAGER_HOST_TARGET_LIMIT bash -c '
        source "$1"
        printf "%s|%s|%s" "$HOST_INVENTORY_MAX_BYTES" "$HOST_INVENTORY_MAX_ROWS" "$HOST_INVENTORY_TARGET_LIMIT"
    ' _ "$PROJECT_ROOT/lib/host_inventory.sh")"
valid_limits="$(
    USER_MANAGER_HOSTS_MAX_BYTES=0000064 USER_MANAGER_HOSTS_MAX_ROWS=0012 USER_MANAGER_HOST_TARGET_LIMIT=008 \
        bash -c '
            source "$1"
            printf "%s|%s|%s" "$HOST_INVENTORY_MAX_BYTES" "$HOST_INVENTORY_MAX_ROWS" "$HOST_INVENTORY_TARGET_LIMIT"
        ' _ "$PROJECT_ROOT/lib/host_inventory.sh"
)"
oversized_limits="$(
    USER_MANAGER_HOSTS_MAX_BYTES=1048577 USER_MANAGER_HOSTS_MAX_ROWS=4097 USER_MANAGER_HOST_TARGET_LIMIT=257 \
        bash -c '
            source "$1"
            printf "%s|%s|%s" "$HOST_INVENTORY_MAX_BYTES" "$HOST_INVENTORY_MAX_ROWS" "$HOST_INVENTORY_TARGET_LIMIT"
        ' _ "$PROJECT_ROOT/lib/host_inventory.sh"
)"
bytes_marker="$TEST_TMPDIR/bytes-arithmetic-executed"
rows_marker="$TEST_TMPDIR/rows-arithmetic-executed"
targets_marker="$TEST_TMPDIR/targets-arithmetic-executed"
malicious_limits="$(
    USER_MANAGER_HOSTS_MAX_BYTES="UID[\$(touch $bytes_marker)]" \
        USER_MANAGER_HOSTS_MAX_ROWS="UID[\$(touch $rows_marker)]" \
        USER_MANAGER_HOST_TARGET_LIMIT="UID[\$(touch $targets_marker)]" \
        bash -c '
            source "$1"
            ((1 <= HOST_INVENTORY_MAX_BYTES && 1 <= HOST_INVENTORY_MAX_ROWS && 1 <= HOST_INVENTORY_TARGET_LIMIT))
            printf "%s|%s|%s" "$HOST_INVENTORY_MAX_BYTES" "$HOST_INVENTORY_MAX_ROWS" "$HOST_INVENTORY_TARGET_LIMIT"
        ' _ "$PROJECT_ROOT/lib/host_inventory.sh"
)"
if [[ "$default_limits" == '65536|256|20' && "$valid_limits" == '64|12|8' &&
    "$oversized_limits" == '65536|256|20' && "$malicious_limits" == '65536|256|20' &&
    ! -e "$bytes_marker" && ! -e "$rows_marker" && ! -e "$targets_marker" ]]; then
    test_pass
else
    test_fail "限制值未校验或默认值异常: defaults=$default_limits valid=$valid_limits oversized=$oversized_limits malicious=$malicious_limits"
fi

test_start "command substitution 中 known_hosts fd 校验正常"
fd_validation="$(
    # The sandbox maps root-owned /tmp to an unmapped uid; isolate this test from that mount-specific ancestor check.
    _host_inventory_parent_chain_is_safe() { return 0; }
    host_inventory_validate_trusted_file "$known_hosts_file" 1048576 >/dev/null 2>&1 && printf 'validated'
)"
if [[ "$fd_validation" == 'validated' ]]; then
    test_pass
else
    test_fail "子 shell 未能通过已打开 known_hosts 描述符校验"
fi

test_start "LocalProvider 执行结构化 host.probe"
local_output=""
if declare -F host_provider_execute >/dev/null && local_output="$(host_provider_execute local host.probe 2>/dev/null)" &&
    [[ "$local_output" == *"result.host=local"* ]] &&
    [[ "$local_output" == *"result.provider=local"* ]] &&
    [[ "$local_output" == *"result.status=success"* ]] &&
    [[ "$local_output" == *"payload.protocol=user-manager-readonly-v1"* ]]; then
    test_pass
else
    test_fail "LocalProvider 输出异常: ${local_output:-<empty>}"
fi

test_start "SSHProvider 使用隔离配置和严格主机校验"
: >"$SSH_CALL_FILE"
ssh_output=""
if declare -F host_provider_execute >/dev/null && ssh_output="$(host_provider_execute compute-01 host.probe 2>/dev/null)"; then
    mapfile -d '' -t ssh_args <"$SSH_ARGV_FILE"
    argv_text="$(printf '%s\n' "${ssh_args[@]}")"
    argc=${#ssh_args[@]}
    if [[ "$argv_text" == *$'-F\n/dev/null'* ]] &&
        [[ "$argv_text" == *"BatchMode=yes"* ]] &&
        [[ "$argv_text" == *"StrictHostKeyChecking=yes"* ]] &&
        [[ "$argv_text" == *"UserKnownHostsFile=$known_hosts_file"* ]] &&
        [[ "$argv_text" == *"GlobalKnownHostsFile=/dev/null"* ]] &&
        [[ "$argv_text" == *"HostKeyAlias=compute-01"* ]] &&
        [[ "$argv_text" == *"ProxyCommand=none"* ]] &&
        [[ "$argv_text" == *"PasswordAuthentication=no"* ]] &&
        [[ "${ssh_args[argc - 2]}" == "192.0.2.10" ]] &&
        [[ "${ssh_args[argc - 1]}" == "/opt/user-manager/scripts/rl-remote-entry.sh host.probe" ]] &&
        [[ "$argv_text" != *"provider-display-injection"* ]]; then
        test_pass
    else
        test_fail "SSH 安全 argv 不符合契约: $argv_text"
    fi
else
    test_fail "SSHProvider 执行失败: ${ssh_output:-<empty>}"
fi

test_start "未知 action 在 SSH 调用前被拒绝"
: >"$SSH_CALL_FILE"
if declare -F host_provider_execute >/dev/null &&
    ! host_provider_execute compute-01 'users.create;id' >/dev/null 2>&1 &&
    [[ ! -s "$SSH_CALL_FILE" ]]; then
    test_pass
else
    test_fail "未知 action 触发了 SSH"
fi

test_start "专用 known_hosts 缺失时不调用 SSH"
: >"$SSH_CALL_FILE"
USER_MANAGER_SSH_KNOWN_HOSTS_FILE="$TEST_TMPDIR/missing-known-hosts"
if declare -F host_provider_execute >/dev/null &&
    ! host_provider_execute compute-01 host.probe >/dev/null 2>&1 &&
    [[ "${PROVIDER_RESULT_CODE:-}" == "KNOWN_HOSTS_UNAVAILABLE" ]] &&
    [[ ! -s "$SSH_CALL_FILE" ]]; then
    test_pass
else
    test_fail "known_hosts 缺失处理异常"
fi
USER_MANAGER_SSH_KNOWN_HOSTS_FILE="$known_hosts_file"

test_start "主机密钥变化映射为独立安全错误"
: >"$SSH_CALL_FILE"
export SSH_EXIT_CODE=255 SSH_STDERR_TEXT='WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!'
if ! host_provider_execute compute-01 host.probe >/dev/null 2>&1 &&
    [[ "${PROVIDER_RESULT_STATUS:-}" == "failed" ]] &&
    [[ "${PROVIDER_RESULT_CODE:-}" == "HOST_KEY_MISMATCH" ]]; then
    test_pass
else
    test_fail "主机密钥变化未被精确映射: ${PROVIDER_RESULT_STATUS:-}/${PROVIDER_RESULT_CODE:-}"
fi

test_start "未知主机密钥不会自动登记"
before_hash="$(sha256sum "$known_hosts_file")"
export SSH_EXIT_CODE=255 SSH_STDERR_TEXT='No ED25519 host key is known for compute-01 and you have requested strict checking.'
if ! host_provider_execute compute-01 host.probe >/dev/null 2>&1 &&
    [[ "${PROVIDER_RESULT_CODE:-}" == "HOST_KEY_UNKNOWN" ]] &&
    [[ "$(sha256sum "$known_hosts_file")" == "$before_hash" ]]; then
    test_pass
else
    test_fail "未知主机密钥处理或 known_hosts 不可变性异常"
fi

test_start "远端协议污染返回 protocol error"
invalid_payload="$TEST_TMPDIR/invalid.payload"
printf 'protocol=user-manager-readonly-v1\naction=host.probe\nstatus=success\ncode=OK\nunknown=bad\nend=1\n' >"$invalid_payload"
export SSH_STDOUT_FILE="$invalid_payload" SSH_EXIT_CODE=0 SSH_STDERR_TEXT=''
if ! host_provider_execute compute-01 host.probe >/dev/null 2>&1 &&
    [[ "${PROVIDER_RESULT_CODE:-}" == "PROTOCOL_ERROR" ]]; then
    test_pass
else
    test_fail "非法协议未被拒绝"
fi

test_start "每主机动作具有 wall-clock 超时"
export SSH_STDOUT_FILE="$host_payload" SSH_EXIT_CODE=0 SSH_SLEEP_SECONDS=3 USER_MANAGER_SSH_ACTION_TIMEOUT=1
start_seconds=$SECONDS
if ! host_provider_execute compute-01 host.probe >/dev/null 2>&1 &&
    [[ "${PROVIDER_RESULT_CODE:-}" == "ACTION_TIMEOUT" ]] &&
    ((SECONDS - start_seconds < 3)); then
    test_pass
else
    test_fail "动作超时未生效: ${PROVIDER_RESULT_CODE:-}"
fi
unset SSH_SLEEP_SECONDS USER_MANAGER_SSH_ACTION_TIMEOUT

cleanup_test_env
test_suite_end
