#!/bin/bash
# test_framework.sh - 简单的测试框架 v1.0
# 提供基本的测试断言和报告功能

set -uo pipefail

# 颜色定义
readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[1;33m'
readonly C_RESET='\033[0m'

# 测试统计
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TEST_SUITE=""

# ============================================================
# 测试生命周期函数
# ============================================================

# 开始测试套件
test_suite_start() {
    local suite_name="$1"
    TEST_SUITE="$suite_name"
    echo ""
    echo "========================================="
    echo "  Test Suite: $TEST_SUITE"
    echo "========================================="
    echo ""
}

# 结束测试套件
test_suite_end() {
    echo ""
    echo "========================================="
    echo "  Test Results"
    echo "========================================="
    echo -e "  Tests Run:    $TESTS_RUN"
    echo -e "  ${C_GREEN}Passed:${C_RESET}       $TESTS_PASSED"
    echo -e "  ${C_RED}Failed:${C_RESET}       $TESTS_FAILED"
    
    local pass_rate=0
    if (( TESTS_RUN > 0 )); then
        pass_rate=$(( TESTS_PASSED * 100 / TESTS_RUN ))
    fi
    
    echo ""
    if (( pass_rate == 100 )); then
        echo -e "  ${C_GREEN}✓ All tests passed!${C_RESET}"
    elif (( pass_rate >= 80 )); then
        echo -e "  ${C_YELLOW}⚠ Pass rate: ${pass_rate}%${C_RESET}"
    else
        echo -e "  ${C_RED}✗ Pass rate: ${pass_rate}%${C_RESET}"
    fi
    
    echo "========================================="
    echo ""
    
    # 返回失败数
    return $TESTS_FAILED
}

# 开始单个测试
test_start() {
    local test_name="$1"
    ((TESTS_RUN++))
    echo -n "  [$TESTS_RUN] $test_name ... "
}

# ============================================================
# 断言函数
# ============================================================

# 测试通过
test_pass() {
    echo -e "${C_GREEN}PASS${C_RESET}"
    ((TESTS_PASSED++))
}

# 测试失败
test_fail() {
    local reason="${1:-No reason provided}"
    echo -e "${C_RED}FAIL${C_RESET}"
    echo "       Reason: $reason"
    ((TESTS_FAILED++))
}

# 断言相等
assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-}"
    
    if [[ "$expected" == "$actual" ]]; then
        test_pass
        return 0
    else
        test_fail "Expected '$expected', got '$actual'. $message"
        return 1
    fi
}

# 断言不相等
assert_not_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-}"
    
    if [[ "$expected" != "$actual" ]]; then
        test_pass
        return 0
    else
        test_fail "Expected different values, but both are '$expected'. $message"
        return 1
    fi
}

# 断言为真
assert_true() {
    local value="$1"
    local message="${2:-}"
    
    if [[ "$value" == "true" || "$value" == "0" ]]; then
        test_pass
        return 0
    else
        test_fail "Expected true, got '$value'. $message"
        return 1
    fi
}

# 断言为假
assert_false() {
    local value="$1"
    local message="${2:-}"
    
    if [[ "$value" == "false" || "$value" == "1" ]]; then
        test_pass
        return 0
    else
        test_fail "Expected false, got '$value'. $message"
        return 1
    fi
}

# 断言字符串包含
assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-}"
    
    if [[ "$haystack" == *"$needle"* ]]; then
        test_pass
        return 0
    else
        test_fail "String does not contain '$needle'. $message"
        return 1
    fi
}

# 断言文件存在
assert_file_exists() {
    local file="$1"
    local message="${2:-}"
    
    if [[ -f "$file" ]]; then
        test_pass
        return 0
    else
        test_fail "File does not exist: $file. $message"
        return 1
    fi
}

# 断言文件不存在
assert_file_not_exists() {
    local file="$1"
    local message="${2:-}"
    
    if [[ ! -f "$file" ]]; then
        test_pass
        return 0
    else
        test_fail "File should not exist: $file. $message"
        return 1
    fi
}

# 断言目录存在
assert_dir_exists() {
    local dir="$1"
    local message="${2:-}"
    
    if [[ -d "$dir" ]]; then
        test_pass
        return 0
    else
        test_fail "Directory does not exist: $dir. $message"
        return 1
    fi
}

# 断言命令成功
assert_success() {
    local command="$1"
    local message="${2:-}"
    
    # 使用 bash -c 替代 eval，更安全
    if bash -c "$command" &>/dev/null; then
        test_pass
        return 0
    else
        test_fail "Command failed: $command. $message"
        return 1
    fi
}

# 断言命令失败
assert_failure() {
    local command="$1"
    local message="${2:-}"
    
    # 使用 bash -c 替代 eval，更安全
    if ! bash -c "$command" &>/dev/null; then
        test_pass
        return 0
    else
        test_fail "Command should have failed: $command. $message"
        return 1
    fi
}

# 断言命令失败
assert_failure() {
    local command="$1"
    local message="${2:-}"
    
    if ! eval "$command" &>/dev/null; then
        test_pass
        return 0
    else
        test_fail "Command should have failed: $command. $message"
        return 1
    fi
}

# 断言函数返回 0
assert_return_0() {
    local func="$1"
    local message="${2:-}"
    
    if $func &>/dev/null; then
        test_pass
        return 0
    else
        test_fail "Function did not return 0: $func. $message"
        return 1
    fi
}

# 断言函数返回非 0
assert_return_nonzero() {
    local func="$1"
    local message="${2:-}"
    
    if ! $func &>/dev/null; then
        test_pass
        return 0
    else
        test_fail "Function returned 0 but should have failed: $func. $message"
        return 1
    fi
}

# 断言数组长度
assert_array_length() {
    local expected_length="$1"
    shift
    local array=("$@")
    local message="${*:$(($# + 1)):1}"
    
    local actual_length=${#array[@]}
    
    if (( actual_length == expected_length )); then
        test_pass
        return 0
    else
        test_fail "Array length is $actual_length, expected $expected_length. $message"
        return 1
    fi
}

# 断言数值相等
assert_numeric_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-}"
    
    if (( expected == actual )); then
        test_pass
        return 0
    else
        test_fail "Expected $expected, got $actual. $message"
        return 1
    fi
}

# 断言数值大于
assert_greater_than() {
    local threshold="$1"
    local value="$2"
    local message="${3:-}"
    
    if (( value > threshold )); then
        test_pass
        return 0
    else
        test_fail "Value $value is not greater than $threshold. $message"
        return 1
    fi
}

# 断言数值小于
assert_less_than() {
    local threshold="$1"
    local value="$2"
    local message="${3:-}"
    
    if (( value < threshold )); then
        test_pass
        return 0
    else
        test_fail "Value $value is not less than $threshold. $message"
        return 1
    fi
}

# ============================================================
# 辅助函数
# ============================================================

# 设置测试环境
setup_test_env() {
    export TEST_TMPDIR=$(mktemp -d)
    trap "rm -rf '$TEST_TMPDIR'" EXIT
    echo "Test environment: $TEST_TMPDIR"
}

# 清理测试环境
cleanup_test_env() {
    if [[ -n "${TEST_TMPDIR:-}" && -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
}

# 跳过测试
test_skip() {
    local reason="${1:-No reason provided}"
    echo -e "${C_YELLOW}SKIP${C_RESET} ($reason)"
}

# 标记为待办
test_todo() {
    local reason="${1:-Not implemented}"
    echo -e "${C_YELLOW}TODO${C_RESET} ($reason)"
}
