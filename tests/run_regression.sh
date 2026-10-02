#!/bin/bash
# run_regression.sh - 分级回归执行器

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

LEVEL="all"
INCLUDE_PERF=0
INCLUDE_LINT=0
PARALLEL=1

# P1 并行执行的测试脚本清单；每个测试使用独立临时数据目录。
P1_SCRIPTS=(
    test_action_registry.sh
    test_audit_integration.sh
    test_backup_core.sh
    test_bootstrap_integration.sh
    test_env_core.sh
    test_event_spool.sh
    test_gpu_core.sh
    test_host_inventory.sh
    test_host_provider.sh
    test_execution_plan.sh
    test_remote_cli.sh
    test_journalctl_core.sh
    test_lock_core.sh
    test_logs_core.sh
    test_logs_presenter.sh
    test_network_stack_core.sh
    test_password_change_smb.sh
    test_proc_manager.sh
    test_quota_core.sh
    test_report_core.sh
    test_resource_core.sh
    test_rl_privilege.sh
    test_scripts.sh
    test_security_baseline_core.sh
    test_security_hardening.sh
    test_security_scan.sh
    test_web_deploy_boundary.sh
    test_web_security_gate.sh
    test_shell_config_core.sh
    test_smb_core.sh
    test_snapshot.sh
    test_snapshot_ops.sh
    test_systemd_timer_core.sh
    test_tui_core.sh
    test_tui_logs_view.sh
    test_tui_mainline.sh
    test_tui_native_forms.sh
    test_ubuntu_maintenance_core.sh
    test_user_core.sh
    test_vm_core.sh
)

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

C_RESET='\033[0m'
C_GREEN='\033[1;32m'
C_RED='\033[1;31m'
C_YELLOW='\033[1;33m'
C_BLUE='\033[1;34m'

usage() {
    cat <<EOF
Usage: bash tests/run_regression.sh [options]

Options:
  --level <p0|p1|p2|all>   Select regression level (default: all)
  --include-perf           Run perf_test.sh when level includes p2
  --include-lint           Also run ShellCheck warning gate in test_scripts.sh
  --no-parallel            Disable P1 parallel execution (default: parallel)
  -h, --help               Show this help

Environment:
  UM_TEST_TIMEOUT           Per-suite timeout in seconds (default: 180)
  UM_TEST_JOBS              P1 parallel jobs (default: 4)

Levels:
  p0    Static/load smoke checks (verify_fixes.sh)
  p1    Core behavior tests (bootstrap/user/quota/privilege/smb/password/audit/proc/security/tui/system/network/timer/lock/backup/vm/gpu/hosts)
  p2    Performance baseline (perf_test.sh)
  all   p0 + p1 (and p2 when --include-perf is set)
EOF
}

run_step() {
    local name="$1"
    shift

    local timeout_seconds="${UM_TEST_TIMEOUT:-180}"
    echo -e "${C_BLUE}[RUN]${C_RESET} $name"

    local rc=0
    if command -v timeout >/dev/null 2>&1; then
        timeout "$timeout_seconds" "$@" </dev/null
        rc=$?
    else
        "$@" </dev/null
        rc=$?
    fi

    if ((rc == 0)); then
        echo -e "${C_GREEN}[PASS]${C_RESET} $name"
        ((PASS_COUNT += 1))
    else
        if ((rc == 124)); then
            echo -e "${C_RED}[FAIL]${C_RESET} $name (TIMEOUT after ${timeout_seconds}s)"
        else
            echo -e "${C_RED}[FAIL]${C_RESET} $name (exit $rc)"
        fi
        ((FAIL_COUNT += 1))
    fi
    echo ""
}

skip_step() {
    local name="$1"
    local reason="$2"
    echo -e "${C_YELLOW}[SKIP]${C_RESET} $name - $reason"
    echo ""
    ((SKIP_COUNT += 1))
}

# 并行 P1 单测执行体：每个测试独立临时数据目录，互不污染。
run_p1_one() {
    local name="$1"
    local work="$2"
    local project_root="$3"
    local include_lint="$4"

    local tmp
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/backup"

    local log="$work/$name.log"
    local result="$work/$name.result"
    local timeout_seconds="${UM_TEST_TIMEOUT:-180}"
    local rc=0

    if command -v timeout >/dev/null 2>&1; then
        timeout "$timeout_seconds" env \
            SUDO_NONINTERACTIVE=1 \
            USER_MANAGER_DATA_BASE="$tmp" \
            USER_MANAGER_BACKUP_ROOT="$tmp/backup" \
            UM_INCLUDE_LINT="$include_lint" \
            bash "$project_root/tests/$name" </dev/null >"$log" 2>&1
        rc=$?
    else
        env \
            SUDO_NONINTERACTIVE=1 \
            USER_MANAGER_DATA_BASE="$tmp" \
            USER_MANAGER_BACKUP_ROOT="$tmp/backup" \
            UM_INCLUDE_LINT="$include_lint" \
            bash "$project_root/tests/$name" </dev/null >"$log" 2>&1
        rc=$?
    fi

    if ((rc == 0)); then
        printf 'PASS\n' >"$result"
    elif ((rc == 124)); then
        printf 'TIMEOUT\n' >"$result"
    else
        printf 'FAIL %s\n' "$rc" >"$result"
    fi

    rm -rf "$tmp"
}

