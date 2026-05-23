#!/bin/bash
# rl_mail_template.sh - 邮件模板渲染模块

: "${SCRIPT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
: "${EMAIL_TEMPLATES_DIR:=$SCRIPT_DIR/templates/email}"

rl_mail_html_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&#39;/g"
}

rl_mail_template_render() {
    local rl_template_file="$1" rl_username="$2" rl_password="$3" rl_action="$4" rl_timestamp="$5"
    local rl_reason="${6:-}" rl_expiry_date="${7:-}" rl_operator="${8:-}" rl_status="${9:-}" rl_quota="${10:-}" rl_content
    [[ -f "$rl_template_file" ]] || return 1
    rl_content=$(<"$rl_template_file") || return 1
    local rl_eu rl_ep rl_ea rl_et rl_er rl_ee rl_eo rl_es rl_eq
    rl_eu=$(rl_mail_html_escape "$rl_username")
    rl_ep=$(rl_mail_html_escape "$rl_password")
    rl_ea=$(rl_mail_html_escape "$rl_action")
    rl_et=$(rl_mail_html_escape "$rl_timestamp")
    rl_er=$(rl_mail_html_escape "$rl_reason")
    rl_ee=$(rl_mail_html_escape "$rl_expiry_date")
    rl_eo=$(rl_mail_html_escape "$rl_operator")
    rl_es=$(rl_mail_html_escape "$rl_status")
    rl_eq=$(rl_mail_html_escape "$rl_quota")

    # Bash 5.2 的 patsub_replacement 会把 replacement 中的 & 展开为匹配文本，
    # 而 HTML escape 会生成 &lt; / &gt;。模板替换必须按字面值插入。
    shopt -u patsub_replacement 2>/dev/null || true
    rl_content="${rl_content//\$\{username\}/$rl_eu}"
    rl_content="${rl_content//\$\{password\}/$rl_ep}"
    rl_content="${rl_content//\$\{action\}/$rl_ea}"
    rl_content="${rl_content//\$\{timestamp\}/$rl_et}"
    rl_content="${rl_content//\$\{reason\}/$rl_er}"
    rl_content="${rl_content//\$\{expiry_date\}/$rl_ee}"
    rl_content="${rl_content//\$\{operator\}/$rl_eo}"
    rl_content="${rl_content//\$\{status\}/$rl_es}"
    rl_content="${rl_content//\$\{quota\}/$rl_eq}"
    printf '%s\n' "$rl_content"
}

rl_mail_template_fallback() {
    local rl_username="$1" rl_password="$2" rl_action="$3" rl_timestamp="$4" rl_eu rl_ep rl_ea rl_et
    rl_eu=$(rl_mail_html_escape "$rl_username"); rl_ep=$(rl_mail_html_escape "$rl_password")
    rl_ea=$(rl_mail_html_escape "$rl_action"); rl_et=$(rl_mail_html_escape "$rl_timestamp")
    cat <<HTMLEOF
<!DOCTYPE html><html lang="zh-CN"><head><meta charset="UTF-8"><title>${rl_ea}通知</title></head>
<body style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#f0f2f5;padding:32px;">
<div style="max-width:560px;margin:auto;background:#fff;border-radius:12px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,.08);">
<div style="background:#16a34a;color:#fff;padding:24px 32px;font-size:20px;font-weight:600;">${rl_ea}通知</div>
<div style="padding:28px 32px;color:#374151;line-height:1.7;">
<p>尊敬的用户 <strong>${rl_eu}</strong>，您好！</p>
<p>您的账户${rl_ea}已完成。以下是您的登录凭据：</p>
<table style="width:100%;background:#f8fafc;border:1px solid #e2e8f0;border-radius:8px;padding:16px;"><tr><td>用户名</td><td><strong>${rl_eu}</strong></td></tr><tr><td>密码</td><td><strong>${rl_ep}</strong></td></tr><tr><td>时间</td><td>${rl_et}</td></tr></table>
<p style="color:#92400e;">安全提示：请妥善保管密码，首次登录后建议立即修改。</p>
</div><div style="padding:16px 32px;border-top:1px solid #e5e7eb;color:#9ca3af;font-size:12px;">用户管理系统 · ${rl_et}</div></div></body></html>
HTMLEOF
}

html_escape_text() { rl_mail_html_escape "$@"; }
render_template_file() { rl_mail_template_render "$@"; }
generate_fallback_template() { rl_mail_template_fallback "$@"; }
