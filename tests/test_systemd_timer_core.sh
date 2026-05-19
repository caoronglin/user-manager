#!/bin/bash
# test_systemd_timer_core.sh - systemd timer 核心模块测试
# shellcheck disable=SC1091

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"

setup_test_env

export TEST_BIN_DIR="$TEST_TMPDIR/bin"
mkdir -p "$TEST_BIN_DIR"
export PATH="$TEST_BIN_DIR:$PATH"

export SYSTEMD_TIMER_UNIT_DIR="$TEST_TMPDIR/etc/systemd/system"
export SYSTEMD_TIMER_STATE_DIR="$TEST_TMPDIR/var/lib/systemd-timer-core"
mkdir -p "$SYSTEMD_TIMER_UNIT_DIR" "$SYSTEMD_TIMER_STATE_DIR"

cat > "$TEST_BIN_DIR/systemctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_TMPDIR/systemctl.log"
case "$1" in
    list-timers)
        cat <<'OUT'
NEXT                        LEFT LAST                        PASSED UNIT                              ACTIVATES
Mon 2026-04-27 03:00:00 UTC 6d   Mon 2026-04-20 03:00:00 UTC 1h ago weekly-report.timer               weekly-report.service
Mon 2026-04-20 03:10:00 UTC 5m   Mon 2026-04-20 03:00:00 UTC 5m ago account-health-check.timer       account-health-check.service
OUT
        ;;
    status)
        printf 'Active: active (waiting)\nLoaded: loaded (/etc/systemd/system/%s; enabled)\n' "$2"
        ;;
    *)
        ;;
esac
EOF
chmod +x "$TEST_BIN_DIR/systemctl"

cat > "$TEST_BIN_DIR/journalctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_TMPDIR/journalctl.log"
cat <<'OUT'
2026-04-20T03:00:00+00:00 host weekly-report[100]: generated report for all managed users
2026-04-20T03:10:00+00:00 host account-health-check[110]: checked passwd expiry and locked users
OUT
EOF
chmod +x "$TEST_BIN_DIR/journalctl"

test_suite_start "Systemd Timer Core"

test_start "模块可加载并导出核心函数"
if bash -c 'set -uo pipefail; source "$1/lib/common.sh"; run_privileged(){ "$@"; }; source "$1/lib/systemd_timer_core.sh"; declare -F systemd_timer_generate_service_unit >/dev/null && declare -F systemd_timer_generate_timer_unit >/dev/null && declare -F systemd_timer_install_profile >/dev/null && declare -F systemd_timer_list_timers >/dev/null && declare -F systemd_timer_show_logs >/dev/null && declare -F systemd_timer_remove >/dev/null' _ "$PROJECT_ROOT" >/dev/null 2>&1; then
    test_pass
else
    test_fail "systemd_timer_core.sh 缺失或未导出预期函数"
fi

test_start "生成 weekly-report profile 的 service/timer 内容"
unit_render_output="$(bash -c 'set -uo pipefail; source "$1/lib/common.sh"; run_privileged(){ "$@"; }; source "$1/lib/systemd_timer_core.sh"; printf "%s\n" "--SERVICE--"; systemd_timer_render_profile_service weekly-report; printf "%s\n" "--TIMER--"; systemd_timer_render_profile_timer weekly-report' _ "$PROJECT_ROOT")"
if [[ "$unit_render_output" == *"Description=Managed User Weekly Report"* ]] && \
   [[ "$unit_render_output" == *"ExecStart=/bin/bash"* ]] && \
   [[ "$unit_render_output" == *"OnCalendar=weekly"* ]] && \
   [[ "$unit_render_output" == *"Persistent=true"* ]]; then
    test_pass
else
    test_fail "weekly-report unit 内容未包含预期字段"
fi

test_start "生成 account-health-check profile 的 service/timer 内容"
health_render_output="$(bash -c 'set -uo pipefail; source "$1/lib/common.sh"; run_privileged(){ "$@"; }; source "$1/lib/systemd_timer_core.sh"; printf "%s\n" "--SERVICE--"; systemd_timer_render_profile_service account-health-check; printf "%s\n" "--TIMER--"; systemd_timer_render_profile_timer account-health-check' _ "$PROJECT_ROOT")"
if [[ "$health_render_output" == *"Description=Managed User Account Health Check"* ]] && \
   [[ "$health_render_output" == *"OnCalendar=daily"* ]] && \
   [[ "$health_render_output" == *"RandomizedDelaySec=15m"* ]]; then
    test_pass
else
    test_fail "account-health-check unit 内容未包含预期字段"
fi

test_start "profile ExecStart 使用项目内非交互入口而非 PATH 探测"
weekly_service_output="$(bash -c 'set -uo pipefail; source "$1/lib/common.sh"; run_privileged(){ "$@"; }; source "$1/lib/systemd_timer_core.sh"; systemd_timer_render_profile_service weekly-report' _ "$PROJECT_ROOT")"
health_service_output="$(bash -c 'set -uo pipefail; source "$1/lib/common.sh"; run_privileged(){ "$@"; }; source "$1/lib/systemd_timer_core.sh"; systemd_timer_render_profile_service account-health-check' _ "$PROJECT_ROOT")"
if [[ "$weekly_service_output" == *"--weekly-report"* ]] && \
   [[ "$health_service_output" == *"--account-health-check"* ]] && \
   [[ "$weekly_service_output" == *"$PROJECT_ROOT/run.sh"* ]] && \
   [[ "$health_service_output" == *"$PROJECT_ROOT/run.sh"* ]] && \
   [[ "$weekly_service_output" != *"command -v user_manager.sh"* ]] && \
   [[ "$health_service_output" != *"command -v user_manager.sh"* ]]; then
    test_pass
