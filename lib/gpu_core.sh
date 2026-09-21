#!/bin/bash
# gpu_core.sh - 显卡状态查询核心模块

gpu_have_nvidia_smi() {
    command -v nvidia-smi >/dev/null 2>&1 || declare -F nvidia-smi >/dev/null 2>&1
}

gpu_have_lspci() {
    command -v lspci >/dev/null 2>&1 || declare -F lspci >/dev/null 2>&1
}

list_gpu_devices() {
    if gpu_have_nvidia_smi; then
        nvidia-smi --query-gpu=index,name,driver_version,memory.total --format=csv,noheader,nounits
        return $?
    fi

    if gpu_have_lspci; then
        lspci | grep -Ei 'vga|3d|display|nvidia|amd|radeon|intel' || true
        return 0
    fi

    echo "未检测到可用的显卡查询工具（nvidia-smi/lspci）"
    return 0
}

show_gpu_status() {
    if gpu_have_nvidia_smi; then
        nvidia-smi
        return $?
    fi

    if gpu_have_lspci; then
        list_gpu_devices
        return 0
    fi

    echo "未检测到可用的显卡查询工具（nvidia-smi/lspci）"
    return 0
}

show_gpu_processes() {
    if gpu_have_nvidia_smi; then
        nvidia-smi pmon -c 1 2>/dev/null || nvidia-smi
        return $?
    fi

    echo "未检测到 nvidia-smi，无法列出 GPU 进程"
    return 0
}

_gpu_command_timeout() {
    local value="${USER_MANAGER_GPU_COMMAND_TIMEOUT:-8}"
    if [[ "$value" =~ ^[0-9]+$ ]] && ((value >= 1 && value <= 60)); then
        printf '%s\n' "$value"
    else
        printf '8\n'
    fi
}

_gpu_run_bounded() {
    local command_name="$1"
    shift
    if declare -F "$command_name" >/dev/null 2>&1; then
        "$command_name" "$@"
        return $?
    fi
    command -v timeout >/dev/null 2>&1 || return 127
    timeout --foreground --signal=TERM --kill-after=2 "$(_gpu_command_timeout)" \
        "$command_name" "$@"
}

_gpu_capture_bounded() {
    local output_name="$1" command_name="$2" temp_file rc=0 size
    shift 2
    umask 077
    temp_file="$(mktemp "${TMPDIR:-/tmp}/user-manager-gpu.XXXXXX")" || return 1
    _gpu_run_bounded "$command_name" "$@" >"$temp_file" 2>/dev/null || rc=$?
    size="$(stat -Lc '%s' -- "$temp_file" 2>/dev/null || printf '0')"
    if [[ ! "$size" =~ ^[0-9]+$ ]] || ((size > 32768)); then
        rm -f -- "$temp_file"
        return 75
    fi
    printf -v "$output_name" '%s' "$(<"$temp_file")"
    rm -f -- "$temp_file"
    return "$rc"
}

_gpu_trim() {
    local value="$1"
    while [[ "$value" == ' '* ]]; do value="${value# }"; done
    while [[ "$value" == *' ' ]]; do value="${value% }"; done
    printf '%s\n' "$value"
}

_gpu_safe_value() {
    local value="$1" output='' char i
    local LC_ALL=C
    value="${value//$'\r'/ }"
    value="${value//$'\n'/ }"
    value="${value//$'\t'/ }"
    for ((i = 0; i < ${#value} && i < 128; i++)); do
        char="${value:i:1}"
        case "$char" in
        [A-Za-z0-9._:+/@%,-]) output+="$char" ;;
        ' ') output+='_' ;;
        *) output+='_' ;;
        esac
    done
    printf '%s\n' "$output"
}

_gpu_emit_header() {
    printf 'protocol=user-manager-readonly-v1\n'
    printf 'action=gpu.summary\n'
}

