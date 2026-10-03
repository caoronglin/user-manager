#!/bin/bash
# execution_plan.sh - 只读多主机计划、顺序执行与结果汇总

EXECUTION_PLAN_PROTOCOL='user-manager-plan-v1'
EXECUTION_PLAN_ID=''
EXECUTION_PLAN_ACTION=''
EXECUTION_PLAN_SELECTOR=''
declare -p EXECUTION_PLAN_HOSTS >/dev/null 2>&1 || declare -ag EXECUTION_PLAN_HOSTS=()

_execution_plan_error() { printf '执行计划错误: %s\n' "$1" >&2; }

execution_plan_action_allowed() {
    case "${1:-}" in host.probe | gpu.summary) return 0 ;; *) return 1 ;; esac
}

_execution_plan_new_id() {
    local stamp
    stamp="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || printf 'unknown')"
    printf 'plan-%s-%s\n' "$stamp" "$$"
}

execution_plan_prepare() {
    local action="${1:-}" selector="${2:-local}" resolved
    execution_plan_action_allowed "$action" || {
        _execution_plan_error "action 不在只读白名单"
        return 2
    }
    resolved="$(host_inventory_resolve "$selector")" || {
        _execution_plan_error "目标无法解析"
        return 2
    }
    EXECUTION_PLAN_HOSTS=()
    mapfile -t EXECUTION_PLAN_HOSTS <<<"$resolved"
    ((${#EXECUTION_PLAN_HOSTS[@]} > 0)) || {
        _execution_plan_error "目标为空"
        return 2
    }
    EXECUTION_PLAN_ACTION="$action"
    EXECUTION_PLAN_SELECTOR="$selector"
    EXECUTION_PLAN_ID="$(_execution_plan_new_id)"
}

execution_plan_print() {
    local mode="${1:-dry-run}" index host
    [[ "$mode" == dry-run || "$mode" == execute ]] || return 2
    printf 'plan.protocol=%s\nplan.id=%s\n' "$EXECUTION_PLAN_PROTOCOL" "$EXECUTION_PLAN_ID"
    printf 'plan.action=%s\nplan.target=%s\nplan.mode=%s\n' "$EXECUTION_PLAN_ACTION" "$EXECUTION_PLAN_SELECTOR" "$mode"
    printf 'plan.capability=unknown-not-probed\nplan.host_count=%s\n' "${#EXECUTION_PLAN_HOSTS[@]}"
    for ((index = 0; index < ${#EXECUTION_PLAN_HOSTS[@]}; index++)); do
        host="${EXECUTION_PLAN_HOSTS[$index]}"
        printf 'plan.host.%s=id=%s;provider=%s\n' "$index" "$host" "${HOST_PROVIDER[$host]}"
    done
    printf 'plan.end=1\n'
}

_execution_plan_audit() {
    local host="$1" action="$2" status="$3" code="$4"
    declare -F audit_log >/dev/null 2>&1 || return 0
    audit_log HOST_READONLY "$host" "$status" "action=$action code=$code" >/dev/null 2>&1 || {
        printf '警告: 主机 %s 的本地审计写入失败\n' "$host" >&2
        return 0
    }
}

execution_plan_run() {
    local action="${1:-}" selector="${2:-local}" mode="${3:-dry-run}"
    local temp_dir result_file host provider_rc status code size
    local success=0 failed=0 unreachable=0 unsupported=0 total=0
    [[ "$mode" == dry-run || "$mode" == execute ]] || {
        _execution_plan_error "mode 必须是 dry-run 或 execute"
        return 2
    }
    execution_plan_prepare "$action" "$selector" || return $?
    execution_plan_print "$mode"
    if [[ "$mode" == dry-run ]]; then
        printf 'summary.mode=dry-run\nsummary.total=%s\nsummary.not_executed=%s\nsummary.end=1\n' \
            "${#EXECUTION_PLAN_HOSTS[@]}" "${#EXECUTION_PLAN_HOSTS[@]}"
        return 0
    fi

    umask 077
    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/user-manager-plan.XXXXXX")" || return 1
    for host in "${EXECUTION_PLAN_HOSTS[@]}"; do
        ((total += 1))
        result_file="$temp_dir/result.$total"
        provider_rc=0
        host_provider_execute "$host" "$action" >"$result_file" || provider_rc=$?
        status="${PROVIDER_RESULT_STATUS:-failed}"
        code="${PROVIDER_RESULT_CODE:-PROVIDER_RESULT_MISSING}"
        size="$(stat -Lc '%s' -- "$result_file" 2>/dev/null || printf '0')"
        if [[ ! "$size" =~ ^[0-9]+$ ]] || ((size > 131072)); then
            status=failed
            code=PROVIDER_OUTPUT_TOO_LARGE
            : >"$result_file"
        fi
        if [[ -s "$result_file" ]]; then /bin/cat "$result_file"; else
            printf 'result.protocol=user-manager-provider-v1\nresult.host=%s\nresult.action=%s\n' "$host" "$action"
            printf 'result.status=%s\nresult.code=%s\nresult.end=1\n' "$status" "$code"
        fi
        case "$status" in success) ((success += 1)) ;; unsupported) ((unsupported += 1)) ;;
        unreachable) ((unreachable += 1)) ;; *) ((failed += 1)) ;; esac
        _execution_plan_audit "$host" "$action" "$status" "$code"
        : "$provider_rc"
    done
    rm -rf -- "$temp_dir"
    printf 'summary.mode=execute\nsummary.total=%s\n' "$total"
    printf 'summary.success=%s\nsummary.failed=%s\n' "$success" "$failed"
    printf 'summary.unreachable=%s\nsummary.unsupported=%s\nsummary.end=1\n' "$unreachable" "$unsupported"
    if ((failed > 0 || unreachable > 0)); then
        return 1
    elif ((unsupported > 0)); then
        return 4
    else return 0; fi
}
