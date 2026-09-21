#!/bin/bash
# host_provider.sh - 本机/SSH 只读 Provider 与结果协议

HOST_PROVIDER_PROTOCOL='user-manager-provider-v1'
HOST_PROVIDER_MAX_STDOUT=65536
HOST_PROVIDER_MAX_STDERR=8192

PROVIDER_RESULT_STATUS=''; PROVIDER_RESULT_CODE=''; PROVIDER_RESULT_MESSAGE=''; PROVIDER_RESULT_DURATION_MS=0

host_provider_action_allowed() {
    case "${1:-}" in host.probe | gpu.summary) return 0 ;; *) return 1 ;; esac
}

_host_provider_remote_command() {
    case "$1" in
    host.probe) printf '%s\n' '/opt/user-manager/scripts/rl-remote-entry.sh host.probe' ;;
    gpu.summary) printf '%s\n' '/opt/user-manager/scripts/rl-remote-entry.sh gpu.summary' ;;
    *) return 1 ;;
    esac
}

_host_provider_set_result() {
    PROVIDER_RESULT_STATUS="$1"; PROVIDER_RESULT_CODE="$2"; PROVIDER_RESULT_MESSAGE="${3:-$2}"
}

_host_provider_now_ms() {
    local now
    now="$(date +%s%3N 2>/dev/null || true)"
    if [[ "$now" =~ ^[0-9]+$ ]]; then printf '%s\n' "$now"; else printf '%s000\n' "$(date +%s)"; fi
}

_host_provider_duration() {
    local start="$1" end
    end="$(_host_provider_now_ms)"
    if [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]] && ((end >= start)); then printf '%s\n' "$((end - start))"
    else printf '0\n'; fi
}

_host_provider_safe_limit() {
    local value="$1" fallback="$2" min="$3" max="$4"
    if [[ "$value" =~ ^[0-9]+$ ]] && ((value >= min && value <= max)); then printf '%s\n' "$value"; else printf '%s\n' "$fallback"; fi
}

_host_provider_temp_dir() { umask 077; mktemp -d "${TMPDIR:-/tmp}/user-manager-provider.XXXXXX"; }

_host_provider_file_is_text_bounded() {
    local file="$1" max_bytes="$2" size clean_size
    size="$(stat -Lc '%s' -- "$file" 2>/dev/null || printf '0')"
    [[ "$size" =~ ^[0-9]+$ ]] && ((size <= max_bytes)) || return 1
    clean_size="$(LC_ALL=C tr -d '\000' <"$file" | wc -c)" || return 1
    [[ "$clean_size" =~ ^[0-9]+$ && "$clean_size" == "$size" ]]
}

_host_provider_key_allowed() {
    local action="$1" key="$2"
    case "$key" in protocol | action | status | code | end) return 0 ;; esac
    case "$action:$key" in
    host.probe:os_id | host.probe:os_version | host.probe:arch | host.probe:bash_version | host.probe:systemd | host.probe:cgroup | host.probe:project_version | host.probe:gpu_backend) return 0 ;;
    gpu.summary:backend | gpu.summary:capability | gpu.summary:gpu_count | gpu.summary:process_count | gpu.summary:process_visibility) return 0 ;;
    gpu.summary:gpu.* | gpu.summary:process.*)
        [[ "$key" =~ ^(gpu|process)\.[0-9]+$ ]]
        return $?
        ;;
    esac
    return 1
}

_host_provider_validate_payload() {
    local file="$1" expected_action="$2" command_rc="$3" line key value line_count=0
    local protocol='' action='' status='' code='' end_marker=''
    local value_pattern='^[A-Za-z0-9._:+/@%,;=-]*$'
    local -A seen=()
    _host_provider_file_is_text_bounded "$file" "$HOST_PROVIDER_MAX_STDOUT" || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_count += 1)); ((line_count <= 400)) || return 1
        ((${#line} <= 1024)) || return 1
        [[ ! "$line" =~ [[:cntrl:]] ]] || return 1
        [[ "$line" == *=* ]] || return 1
        key="${line%%=*}"; value="${line#*=}"
        [[ "$key" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
        [[ "$value" =~ $value_pattern ]] || return 1
        _host_provider_key_allowed "$expected_action" "$key" || return 1
        [[ -z "${seen[$key]:-}" ]] || return 1
        seen["$key"]=1
        case "$key" in protocol) protocol="$value" ;; action) action="$value" ;; status) status="$value" ;;
        code) code="$value" ;; end) end_marker="$value" ;; esac
    done <"$file"
    [[ "$protocol" == 'user-manager-readonly-v1' && "$action" == "$expected_action" &&
        "$end_marker" == '1' && -n "$code" ]] || return 1
    case "$status" in
    success) ((command_rc == 0)) || return 1 ;; unsupported) ((command_rc == 4)) || return 1 ;;
    failed) ((command_rc != 0 && command_rc != 4)) || return 1 ;; *) return 1 ;;
    esac
    PROVIDER_RESULT_STATUS="$status"; PROVIDER_RESULT_CODE="$code"; PROVIDER_RESULT_MESSAGE="$code"
}

