#!/bin/bash
# test_security_hardening.sh - 安全加固回归测试

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"

setup_test_env

export USER_MANAGER_DATA_BASE="${USER_MANAGER_DATA_BASE:-$PROJECT_ROOT/data}"
export USER_MANAGER_BACKUP_ROOT="${USER_MANAGER_BACKUP_ROOT:-$PROJECT_ROOT/data/backup}"

source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/config.sh"
source "$PROJECT_ROOT/lib/access_control.sh"
source "$PROJECT_ROOT/lib/privilege.sh"
source "$PROJECT_ROOT/lib/user_core.sh"
source "$PROJECT_ROOT/lib/email_core.sh"
source "$PROJECT_ROOT/lib/symlink_core.sh"

test_suite_start "Security Hardening"

test_start "acl_cache_get 在 set -u 下不会触发未绑定变量"
acl_cache_clear
acl_cache_set "level:cacheuser" "$ACL_LEVEL_USER"
if unset level 2>/dev/null; acl_cache_get "level:cacheuser" level && [[ "$level" == "$ACL_LEVEL_USER" ]]; then
    test_pass
else
    test_fail "acl_cache_get 未正确写入输出变量或触发了 set -u 问题"
fi

test_start "validate_safe_link_name 拒绝路径穿越和分隔符"
if declare -F validate_safe_link_name >/dev/null 2>&1 && \
   ! validate_safe_link_name '../evil' >/dev/null 2>&1 && \
   ! validate_safe_link_name 'nested/path' >/dev/null 2>&1 && \
   ! validate_safe_link_name '--danger' >/dev/null 2>&1 && \
   validate_safe_link_name 'shared_data' >/dev/null 2>&1; then
    test_pass
else
    test_fail "validate_safe_link_name 未正确校验链接名称"
fi

test_start "validate_email_config 拒绝可疑 SMTP 主机名"
if command -v jq >/dev/null 2>&1; then
    test_email_config="$TEST_TMPDIR/email_config.json"
    cat > "$test_email_config" <<'EOF'
{
  "smtp_server": "smtp.example.com;touch /tmp/pwned",
  "smtp_port": "465",
  "smtp_user": "test@example.com",
  "smtp_password": "placeholder",
  "from_address": "test@example.com",
  "from_name": "Tester",
  "use_starttls": false,
  "use_ssl": true
}
EOF
    original_email_config="$EMAIL_CONFIG_FILE"
    EMAIL_CONFIG_FILE="$test_email_config"
    if ! validate_email_config >/dev/null 2>&1; then
        test_pass
    else
        test_fail "validate_email_config 未拒绝危险 smtp_server"
    fi
    EMAIL_CONFIG_FILE="$original_email_config"
else
    test_skip "jq 未安装"
fi

test_start "sanitize_mail_header_value 去除 CRLF 头注入"
if declare -F sanitize_mail_header_value >/dev/null 2>&1; then
    sanitized_header="$(sanitize_mail_header_value $'Ops\r\nBcc: attacker@example.com')"
    assert_equals 'Ops Bcc: attacker@example.com' "$sanitized_header"
else
    test_fail "sanitize_mail_header_value 未定义"
fi

test_start "html_escape_text 转义 HTML 特殊字符"
if declare -F html_escape_text >/dev/null 2>&1; then
    raw_html=$(cat <<'EOF'
<b>&"'test'</b>
EOF
)
    escaped_html="$(html_escape_text "$raw_html")"
    assert_equals '&lt;b&gt;&amp;&quot;&#39;test&#39;&lt;/b&gt;' "$escaped_html"
else
    test_fail "html_escape_text 未定义"
fi

test_start "write_privileged_text_file 通过特权写入并设置权限"
if declare -F write_privileged_text_file >/dev/null 2>&1; then
    target_file="$TEST_TMPDIR/managed.conf"
    priv_log="$TEST_TMPDIR/privileged.log"
    priv_tee() { cat > "$1"; }
    priv_chown() { printf 'chown %s\n' "$*" >> "$priv_log"; }
    priv_chmod() { printf 'chmod %s\n' "$*" >> "$priv_log"; }
    if write_privileged_text_file "$target_file" "0640" "root:root" <<'EOF'
managed=true
EOF
    then
        managed_content="$(<"$target_file")"
        managed_log="$(<"$priv_log")"
        if [[ "$managed_content" == 'managed=true' ]] && [[ "$managed_log" == *'chown root:root'* ]] && [[ "$managed_log" == *'chmod 0640'* ]]; then
            test_pass
        else
            test_fail "write_privileged_text_file 未按预期写入文件或设置权限"
        fi
    else
        test_fail "write_privileged_text_file 执行失败"
    fi
