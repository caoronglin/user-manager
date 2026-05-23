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
<!DOCTYPE html>
<html lang="zh-CN">
<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>${rl_ea}通知</title></head>
<body style="margin:0;background:#f6f8fb;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,'Noto Sans SC',sans-serif;color:#1f2937;line-height:1.7;padding:28px 14px;">
<div style="max-width:620px;margin:auto;background:#fff;border:1px solid #e5e7eb;border-radius:12px;overflow:hidden;box-shadow:0 4px 18px rgba(15,23,42,.08);">
  <div style="background:#166534;color:#fff;padding:24px 30px;">
    <div style="font-size:12px;letter-spacing:.08em;text-transform:uppercase;opacity:.82;">System Notice</div>
    <h1 style="margin:6px 0 0;font-size:22px;line-height:1.3;">${rl_ea}通知</h1>
  </div>
  <div style="padding:28px 30px;">
    <div style="background:#f0fdf4;border-left:4px solid #16a34a;border-radius:8px;padding:16px 18px;margin-bottom:20px;">
      <p style="margin:0;">尊敬的用户 <strong>${rl_eu}</strong>，您好！您的账户${rl_ea}已完成。</p>
    </div>
    <table style="width:100%;border-collapse:collapse;border:1px solid #e5e7eb;border-radius:8px;overflow:hidden;">
      <tr><td style="width:120px;background:#f9fafb;color:#64748b;padding:12px;">用户名</td><td style="padding:12px;font-weight:700;">${rl_eu}</td></tr>
      <tr><td style="background:#f9fafb;color:#64748b;padding:12px;">密码</td><td style="padding:12px;font-family:Consolas,'Courier New',monospace;font-weight:700;color:#166534;letter-spacing:1px;">${rl_ep}</td></tr>
      <tr><td style="background:#f9fafb;color:#64748b;padding:12px;">时间</td><td style="padding:12px;">${rl_et}</td></tr>
    </table>
    <div style="margin-top:20px;background:#fff7ed;border-left:4px solid #f97316;border-radius:8px;padding:14px 16px;color:#9a3412;font-size:13px;">安全提示：请妥善保管密码，首次登录后建议立即修改。</div>
  </div>
  <div style="padding:16px 30px;background:#f9fafb;border-top:1px solid #e5e7eb;color:#94a3b8;font-size:12px;">用户管理系统 · ${rl_et}</div>
</div>
</body>
</html>
HTMLEOF
}

html_escape_text() { rl_mail_html_escape "$@"; }
render_template_file() { rl_mail_template_render "$@"; }
generate_fallback_template() { rl_mail_template_fallback "$@"; }
