#!/bin/bash
# test_gpu_core.sh - 显卡管理核心模块测试

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"

if [[ -f "$PROJECT_ROOT/lib/gpu_core.sh" ]]; then
    # shellcheck disable=SC1091
    source "$PROJECT_ROOT/lib/gpu_core.sh"
fi

setup_test_env
test_suite_start "GPU Core"

test_start "gpu_core.sh 文件存在"
assert_file_exists "$PROJECT_ROOT/lib/gpu_core.sh"

test_start "GPU core 导出基础函数"
if declare -F list_gpu_devices >/dev/null && \
   declare -F show_gpu_status >/dev/null && \
   declare -F show_gpu_processes >/dev/null; then
    test_pass
else
    test_fail "GPU core 未导出预期函数"
fi

test_start "list_gpu_devices 优先使用 nvidia-smi"
nvidia-smi() {
    printf '%s\n' "$*" >> "$TEST_TMPDIR/nvidia-smi.calls"
    if [[ "$*" == *"--query-gpu=index,name,driver_version,memory.total"* ]]; then
        printf '0, NVIDIA RTX 4090, 550.54, 24564\n'
        return 0
    fi
    return 1
}
if declare -F list_gpu_devices >/dev/null && gpu_output="$(list_gpu_devices 2>/dev/null)" && [[ "$gpu_output" == *"NVIDIA RTX 4090"* ]] && [[ "$gpu_output" == *"24564"* ]]; then
    test_pass
else
    test_fail "list_gpu_devices 未优先展示 nvidia-smi 数据"
fi

test_start "无 nvidia-smi 时回退 lspci"
unset -f nvidia-smi
lspci() {
    printf '01:00.0 VGA compatible controller: NVIDIA Corporation AD102 [GeForce RTX]\n'
    return 0
}
if declare -F list_gpu_devices >/dev/null && fallback_output="$(list_gpu_devices 2>/dev/null)" && [[ "$fallback_output" == *"GeForce RTX"* ]]; then
    test_pass
else
    test_fail "list_gpu_devices 未在无 nvidia-smi 时回退 lspci"
fi

test_start "show_gpu_status 在缺少工具时给出可读提示"
unset -f lspci
if declare -F show_gpu_status >/dev/null; then
    status_output="$(PATH="$TEST_TMPDIR" show_gpu_status 2>/dev/null || true)"
    if [[ "$status_output" == *"未检测到可用的显卡查询工具"* ]]; then
        test_pass
    else
        test_fail "缺少显卡工具时未给出预期提示"
    fi
else
    test_fail "show_gpu_status 函数不存在"
fi

cleanup_test_env
test_suite_end
