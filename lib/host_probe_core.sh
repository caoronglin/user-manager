#!/bin/bash
# host_probe_core.sh - 本机系统能力的版本化只读快照

_host_probe_safe_value() {
    local value="$1" output='' char i
    local LC_ALL=C
    value="${value//$'\r'/ }"
    value="${value//$'\n'/ }"
    value="${value//$'\t'/ }"
    for ((i = 0; i < ${#value} && i < 128; i++)); do
        char="${value:i:1}"
        case "$char" in [A-Za-z0-9._:+/@%,-]) output+="$char" ;; ' ') output+='_' ;; *) output+='_' ;; esac
    done
    printf '%s\n' "$output"
}

_host_probe_os_release() {
    local wanted="$1" key value
    [[ -r /etc/os-release ]] || {
        printf 'unknown\n'
        return 0
    }
    while IFS='=' read -r key value; do
        [[ "$key" == "$wanted" ]] || continue
        if [[ "${value:0:1}" == '"' ]]; then value="${value:1}"; fi
        if [[ "${value: -1}" == '"' ]]; then value="${value:0:${#value}-1}"; fi
        _host_probe_safe_value "$value"
        return 0
    done </etc/os-release
    printf 'unknown\n'
}

_host_probe_systemd_state() {
    if ! command -v systemctl >/dev/null 2>&1; then
        printf 'missing\n'
    elif [[ -d /run/systemd/system ]]; then
        printf 'available\n'
    else printf 'not-running\n'; fi
}

_host_probe_cgroup_version() {
    local fs_type
    fs_type="$(stat -fc '%T' /sys/fs/cgroup 2>/dev/null || true)"
    case "$fs_type" in cgroup2fs) printf 'v2\n' ;; tmpfs) printf 'v1\n' ;; *) printf 'unknown\n' ;; esac
}

_host_probe_gpu_backend() {
    if declare -F gpu_have_nvidia_smi >/dev/null 2>&1 && gpu_have_nvidia_smi; then
        printf 'nvidia-smi\n'
    elif declare -F gpu_have_lspci >/dev/null 2>&1 && gpu_have_lspci; then
        printf 'lspci\n'
    else printf 'none\n'; fi
}

host_probe_snapshot_kv() {
    local arch version
    arch="$(uname -m 2>/dev/null || printf 'unknown')"
    version="${USER_MANAGER_VERSION:-dev}"
    printf 'protocol=user-manager-readonly-v1\n'
    printf 'action=host.probe\nstatus=success\ncode=OK\n'
    printf 'os_id=%s\n' "$(_host_probe_os_release ID)"
    printf 'os_version=%s\n' "$(_host_probe_os_release VERSION_ID)"
    printf 'arch=%s\n' "$(_host_probe_safe_value "$arch")"
    printf 'bash_version=%s.%s\n' "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"
    printf 'systemd=%s\n' "$(_host_probe_systemd_state)"
    printf 'cgroup=%s\n' "$(_host_probe_cgroup_version)"
    printf 'project_version=%s\n' "$(_host_probe_safe_value "$version")"
    printf 'gpu_backend=%s\n' "$(_host_probe_gpu_backend)"
    printf 'end=1\n'
}
