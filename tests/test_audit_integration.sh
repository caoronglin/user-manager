#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../tests/test_framework.sh"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/config.sh"
source "$SCRIPT_DIR/../lib/audit_core.sh"

test_suite_start "Audit System Integration"

test_start "audit_init creates log directory"
test_audit_dir="/tmp/test_audit_$$"
AUDIT_LOG_DIR="$test_audit_dir"
AUDIT_LOG_FILE="$test_audit_dir/audit.log"

if audit_init && [[ -d "$test_audit_dir" ]]; then
    test_pass
else
    test_fail "审计目录创建失败"
fi

test_start "audit_log writes to file"
audit_log "TEST_OP" "test_target" "SUCCESS" "test details"
if [[ -f "$AUDIT_LOG_FILE" ]] && grep -q "TEST_OP" "$AUDIT_LOG_FILE"; then
    test_pass
else
    test_fail "审计日志写入失败"
fi

test_start "audit_success records success"
audit_success "SUCCESS_TEST" "success_target"
if grep -q "SUCCESS" "$AUDIT_LOG_FILE"; then
    test_pass
else
    test_fail "审计成功记录失败"
fi

test_start "audit_failure records failure"
audit_failure "FAILURE_TEST" "failure_target"
if grep -q "FAILURE" "$AUDIT_LOG_FILE"; then
    test_pass
else
    test_fail "审计失败记录失败"
fi

rm -rf "$test_audit_dir"
test_suite_end