else
    test_fail "profile ExecStart 未使用项目内 run.sh 非交互入口，或仍依赖 command -v user_manager.sh"
fi

test_start "安装 profile 写入 unit 文件并触发 daemon-reload/enable/start"
rm -f "$TEST_TMPDIR/systemctl.log"
if bash -c 'set -uo pipefail; export PATH="$1/bin:$PATH" SYSTEMD_TIMER_UNIT_DIR="$1/etc/systemd/system" SYSTEMD_TIMER_STATE_DIR="$1/var/lib/systemd-timer-core" TEST_TMPDIR="$1"; source "$2/lib/common.sh"; run_privileged(){ "$@"; }; priv_systemctl(){ systemctl "$@"; }; source "$2/lib/systemd_timer_core.sh"; systemd_timer_install_profile weekly-report' _ "$TEST_TMPDIR" "$PROJECT_ROOT" >/dev/null 2>&1; then
    service_file="$SYSTEMD_TIMER_UNIT_DIR/weekly-report.service"
    timer_file="$SYSTEMD_TIMER_UNIT_DIR/weekly-report.timer"
    systemctl_log="$(<"$TEST_TMPDIR/systemctl.log")"
    if [[ -f "$service_file" ]] && [[ -f "$timer_file" ]] && \
       [[ "$systemctl_log" == *"daemon-reload"* ]] && \
       [[ "$systemctl_log" == *"enable weekly-report.timer"* ]] && \
       [[ "$systemctl_log" == *"start weekly-report.timer"* ]]; then
        test_pass
    else
        test_fail "安装后文件或 systemctl 调用不符合预期"
    fi
else
    test_fail "安装 weekly-report profile 失败"
fi

test_start "列出 timer 状态调用 systemctl list-timers"
list_output="$(bash -c 'set -uo pipefail; export PATH="$1/bin:$PATH" TEST_TMPDIR="$1"; source "$2/lib/common.sh"; run_privileged(){ "$@"; }; source "$2/lib/systemd_timer_core.sh"; systemd_timer_list_timers' _ "$TEST_TMPDIR" "$PROJECT_ROOT")"
if [[ "$list_output" == *"weekly-report.timer"* ]] && [[ "$list_output" == *"account-health-check.timer"* ]]; then
    test_pass
else
    test_fail "timer 状态列表输出不正确"
fi

test_start "查看指定 timer 日志调用 journalctl -u 对应 service"
rm -f "$TEST_TMPDIR/journalctl.log"
log_output="$(bash -c 'set -uo pipefail; export PATH="$1/bin:$PATH" TEST_TMPDIR="$1"; source "$2/lib/common.sh"; run_privileged(){ "$@"; }; source "$2/lib/systemd_timer_core.sh"; systemd_timer_show_logs weekly-report 20' _ "$TEST_TMPDIR" "$PROJECT_ROOT")"
journalctl_log="$(<"$TEST_TMPDIR/journalctl.log")"
if [[ "$log_output" == *"generated report for all managed users"* ]] && [[ "$journalctl_log" == *"-u weekly-report.service -n 20"* ]]; then
    test_pass
else
    test_fail "查看日志未读取预期 service 日志"
fi

test_start "删除 timer 停止并禁用 timer 后移除 unit 文件"
rm -f "$TEST_TMPDIR/systemctl.log"
if bash -c 'set -uo pipefail; export PATH="$1/bin:$PATH" SYSTEMD_TIMER_UNIT_DIR="$1/etc/systemd/system" SYSTEMD_TIMER_STATE_DIR="$1/var/lib/systemd-timer-core" TEST_TMPDIR="$1"; source "$2/lib/common.sh"; run_privileged(){ "$@"; }; priv_systemctl(){ systemctl "$@"; }; source "$2/lib/systemd_timer_core.sh"; systemd_timer_remove weekly-report' _ "$TEST_TMPDIR" "$PROJECT_ROOT" >/dev/null 2>&1; then
    systemctl_log="$(<"$TEST_TMPDIR/systemctl.log")"
    if [[ ! -f "$SYSTEMD_TIMER_UNIT_DIR/weekly-report.service" ]] && \
       [[ ! -f "$SYSTEMD_TIMER_UNIT_DIR/weekly-report.timer" ]] && \
       [[ "$systemctl_log" == *"stop weekly-report.timer"* ]] && \
       [[ "$systemctl_log" == *"disable weekly-report.timer"* ]] && \
       [[ "$systemctl_log" == *"daemon-reload"* ]]; then
        test_pass
    else
        test_fail "删除 timer 后状态不符合预期"
    fi
else
    test_fail "删除 weekly-report timer 失败"
fi

cleanup_test_env

test_suite_end
