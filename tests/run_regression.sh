#!/bin/bash
# run_regression.sh - 分级回归执行器

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

LEVEL="all"
INCLUDE_PERF=0

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
  -h, --help               Show this help

Levels:
  p0    Static/load smoke checks (verify_fixes.sh)
  p1    Core behavior tests (bootstrap/user/audit/proc/security/tui/system/network/timer/lock/backup/vm/gpu)
  p2    Performance baseline (perf_test.sh)
  all   p0 + p1 (and p2 when --include-perf is set)
EOF
}

run_step() {
    local name="$1"
    shift

    echo -e "${C_BLUE}[RUN]${C_RESET} $name"
    if "$@"; then
        echo -e "${C_GREEN}[PASS]${C_RESET} $name"
        ((PASS_COUNT+=1))
    else
        echo -e "${C_RED}[FAIL]${C_RESET} $name"
        ((FAIL_COUNT+=1))
    fi
    echo ""
}

skip_step() {
    local name="$1"
    local reason="$2"
    echo -e "${C_YELLOW}[SKIP]${C_RESET} $name - $reason"
    echo ""
    ((SKIP_COUNT+=1))
}

run_p0() {
    run_step "P0 verify_fixes" bash "$PROJECT_ROOT/verify_fixes.sh"
}

run_p1() {
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

    run_step "P1 logs presenter" env \
        SUDO_NONINTERACTIVE=1 \
        USER_MANAGER_DATA_BASE="$PROJECT_ROOT/data" \
        USER_MANAGER_BACKUP_ROOT="$PROJECT_ROOT/data/backup" \
        bash "$SCRIPT_DIR/test_logs_presenter.sh"

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
        -h|--help)
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
if (( FAIL_COUNT > 0 )); then
    exit 1
fi

exit 0