_host_provider_emit_result() {
    local host="$1" provider="$2" action="$3" payload="$4" line
    printf 'result.protocol=%s\n' "$HOST_PROVIDER_PROTOCOL"
    printf 'result.host=%s\nresult.provider=%s\nresult.action=%s\n' "$host" "$provider" "$action"
    printf 'result.status=%s\nresult.code=%s\n' "$PROVIDER_RESULT_STATUS" "$PROVIDER_RESULT_CODE"
    printf 'result.duration_ms=%s\n' "$PROVIDER_RESULT_DURATION_MS"
    if [[ -f "$payload" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do printf 'payload.%s\n' "$line"; done <"$payload"
    fi
    printf 'result.end=1\n'
}

_host_provider_return_code() {
    case "$PROVIDER_RESULT_STATUS" in success) return 0 ;; unsupported) return 4 ;; unreachable) return 5 ;; *) return 6 ;; esac
}

_host_provider_execute_local() {
    local host="$1" action="$2" temp_dir payload rc=0 start
    start="$(_host_provider_now_ms)"; temp_dir="$(_host_provider_temp_dir)" || return 6; payload="$temp_dir/payload"
    case "$action" in
    host.probe) host_probe_snapshot_kv >"$payload" 2>/dev/null || rc=$? ;;
    gpu.summary) gpu_snapshot_kv >"$payload" 2>/dev/null || rc=$? ;;
    *) rm -rf -- "$temp_dir"; _host_provider_set_result failed ACTION_NOT_ALLOWED; return 2 ;;
    esac
    if ! _host_provider_validate_payload "$payload" "$action" "$rc"; then _host_provider_set_result failed PROTOCOL_ERROR; fi
    PROVIDER_RESULT_DURATION_MS="$(_host_provider_duration "$start")"
    _host_provider_emit_result "$host" local "$action" "$payload"
    rm -rf -- "$temp_dir"
    _host_provider_return_code
}

_host_provider_map_ssh_error() {
    local rc="$1" diagnostic="$2"
    if ((rc == 124 || rc == 137)); then _host_provider_set_result failed ACTION_TIMEOUT
    elif [[ "$diagnostic" == *'REMOTE HOST IDENTIFICATION HAS CHANGED'* ]]; then _host_provider_set_result failed HOST_KEY_MISMATCH
    elif [[ "$diagnostic" == *'No '*" host key is known"* || "$diagnostic" == *'Host key verification failed'* ]]; then _host_provider_set_result failed HOST_KEY_UNKNOWN
    elif [[ "$diagnostic" == *'Permission denied'* ]]; then _host_provider_set_result failed AUTH_FAILED
    elif [[ "$diagnostic" == *'Connection timed out'* || "$diagnostic" == *'Operation timed out'* ]]; then _host_provider_set_result unreachable CONNECT_TIMEOUT
    elif ((rc == 255)); then _host_provider_set_result unreachable SSH_TRANSPORT_ERROR
    else _host_provider_set_result failed REMOTE_ACTION_FAILED; fi
}

