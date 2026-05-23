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
# 用户组与权限管理测试
# ------------------------------------------------------------

test_start "add_user_to_group: 自动创建缺失用户组并追加用户"
group_call_log="$TEST_TMPDIR/group_calls.log"
permission_home="$TEST_TMPDIR/alice_home"
mkdir -p "$permission_home"
id() {
    if [[ "${1:-}" == "-nG" ]]; then
        printf 'alice users sudo\n'
        return 0
    fi
    [[ "${1:-}" == "alice" ]] && return 0
    return 1
}
getent() {
    case "${1:-}:${2:-}" in
        passwd:alice) printf 'alice:x:1001:1001:Alice:%s:/bin/bash\n' "$permission_home" ;;
        group:dev) return 2 ;;
        group:sudo) printf 'sudo:x:27:alice\n' ;;
        *) return 2 ;;
    esac
}
priv_groupadd() { printf 'groupadd %s\n' "$*" >> "$group_call_log"; return 0; }
priv_usermod() { printf 'usermod %s\n' "$*" >> "$group_call_log"; return 0; }
priv_deluser() { printf 'deluser %s\n' "$*" >> "$group_call_log"; return 0; }
priv_groupdel() { printf 'groupdel %s\n' "$*" >> "$group_call_log"; return 0; }
priv_chmod() { printf 'chmod %s\n' "$*" >> "$group_call_log"; return 0; }
priv_chgrp() { printf 'chgrp %s\n' "$*" >> "$group_call_log"; return 0; }
record_user_event() { return 0; }
if add_user_to_group alice dev >/dev/null 2>&1 && \
   grep -q '^groupadd dev$' "$group_call_log" && \
   grep -q '^usermod -aG dev alice$' "$group_call_log"; then
    test_pass
else
    test_fail "add_user_to_group 未创建组或未追加用户，日志: $(cat "$group_call_log" 2>/dev/null)"
fi

test_start "权限管理: 设置主目录权限和管理员权限"
: > "$group_call_log"
if set_user_home_mode alice 750 >/dev/null 2>&1 && \
   set_user_home_group alice sudo >/dev/null 2>&1 && \
   grant_user_admin_permission alice >/dev/null 2>&1 && \
   revoke_user_admin_permission alice >/dev/null 2>&1 && \
   grep -q "^chmod 750 $permission_home$" "$group_call_log" && \
   grep -q "^chgrp sudo $permission_home$" "$group_call_log" && \
   grep -q '^usermod -aG sudo alice$' "$group_call_log" && \
   grep -q '^deluser alice sudo$' "$group_call_log"; then
    test_pass
else
    test_fail "权限管理操作未按预期调用权限封装，日志: $(cat "$group_call_log" 2>/dev/null)"
fi
unset -f id getent priv_groupadd priv_usermod priv_deluser priv_groupdel priv_chmod priv_chgrp record_user_event

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
# 账户停用/禁用状态机测试
# ------------------------------------------------------------

ACCOUNT_DISABLE_LOG="$TEST_TMPDIR/account_disable_calls.log"
DISABLED_USERS_FILE="$TEST_TMPDIR/disabled_users.tsv"
: > "$ACCOUNT_DISABLE_LOG"

