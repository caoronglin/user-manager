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

test_start "numeric environment overrides reject arithmetic expressions"
config_marker="$TEST_TMPDIR/arithmetic-injection"
config_payload="1[\$(touch $config_marker)]"
config_output="$(env \
    USER_MANAGER_PASSWORD_POOL_KEEP="$config_payload" \
    USER_MANAGER_QUOTA_DEFAULT="$config_payload" \
    USER_MANAGER_BACKUP_MIN_KEEP="$config_payload" \
    USER_MANAGER_BACKUP_RETENTION_DAYS="$config_payload" \
    USER_MANAGER_DISK_WARNING_THRESHOLD="$config_payload" \
    USER_MANAGER_PASSWORD_ROTATE_INTERVAL_DAYS="$config_payload" \
    bash -c 'source "$1/lib/config.sh"; ((80 > DISK_WARNING_THRESHOLD)) || true; ((1 < QUOTA_DEFAULT)) || true; ((PASSWORD_POOL_KEEP >= 0)) || true; ((BACKUP_MIN_KEEP >= 0)) || true; ((BACKUP_RETENTION_DAYS >= 0)) || true; ((PASSWORD_ROTATE_INTERVAL_DAYS >= 1)) || true; printf "%s:%s:%s:%s:%s:%s" "$PASSWORD_POOL_KEEP" "$QUOTA_DEFAULT" "$BACKUP_MIN_KEEP" "$BACKUP_RETENTION_DAYS" "$DISK_WARNING_THRESHOLD" "$PASSWORD_ROTATE_INTERVAL_DAYS"' _ "$PROJECT_ROOT" 2>/dev/null)"
if [[ "$config_output" == "5:536870912000:3:7:90:90" && ! -e "$config_marker" ]]; then
    test_pass
else
    test_fail "非法数值配置未安全回退，输出为: $config_output"
fi

test_start "acl_cache_get 在 set -u 下不会触发未绑定变量"
acl_cache_clear
acl_cache_set "level:cacheuser" "$ACL_LEVEL_USER"
if
    unset level 2>/dev/null
    acl_cache_get "level:cacheuser" level && [[ "$level" == "$ACL_LEVEL_USER" ]]
then
    test_pass
else
    test_fail "acl_cache_get 未正确写入输出变量或触发了 set -u 问题"
fi

test_start "validate_safe_link_name 拒绝路径穿越和分隔符"
if declare -F validate_safe_link_name >/dev/null 2>&1 &&
    ! validate_safe_link_name '../evil' >/dev/null 2>&1 &&
    ! validate_safe_link_name 'nested/path' >/dev/null 2>&1 &&
    ! validate_safe_link_name '--danger' >/dev/null 2>&1 &&
    validate_safe_link_name 'shared_data' >/dev/null 2>&1; then
    test_pass
else
    test_fail "validate_safe_link_name 未正确校验链接名称"
fi

