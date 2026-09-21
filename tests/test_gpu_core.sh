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
if declare -F list_gpu_devices >/dev/null &&
    declare -F show_gpu_status >/dev/null &&
    declare -F show_gpu_processes >/dev/null; then
    test_pass
else
    test_fail "GPU core 未导出预期函数"
fi

test_start "list_gpu_devices 优先使用 nvidia-smi"
nvidia-smi() {
    printf '%s\n' "$*" >>"$TEST_TMPDIR/nvidia-smi.calls"
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

test_start "GPU core 导出结构化只读快照"
if declare -F gpu_snapshot_kv >/dev/null; then
    test_pass
else
    test_fail "gpu_snapshot_kv 函数不存在"
fi

test_start "gpu_snapshot_kv 输出 NVIDIA 设备与进程归属"
nvidia-smi() {
    case "$*" in
    *"--query-gpu="*)
        printf '0, GPU-abc, NVIDIA RTX 4090, 550.54, 42, 125.5, 24564, 1024, 30\n'
        ;;
    *"--query-compute-apps="*)
        printf '4242, GPU-abc, 512, python\n'
        ;;
    *) return 1 ;;
    esac
}
ps() {
    printf 'alice\n'
}
if declare -F gpu_snapshot_kv >/dev/null && snapshot_output="$(gpu_snapshot_kv 2>/dev/null)" &&
    [[ "$snapshot_output" == *"status=success"* ]] &&
    [[ "$snapshot_output" == *"backend=nvidia-smi"* ]] &&
    [[ "$snapshot_output" == *"gpu_count=1"* ]] &&
    [[ "$snapshot_output" == *"uuid=GPU-abc"* ]] &&
    [[ "$snapshot_output" == *"process_count=1"* ]] &&
    [[ "$snapshot_output" == *"user=alice"* ]]; then
    test_pass
else
    test_fail "NVIDIA 结构化快照异常: ${snapshot_output:-<empty>}"
fi
unset -f nvidia-smi ps

test_start "gpu_snapshot_kv 在无 NVIDIA 时降级为 PCI 概览"
lspci() {
    printf '01:00.0 VGA compatible controller: NVIDIA Corporation AD102 [GeForce RTX]\n'
    printf '00:1f.3 Audio device: Intel Corporation Device\n'
}
if snapshot_output="$(gpu_snapshot_kv 2>/dev/null)" &&
    [[ "$snapshot_output" == *"status=success"* ]] &&
    [[ "$snapshot_output" == *"backend=lspci"* ]] &&
    [[ "$snapshot_output" == *"capability=limited"* ]] &&
    [[ "$snapshot_output" == *"gpu_count=1"* ]]; then
    test_pass
else
    test_fail "PCI 降级快照异常: ${snapshot_output:-<empty>}"
fi
unset -f lspci

test_start "gpu_snapshot_kv 缺少全部工具时返回 unsupported"
snapshot_rc=0
snapshot_output="$(PATH="$TEST_TMPDIR" gpu_snapshot_kv 2>/dev/null)" || snapshot_rc=$?
if ((snapshot_rc != 0)) && [[ "$snapshot_output" == *"status=unsupported"* ]] && [[ "$snapshot_output" == *"backend=none"* ]]; then
    test_pass
else
    test_fail "无工具降级语义异常: rc=$snapshot_rc output=${snapshot_output:-<empty>}"
fi

test_start "gpu_snapshot_kv 不泄露完整进程命令"
nvidia-smi() {
    case "$*" in
    *"--query-gpu="*) printf '0, GPU-abc, GPU Name, 550.54, 42, 10, 100, 1, 2\n' ;;
    *"--query-compute-apps="*) printf '99, GPU-abc, 1, python --token=secret-value\n' ;;
    *) return 1 ;;
    esac
}
ps() { printf 'bob\n'; }
snapshot_output="$(gpu_snapshot_kv 2>/dev/null || true)"
if [[ "$snapshot_output" != *"secret-value"* ]] && [[ "$snapshot_output" == *"name=python"* ]]; then
    test_pass
else
    test_fail "GPU 进程输出包含完整命令或未裁剪: $snapshot_output"
fi
unset -f nvidia-smi ps

test_start "nvidia-smi 查询失败后保留 PCI 降级原因"
nvidia-smi() { return 1; }
lspci() { printf '01:00.0 3D controller: NVIDIA Corporation Device\n'; }
snapshot_rc=0
snapshot_output="$(gpu_snapshot_kv 2>/dev/null)" || snapshot_rc=$?
if ((snapshot_rc == 0)) && [[ "$snapshot_output" == *"backend=lspci"* ]] &&
    [[ "$snapshot_output" == *"code=NVIDIA_QUERY_FAILED_FALLBACK"* ]]; then
    test_pass
else
    test_fail "NVIDIA 失败降级异常: rc=$snapshot_rc output=$snapshot_output"
fi
unset -f nvidia-smi lspci

test_start "lspci 存在但无 GPU 时返回 GPU_NOT_FOUND"
lspci() { printf '00:1f.3 Audio device: Intel Corporation Device\n'; }
snapshot_rc=0
snapshot_output="$(gpu_snapshot_kv 2>/dev/null)" || snapshot_rc=$?
if ((snapshot_rc == 4)) && [[ "$snapshot_output" == *"backend=lspci"* ]] &&
    [[ "$snapshot_output" == *"status=unsupported"* ]] && [[ "$snapshot_output" == *"code=GPU_NOT_FOUND"* ]]; then
    test_pass
else
    test_fail "无 GPU 的 PCI 语义异常: rc=$snapshot_rc output=$snapshot_output"
fi
unset -f lspci

cleanup_test_env
test_suite_end