run_p1_parallel() {
    local jobs="${UM_TEST_JOBS:-4}"
    local work
    work="$(mktemp -d)"

    export -f run_p1_one
    printf '%s\n' "${P1_SCRIPTS[@]}" | xargs -P "$jobs" -I{} \
        bash -c 'run_p1_one "$1" "$2" "$3" "$4"' _ {} "$work" "$PROJECT_ROOT" "$INCLUDE_LINT"
    local xrc=$?

    local name status extra
    for name in "${P1_SCRIPTS[@]}"; do
        if [[ ! -f "$work/$name.result" ]]; then
            echo -e "${C_RED}[FAIL]${C_RESET} $name (no result)"
            ((FAIL_COUNT += 1))
            echo ""
            continue
        fi

        read -r status extra <"$work/$name.result"
        case "$status" in
        PASS)
            echo -e "${C_GREEN}[PASS]${C_RESET} $name"
            ((PASS_COUNT += 1))
            ;;
        TIMEOUT)
            echo -e "${C_RED}[FAIL]${C_RESET} $name (TIMEOUT after ${UM_TEST_TIMEOUT:-180}s)"
            ((FAIL_COUNT += 1))
            tail -20 "$work/$name.log" 2>/dev/null || true
            ;;
        FAIL)
            echo -e "${C_RED}[FAIL]${C_RESET} $name (exit ${extra:-1})"
            ((FAIL_COUNT += 1))
            tail -20 "$work/$name.log" 2>/dev/null || true
            ;;
        esac
        echo ""
    done

    rm -rf "$work"
    return "$xrc"
}

run_p0() {
    run_step "P0 verify_fixes" bash "$PROJECT_ROOT/verify_fixes.sh"
}

