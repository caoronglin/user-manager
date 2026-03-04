#!/bin/bash
# test_audit_integration.sh - 审计系统集成测试

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANAGER_DIR="$(dirname "$SCRIPT_DIR")"

source "$MANAGER_DIR/tests/test_framework.sh"
source "$MANAGER_DIR/lib/common.sh"
source "$MANAGER_DIR/lib/config.sh"
source "$MANAGER_DIR/lib/audit_core.sh"

test_suite_start "Audit System Integration"

# Test 1: 审计初始化
test_start "audit_init creates log directory"
test_audit_dir="/tmp/test_audit_$$"
export AUDIT_LOG_DIR="$test_audit_dir"
export AUDIT_LOG_FILE="$test_audit_dir/audit.log"

if audit_init && [[ -d "$test_audit_dir" ]]; then
    test_pass
else
    test_fail "审计目录创建失败"
fi

# Test 2: 审计日志写入
test_start "audit_log writes to file"
audit_log "TEST_OP" "test_target" "SUCCESS" "test details"
if [[ -f "$AUDIT_LOG_FILE" ]] && grep -q "TEST_OP" "$AUDIT_LOG_FILE"; then
    test_pass
else
    test_fail "审计日志写入失败"
fi

# Test 3: 审计成功记录
test_start "audit_success records success"
audit_success "SUCCESS_TEST" "success_target"
if grep -q "SUCCESS" "$AUDIT_LOG_FILE"; then
    test_pass
else
    test_fail "审计成功记录失败"
fi

# Test 4: 审计失败记录
test_start "audit_failure records failure"
audit_failure "FAILURE_TEST" "failure_target"
if grep -q "FAILURE" "$AUDIT_LOG_FILE"; then
    test_pass
else
    test_fail "审计失败记录失败"
fi

# Test 5: 审计查询
test_start "audit_query returns results"
query_result=$(audit_query "TEST_OP" 2>/dev/null || true)
if [[ -n "$query_result" ]]; then
    test_pass
else
    test_fail "审计查询失败"
fi

# 清理
rm -rf "$test_audit_dir"

test_suite_end
