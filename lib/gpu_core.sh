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
