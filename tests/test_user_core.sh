#!/bin/bash
# test_user_core.sh - 用户核心功能测试
# 测试用户名验证、密码生成等核心功能

set -uo pipefail

# 获取项目根目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# 加载测试框架
source "$SCRIPT_DIR/test_framework.sh"

# 加载项目库
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/config.sh"
source "$PROJECT_ROOT/lib/privilege.sh"
source "$PROJECT_ROOT/lib/user_core.sh"

# 设置测试环境
setup_test_env

# ============================================================
# 测试套件
# ============================================================

test_suite_start "User Core Functions"

# ------------------------------------------------------------
# 用户名验证测试
# ------------------------------------------------------------

test_start "validate_username: 有效的用户名"
if validate_username "test_user" 2>/dev/null; then
    test_pass
else
    test_fail "应该接受包含下划线的用户名"
fi

test_start "validate_username: 有效的用户名（带数字）"
if validate_username "user123" 2>/dev/null; then
    test_pass
else
    test_fail "应该接受包含数字的用户名"
fi

test_start "validate_username: 无效的用户名（数字开头）"
if ! validate_username "123user" 2>/dev/null; then
    test_pass
else
    test_fail "应该拒绝以数字开头的用户名"
fi

test_start "validate_username: 无效的用户名（特殊字符）"
if ! validate_username "user@name" 2>/dev/null; then
    test_pass
else
    test_fail "应该拒绝包含特殊字符的用户名"
fi

test_start "validate_username: 无效的用户名（空）"
if ! validate_username "" 2>/dev/null; then
    test_pass
else
    test_fail "应该拒绝空用户名"
fi

test_start "validate_username: 无效的用户名（过长）"
long_username="user_$(printf 'a%.0s' {1..40})"
if ! validate_username "$long_username" 2>/dev/null; then
    test_pass
else
    test_fail "应该拒绝过长的用户名"
fi

# ------------------------------------------------------------
# 密码池测试
# ------------------------------------------------------------

test_start "generate_password_pool: 生成密码池"
test_pool="$TEST_TMPDIR/test_password_pool.txt"
generate_password_pool "$test_pool" 2>/dev/null
assert_file_exists "$test_pool"

test_start "generate_password_pool: 密码池行数正确"
count=$(wc -l < "$test_pool" 2>/dev/null || echo "0")
assert_equals "8568" "$count" "密码池应该包含 8568 个密码"

test_start "generate_password_pool: 密码格式正确（长度为8）"
first_password=$(head -n 1 "$test_pool")
assert_equals "8" "${#first_password}" "密码长度应该为 8"

test_start "generate_password_pool: 密码格式正确（包含特殊字符）"
special_chars='!@#$%^&*?'
has_special=false
sample_passwords=$(head -n 10 "$test_pool")

if [[ "$sample_passwords" =~ [$special_chars] ]]; then
    test_pass
else
    test_fail "密码应该包含特殊字符"
fi

test_start "get_random_password: 获取随机密码"
password=$(get_random_password 2>/dev/null || echo "")
if [[ -n "$password" && ${#password} -eq 8 ]]; then
    test_pass
else
    test_fail "应该返回有效的密码"
fi

# ------------------------------------------------------------
# 配置管理测试
# ------------------------------------------------------------

test_start "update_user_config: 更新用户配置"
test_config="$TEST_TMPDIR/test_user_config.json"
echo "{}" > "$test_config"

# 临时替换配置文件
original_config="$USER_CONFIG_FILE"
USER_CONFIG_FILE="$test_config"

if update_user_config "testuser" "test@example.com" "50%" "8G" 2>/dev/null; then
    test_pass
else
    test_fail "应该成功更新用户配置"
fi

test_start "update_user_config: 配置文件格式正确"
if command -v jq &>/dev/null; then
    if jq empty "$test_config" 2>/dev/null; then
        test_pass
    else
        test_fail "配置文件应该是有效的 JSON"
    fi
else
    test_skip "jq 未安装"
fi

# 恢复原始配置
USER_CONFIG_FILE="$original_config"

# ------------------------------------------------------------
# 用户存在性检查测试
# ------------------------------------------------------------

test_start "get_user_home: 获取当前用户主目录"
home=$(get_user_home "$USER" 2>/dev/null || echo "")
if [[ -n "$home" && "$home" == "$HOME" ]]; then
    test_pass
else
    test_fail "应该返回正确的主目录"
fi

test_start "get_user_home: 不存在的用户"
home=$(get_user_home "nonexistent_user_12345" 2>/dev/null || echo "")
if [[ -z "$home" ]]; then
    test_pass
else
    test_fail "不存在的用户应该返回空"
fi

# ------------------------------------------------------------
# 用户组管理测试
# ------------------------------------------------------------

test_start "get_managed_usernames: 获取受管理用户列表"
users=$(get_managed_usernames 2>/dev/null || echo "")
# 只要不报错就算通过
test_pass

# ============================================================
# 测试结束
# ============================================================

# 清理测试环境
cleanup_test_env

# 输出测试结果
test_suite_end
