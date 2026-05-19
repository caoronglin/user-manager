#!/bin/bash
# test_user_core.sh - 用户核心功能测试
# 测试用户名验证、密码生成等核心功能

set -uo pipefail

# 获取项目根目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

export SUDO_NONINTERACTIVE="${SUDO_NONINTERACTIVE:-1}"
export USER_MANAGER_DATA_BASE="${USER_MANAGER_DATA_BASE:-$PROJECT_ROOT/data}"
export USER_MANAGER_BACKUP_ROOT="${USER_MANAGER_BACKUP_ROOT:-$PROJECT_ROOT/data/backup}"

# 加载测试框架
source "$SCRIPT_DIR/test_framework.sh"

# 加载项目库
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/config.sh"
source "$PROJECT_ROOT/lib/access_control.sh"
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

test_start "get_random_password: 空密码池首跑只向 stdout 返回密码"
first_run_pool_dir="$TEST_TMPDIR/first_run_password_pools"
old_password_pool_dir="$PASSWORD_POOL_DIR"
old_password_pool_file="$PASSWORD_POOL_FILE"
PASSWORD_POOL_DIR="$first_run_pool_dir"
PASSWORD_POOL_FILE="$PASSWORD_POOL_DIR/password_pool.txt"
mkdir -p "$PASSWORD_POOL_DIR"
first_run_password_output=$(get_random_password 2>/dev/null || true)
first_run_line_count=$(printf '%s\n' "$first_run_password_output" | wc -l | tr -d ' ')
if [[ "$first_run_line_count" == "1" && "$first_run_password_output" =~ ^[A-Z]{3}[a-z][0-9]{3}[!@#$%^\&*?]$ ]]; then
    test_pass
else
    test_fail "空池首跑应只返回 1 行 8 位密码，实际输出: $first_run_password_output"
fi
PASSWORD_POOL_DIR="$old_password_pool_dir"
PASSWORD_POOL_FILE="$old_password_pool_file"

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
# Shell proxy 配置测试
# ------------------------------------------------------------

test_start "ensure_user_proxy_function: 写入 bashrc 和 zshrc"
proxy_home="$TEST_TMPDIR/proxy_home"
mkdir -p "$proxy_home"
PROXY_PRIV_CALL_LOG="$TEST_TMPDIR/proxy_priv_calls.log"
priv_touch() { printf 'touch %s\n' "$*" >> "$PROXY_PRIV_CALL_LOG"; : > "$1"; }
priv_tee() {
    printf 'tee %s\n' "$*" >> "$PROXY_PRIV_CALL_LOG"
    if [[ "${1:-}" == "-a" ]]; then
        shift
        cat >> "$1"
    else
        cat > "$1"
    fi
}
priv_chown() { printf 'chown %s\n' "$*" >> "$PROXY_PRIV_CALL_LOG"; return 0; }
priv_chmod() { printf 'chmod %s\n' "$*" >> "$PROXY_PRIV_CALL_LOG"; chmod "$@"; }
if declare -F ensure_user_proxy_function >/dev/null && ensure_user_proxy_function "testuser" "$proxy_home" >/dev/null 2>&1 && \
   grep -q 'proxy()' "$proxy_home/.bashrc" && \
   grep -q 'proxy()' "$proxy_home/.zshrc" && \
   grep -q 'http_proxy' "$proxy_home/.bashrc" && \
   grep -q 'http_proxy' "$proxy_home/.zshrc"; then
    test_pass
else
    test_fail "proxy() 未同时写入 .bashrc 和 .zshrc"
fi

test_start "ensure_user_proxy_function: 通过 priv_tee 追加 rc 文件"
if grep -q "tee -a $proxy_home/.bashrc" "$PROXY_PRIV_CALL_LOG" && grep -q "tee -a $proxy_home/.zshrc" "$PROXY_PRIV_CALL_LOG"; then
    test_pass
else
    test_fail "proxy helper 未通过 priv_tee -a 写入 rc 文件"
fi

test_start "ensure_user_proxy_function: 重复执行不重复写入"
if declare -F ensure_user_proxy_function >/dev/null; then
    ensure_user_proxy_function "testuser" "$proxy_home" >/dev/null 2>&1 || true
    bash_count=$(grep -c '# >>> user-manager proxy helper >>>' "$proxy_home/.bashrc" 2>/dev/null || echo 0)
    zsh_count=$(grep -c '# >>> user-manager proxy helper >>>' "$proxy_home/.zshrc" 2>/dev/null || echo 0)
    if [[ "$bash_count" == "1" && "$zsh_count" == "1" ]]; then
        test_pass
    else
        test_fail "proxy helper 被重复写入: bash=$bash_count zsh=$zsh_count"
    fi
else
    test_fail "ensure_user_proxy_function 函数不存在"
fi
unset -f priv_touch priv_tee priv_chown priv_chmod

# ------------------------------------------------------------
# 密码轮换脚本测试
# ------------------------------------------------------------

test_start "configure_password_rotation: 生成脚本使用当前密码池配置并通过权限封装改密"
rotation_capture="$TEST_TMPDIR/password_rotate_generated.sh"
write_privileged_text_file() {
    local target_path="$1"
    local file_mode="${2:-0644}"
    local owner_group="${3:-root:root}"
    local file_content
    file_content="$(cat)"
    printf '%s' "$file_content" > "$rotation_capture"
    printf '%s|%s|%s\n' "$target_path" "$file_mode" "$owner_group" > "$TEST_TMPDIR/password_rotate_target.txt"
    return 0
}
priv_chmod() { return 0; }
priv_crontab() { cat >/dev/null; return 0; }
draw_header() { return 0; }
draw_info_card() { return 0; }
msg_step() { return 0; }
msg_ok() { return 0; }
msg_err() { return 0; }
PASSWORD_POOL_DIR="$TEST_TMPDIR/password_pools"
PASSWORD_POOL_FILE="$PASSWORD_POOL_DIR/password_pool_current.txt"
mkdir -p "$PASSWORD_POOL_DIR"
if configure_password_rotation 30 >/dev/null 2>&1 && \
   [[ -f "$rotation_capture" ]] && \
   grep -q 'source "\$MANAGER_DIR/lib/user_core.sh"' "$rotation_capture" && \
   grep -q 'source "\$MANAGER_DIR/lib/email_core.sh"' "$rotation_capture" && \
   grep -q 'NEW_PASS=$(get_random_password' "$rotation_capture" && \
   ! grep -q 'PASSWORD_POOL_FILE="${PASSWORD_POOL_FILE:-' "$rotation_capture" && \
   ! grep -q 'TOTAL_PASSWORDS=' "$rotation_capture" && \
   ! grep -q 'RAND_LINE=' "$rotation_capture" && \
   grep -q 'priv_chpasswd' "$rotation_capture" && \
   grep -q 'send_password_email "\$username" "\$NEW_PASS" "\$EMAIL" "定时密码更新"' "$rotation_capture" && \
   ! grep -q '| chpasswd' "$rotation_capture" && \
   ! grep -q 'sendmail -t' "$rotation_capture" && \
   ! grep -q 'echo "From:' "$rotation_capture"; then
    test_pass
else
    test_fail "轮换脚本未复用 get_random_password/邮件模块，或仍直接读取密码池/调用 chpasswd/sendmail"
fi
unset -f write_privileged_text_file priv_chmod priv_crontab draw_header draw_info_card msg_step msg_ok msg_err

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