run_p1() {
    if [[ "$PARALLEL" == "1" ]]; then
        run_p1_parallel
        return $?
    fi

    run_step "P1 bootstrap integration" env \
        SUDO_NONINTERACTIVE=1 \
        USER_MANAGER_DATA_BASE="$PROJECT_ROOT/data" \
        USER_MANAGER_BACKUP_ROOT="$PROJECT_ROOT/data/backup" \
        bash "$SCRIPT_DIR/test_bootstrap_integration.sh"

    run_step "P1 user core" env \
        SUDO_NONINTERACTIVE=1 \
        USER_MANAGER_DATA_BASE="$PROJECT_ROOT/data" \
        USER_MANAGER_BACKUP_ROOT="$PROJECT_ROOT/data/backup" \
        bash "$SCRIPT_DIR/test_user_core.sh"

    run_step "P1 password change SMB" env \
        SUDO_NONINTERACTIVE=1 \
        USER_MANAGER_DATA_BASE="$PROJECT_ROOT/data" \
        USER_MANAGER_BACKUP_ROOT="$PROJECT_ROOT/data/backup" \
        bash "$SCRIPT_DIR/test_password_change_smb.sh"

    run_step "P1 resource core" env \
        SUDO_NONINTERACTIVE=1 \
        USER_MANAGER_DATA_BASE="$PROJECT_ROOT/data" \
        USER_MANAGER_BACKUP_ROOT="$PROJECT_ROOT/data/backup" \
        bash "$SCRIPT_DIR/test_resource_core.sh"

    run_step "P1 quota core" env \
        SUDO_NONINTERACTIVE=1 \
        USER_MANAGER_DATA_BASE="$PROJECT_ROOT/data" \
        USER_MANAGER_BACKUP_ROOT="$PROJECT_ROOT/data/backup" \
        bash "$SCRIPT_DIR/test_quota_core.sh"

    run_step "P1 rl_privilege" bash "$SCRIPT_DIR/test_rl_privilege.sh"

    run_step "P1 smb core" bash "$SCRIPT_DIR/test_smb_core.sh"

    run_step "P1 standalone scripts" env \
        UM_INCLUDE_LINT="$INCLUDE_LINT" \
        bash "$SCRIPT_DIR/test_scripts.sh"

    run_step "P1 audit integration" env \
        SUDO_NONINTERACTIVE=1 \
        USER_MANAGER_DATA_BASE="$PROJECT_ROOT/data" \
        USER_MANAGER_BACKUP_ROOT="$PROJECT_ROOT/data/backup" \
        bash "$SCRIPT_DIR/test_audit_integration.sh"

    run_step "P1 proc manager" env \
        SUDO_NONINTERACTIVE=1 \
        USER_MANAGER_DATA_BASE="$PROJECT_ROOT/data" \
        USER_MANAGER_BACKUP_ROOT="$PROJECT_ROOT/data/backup" \
        bash "$SCRIPT_DIR/test_proc_manager.sh"

    run_step "P1 TUI core" env \
        SUDO_NONINTERACTIVE=1 \
        USER_MANAGER_DATA_BASE="$PROJECT_ROOT/data" \
        USER_MANAGER_BACKUP_ROOT="$PROJECT_ROOT/data/backup" \
        bash "$SCRIPT_DIR/test_tui_core.sh"

    run_step "P1 TUI native forms" env \
        SUDO_NONINTERACTIVE=1 \
        USER_MANAGER_DATA_BASE="$PROJECT_ROOT/data" \
        USER_MANAGER_BACKUP_ROOT="$PROJECT_ROOT/data/backup" \
        bash "$SCRIPT_DIR/test_tui_native_forms.sh"

    run_step "P1 TUI mainline" env \
        SUDO_NONINTERACTIVE=1 \
        USER_MANAGER_DATA_BASE="$PROJECT_ROOT/data" \
        USER_MANAGER_BACKUP_ROOT="$PROJECT_ROOT/data/backup" \
        bash "$SCRIPT_DIR/test_tui_mainline.sh"

    run_step "P1 security hardening" env \
        SUDO_NONINTERACTIVE=1 \
        USER_MANAGER_DATA_BASE="$PROJECT_ROOT/data" \
        USER_MANAGER_BACKUP_ROOT="$PROJECT_ROOT/data/backup" \
        bash "$SCRIPT_DIR/test_security_hardening.sh"

    run_step "P1 security scan" env \
        SUDO_NONINTERACTIVE=1 \
        USER_MANAGER_DATA_BASE="$PROJECT_ROOT/data" \
        USER_MANAGER_BACKUP_ROOT="$PROJECT_ROOT/data/backup" \
        bash "$SCRIPT_DIR/test_security_scan.sh"

    run_step "P1 journalctl core" env \
        SUDO_NONINTERACTIVE=1 \
        USER_MANAGER_DATA_BASE="$PROJECT_ROOT/data" \
        USER_MANAGER_BACKUP_ROOT="$PROJECT_ROOT/data/backup" \
        bash "$SCRIPT_DIR/test_journalctl_core.sh"

    run_step "P1 environment core" env \
        SUDO_NONINTERACTIVE=1 \
        USER_MANAGER_DATA_BASE="$PROJECT_ROOT/data" \
        USER_MANAGER_BACKUP_ROOT="$PROJECT_ROOT/data/backup" \
        bash "$SCRIPT_DIR/test_env_core.sh"

    run_step "P1 action registry" env \
        SUDO_NONINTERACTIVE=1 \
        USER_MANAGER_DATA_BASE="$PROJECT_ROOT/data" \
        USER_MANAGER_BACKUP_ROOT="$PROJECT_ROOT/data/backup" \
        bash "$SCRIPT_DIR/test_action_registry.sh"

    run_step "P1 logs core" env \
        SUDO_NONINTERACTIVE=1 \
        USER_MANAGER_DATA_BASE="$PROJECT_ROOT/data" \
        USER_MANAGER_BACKUP_ROOT="$PROJECT_ROOT/data/backup" \
        bash "$SCRIPT_DIR/test_logs_core.sh"

    run_step "P1 report core" env \
        SUDO_NONINTERACTIVE=1 \
        USER_MANAGER_DATA_BASE="$PROJECT_ROOT/data" \
        USER_MANAGER_BACKUP_ROOT="$PROJECT_ROOT/data/backup" \
        bash "$SCRIPT_DIR/test_report_core.sh"

    run_step "P1 shell config core" bash "$SCRIPT_DIR/test_shell_config_core.sh"

    run_step "P1 logs presenter" env \
        SUDO_NONINTERACTIVE=1 \
        USER_MANAGER_DATA_BASE="$PROJECT_ROOT/data" \
        USER_MANAGER_BACKUP_ROOT="$PROJECT_ROOT/data/backup" \
        bash "$SCRIPT_DIR/test_logs_presenter.sh"

    run_step "P1 TUI logs view" env \
        SUDO_NONINTERACTIVE=1 \
        USER_MANAGER_DATA_BASE="$PROJECT_ROOT/data" \
        USER_MANAGER_BACKUP_ROOT="$PROJECT_ROOT/data/backup" \
        bash "$SCRIPT_DIR/test_tui_logs_view.sh"

    run_step "P1 ubuntu maintenance" env \
        SUDO_NONINTERACTIVE=1 \
        USER_MANAGER_DATA_BASE="$PROJECT_ROOT/data" \
        USER_MANAGER_BACKUP_ROOT="$PROJECT_ROOT/data/backup" \
        bash "$SCRIPT_DIR/test_ubuntu_maintenance_core.sh"

    run_step "P1 security baseline" env \
        SUDO_NONINTERACTIVE=1 \
        USER_MANAGER_DATA_BASE="$PROJECT_ROOT/data" \
        USER_MANAGER_BACKUP_ROOT="$PROJECT_ROOT/data/backup" \
        bash "$SCRIPT_DIR/test_security_baseline_core.sh"

    run_step "P1 network stack" env \
        SUDO_NONINTERACTIVE=1 \
        USER_MANAGER_DATA_BASE="$PROJECT_ROOT/data" \
        USER_MANAGER_BACKUP_ROOT="$PROJECT_ROOT/data/backup" \
        bash "$SCRIPT_DIR/test_network_stack_core.sh"

    run_step "P1 systemd timer" env \
        SUDO_NONINTERACTIVE=1 \
        USER_MANAGER_DATA_BASE="$PROJECT_ROOT/data" \
        USER_MANAGER_BACKUP_ROOT="$PROJECT_ROOT/data/backup" \
        bash "$SCRIPT_DIR/test_systemd_timer_core.sh"

    run_step "P1 lock core" env \
        SUDO_NONINTERACTIVE=1 \
        USER_MANAGER_DATA_BASE="$PROJECT_ROOT/data" \
        USER_MANAGER_BACKUP_ROOT="$PROJECT_ROOT/data/backup" \
        bash "$SCRIPT_DIR/test_lock_core.sh"

    run_step "P1 backup core" env \
        SUDO_NONINTERACTIVE=1 \
        USER_MANAGER_DATA_BASE="$PROJECT_ROOT/data" \
        USER_MANAGER_BACKUP_ROOT="$PROJECT_ROOT/data/backup" \
        bash "$SCRIPT_DIR/test_backup_core.sh"

    run_step "P1 VM core" env \
        SUDO_NONINTERACTIVE=1 \
        USER_MANAGER_DATA_BASE="$PROJECT_ROOT/data" \
        USER_MANAGER_BACKUP_ROOT="$PROJECT_ROOT/data/backup" \
        bash "$SCRIPT_DIR/test_vm_core.sh"

    run_step "P1 GPU core" env \
        SUDO_NONINTERACTIVE=1 \
        USER_MANAGER_DATA_BASE="$PROJECT_ROOT/data" \
        USER_MANAGER_BACKUP_ROOT="$PROJECT_ROOT/data/backup" \
        bash "$SCRIPT_DIR/test_gpu_core.sh"

    run_step "P1 host inventory" bash "$SCRIPT_DIR/test_host_inventory.sh"
    run_step "P1 host provider" bash "$SCRIPT_DIR/test_host_provider.sh"
    run_step "P1 execution plan" bash "$SCRIPT_DIR/test_execution_plan.sh"
    run_step "P1 remote CLI" bash "$SCRIPT_DIR/test_remote_cli.sh"
}