else
    test_fail "write_privileged_text_file 未定义"
fi

unset -f priv_tee priv_chown priv_chmod

test_start "run_privileged 拒绝将 bash 作为特权 trampoline"
trampoline_output="$(run_privileged bash -c 'echo owned' 2>&1 || true)"
if [[ "$trampoline_output" == *"拒绝"* || "$trampoline_output" == *"unsafe"* || "$trampoline_output" == *"shell trampoline"* ]]; then
    test_pass
else
    test_fail "run_privileged 仍允许 bash trampoline"
fi

test_start "run_privileged 拒绝以选项作为命令名"
option_output="$(run_privileged -u root id 2>&1 || true)"
if [[ "$option_output" == *"命令"* || "$option_output" == *"option"* || "$option_output" == *"选项"* ]]; then
    test_pass
else
    test_fail "run_privileged 仍接受选项作为命令名"
fi

test_start "privilege 白名单包含关键文件与调度命令"
if priv_check_whitelist mkdir && priv_check_whitelist rm && priv_check_whitelist cp && priv_check_whitelist mv && \
   priv_check_whitelist ln && priv_check_whitelist tee && priv_check_whitelist crontab && \
   priv_check_whitelist du && priv_check_whitelist quota && priv_check_whitelist apt-get && \
   priv_check_whitelist sed && priv_check_whitelist parallel && priv_check_whitelist xargs; then
    test_pass
else
    test_fail "privilege 白名单未覆盖关键命令"
fi

test_start "关键模块不再用泛化 run_privileged 调 helper 已覆盖的命令"
if ! grep -q 'run_privileged iptables' "$PROJECT_ROOT/lib/dns_core.sh" && \
   ! grep -q 'run_privileged smartctl' "$PROJECT_ROOT/lib/system_core.sh" && \
   ! grep -q 'run_privileged mkdir' "$PROJECT_ROOT/lib/async_core.sh" && \
   ! grep -q 'run_privileged mkdir' "$PROJECT_ROOT/lib/proc_manager.sh" && \
   ! grep -q 'run_privileged chmod' "$PROJECT_ROOT/lib/proc_manager.sh" && \
   ! grep -q 'run_privileged cp -r /etc/skel' "$PROJECT_ROOT/lib/user_core.sh" && \
   ! grep -q 'run_privileged userdel' "$PROJECT_ROOT/lib/user_core.sh" && \
   ! grep -q 'run_privileged quota' "$PROJECT_ROOT/lib/quota_core.sh" && \
   ! grep -q 'run_privileged rsync' "$PROJECT_ROOT/lib/backup_core.sh" && \
   ! grep -q 'run_privileged crontab' "$PROJECT_ROOT/lib/user_core.sh" && \
   ! grep -q 'run_privileged crontab' "$PROJECT_ROOT/lib/backup_core.sh" && \
   ! grep -q 'run_privileged crontab' "$PROJECT_ROOT/lib/controller_user_lifecycle.sh" && \
   ! grep -q 'run_privileged tee' "$PROJECT_ROOT/lib/user_core.sh" && \
   ! grep -q 'run_privileged tee' "$PROJECT_ROOT/lib/backup_core.sh" && \
   ! grep -q 'run_privileged tee' "$PROJECT_ROOT/lib/resource_core.sh" && \
   ! grep -q 'run_privileged tee' "$PROJECT_ROOT/lib/security_baseline_core.sh" && \
   ! grep -q 'run_privileged du' "$PROJECT_ROOT/lib/backup_core.sh" && \
   ! grep -q 'run_privileged rm' "$PROJECT_ROOT/lib/resource_core.sh" && \
   ! grep -q 'run_privileged rmdir' "$PROJECT_ROOT/lib/resource_core.sh" && \
   ! grep -q 'run_privileged mkdir' "$PROJECT_ROOT/lib/resource_core.sh" && \
   ! grep -q 'run_privileged apt-get' "$PROJECT_ROOT/lib/system_core.sh" && \
   ! grep -q 'run_privileged sed' "$PROJECT_ROOT/lib/controller_user_lifecycle.sh" && \
   ! grep -q 'run_privileged parallel' "$PROJECT_ROOT/lib/backup_core.sh" && \
   ! grep -q 'run_privileged xargs' "$PROJECT_ROOT/lib/backup_core.sh"; then
    test_pass
else
    test_fail "仍有 helper 已覆盖的命令经由泛化 run_privileged 执行"
fi

cleanup_test_env

test_suite_end
