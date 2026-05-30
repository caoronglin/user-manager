#!/bin/bash
# test_report_core.sh - 报告核心行为测试

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"

test_suite_start "Report Core"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PATH="$TMP_ROOT/bin:$PATH"
mkdir -p "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/last" <<'FAKELAST'
#!/bin/sh
[ -n "$LAST_CALL_LOG" ] && printf 'last\n' >> "$LAST_CALL_LOG"
cat <<'EOF'
alice pts/0        10.0.0.1        Mon May 20 10:00   still logged in
alice pts/1        10.0.0.2        Tue May 19 09:00 - 10:00  (01:00)
alice tty1         Mon May 18 08:00 - 08:05  (00:05)
bob   pts/2        10.0.0.3        Mon May 20 11:00 - 11:10  (00:10)
wtmp begins Mon May 18 08:00:00 2026
EOF
FAKELAST
chmod +x "$TMP_ROOT/bin/last"
LAST_CALL_LOG="$TMP_ROOT/last_calls.log"
export LAST_CALL_LOG

REPORT_DIR="$TMP_ROOT/report"
DATA_BASE="$TMP_ROOT/data"
JOB_STATS_DIR="$TMP_ROOT/job_stats"
ALL_DISKS=(1)
DISABLED_USERS_FILE="$TMP_ROOT/disabled_users.txt"
USER_CREATION_LOG="$TMP_ROOT/user_creation.csv"
C_BOLD=""

msg_err() { :; }
msg_ok() { :; }
msg_info() { :; }
msg_warn() { :; }
msg_step() { :; }
bytes_to_human() { printf '%sB\n' "$1"; }
get_managed_usernames() { printf 'alice\n'; }
get_user_home() { printf '/home/%s\n' "$1"; }
get_user_mountpoint() { printf '/mnt/data01\n'; }
get_user_quota_info() { printf '1024:2048\n'; }
get_current_resource_limits() { printf '50%%:2G\n'; }
get_weekly_job_stats() { printf 'records=2 avg=1.5 max=3 min=1\n'; }
get_monthly_job_stats() { printf 'records=8 avg=2.5 max=6 min=1\n'; }
id() { [[ "$1" == "-u" ]] && { printf '1001\n'; return 0; }; [[ "$1" == "alice" ]]; }
who() { printf 'alice pts/0 2026-05-20 10:00 (10.0.0.1)\n'; }

# shellcheck disable=SC1091
source "$PROJECT_ROOT/lib/report_core.sh"

test_start "report_get_login_stats 统计登录次数和去重来源"
REPORT_LOGIN_STATS_CACHE=()
login_stats="$(report_get_login_stats alice)"
if [[ "$login_stats" == 3\|* && "$login_stats" == *"10.0.0.1"* && "$login_stats" == *"10.0.0.2"* && "$login_stats" != *"10.0.0.3"* ]]; then
    test_pass
else
    test_fail "登录统计不符合预期: $login_stats"
fi

test_start "report_get_login_stats 同一用户复用缓存"
: > "$LAST_CALL_LOG"
REPORT_LOGIN_STATS_CACHE=()
report_set_login_stats alice
first_stats="${REPORT_LOGIN_COUNT}|${REPORT_LOGIN_SOURCES}"
report_set_login_stats alice
second_stats="${REPORT_LOGIN_COUNT}|${REPORT_LOGIN_SOURCES}"
last_calls="$(wc -l < "$LAST_CALL_LOG" | tr -d ' ')"
if [[ "$first_stats" == "$second_stats" && "$last_calls" == "1" ]]; then
    test_pass
else
    test_fail "登录统计缓存未生效: calls=$last_calls first=$first_stats second=$second_stats"
fi

test_start "个人 HTML 报告包含登录次数和登录 IP"
REPORT_LOGIN_STATS_CACHE=()
personal_report="$TMP_ROOT/alice_report.html"
if generate_user_personal_report alice "$personal_report" >/dev/null && \
   grep -q "近期登录次数" "$personal_report" && \
   grep -q "登录 IP/来源" "$personal_report" && \
   grep -q "10.0.0.1" "$personal_report" && \
   grep -q "metric-grid" "$personal_report"; then
    test_pass
else
    test_fail "个人报告缺少登录统计或层级样式"
fi

test_start "汇总资源 HTML 表包含登录列"
summary_html="$(generate_html_resource_usage_section)"
if [[ "$summary_html" == *"登录次数"* && "$summary_html" == *"登录 IP/来源"* && "$summary_html" == *"10.0.0.2"* ]]; then
    test_pass
else
    test_fail "汇总资源表缺少登录列: $summary_html"
fi

test_start "send_user_report_email 复用统一邮件后端且不调用 sendmail"
cat > "$TMP_ROOT/bin/sendmail" <<'FAKESENDMAIL'
#!/bin/sh
printf 'sendmail-called\n' >> "$SENDMAIL_CALL_LOG"
exit 11
FAKESENDMAIL
chmod +x "$TMP_ROOT/bin/sendmail"
SENDMAIL_CALL_LOG="$TMP_ROOT/sendmail_calls.log"
REPORT_MAIL_LOG="$TMP_ROOT/report_mail.log"
export SENDMAIL_CALL_LOG REPORT_MAIL_LOG
get_user_email() { [[ "${1:-}" == "alice" ]] && printf 'alice@example.com\n'; }
get_email_config() {
    case "${1:-}" in
        from_name) printf '用户管理系统\n' ;;
        from_address) printf 'noreply@example.com\n' ;;
        *) printf '\n' ;;
    esac
}
validate_email_config() { return 0; }
sanitize_mail_header_value() { printf '%s' "${1//$'\n'/ }"; }
rl_mail_send() {
    printf 'to=%s\nsubject=%s\nbody=%s\nretries=%s\n' "$1" "$2" "$3" "${4:-}" >> "$REPORT_MAIL_LOG"
    return 0
}
if send_user_report_email alice "$personal_report" >/dev/null 2>&1 && \
   grep -q 'to=alice@example.com' "$REPORT_MAIL_LOG" && \
   grep -q '个人使用报告' "$REPORT_MAIL_LOG" && \
   grep -q '近期登录次数' "$REPORT_MAIL_LOG" && \
   [[ ! -f "$SENDMAIL_CALL_LOG" ]]; then
    test_pass
else
    test_fail "报告邮件未走统一邮件后端，或仍调用 sendmail"
fi

test_suite_end