_gpu_snapshot_lspci() {
    local nvidia_failed="${1:-0}" pci_output line normalized count=0
    local -a devices=()

    if ! gpu_have_lspci; then
        _gpu_emit_header
        printf 'status=unsupported\ncode=GPU_TOOL_MISSING\nbackend=none\ncapability=none\n'
        printf 'gpu_count=0\nprocess_count=0\nend=1\n'
        return 4
    fi
    if ! _gpu_capture_bounded pci_output lspci; then
        _gpu_emit_header
        printf 'status=failed\ncode=GPU_PCI_QUERY_FAILED\nbackend=lspci\ncapability=none\n'
        printf 'gpu_count=0\nprocess_count=0\nend=1\n'
        return 1
    fi
    while IFS= read -r line; do
        normalized="${line,,}"
        if [[ "$normalized" == *'vga compatible controller'* ||
            "$normalized" == *'3d controller'* ||
            "$normalized" == *'display controller'* ]]; then
            devices+=("$(_gpu_safe_value "$line")")
            ((count += 1))
            ((count >= 64)) && break
        fi
    done <<<"$pci_output"

    _gpu_emit_header
    if ((count == 0)); then
        printf 'status=unsupported\ncode=GPU_NOT_FOUND\nbackend=lspci\ncapability=limited\n'
        printf 'gpu_count=0\nprocess_count=0\nend=1\n'
        return 4
    fi
    printf 'status=success\n'
    if ((nvidia_failed)); then printf 'code=NVIDIA_QUERY_FAILED_FALLBACK\n'; else printf 'code=OK\n'; fi
    printf 'backend=lspci\ncapability=limited\n'
    printf 'gpu_count=%s\n' "$count"
    for ((count = 0; count < ${#devices[@]}; count++)); do
        printf 'gpu.%s=description=%s\n' "$count" "${devices[$count]}"
    done
    printf 'process_count=0\nend=1\n'
}

gpu_snapshot_kv() {
    local gpu_output process_output line
    local index uuid name driver temperature power memory_total memory_used utilization extra
    local pid process_uuid process_memory process_name process_short process_user
    local gpu_count=0 process_count=0 process_visibility='available'
    local -a gpu_records=() process_records=()

    if ! gpu_have_nvidia_smi; then
        _gpu_snapshot_lspci 0
        return $?
    fi
    if ! _gpu_capture_bounded gpu_output nvidia-smi \
        --query-gpu=index,uuid,name,driver_version,temperature.gpu,power.draw,memory.total,memory.used,utilization.gpu \
        --format=csv,noheader,nounits || [[ -z "$gpu_output" ]]; then
        _gpu_snapshot_lspci 1
        return $?
    fi

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        IFS=',' read -r index uuid name driver temperature power memory_total memory_used utilization extra \
            <<<"$line"
        [[ -z "$extra" ]] || continue
        index="$(_gpu_trim "$index")"; uuid="$(_gpu_trim "$uuid")"; name="$(_gpu_trim "$name")"
        driver="$(_gpu_trim "$driver")"; temperature="$(_gpu_trim "$temperature")"
        power="$(_gpu_trim "$power")"; memory_total="$(_gpu_trim "$memory_total")"
        memory_used="$(_gpu_trim "$memory_used")"; utilization="$(_gpu_trim "$utilization")"
        [[ "$index" =~ ^[0-9]+$ && -n "$uuid" ]] || continue
        gpu_records+=("index=$(_gpu_safe_value "$index");uuid=$(_gpu_safe_value "$uuid");name=$(_gpu_safe_value "$name");driver=$(_gpu_safe_value "$driver");temperature_c=$(_gpu_safe_value "$temperature");power_w=$(_gpu_safe_value "$power");memory_total_mib=$(_gpu_safe_value "$memory_total");memory_used_mib=$(_gpu_safe_value "$memory_used");utilization_pct=$(_gpu_safe_value "$utilization")")
        ((gpu_count += 1))
        ((gpu_count >= 64)) && break
    done <<<"$gpu_output"
    if ((gpu_count == 0)); then
        _gpu_snapshot_lspci 1
        return $?
    fi

    if _gpu_capture_bounded process_output nvidia-smi \
        --query-compute-apps=pid,gpu_uuid,used_gpu_memory,process_name \
        --format=csv,noheader,nounits; then
        while IFS= read -r line; do
            [[ -n "$line" && "$line" != *'No running processes found'* ]] || continue
            IFS=',' read -r pid process_uuid process_memory process_name extra <<<"$line"
            [[ -z "$extra" ]] || continue
            pid="$(_gpu_trim "$pid")"; process_uuid="$(_gpu_trim "$process_uuid")"
            process_memory="$(_gpu_trim "$process_memory")"; process_name="$(_gpu_trim "$process_name")"
            [[ "$pid" =~ ^[0-9]+$ ]] || continue
            read -r process_short _ <<<"$process_name"
            process_user="$(ps -o user= -p "$pid" 2>/dev/null || true)"
            process_user="$(_gpu_trim "$process_user")"
            [[ -n "$process_user" ]] || process_user='unknown'
            process_records+=("pid=$(_gpu_safe_value "$pid");gpu_uuid=$(_gpu_safe_value "$process_uuid");used_memory_mib=$(_gpu_safe_value "$process_memory");user=$(_gpu_safe_value "$process_user");name=$(_gpu_safe_value "$process_short")")
            ((process_count += 1))
            ((process_count >= 256)) && break
        done <<<"$process_output"
    else
        process_visibility='unavailable'
    fi

    _gpu_emit_header
    printf 'status=success\ncode=OK\nbackend=nvidia-smi\ncapability=full\n'
    printf 'gpu_count=%s\n' "$gpu_count"
    for ((index = 0; index < ${#gpu_records[@]}; index++)); do
        printf 'gpu.%s=%s\n' "$index" "${gpu_records[$index]}"
    done
    printf 'process_visibility=%s\nprocess_count=%s\n' "$process_visibility" "$process_count"
    for ((index = 0; index < ${#process_records[@]}; index++)); do
        printf 'process.%s=%s\n' "$index" "${process_records[$index]}"
    done
    printf 'end=1\n'
}