run_p2() {
    if [[ "$INCLUDE_PERF" != "1" ]]; then
        skip_step "P2 performance" "Use --include-perf to enable"
        return 0
    fi

    if [[ ! -f "$PROJECT_ROOT/perf_test.sh" ]]; then
        skip_step "P2 performance" "perf_test.sh not found"
        return 0
    fi

    run_step "P2 perf baseline" bash "$PROJECT_ROOT/perf_test.sh"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
    --level)
        LEVEL="${2:-}"
        shift 2
        ;;
    --include-perf)
        INCLUDE_PERF=1
        shift
        ;;
    --include-lint)
        INCLUDE_LINT=1
        shift
        ;;
    --no-parallel)
        PARALLEL=0
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        echo "Unknown option: $1" >&2
        usage
        exit 2
        ;;
    esac
done

case "$LEVEL" in
p0)
    run_p0
    ;;
p1)
    run_p1
    ;;
p2)
    run_p2
    ;;
all)
    run_p0
    run_p1
    run_p2
    ;;
*)
    echo "Invalid --level value: $LEVEL" >&2
    usage
    exit 2
    ;;
esac

echo "========================================="
echo "Regression Summary"
echo "========================================="
echo -e "Passed: ${C_GREEN}${PASS_COUNT}${C_RESET}"
echo -e "Failed: ${C_RED}${FAIL_COUNT}${C_RESET}"
echo -e "Skipped: ${C_YELLOW}${SKIP_COUNT}${C_RESET}"

echo ""
if ((FAIL_COUNT > 0)); then
    exit 1
fi

exit 0
