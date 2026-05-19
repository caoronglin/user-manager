#!/bin/bash
# test_rl_wecom.sh - 企业微信 Bot 预留接口安全测试

set -uo pipefail

rl_test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rl_project_root="$(dirname "$rl_test_dir")"
rl_tmpdir="$(mktemp -d)"
trap 'rm -rf "$rl_tmpdir"' EXIT

SCRIPT_DIR="$rl_project_root"
rl_stub_dir="$rl_tmpdir/bin"
rl_curl_log="$rl_tmpdir/curl.log"
mkdir -p "$rl_stub_dir"
: > "$rl_curl_log"

cat > "$rl_stub_dir/curl" <<'EOS'
#!/bin/bash
printf '%s\n' "$*" >> "$RL_CURL_LOG"
printf '{"errcode":0,"errmsg":"ok"}\n'
EOS
chmod +x "$rl_stub_dir/curl"
export PATH="$rl_stub_dir:$PATH"
export RL_CURL_LOG="$rl_curl_log"

rl_pass=0
rl_fail=0
rl_ok() { printf 'ok - %s\n' "$1"; rl_pass=$((rl_pass + 1)); }
rl_not_ok() { printf 'not ok - %s\n' "$1" >&2; rl_fail=$((rl_fail + 1)); }

msg_err() { :; }
msg_warn() { :; }
msg_info() { :; }

# shellcheck source=lib/rl_wecom_bot_sender.sh
if source "$rl_project_root/lib/rl_wecom_bot_sender.sh"; then
    rl_ok "rl_wecom_bot_sender.sh 可 source"
else
    rl_not_ok "rl_wecom_bot_sender.sh source 失败"
fi

unset USER_MANAGER_WECOM_ENABLED USER_MANAGER_WECOM_DRY_RUN USER_MANAGER_WECOM_WEBHOOK USER_MANAGER_WECOM_EVENTS
: > "$rl_curl_log"
if rl_wecom_bot_send_text account_disabled '{"summary":"用户禁用"}' >/dev/null 2>&1 && [[ ! -s "$rl_curl_log" ]]; then
    rl_ok "默认关闭时 no-op 且不调用 curl"
else
    rl_not_ok "默认关闭时不应调用 curl 或失败"
fi

USER_MANAGER_WECOM_ENABLED=1
USER_MANAGER_WECOM_DRY_RUN=1
USER_MANAGER_WECOM_WEBHOOK='https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=abc-123'
: > "$rl_curl_log"
if rl_wecom_bot_send_text account_disabled '{"summary":"dry"}' >/dev/null 2>&1 && [[ ! -s "$rl_curl_log" ]]; then
    rl_ok "dry-run 时不调用 curl"
else
    rl_not_ok "dry-run 不应调用 curl"
fi

USER_MANAGER_WECOM_DRY_RUN=0
USER_MANAGER_WECOM_WEBHOOK=''
if rl_wecom_bot_send_text account_disabled '{"summary":"empty"}' >/dev/null 2>&1; then
    rl_ok "webhook 为空时 skip"
else
    rl_not_ok "webhook 为空应安全 skip"
fi

USER_MANAGER_WECOM_WEBHOOK='https://example.com/webhook?key=abc'
if ! rl_wecom_bot_send_text account_disabled '{"summary":"bad url"}' >/dev/null 2>&1; then
    rl_ok "非法 URL 被拒绝"
else
    rl_not_ok "非法 URL 应拒绝"
fi

USER_MANAGER_WECOM_WEBHOOK='https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=abc-123'
USER_MANAGER_WECOM_EVENTS='account_disabled,quota_hard_limit_set'
if rl_wecom_event_allowed account_disabled && ! rl_wecom_event_allowed account_restored; then
    rl_ok "事件 allowlist 生效"
else
    rl_not_ok "事件 allowlist 未生效"
fi

: > "$rl_curl_log"
if rl_wecom_bot_send_text account_disabled '{"summary":"用户 <alice>","password":"Secret123","webhook":"https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=secret"}' >/dev/null 2>&1 && \
   grep -q -- '--max-time 5' "$rl_curl_log" && \
   grep -q 'qyapi.weixin.qq.com/cgi-bin/webhook/send?key=abc-123' "$rl_curl_log" && \
   ! grep -q 'Secret123' "$rl_curl_log" && \
   ! grep -q 'key=secret' "$rl_curl_log"; then
    rl_ok "启用时调用 stub curl、带超时并脱敏 payload"
else
    rl_not_ok "启用发送未满足 curl/timeout/脱敏要求"
fi

masked="$(rl_wecom_mask_secret 'https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=abc-123')"
if [[ "$masked" == *'key=***'* && "$masked" != *'abc-123'* ]]; then
    rl_ok "webhook 脱敏输出"
else
    rl_not_ok "webhook 未脱敏: $masked"
fi

long_key_masked="$(rl_wecom_mask_secret 'https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=12345678-1234-1234-1234-123456789abc&debug=1')"
json_masked="$(rl_wecom_mask_secret '{"password":"Secret123","token":"tok_abcdef123456","secret":"sec-value","webhook":"https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=12345678-1234-1234-1234-123456789abc"}')"
if [[ "$long_key_masked" == *'key=***&debug=1'* && "$long_key_masked" != *'123456789abc'* && \
      "$json_masked" != *'Secret123'* && "$json_masked" != *'tok_abcdef123456'* && \
      "$json_masked" != *'sec-value'* && "$json_masked" != *'123456789abc'* ]]; then
    rl_ok "长 webhook key 与敏感 JSON 字段完全脱敏"
else
    rl_not_ok "长 key 或敏感 JSON 字段脱敏不完整: $long_key_masked / $json_masked"
fi

printf 'passed=%s failed=%s\n' "$rl_pass" "$rl_fail"
[[ "$rl_fail" -eq 0 ]]