test_start "validate_email_config 拒绝可疑 SMTP 主机名"
if command -v jq >/dev/null 2>&1; then
    test_email_config="$TEST_TMPDIR/email_config.json"
    cat >"$test_email_config" <<'EOF'
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
    raw_html=$(
        cat <<'EOF'
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
    priv_tee() { cat >"$1"; }
    priv_chown() { printf 'chown %s\n' "$*" >>"$priv_log"; }
    priv_chmod() { printf 'chmod %s\n' "$*" >>"$priv_log"; }
    if write_privileged_text_file "$target_file" "0640" "root:root" <<'EOF'; then
managed=true
EOF
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
if priv_check_whitelist mkdir && priv_check_whitelist rm && priv_check_whitelist cp && priv_check_whitelist mv &&
    priv_check_whitelist ln && priv_check_whitelist tee && priv_check_whitelist crontab &&
    priv_check_whitelist du && priv_check_whitelist quota && priv_check_whitelist apt-get &&
    priv_check_whitelist sed && priv_check_whitelist parallel && priv_check_whitelist xargs; then
    test_pass
else
    test_fail "privilege 白名单未覆盖关键命令"
fi

test_start "关键模块不再用泛化 run_privileged 调 helper 已覆盖的命令"
if ! grep -q 'run_privileged iptables' "$PROJECT_ROOT/lib/dns_core.sh" &&
    ! grep -q 'run_privileged smartctl' "$PROJECT_ROOT/lib/system_core.sh" &&
    ! grep -q 'run_privileged mkdir' "$PROJECT_ROOT/lib/async_core.sh" &&
    ! grep -q 'run_privileged mkdir' "$PROJECT_ROOT/lib/proc_manager.sh" &&
    ! grep -q 'run_privileged chmod' "$PROJECT_ROOT/lib/proc_manager.sh" &&
    ! grep -q 'run_privileged cp -r /etc/skel' "$PROJECT_ROOT/lib/user_core.sh" &&
    ! grep -q 'run_privileged userdel' "$PROJECT_ROOT/lib/user_core.sh" &&
    ! grep -q 'run_privileged quota' "$PROJECT_ROOT/lib/quota_core.sh" &&
    ! grep -q 'run_privileged rsync' "$PROJECT_ROOT/lib/backup_core.sh" &&
    ! grep -q 'run_privileged crontab' "$PROJECT_ROOT/lib/user_core.sh" &&
    ! grep -q 'run_privileged crontab' "$PROJECT_ROOT/lib/backup_core.sh" &&
    ! grep -q 'run_privileged crontab' "$PROJECT_ROOT/lib/controller_user_lifecycle.sh" &&
    ! grep -q 'run_privileged tee' "$PROJECT_ROOT/lib/user_core.sh" &&
    ! grep -q 'run_privileged tee' "$PROJECT_ROOT/lib/backup_core.sh" &&
    ! grep -q 'run_privileged tee' "$PROJECT_ROOT/lib/resource_core.sh" &&
    ! grep -q 'run_privileged tee' "$PROJECT_ROOT/lib/security_baseline_core.sh" &&
    ! grep -q 'run_privileged du' "$PROJECT_ROOT/lib/backup_core.sh" &&
    ! grep -q 'run_privileged rm' "$PROJECT_ROOT/lib/resource_core.sh" &&
    ! grep -q 'run_privileged rmdir' "$PROJECT_ROOT/lib/resource_core.sh" &&
    ! grep -q 'run_privileged mkdir' "$PROJECT_ROOT/lib/resource_core.sh" &&
    ! grep -q 'run_privileged apt-get' "$PROJECT_ROOT/lib/system_core.sh" &&
    ! grep -q 'run_privileged sed' "$PROJECT_ROOT/lib/controller_user_lifecycle.sh" &&
    ! grep -q 'run_privileged parallel' "$PROJECT_ROOT/lib/backup_core.sh" &&
    ! grep -q 'run_privileged xargs' "$PROJECT_ROOT/lib/backup_core.sh"; then
    test_pass
else
    test_fail "仍有 helper 已覆盖的命令经由泛化 run_privileged 执行"
fi

# 邮件队列/异步任务公共 API 的输入校验
export DATA_DIR="$TEST_TMPDIR/security_data"
mkdir -p "$DATA_DIR"
export EMAIL_QUEUE_DB="$DATA_DIR/security_mail_queue.db"
# shellcheck source=lib/rl_mail_queue.sh
source "$PROJECT_ROOT/lib/rl_mail_queue.sh"
# shellcheck source=lib/async_core.sh
source "$PROJECT_ROOT/lib/async_core.sh"
export EMAIL_QUEUE_SECRET_DIR="$DATA_DIR/secrets"
export EMAIL_QUEUE_KEY_FILE="$EMAIL_QUEUE_SECRET_DIR/.key"
export EMAIL_QUEUE_MASTER_KEY=""

test_start "邮件队列拒绝空必填字段"
if ! rl_mail_queue_enqueue "" "" "" >/dev/null 2>&1; then
    test_pass
else
    test_fail "rl_mail_queue_enqueue 未拒绝空必填字段"
fi

test_start "邮件队列拒绝非法保留天数"
if ! rl_mail_queue_cleanup "1; DROP TABLE email_queue" >/dev/null 2>&1; then
    test_pass
else
    test_fail "rl_mail_queue_cleanup 未拒绝非法保留天数"
fi

test_start "异步任务提交拒绝非法类型和非 1-10 优先级"
if ! async_submit 'bad; DROP' '' 5 >/dev/null 2>&1 &&
    ! async_submit 'email' '' 99 >/dev/null 2>&1; then
    test_pass
else
    test_fail "async_submit 未拒绝非法任务类型或优先级"
fi

test_start "异步查询/清理 API 拒绝 SQL 注入形态参数"
if ! async_status 'task_1; DROP TABLE tasks' >/dev/null 2>&1 &&
    ! async_list '' '1; DROP TABLE tasks' >/dev/null 2>&1 &&
    ! async_cleanup '1; DROP TABLE tasks' >/dev/null 2>&1; then
    test_pass
else
    test_fail "async 查询/清理 API 未拒绝非法参数"
fi

test_start "邮件队列密码不落数据库明文"
if command -v sqlite3 >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    rl_secret_id=$(rl_mail_queue_enqueue "alice" "alice@example.com" "password_notify" '{"password":"SuperSecret123","action":"密码更新"}' 5)
    rl_stored_data=$(sqlite3 "$EMAIL_QUEUE_DB" "SELECT data FROM email_queue WHERE id=$rl_secret_id;")
    if [[ "$rl_stored_data" != *"SuperSecret123"* ]] && [[ "$rl_stored_data" == *"secret_token"* ]]; then
        test_pass
    else
        test_fail "密码仍出现在邮件队列 DB 中: $rl_stored_data"
    fi
    rl_secret_token=$(jq -r '.secret_token // empty' <<<"$rl_stored_data")
    rl_mail_queue_remove_secret "$rl_secret_token"
else
    test_skip "sqlite3/jq 未安装"
fi

test_start "邮件队列 secret 文件加密落盘（不落明文）"
if ! command -v openssl >/dev/null 2>&1; then
    test_skip "openssl 未安装"
else
    rl_test_secret_dir="$TEST_TMPDIR/secret_enc_test"
    mkdir -p "$rl_test_secret_dir"
    export EMAIL_QUEUE_SECRET_DIR="$rl_test_secret_dir"
    export EMAIL_QUEUE_KEY_FILE="$rl_test_secret_dir/.key"
    export EMAIL_QUEUE_MASTER_KEY=""
    rl_enc_token=$(rl_mail_queue_store_secret "SuperSecret123")
    rl_enc_content=$(cat "$rl_test_secret_dir/$rl_enc_token")
    if [[ "$rl_enc_content" == v2:* ]] && [[ "$rl_enc_content" != *"SuperSecret123"* ]]; then
        test_pass
    else
        test_fail "secret 文件未加密或仍含明文: $rl_enc_content"
    fi
fi

test_start "邮件队列 secret 解密往返一致"
if ! command -v openssl >/dev/null 2>&1; then
    test_skip "openssl 未安装"
else
    rl_test_secret_dir="$TEST_TMPDIR/secret_dec_test"
    mkdir -p "$rl_test_secret_dir"
    export EMAIL_QUEUE_SECRET_DIR="$rl_test_secret_dir"
    export EMAIL_QUEUE_KEY_FILE="$rl_test_secret_dir/.key"
    export EMAIL_QUEUE_MASTER_KEY=""
    rl_dec_token=$(rl_mail_queue_store_secret "Secret456!")
    rl_dec_got=$(rl_mail_queue_read_secret "$rl_dec_token")
    if [[ "$rl_dec_got" == "Secret456!" ]]; then
        test_pass
    else
        test_fail "解密结果不一致: got=[$rl_dec_got]"
    fi
fi

test_start "邮件队列兼容并升级旧版 base64 IV/MAC secret"
if ! command -v openssl >/dev/null 2>&1; then
    test_skip "openssl 未安装"
else
    rl_test_secret_dir="$TEST_TMPDIR/secret_legacy_test"
    mkdir -p "$rl_test_secret_dir"
    export EMAIL_QUEUE_SECRET_DIR="$rl_test_secret_dir"
    export EMAIL_QUEUE_KEY_FILE="$rl_test_secret_dir/.key"
    export EMAIL_QUEUE_MASTER_KEY=""
    rl_legacy_key=$(rl_mail_secret_key)
    rl_legacy_mac_key=$(rl_mail_secret_mac_key "$rl_legacy_key")
    openssl rand 16 >"$rl_test_secret_dir/iv"
    rl_legacy_iv_hex=$(od -An -v -tx1 "$rl_test_secret_dir/iv" | tr -d '[:space:]')
    rl_legacy_iv_b64=$(openssl base64 -A <"$rl_test_secret_dir/iv")
    rl_legacy_ct_b64=$(printf '%s' "LegacyEncryptedSecret" | openssl enc -aes-256-cbc -K "$rl_legacy_key" -iv "$rl_legacy_iv_hex" -a -A)
    rl_legacy_mac_b64=$(printf '%s' "$rl_legacy_ct_b64" | openssl base64 -d -A | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$rl_legacy_mac_key" -binary | openssl base64 -A)
    printf 'v1:%s:%s:%s' "$rl_legacy_iv_b64" "$rl_legacy_ct_b64" "$rl_legacy_mac_b64" >"$rl_test_secret_dir/legacy_token"
    chmod 600 "$rl_test_secret_dir/legacy_token"
    if [[ "$(rl_mail_queue_read_secret "legacy_token")" == "LegacyEncryptedSecret" ]]; then
        rl_legacy_orig=$(cat "$rl_test_secret_dir/legacy_token")
        IFS=':' read -r rl_legacy_version rl_legacy_iv rl_legacy_ct rl_legacy_mac <<<"$rl_legacy_orig"
        if [[ "${rl_legacy_mac:0:1}" == A ]]; then rl_legacy_mac_flip=B; else rl_legacy_mac_flip=A; fi
        printf '%s:%s:%s:%s' "$rl_legacy_version" "$rl_legacy_iv" "$rl_legacy_ct" "$rl_legacy_mac_flip${rl_legacy_mac:1}" >"$rl_test_secret_dir/legacy_token"
        rl_legacy_tampered=$(cat "$rl_test_secret_dir/legacy_token")
        if ! rl_mail_queue_migrate_secret "legacy_token" &&
            [[ "$(cat "$rl_test_secret_dir/legacy_token")" == "$rl_legacy_tampered" ]]; then
            printf '%s' "$rl_legacy_orig" >"$rl_test_secret_dir/legacy_token"
            if rl_mail_queue_migrate_secret "legacy_token" &&
                [[ "$(cat "$rl_test_secret_dir/legacy_token")" == v2:* ]] &&
                [[ "$(rl_mail_queue_read_secret "legacy_token")" == "LegacyEncryptedSecret" ]]; then
                test_pass
            else
                test_fail "有效旧版 secret 未安全升级为 v2"
            fi
        else
            test_fail "无效旧版 secret 迁移成功或修改了原文件"
        fi
    else
        test_fail "旧版 base64 IV/MAC secret 解密失败"
    fi
fi

test_start "邮件队列 secret 篡改被 HMAC 检测拒绝"
if ! command -v openssl >/dev/null 2>&1; then
    test_skip "openssl 未安装"
else
    rl_test_secret_dir="$TEST_TMPDIR/secret_tamper_test"
    mkdir -p "$rl_test_secret_dir"
    export EMAIL_QUEUE_SECRET_DIR="$rl_test_secret_dir"
    export EMAIL_QUEUE_KEY_FILE="$rl_test_secret_dir/.key"
    export EMAIL_QUEUE_MASTER_KEY=""
    rl_tamper_token=$(rl_mail_queue_store_secret "Secret789!")
    rl_tamper_path="$rl_test_secret_dir/$rl_tamper_token"
    rl_tamper_orig=$(cat "$rl_tamper_path")
    IFS=':' read -r rl_t_version rl_t_iv rl_t_ct rl_t_mac <<<"$rl_tamper_orig"
    # 修改一个有效长度的标签，触发认证失败。
    if [[ "${rl_t_mac:0:1}" == 0 ]]; then rl_t_mac_flip=1; else rl_t_mac_flip=0; fi
    printf '%s:%s:%s:%s' "$rl_t_version" "$rl_t_iv" "$rl_t_ct" "$rl_t_mac_flip${rl_t_mac:1}" >"$rl_tamper_path"
    if ! rl_mail_queue_read_secret "$rl_tamper_token" >/dev/null 2>&1; then
        test_pass
    else
        test_fail "篡改后的 secret 未被拒绝"
    fi
    printf '%s' "$rl_tamper_orig" >"$rl_tamper_path"
fi

test_start "邮件队列 secret 篡改 IV 被 HMAC 检测拒绝"
if ! command -v openssl >/dev/null 2>&1; then
    test_skip "openssl 未安装"
else
    rl_test_secret_dir="$TEST_TMPDIR/secret_iv_tamper_test"
    mkdir -p "$rl_test_secret_dir"
    export EMAIL_QUEUE_SECRET_DIR="$rl_test_secret_dir"
    export EMAIL_QUEUE_KEY_FILE="$rl_test_secret_dir/.key"
    export EMAIL_QUEUE_MASTER_KEY=""
    rl_iv_token=$(rl_mail_queue_store_secret "IVIntegrity123")
    rl_iv_path="$rl_test_secret_dir/$rl_iv_token"
    rl_iv_orig=$(cat "$rl_iv_path")
    IFS=':' read -r rl_iv_version rl_iv_hex rl_iv_ct rl_iv_mac <<<"$rl_iv_orig"
    if [[ "${rl_iv_hex:0:1}" == 0 ]]; then rl_iv_flip=1; else rl_iv_flip=0; fi
    printf '%s:%s:%s:%s' "$rl_iv_version" "$rl_iv_flip${rl_iv_hex:1}" "$rl_iv_ct" "$rl_iv_mac" >"$rl_iv_path"
    rl_iv_tampered=$(cat "$rl_iv_path")
    if ! rl_mail_queue_read_secret "$rl_iv_token" >/dev/null 2>&1 &&
        ! rl_mail_queue_migrate_secret "$rl_iv_token" &&
        [[ "$(cat "$rl_iv_path")" == "$rl_iv_tampered" ]]; then
        test_pass
    else
        test_fail "篡改后的 IV 未被拒绝，或迁移改写了原文件"
    fi
    printf '%s' "$rl_iv_orig" >"$rl_iv_path"
fi

test_start "邮件队列明文 secret 迁移为加密格式"
if ! command -v openssl >/dev/null 2>&1; then
    test_skip "openssl 未安装"
else
    rl_test_secret_dir="$TEST_TMPDIR/secret_migrate_test"
    mkdir -p "$rl_test_secret_dir"
    export EMAIL_QUEUE_SECRET_DIR="$rl_test_secret_dir"
    export EMAIL_QUEUE_KEY_FILE="$rl_test_secret_dir/.key"
    export EMAIL_QUEUE_MASTER_KEY=""
    printf 'LegacyPlainSecret' >"$rl_test_secret_dir/legacy_token"
    if rl_mail_queue_migrate_secret "legacy_token" &&
        [[ "$(cat "$rl_test_secret_dir/legacy_token")" == v2:* ]] &&
        [[ "$(rl_mail_queue_read_secret "legacy_token")" == "LegacyPlainSecret" ]]; then
        test_pass
    else
        test_fail "明文 secret 迁移失败"
    fi
fi

test_start "邮件队列 secret token 拒绝路径穿越"
rl_test_secret_dir="$TEST_TMPDIR/secret_token_path_test"
mkdir -p "$rl_test_secret_dir"
rl_token_sentinel="$TEST_TMPDIR/secret-token-sentinel"
printf 'outside-secret' >"$rl_token_sentinel"
export EMAIL_QUEUE_SECRET_DIR="$rl_test_secret_dir"
export EMAIL_QUEUE_KEY_FILE="$rl_test_secret_dir/.key"
if ! rl_mail_queue_read_secret '../secret-token-sentinel' >/dev/null 2>&1 &&
    ! rl_mail_queue_migrate_secret '../secret-token-sentinel' >/dev/null 2>&1 &&
    ! rl_mail_queue_remove_secret '../secret-token-sentinel' >/dev/null 2>&1 &&
    [[ "$(cat "$rl_token_sentinel")" == 'outside-secret' ]]; then
    test_pass
else
    test_fail "非法 secret token 可访问或修改 secret 目录外文件"
fi

test_start "邮件队列拒绝符号链接密钥文件"
rl_test_secret_dir="$TEST_TMPDIR/secret_key_symlink_test"
mkdir -p "$rl_test_secret_dir"
printf '%064d\n' 1 >"$rl_test_secret_dir/real-key"
ln -s real-key "$rl_test_secret_dir/.key"
export EMAIL_QUEUE_SECRET_DIR="$rl_test_secret_dir"
export EMAIL_QUEUE_KEY_FILE="$rl_test_secret_dir/.key"
if ! rl_mail_secret_key >/dev/null 2>&1 &&
    [[ "$(cat "$rl_test_secret_dir/real-key")" == "$(printf '%064d' 1)" ]]; then
    test_pass
else
    test_fail "符号链接密钥未被拒绝"
fi

test_start "邮件队列拒绝硬链接密钥文件"
rl_test_secret_dir="$TEST_TMPDIR/secret_key_hardlink_test"
mkdir -p "$rl_test_secret_dir"
printf '%064d\n' 2 >"$rl_test_secret_dir/.key"
ln "$rl_test_secret_dir/.key" "$TEST_TMPDIR/secret-key-hardlink"
export EMAIL_QUEUE_SECRET_DIR="$rl_test_secret_dir"
export EMAIL_QUEUE_KEY_FILE="$rl_test_secret_dir/.key"
if ! rl_mail_secret_key >/dev/null 2>&1 && [[ "$(stat -c '%h' "$rl_test_secret_dir/.key")" == 2 ]]; then
    test_pass
else
    test_fail "硬链接密钥未被拒绝"
fi

cleanup_test_env

test_suite_end
