#!/bin/bash
# test_rl_mail.sh - 拆分邮件模块基础测试

set -uo pipefail

rl_test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rl_project_root="$(dirname "$rl_test_dir")"
rl_tmpdir="$(mktemp -d)"
trap 'rm -rf "$rl_tmpdir"' EXIT

SCRIPT_DIR="$rl_project_root"
DATA_DIR="$rl_tmpdir/data"
LOG_DIR="$rl_tmpdir/logs"
EMAIL_CONFIG_FILE="$DATA_DIR/email_config.json"

rl_pass=0
rl_fail=0

rl_ok() { printf 'ok - %s\n' "$1"; rl_pass=$((rl_pass + 1)); }
rl_not_ok() { printf 'not ok - %s\n' "$1" >&2; rl_fail=$((rl_fail + 1)); }

msg_err() { :; }
msg_warn() { :; }
msg_info() { :; }
msg_ok() { :; }

rl_files=(
    rl_mail_config.sh
    rl_mail_template.sh
    rl_mail_sender.sh
    rl_mail_queue.sh
    rl_mail_events.sh
    rl_mail_audit.sh
)

for rl_file in "${rl_files[@]}"; do
    if [[ -f "$rl_project_root/lib/$rl_file" ]]; then
        # shellcheck disable=SC1090
        source "$rl_project_root/lib/$rl_file" && rl_ok "$rl_file 可 source" || rl_not_ok "$rl_file source 失败"
    else
        rl_not_ok "$rl_file 不存在"
    fi
done

if rl_mail_config_load; then
    rl_ok "rl_mail_config_load 返回成功"
else
    rl_not_ok "rl_mail_config_load 返回失败"
fi

rl_escaped="$(rl_mail_html_escape '<tag>')"
if [[ "$rl_escaped" == '&lt;tag&gt;' ]]; then
    rl_ok "rl_mail_html_escape 转义尖括号"
else
    rl_not_ok "rl_mail_html_escape 转义失败: $rl_escaped"
fi

if ! rl_mail_send '' 'subject' 'body' >/dev/null 2>&1; then
    rl_ok "rl_mail_send 拒绝空收件人"
else
    rl_not_ok "rl_mail_send 未拒绝空收件人"
fi

rl_extended_template="$rl_tmpdir/extended_template.html"
cat > "$rl_extended_template" <<'EOF'
user=${username};reason=${reason};expiry=${expiry_date};operator=${operator};status=${status};quota=${quota}
EOF
rl_rendered="$(rl_mail_template_render "$rl_extended_template" 'alice' '' '停用' '2026-01-02 03:04:05' '<script>x</script>' '2026-02-01' 'admin<ops>' 'disabled' '1G')"
if [[ "$rl_rendered" == *'reason=&lt;script&gt;x&lt;/script&gt;'* && \
      "$rl_rendered" == *'expiry=2026-02-01'* && \
      "$rl_rendered" == *'operator=admin&lt;ops&gt;'* && \
      "$rl_rendered" == *'status=disabled'* && \
      "$rl_rendered" == *'quota=1G'* ]]; then
    rl_ok "rl_mail_template_render 支持账户/配额扩展变量并 HTML 转义"
else
    rl_not_ok "rl_mail_template_render 未正确渲染扩展变量: $rl_rendered"
fi

RL_MAIL_SEND_LOG="$rl_tmpdir/mail_send.log"
rl_mail_send() {
    printf 'to=%s\nsubject=%s\nbody=%s\nretries=%s\n---\n' "$1" "$2" "$3" "${4:-}" >> "$RL_MAIL_SEND_LOG"
    [[ "${RL_MAIL_SEND_FAIL:-0}" != "1" ]]
}
rl_mail_audit_log() { printf 'audit=%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "${5:-}" >> "$rl_tmpdir/mail_audit.log"; }

: > "$RL_MAIL_SEND_LOG"
if send_account_disabled_email 'alice' 'alice@example.com' '<bad>' '2026-02-01' 'admin' >/dev/null 2>&1 && \
   grep -q 'to=alice@example.com' "$RL_MAIL_SEND_LOG" && \
   grep -q '账户已禁用' "$RL_MAIL_SEND_LOG" && \
   grep -q '&lt;bad&gt;' "$RL_MAIL_SEND_LOG"; then
    rl_ok "send_account_disabled_email 使用模板发送且转义 reason"
else
    rl_not_ok "send_account_disabled_email 未按预期发送模板邮件"
fi

if send_account_restored_email 'alice' '' 'admin' >/dev/null 2>&1; then
    rl_ok "账户恢复邮件空收件人时安全跳过"
else
    rl_not_ok "账户恢复邮件空收件人应返回成功并跳过"
fi

if ! send_account_suspended_email 'alice' 'bad-address' 'reason' 'permanent' 'admin' >/dev/null 2>&1; then
    rl_ok "账户停用邮件拒绝非法邮箱"
else
    rl_not_ok "账户停用邮件未拒绝非法邮箱"
fi

: > "$RL_MAIL_SEND_LOG"
if send_quota_hard_limit_email 'alice' 'alice@example.com' '1G' 'admin' >/dev/null 2>&1 && \
   grep -q '硬配额' "$RL_MAIL_SEND_LOG" && \
   grep -q '1G' "$RL_MAIL_SEND_LOG"; then
    rl_ok "send_quota_hard_limit_email 发送硬配额通知"
else
    rl_not_ok "send_quota_hard_limit_email 未按预期发送"
fi

RL_MAIL_SEND_FAIL=1
if ! send_account_disabled_email 'alice' 'alice@example.com' 'reason' 'permanent' 'admin' >/dev/null 2>&1; then
    rl_ok "账户通知发送失败时返回非零"
else
    rl_not_ok "账户通知发送失败时应返回非零"
fi
unset RL_MAIL_SEND_FAIL

if declare -F rl_mail_queue_dispatch_template >/dev/null 2>&1 && \
   rl_mail_queue_dispatch_template 'account_disabled' 'alice' 'alice@example.com' '{"reason":"r","expiry_date":"permanent","operator":"admin"}' >/dev/null 2>&1 && \
   rl_mail_queue_dispatch_template 'account_restored' 'alice' 'alice@example.com' '{"operator":"admin"}' >/dev/null 2>&1 && \
   rl_mail_queue_dispatch_template 'quota_hard_limit_set' 'alice' 'alice@example.com' '{"quota":"1G","operator":"admin"}' >/dev/null 2>&1; then
    rl_ok "邮件队列支持账户与硬配额模板分发"
else
    rl_not_ok "邮件队列未支持账户/硬配额模板分发"
fi

printf 'passed=%s failed=%s\n' "$rl_pass" "$rl_fail"
[[ "$rl_fail" -eq 0 ]]
