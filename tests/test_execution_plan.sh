#!/bin/bash
# test_execution_plan.sh - 只读执行计划与 best-effort 汇总测试

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/test_framework.sh"
for module in host_inventory execution_plan; do
    [[ -f "$PROJECT_ROOT/lib/$module.sh" ]] && source "$PROJECT_ROOT/lib/$module.sh"
done

setup_test_env
test_suite_start "Execution Plan"

HOST_INVENTORY_IDS=(local ok-01 down-01 nogpu-01 ok-02)
declare -gA HOST_PROVIDER=([local]=local [ok - 01]=ssh [down - 01]=ssh [nogpu - 01]=ssh [ok - 02]=ssh)
declare -gA HOST_ENABLED=([local]=true [ok - 01]=true [down - 01]=true [nogpu - 01]=true [ok - 02]=true)
declare -gA HOST_GROUPS=([local]=local [ok - 01]=gpu [down - 01]=gpu [nogpu - 01]=gpu [ok - 02]=gpu)

provider_execute_count=0
host_provider_execute() {
    local host="$1" action="$2"
    ((provider_execute_count += 1))
    printf '%s|%s\n' "$host" "$action" >>"$TEST_TMPDIR/provider.calls"
    PROVIDER_RESULT_CODE=OK
    case "$host" in
    down-01)
        PROVIDER_RESULT_STATUS=unreachable
        PROVIDER_RESULT_CODE=SSH_TRANSPORT_ERROR
        ;;
    nogpu-01)
        PROVIDER_RESULT_STATUS=unsupported
        PROVIDER_RESULT_CODE=GPU_NOT_FOUND
        ;;
    *) PROVIDER_RESULT_STATUS=success ;;
    esac
    printf 'result.host=%s\nresult.status=%s\nresult.code=%s\nresult.end=1\n' \
        "$host" "$PROVIDER_RESULT_STATUS" "$PROVIDER_RESULT_CODE"
    case "$PROVIDER_RESULT_STATUS" in success) return 0 ;; unsupported) return 4 ;; unreachable) return 5 ;; *) return 6 ;; esac
}

test_start "Planner 导出准备、打印和执行接口"
if declare -F execution_plan_prepare >/dev/null && declare -F execution_plan_print >/dev/null &&
    declare -F execution_plan_run >/dev/null; then
    test_pass
else
    test_fail "Execution Plan 接口缺失"
fi

test_start "dry-run 纯本地且 Provider 调用数为零"
: >"$TEST_TMPDIR/provider.calls"
provider_execute_count=0
dry_output=""
if declare -F execution_plan_run >/dev/null && dry_output="$(execution_plan_run host.probe group:gpu dry-run 2>/dev/null)" &&
    [[ ! -s "$TEST_TMPDIR/provider.calls" ]] &&
    [[ "$dry_output" == *"plan.mode=dry-run"* ]] &&
    [[ "$dry_output" == *"plan.host_count=4"* ]] &&
    [[ "$dry_output" == *"plan.capability=unknown-not-probed"* ]]; then
    test_pass
else
    test_fail "dry-run 发生执行或输出异常: ${dry_output:-<empty>}"
fi

test_start "部分不可达后继续执行并正确汇总"
: >"$TEST_TMPDIR/provider.calls"
run_rc=0
run_output="$(execution_plan_run host.probe group:gpu execute 2>/dev/null)" || run_rc=$?
call_order="$(cut -d'|' -f1 "$TEST_TMPDIR/provider.calls")"
if ((run_rc != 0)) && [[ "$call_order" == $'ok-01\ndown-01\nnogpu-01\nok-02' ]] &&
    [[ "$run_output" == *"summary.success=2"* ]] &&
    [[ "$run_output" == *"summary.unreachable=1"* ]] &&
    [[ "$run_output" == *"summary.unsupported=1"* ]] &&
    [[ "$run_output" == *"summary.total=4"* ]]; then
    test_pass
else
    test_fail "best-effort 汇总异常: rc=$run_rc calls=$call_order output=$run_output"
fi

test_start "全部成功时返回零"
HOST_INVENTORY_IDS=(local ok-01 ok-02)
HOST_PROVIDER[local]=local
HOST_PROVIDER[ok - 01]=ssh
HOST_PROVIDER[ok - 02]=ssh
HOST_ENABLED[local]=true
HOST_ENABLED[ok - 01]=true
HOST_ENABLED[ok - 02]=true
HOST_GROUPS[local]=all-ok
HOST_GROUPS[ok - 01]=all-ok
HOST_GROUPS[ok - 02]=all-ok
success_output=""
if success_output="$(execution_plan_run host.probe group:all-ok execute 2>/dev/null)" &&
    [[ "$success_output" == *"summary.success=3"* ]] && [[ "$success_output" == *"summary.failed=0"* ]]; then
    test_pass
else
    test_fail "全成功退出语义异常"
fi

test_start "未知 action 在计划阶段失败且零执行"
: >"$TEST_TMPDIR/provider.calls"
if ! execution_plan_run users.create all execute >/dev/null 2>&1 && [[ ! -s "$TEST_TMPDIR/provider.calls" ]]; then
    test_pass
else
    test_fail "未知 action 进入了执行阶段"
fi

cleanup_test_env
test_suite_end
