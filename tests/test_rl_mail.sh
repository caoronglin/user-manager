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

printf 'passed=%s failed=%s\n' "$rl_pass" "$rl_fail"
[[ "$rl_fail" -eq 0 ]]