_host_provider_execute_ssh() {
    local host="$1" action="$2" start temp_dir payload diagnostic_file diagnostic rc=0
    local known_hosts ssh_bin timeout_bin remote_command connect_timeout alive_interval alive_count action_timeout
    local -a args=()
    start="$(_host_provider_now_ms)"
    known_hosts="${USER_MANAGER_SSH_KNOWN_HOSTS_FILE:-${DATA_DIR:-./data}/ssh_known_hosts}"
    if ! host_inventory_validate_trusted_file "$known_hosts" 1048576 >/dev/null 2>&1; then
        _host_provider_set_result failed KNOWN_HOSTS_UNAVAILABLE
        PROVIDER_RESULT_DURATION_MS="$(_host_provider_duration "$start")"
        return 6
    fi
    ssh_bin="$(command -v ssh 2>/dev/null || true)"; timeout_bin="$(command -v timeout 2>/dev/null || true)"
    [[ -n "$ssh_bin" && -n "$timeout_bin" ]] || {
        _host_provider_set_result failed SSH_CLIENT_UNAVAILABLE
        PROVIDER_RESULT_DURATION_MS="$(_host_provider_duration "$start")"
        return 6
    }
    remote_command="$(_host_provider_remote_command "$action")" || {
        _host_provider_set_result failed ACTION_NOT_ALLOWED
        PROVIDER_RESULT_DURATION_MS="$(_host_provider_duration "$start")"
        return 2
    }
    connect_timeout="$(_host_provider_safe_limit "${USER_MANAGER_SSH_CONNECT_TIMEOUT:-8}" 8 1 60)"
    alive_interval="$(_host_provider_safe_limit "${USER_MANAGER_SSH_ALIVE_INTERVAL:-5}" 5 1 60)"
    alive_count="$(_host_provider_safe_limit "${USER_MANAGER_SSH_ALIVE_COUNT:-2}" 2 1 10)"
    action_timeout="$(_host_provider_safe_limit "${USER_MANAGER_SSH_ACTION_TIMEOUT:-30}" 30 1 300)"
    args=(-F /dev/null
        -o BatchMode=yes -o StrictHostKeyChecking=yes
        -o "UserKnownHostsFile=$known_hosts" -o GlobalKnownHostsFile=/dev/null
        -o "HostKeyAlias=$host" -o CheckHostIP=no
        -o "ConnectTimeout=$connect_timeout" -o "ServerAliveInterval=$alive_interval" -o "ServerAliveCountMax=$alive_count"
        -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o PreferredAuthentications=publickey
        -o ForwardAgent=no -o ClearAllForwardings=yes -o PermitLocalCommand=no
        -o ProxyCommand=none -o ProxyJump=none -o RemoteCommand=none -o RequestTTY=no
        -p "${HOST_PORT[$host]}" -l "${HOST_USER[$host]}" -- "${HOST_ADDRESS[$host]}" "$remote_command")

    temp_dir="$(_host_provider_temp_dir)" || return 6
    payload="$temp_dir/payload"; diagnostic_file="$temp_dir/stderr"
    LC_ALL=C "$timeout_bin" --foreground --signal=TERM --kill-after=2 "$action_timeout" \
        "$ssh_bin" "${args[@]}" >"$payload" 2>"$diagnostic_file" || rc=$?
    if ! _host_provider_file_is_text_bounded "$diagnostic_file" "$HOST_PROVIDER_MAX_STDERR"; then
        _host_provider_set_result failed SSH_DIAGNOSTIC_TOO_LARGE
    else
        diagnostic="$(<"$diagnostic_file")"
        if ((rc == 0 || rc == 1 || rc == 2 || rc == 3 || rc == 4 || rc == 6)); then
            if ! _host_provider_validate_payload "$payload" "$action" "$rc"; then _host_provider_set_result failed PROTOCOL_ERROR; fi
        else
            _host_provider_map_ssh_error "$rc" "$diagnostic"
        fi
    fi
    PROVIDER_RESULT_DURATION_MS="$(_host_provider_duration "$start")"
    _host_provider_emit_result "$host" ssh "$action" "$payload"
    rm -rf -- "$temp_dir"
    _host_provider_return_code
}

host_provider_execute() {
    local host="${1:-}" action="${2:-}"
    PROVIDER_RESULT_STATUS=''; PROVIDER_RESULT_CODE=''; PROVIDER_RESULT_MESSAGE=''; PROVIDER_RESULT_DURATION_MS=0
    if ! host_provider_action_allowed "$action"; then _host_provider_set_result failed ACTION_NOT_ALLOWED; return 2; fi
    if [[ -z "$host" || -z "${HOST_PROVIDER[$host]:-}" || "${HOST_ENABLED[$host]:-false}" != true ]]; then
        _host_provider_set_result failed HOST_NOT_AVAILABLE
        return 2
    fi
    case "${HOST_PROVIDER[$host]}" in
    local) _host_provider_execute_local "$host" "$action" ;;
    ssh) _host_provider_execute_ssh "$host" "$action" ;;
    *) _host_provider_set_result failed PROVIDER_NOT_SUPPORTED; return 2 ;;
    esac
}

host_provider_probe() { host_provider_execute "$1" host.probe; }