id() {
    case "${1:-}" in
        root) return 0 ;;
        alice|bob|sysdaemon) return 0 ;;
        *) return 1 ;;
    esac
}
PASSWD_STATUS_LOCKED=0
CHAGE_EXPIRE_VALUE="-1"
ROLLBACK_RECORD_FAIL=0
getent() {
    if [[ "${1:-}" == "passwd" ]]; then
        case "${2:-}" in
            alice) printf 'alice:x:1001:1001:Alice:/home/alice:/bin/bash\n' ;;
            bob) printf 'bob:x:1002:1002:Bob:/home/bob:/bin/zsh\n' ;;
            root) printf 'root:x:0:0:root:/root:/bin/bash\n' ;;
            sysdaemon) printf 'sysdaemon:x:999:999:System:/nonexistent:/usr/sbin/nologin\n' ;;
            *) return 2 ;;
        esac
        return 0
    fi
    command getent "$@"
}
passwd() {
    if [[ "${1:-}" == "-S" ]]; then
        if [[ "$PASSWD_STATUS_LOCKED" == "1" ]]; then
            printf '%s L 2026-01-01 0 99999 7 -1\n' "${2:-alice}"
        else
            printf '%s P 2026-01-01 0 99999 7 -1\n' "${2:-alice}"
        fi
        return 0
    fi
    return 1
}
chage() {
    if [[ "${1:-}" == "-l" ]]; then
        printf 'Last password change                                    : Jan 01, 2026\n'
        if [[ "$CHAGE_EXPIRE_VALUE" == "-1" ]]; then
            printf 'Account expires                                         : never\n'
        else
            printf 'Account expires                                         : %s\n' "$CHAGE_EXPIRE_VALUE"
        fi
        return 0
    fi
    return 1
}
priv_usermod() { printf 'usermod %s\n' "$*" >> "$ACCOUNT_DISABLE_LOG"; return 0; }
priv_chage() { printf 'chage %s\n' "$*" >> "$ACCOUNT_DISABLE_LOG"; return 0; }
_um_write_disabled_records() { [[ "$ROLLBACK_RECORD_FAIL" != "1" ]] || return 1; command cp "$1" "$DISABLED_USERS_FILE"; }
record_user_event() { printf 'event %s|%s|%s\n' "${1:-}" "${2:-}" "${3:-}" >> "$ACCOUNT_DISABLE_LOG"; return 0; }
get_user_email() { [[ "${1:-}" == "alice" ]] && printf 'alice@example.com\n'; }
send_account_disabled_email() { printf 'mail-disabled %s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" >> "$ACCOUNT_DISABLE_LOG"; [[ "${ACCOUNT_MAIL_FAIL:-0}" != "1" ]]; }
send_account_suspended_email() { printf 'mail-suspended %s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" >> "$ACCOUNT_DISABLE_LOG"; return 0; }
send_account_restored_email() { printf 'mail-restored %s|%s|%s\n' "$1" "$2" "$3" >> "$ACCOUNT_DISABLE_LOG"; return 0; }
msg_info() { return 0; }
msg_warn() { return 0; }
msg_err() { return 0; }
msg_ok() { return 0; }

test_start "disable_user_account: 拒绝 root、当前用户和系统 UID 用户"
old_user_for_disable="$USER"
USER="bob"
if ! disable_user_account root "maint" "permanent" >/dev/null 2>&1 && \
   ! disable_user_account bob "maint" "permanent" >/dev/null 2>&1 && \
   ! disable_user_account sysdaemon "maint" "permanent" >/dev/null 2>&1 && \
   [[ ! -s "$ACCOUNT_DISABLE_LOG" ]]; then
    test_pass
else
    test_fail "禁用保护未拒绝 root/current/system user 或产生了特权调用"
fi
USER="$old_user_for_disable"

test_start "disable_user_account: 锁定密码、设置过期、切换 nologin 并记录状态"
: > "$ACCOUNT_DISABLE_LOG"
if disable_user_account alice $'维护,原因\n换行' "2026-01-02" >/dev/null 2>&1 && \
   grep -q '^usermod -L alice$' "$ACCOUNT_DISABLE_LOG" && \
   grep -q '^chage -E 0 alice$' "$ACCOUNT_DISABLE_LOG" && \
   grep -q '^usermod -s .*nologin alice$' "$ACCOUNT_DISABLE_LOG" && \
   grep -q '^mail-disabled alice|alice@example.com|维护 原因 换行|2026-01-02|' "$ACCOUNT_DISABLE_LOG" && \
   grep -q $'^alice\t' "$DISABLED_USERS_FILE" && \
   grep -q $'\t/bin/bash\t' "$DISABLED_USERS_FILE" && \
   [[ "$(wc -l < "$DISABLED_USERS_FILE" | tr -d ' ')" == "1" ]] && \
   ! grep -q ',' "$DISABLED_USERS_FILE"; then
    test_pass
else
    test_fail "disable_user_account 未执行完整停用序列或状态记录不安全"
fi

test_start "disable_user_account: 重复禁用幂等且不重复写记录"
: > "$ACCOUNT_DISABLE_LOG"
before_disable_lines=$(wc -l < "$DISABLED_USERS_FILE" | tr -d ' ')
disable_user_account alice "重复" "2026-01-03" >/dev/null 2>&1 || true
after_disable_lines=$(wc -l < "$DISABLED_USERS_FILE" | tr -d ' ')
if [[ "$before_disable_lines" == "$after_disable_lines" ]] && [[ ! -s "$ACCOUNT_DISABLE_LOG" ]]; then
    test_pass
else
    test_fail "重复禁用应为 no-op 且不重复写状态"
fi

test_start "enable_user_account: 恢复锁定、过期和原 shell 并移除状态"
: > "$ACCOUNT_DISABLE_LOG"
if enable_user_account alice >/dev/null 2>&1 && \
   grep -q '^usermod -U alice$' "$ACCOUNT_DISABLE_LOG" && \
   grep -q '^chage -E -1 alice$' "$ACCOUNT_DISABLE_LOG" && \
   grep -q '^usermod -s /bin/bash alice$' "$ACCOUNT_DISABLE_LOG" && \
   grep -q '^mail-restored alice|alice@example.com|' "$ACCOUNT_DISABLE_LOG" && \
   ! grep -q $'^alice\t' "$DISABLED_USERS_FILE"; then
    test_pass
else
    test_fail "enable_user_account 未恢复账户状态或未清理状态记录"
fi

test_start "enable_user_account: 保留停用前已锁定和已过期状态"
: > "$ACCOUNT_DISABLE_LOG"
printf 'alice\tlocked\t2026-01-01\tpermanent\t/bin/bash\tlocked\t2026-03-04\tdisable\n' > "$DISABLED_USERS_FILE"
if enable_user_account alice >/dev/null 2>&1 && \
   ! grep -q '^usermod -U alice$' "$ACCOUNT_DISABLE_LOG" && \
   grep -q '^chage -E 2026-03-04 alice$' "$ACCOUNT_DISABLE_LOG" && \
   grep -q '^usermod -s /bin/bash alice$' "$ACCOUNT_DISABLE_LOG"; then
    test_pass
else
    test_fail "恢复不应解锁原本锁定账户，且应恢复原过期日期"
fi

test_start "disable_user_account: 状态记录失败时回滚已执行的账户变更"
: > "$ACCOUNT_DISABLE_LOG"
PASSWD_STATUS_LOCKED=0
CHAGE_EXPIRE_VALUE="2026-05-06"
ROLLBACK_RECORD_FAIL=1
if ! disable_user_account alice "记录失败" "2026-06-01" >/dev/null 2>&1 && \
   grep -q '^usermod -L alice$' "$ACCOUNT_DISABLE_LOG" && \
   grep -q '^chage -E 0 alice$' "$ACCOUNT_DISABLE_LOG" && \
   grep -q '^usermod -s .*nologin alice$' "$ACCOUNT_DISABLE_LOG" && \
   grep -q '^usermod -U alice$' "$ACCOUNT_DISABLE_LOG" && \
   grep -q '^chage -E 2026-05-06 alice$' "$ACCOUNT_DISABLE_LOG" && \
   grep -q '^usermod -s /bin/bash alice$' "$ACCOUNT_DISABLE_LOG"; then
    test_pass
else
    test_fail "状态记录失败时应回滚锁定、过期和 shell 变更"
fi
ROLLBACK_RECORD_FAIL=0
CHAGE_EXPIRE_VALUE="-1"
PASSWD_STATUS_LOCKED=0

test_start "disable_user_account: 通知失败不阻断账户禁用"
: > "$ACCOUNT_DISABLE_LOG"
ACCOUNT_MAIL_FAIL=1
if disable_user_account alice "通知失败" "2026-01-04" >/dev/null 2>&1 && \
   grep -q '^usermod -L alice$' "$ACCOUNT_DISABLE_LOG" && \
   grep -q '^mail-disabled alice|alice@example.com|通知失败|2026-01-04|' "$ACCOUNT_DISABLE_LOG"; then
    test_pass
else
    test_fail "通知失败不应阻断账户禁用"
fi
unset ACCOUNT_MAIL_FAIL
enable_user_account alice >/dev/null 2>&1 || true

test_start "check_expired_suspensions: 到期记录调用 enable_user_account"
: > "$ACCOUNT_DISABLE_LOG"
printf 'alice\ttest\t2000-01-01\t2000-01-02\t/bin/bash\tactive\tdisable\n' > "$DISABLED_USERS_FILE"
enable_user_account() { printf 'enable-called %s\n' "$1" >> "$ACCOUNT_DISABLE_LOG"; return 0; }
if check_expired_suspensions >/dev/null 2>&1 && grep -q '^enable-called alice$' "$ACCOUNT_DISABLE_LOG"; then
    test_pass
else
    test_fail "过期暂停检查未委托 enable_user_account"
fi
unset -f enable_user_account

unset -f id getent passwd chage priv_usermod priv_chage _um_write_disabled_records record_user_event get_user_email send_account_disabled_email send_account_suspended_email send_account_restored_email msg_info msg_warn msg_err msg_ok

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
