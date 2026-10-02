#!/bin/bash
# test_tui_mainline.sh - TUI 主线与历史入口清理测试

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"

test_suite_start "TUI Mainline"

test_start "run.sh 默认进入 noTUI CLI（经典 user_manager.sh）"
if grep -q 'exec bash user_manager.sh "\$@"' "$PROJECT_ROOT/run.sh"; then
    test_pass
else
    test_fail "run.sh 默认未进入 user_manager.sh 经典 CLI"
fi

test_start "run.sh 支持 --tui 显式进入 TUI 主线"
if grep -Eq '(^|[[:space:]])--tui([|)]|[[:space:]])' "$PROJECT_ROOT/run.sh" &&
    grep -q 'exec bash tui_manager.sh' "$PROJECT_ROOT/run.sh"; then
    test_pass
else
    test_fail "run.sh 未提供 --tui 到 tui_manager.sh 的分流"
fi

test_start "run.sh 在非交互不支持 TUI 的终端不启动经典菜单"
launcher_stdout="$(mktemp)"
launcher_stderr="$(mktemp)"
launcher_rc=0
TERM=dumb timeout 5 bash "$PROJECT_ROOT/run.sh" --tui </dev/null >"$launcher_stdout" 2>"$launcher_stderr" || launcher_rc=$?
launcher_stdout_text="$(<"$launcher_stdout")"
launcher_stderr_text="$(<"$launcher_stderr")"
rm -f -- "$launcher_stdout" "$launcher_stderr"
if ((launcher_rc == 3)) && [[ "$launcher_stderr_text" == *"无法回退到经典 CLI"* ]] &&
    [[ "$launcher_stdout_text$launcher_stderr_text" != *$$'\033'* ]]; then
    test_pass
else
    test_fail "非交互 TUI 回退语义异常: rc=$launcher_rc out=$launcher_stdout_text err=$launcher_stderr_text"
fi

test_start "run.sh 明确消费 --no-tui 和 --cli 兼容别名"
launcher_dir="$(mktemp -d)"
mkdir -p "$launcher_dir/bin"
cat >"$launcher_dir/bin/bash" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" >"$RUN_SH_CAPTURE_FILE"
STUB
chmod 700 "$launcher_dir/bin/bash"
no_tui_capture="$launcher_dir/no-tui.args"
cli_capture="$launcher_dir/cli.args"
RUN_SH_CAPTURE_FILE="$no_tui_capture" PATH="$launcher_dir/bin:$PATH" /bin/bash "$PROJECT_ROOT/run.sh" --no-tui --weekly-report
RUN_SH_CAPTURE_FILE="$cli_capture" PATH="$launcher_dir/bin:$PATH" /bin/bash "$PROJECT_ROOT/run.sh" --cli --account-health-check
no_tui_args="$(<"$no_tui_capture")"
cli_args="$(<"$cli_capture")"
rm -rf -- "$launcher_dir"
if [[ "$no_tui_args" == $'user_manager.sh\n--weekly-report' ]] &&
    [[ "$cli_args" == $'user_manager.sh\n--account-health-check' ]]; then
    test_pass
else
    test_fail "no-tui/cli 未被 launcher 正确消费: no-tui=$no_tui_args cli=$cli_args"
fi

test_start "tui_manager --check-terminal 对 TERM=dumb 返回稳定诊断和退出码"
terminal_stdout="$(mktemp)"
terminal_stderr="$(mktemp)"
terminal_rc=0
TERM=dumb bash "$PROJECT_ROOT/tui_manager.sh" --check-terminal >"$terminal_stdout" 2>"$terminal_stderr" || terminal_rc=$?
terminal_stdout_text="$(<"$terminal_stdout")"
terminal_stderr_text="$(<"$terminal_stderr")"
rm -f -- "$terminal_stdout" "$terminal_stderr"
if ((terminal_rc == 3)) && [[ "$terminal_stderr_text" == *"tui.terminal=unsupported"* ]] &&
    [[ "$terminal_stderr_text" == *"reason=unsupported-term:dumb"* ]] && [[ -z "$terminal_stdout_text" ]] &&
    [[ "$terminal_stderr_text" != *$$'\033'* ]]; then
    test_pass
else
    test_fail "TERM=dumb 终端诊断异常: rc=$terminal_rc out=$terminal_stdout_text err=$terminal_stderr_text"
fi

test_start "run.sh 支持 --no-tui 兼容进入 noTUI CLI"
if grep -q 'exec bash user_manager.sh' "$PROJECT_ROOT/run.sh"; then
    test_pass
else
    test_fail "run.sh 默认未进入 user_manager.sh CLI"
fi

test_start "run.sh 支持 --cli 作为无 TUI 别名兼容"
if grep -q 'exec bash user_manager.sh' "$PROJECT_ROOT/run.sh"; then
    test_pass
else
    test_fail "run.sh 默认未进入 user_manager.sh CLI"
fi

test_start "user_manager.sh 支持每周报告非交互入口"
weekly_cli_output="$(env USER_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/user_manager.sh"; check_dependencies(){ return 0; }; load_config(){ return 0; }; setup_trap_handler(){ return 0; }; send_all_user_reports(){ printf "send-all-user-reports\n"; }; controller_start(){ printf "controller-start\n"; }; user_manager_handle_cli --weekly-report' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$weekly_cli_output" == "send-all-user-reports" ]]; then
    test_pass
else
    test_fail "--weekly-report 未分发到 send_all_user_reports，输出为: $weekly_cli_output"
fi

test_start "user_manager.sh 支持账户健康检查非交互入口"
health_cli_output="$(env USER_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/user_manager.sh"; check_dependencies(){ return 0; }; load_config(){ return 0; }; setup_trap_handler(){ return 0; }; check_expired_suspensions(){ printf "check-expired-suspensions\n"; }; controller_start(){ printf "controller-start\n"; }; user_manager_handle_cli --account-health-check' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$health_cli_output" == "check-expired-suspensions" ]]; then
    test_pass
else
    test_fail "--account-health-check 未分发到 check_expired_suspensions，输出为: $health_cli_output"
fi

test_start "user_manager.sh 非交互入口执行初始化并传播业务退出码"
cli_init_output="$(env USER_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/user_manager.sh"; check_dependencies(){ printf "deps\n"; return 0; }; load_config(){ printf "load\n"; return 0; }; setup_trap_handler(){ printf "trap\n"; return 0; }; send_all_user_reports(){ printf "send\n"; return 7; }; controller_start(){ printf "controller-start\n"; }; user_manager_handle_cli --weekly-report; printf "rc=%s\n" "$?"' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$cli_init_output" == $'deps\nload\ntrap\nsend\nrc=7' ]]; then
    test_pass
else
    test_fail "非交互入口未按 deps/load/trap/send 顺序执行或未传播退出码，输出为: $cli_init_output"
fi

test_start "send_all_user_reports: 任一用户失败时返回非零"
report_fail_rc="$(env USER_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/user_manager.sh"; get_managed_usernames(){ printf "alice\n"; }; generate_user_personal_report(){ return 1; }; msg_err(){ return 0; }; msg_warn(){ return 0; }; msg_info(){ return 0; }; send_all_user_reports >/dev/null 2>&1; printf "%s" "$?"' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$report_fail_rc" == "1" ]]; then
    test_pass
else
    test_fail "send_all_user_reports 在报告生成失败时应返回 1，实际: $report_fail_rc"
fi

test_start "common.sh 及所有 lib 文件不再使用蓝/青/黄色"
rl_color_violations=$(grep -rn '\bC_BLUE\b\|\bC_CYAN\b\|\bC_YELLOW\b\|\bC_MAGENTA\b\|\bC_BBLUE\b\|\bC_BCYAN\b\|\bC_BYELLOW\b\|\bC_BMAGENTA\b' "$PROJECT_ROOT/lib/" --include='*.sh' 2>/dev/null || true)
if [[ -z "$rl_color_violations" ]]; then
    test_pass
else
    test_fail "仍有文件使用蓝/青/黄色: $rl_color_violations"
fi

test_start "rl_read_menu_key 函数存在且支持 0/q 立即返回"
if source "$PROJECT_ROOT/lib/common.sh" 2>/dev/null && declare -F rl_read_menu_key &>/dev/null; then
    rl_key="$(echo -n 0 | rl_read_menu_key)"
    if [[ "$rl_key" == "0" ]]; then
        test_pass
    else
        test_fail "rl_read_menu_key 未正确读取 '0' 键，得到: $rl_key"
    fi
else
    test_fail "rl_read_menu_key 函数不存在"
fi

test_start "rl_read_menu_key 支持多位数字无需回车"
if source "$PROJECT_ROOT/lib/common.sh" 2>/dev/null && declare -F rl_read_menu_key &>/dev/null; then
    rl_key="$(printf '10' | RL_MENU_DIGIT_TIMEOUT=0.01 rl_read_menu_key 21)"
    if [[ "$rl_key" == "10" ]]; then
        test_pass
    else
        test_fail "rl_read_menu_key 未正确读取多位数字，得到: $rl_key"
    fi
else
    test_fail "rl_read_menu_key 函数不存在"
fi

test_start "rl_read_menu_key 根据菜单编号范围决定是否等待下一位"
if source "$PROJECT_ROOT/lib/common.sh" 2>/dev/null && declare -F rl_read_menu_key &>/dev/null; then
    rl_single="$(printf '10' | RL_MENU_DIGIT_TIMEOUT=0.01 rl_read_menu_key 9)"
    rl_high_single="$(printf '90' | RL_MENU_DIGIT_TIMEOUT=0.01 rl_read_menu_key 21)"
    rl_twenty_one="$(printf '21' | RL_MENU_DIGIT_TIMEOUT=0.01 rl_read_menu_key 21)"
    if [[ "$rl_single" == "1" && "$rl_high_single" == "9" && "$rl_twenty_one" == "21" ]]; then
        test_pass
    else
        test_fail "菜单范围感知读取异常，max9=$rl_single max21-prefix9=$rl_high_single max21-prefix2=$rl_twenty_one"
    fi
else
    test_fail "rl_read_menu_key 函数不存在"
fi

test_start "TUI 主循环中断 trap 不输出 return 噪声"
if grep -q "trap 'tui_handle_interrupt' INT TERM" "$PROJECT_ROOT/lib/tui_core.sh" &&
    ! grep -q "trap 'tui_cleanup; return 0' INT TERM EXIT" "$PROJECT_ROOT/lib/tui_core.sh"; then
    test_pass
else
    test_fail "tui_run 仍使用 return 型 trap，可能在中断/退出时产生 shell 噪声"
fi

test_start "tui_manager.sh 可在测试模式下被 source 且不自动执行 main"
if env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; declare -F tui_run_classic_menu >/dev/null && declare -F tui_run_user_management_menu >/dev/null && declare -F handle_tui_user_menu_key >/dev/null && declare -F draw_tui_user_menu >/dev/null && declare -F tui_run_disk_quota_menu >/dev/null && declare -F handle_tui_disk_quota_menu_key >/dev/null && declare -F draw_tui_disk_quota_menu >/dev/null && declare -F tui_run_network_security_menu >/dev/null && declare -F handle_tui_network_security_menu_key >/dev/null && declare -F draw_tui_network_security_menu >/dev/null && declare -F tui_run_firewall_menu_native >/dev/null && declare -F handle_tui_firewall_menu_key >/dev/null && declare -F draw_tui_firewall_menu >/dev/null && declare -F tui_run_dns_menu_native >/dev/null && declare -F handle_tui_dns_menu_key >/dev/null && declare -F draw_tui_dns_menu >/dev/null && declare -F tui_run_symlink_menu_native >/dev/null && declare -F handle_tui_symlink_menu_key >/dev/null && declare -F draw_tui_symlink_menu >/dev/null && declare -F tui_run_ssh_fail2ban_menu_native >/dev/null && declare -F handle_tui_ssh_fail2ban_menu_key >/dev/null && declare -F draw_tui_ssh_fail2ban_menu >/dev/null && declare -F tui_run_backup_menu_native >/dev/null && declare -F handle_tui_backup_menu_key >/dev/null && declare -F draw_tui_backup_menu >/dev/null && declare -F tui_run_backup_advanced_menu_native >/dev/null && declare -F handle_tui_backup_advanced_menu_key >/dev/null && declare -F draw_tui_backup_advanced_menu >/dev/null && declare -F tui_run_report_stats_menu_native >/dev/null && declare -F handle_tui_report_stats_menu_key >/dev/null && declare -F draw_tui_report_stats_menu >/dev/null && declare -F tui_run_job_stats_menu_native >/dev/null && declare -F handle_tui_job_stats_menu_key >/dev/null && declare -F draw_tui_job_stats_menu >/dev/null && declare -F tui_run_password_rotation_menu_native >/dev/null && declare -F handle_tui_password_rotation_menu_key >/dev/null && declare -F draw_tui_password_rotation_menu >/dev/null && declare -F tui_run_report_menu_native >/dev/null && declare -F handle_tui_report_menu_key >/dev/null && declare -F draw_tui_report_menu >/dev/null && declare -F tui_run_system_menu_native >/dev/null && declare -F handle_tui_system_menu_key >/dev/null && declare -F draw_tui_system_menu >/dev/null && declare -F tui_run_systemd_timer_menu_native >/dev/null && declare -F handle_tui_systemd_timer_menu_key >/dev/null && declare -F draw_tui_systemd_timer_menu >/dev/null && declare -F tui_run_system_details_menu_native >/dev/null && declare -F handle_tui_system_details_menu_key >/dev/null && declare -F draw_tui_system_details_menu >/dev/null && declare -F tui_run_audit_menu_native >/dev/null && declare -F handle_tui_audit_menu_key >/dev/null && declare -F draw_tui_audit_menu >/dev/null && declare -F tui_run_audit_advanced_menu_native >/dev/null && declare -F handle_tui_audit_advanced_menu_key >/dev/null && declare -F draw_tui_audit_advanced_menu >/dev/null' _ "$PROJECT_ROOT" >/dev/null 2>&1; then
    test_pass
else
    test_fail "tui_manager.sh 不能在测试模式下安全 source，或缺少 TUI 原生菜单函数"
fi

test_start "TUI 可委托到经典菜单并正确清理/恢复终端状态"
delegate_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_cleanup() { printf "cleanup\\n"; }; tui_init() { printf "init\\n"; }; demo_menu() { printf "menu\\n"; }; tui_run_classic_menu demo_menu' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$delegate_output" == $'cleanup\nmenu\ninit' ]]; then
    test_pass
else
    test_fail "TUI 未按预期委托到经典菜单，输出为: $delegate_output"
fi

test_start "提示序列动作使用 TUI 原生输入而不是 read_input"
prompt_sequence_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; idx=0; vals=(alice tcp); tui_prompt_input(){ REPLY_INPUT="${vals[$idx]}"; ((idx++)); return 0; }; read_input(){ printf "read_input_called\\n"; REPLY_INPUT="legacy"; }; tui_cleanup(){ printf "cleanup\\n"; }; tui_init(){ printf "init\\n"; }; demo_action(){ printf "%s|%s\\n" "$1" "$2"; }; tui_run_prompt_sequence_action demo_action "用户名" "协议"' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$prompt_sequence_output" == $'cleanup\nalice|tcp\ninit' ]]; then
    test_pass
else
    test_fail "提示序列仍未走原生 TUI 输入，输出为: $prompt_sequence_output"
fi

test_start "用户名提示动作使用 TUI 原生输入并验证存在"
prompt_user_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_prompt_input(){ REPLY_INPUT="tester"; return 0; }; read_input(){ printf "read_input_called\\n"; REPLY_INPUT="legacy"; }; validate_username(){ return 0; }; id(){ return 0; }; tui_cleanup(){ printf "cleanup\\n"; }; tui_init(){ printf "init\\n"; }; show_user(){ printf "%s\\n" "$1"; }; tui_run_prompted_username_action "请输入用户名" show_user' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$prompt_user_output" == $'cleanup\ntester\ninit' ]]; then
    test_pass
else
    test_fail "用户名提示仍未走原生 TUI 输入，输出为: $prompt_user_output"
fi

test_start "主菜单用户管理入口进入原生 TUI 用户菜单"
native_menu_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key() { if [[ "${2:-}" == "state" ]]; then TUI_MENU_RESULT=0; else echo 0; fi; }; tui_run_user_management_menu() { echo native-user-menu; }; tui_run_classic_menu() { echo classic:$1; }; handle_main_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$native_menu_output" == *"native-user-menu"* ]] && [[ "$native_menu_output" != *"classic:user_management_menu"* ]]; then
    test_pass
else
    test_fail "主菜单仍未切到原生 TUI 用户菜单，输出为: $native_menu_output"
fi

test_start "原生 TUI 用户菜单中的旧工作流动作仍正确 cleanup/init"
user_action_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key() { if [[ "${2:-}" == "state" ]]; then TUI_MENU_RESULT=1; else echo 1; fi; }; tui_cleanup() { printf "cleanup\\n"; }; tui_init() { printf "init\\n"; }; change_user_password() { printf "workflow\\n"; }; handle_tui_user_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$user_action_output" == $'cleanup\nworkflow\ninit' ]]; then
    test_pass
else
    test_fail "原生 TUI 用户菜单中的工作流动作未正确执行，输出为: $user_action_output"
fi

test_start "查看托管用户使用原生 TUI 视图而不退出终端"
native_user_list_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key() { if [[ "${2:-}" == "state" ]]; then TUI_MENU_RESULT=7; else echo 7; fi; }; tui_cleanup() { printf "cleanup\\n"; }; tui_init() { printf "init\\n"; }; tui_show_managed_users_view() { printf "native-user-list\\n"; }; handle_tui_user_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$native_user_list_output" == *"native-user-list"* ]] && [[ "$native_user_list_output" != *"cleanup"* ]] && [[ "$native_user_list_output" != *"init"* ]]; then
    test_pass
else
    test_fail "查看托管用户仍未使用原生 TUI 视图，输出为: $native_user_list_output"
fi

test_start "主菜单磁盘与配额入口进入原生 TUI 磁盘菜单"
native_disk_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key() { if [[ "${2:-}" == "state" ]]; then TUI_MENU_RESULT=1; else echo 1; fi; }; tui_run_disk_quota_menu() { echo native-disk-menu; }; tui_run_classic_menu() { echo classic:$1; }; handle_main_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$native_disk_output" == *"native-disk-menu"* ]] && [[ "$native_disk_output" != *"classic:disk_quota_menu"* ]]; then
    test_pass
else
    test_fail "主菜单仍未切到原生 TUI 磁盘菜单，输出为: $native_disk_output"
fi

test_start "原生 TUI 磁盘菜单执行概览动作时正确 cleanup/init"
disk_action_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key() { if [[ "${2:-}" == "state" ]]; then TUI_MENU_RESULT=0; else echo 0; fi; }; tui_cleanup() { printf "cleanup\\n"; }; tui_init() { printf "init\\n"; }; show_disk_overview() { printf "disk-overview\\n"; }; handle_tui_disk_quota_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$disk_action_output" == $'cleanup\ndisk-overview\ninit' ]]; then
    test_pass
else
    test_fail "原生 TUI 磁盘菜单未正确执行概览动作，输出为: $disk_action_output"
fi

test_start "主菜单网络与安全入口进入原生 TUI 网络菜单"
native_network_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key() { if [[ "${2:-}" == "state" ]]; then TUI_MENU_RESULT=2; else echo 2; fi; }; tui_run_network_security_menu() { echo native-network-menu; }; tui_run_classic_menu() { echo classic:$1; }; handle_main_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$native_network_output" == *"native-network-menu"* ]] && [[ "$native_network_output" != *"classic:network_security_menu"* ]]; then
    test_pass
else
    test_fail "主菜单仍未切到原生 TUI 网络菜单，输出为: $native_network_output"
fi

test_start "原生 TUI 网络菜单执行诊断动作时正确 cleanup/init"
network_action_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key() { if [[ "${2:-}" == "state" ]]; then TUI_MENU_RESULT=4; else echo 4; fi; }; tui_cleanup() { printf "cleanup\\n"; }; tui_init() { printf "init\\n"; }; show_network_stack_panel() { printf "network-panel\\n"; }; handle_tui_network_security_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$network_action_output" == $'cleanup\nnetwork-panel\ninit' ]]; then
    test_pass
else
    test_fail "原生 TUI 网络菜单未正确执行诊断动作，输出为: $network_action_output"
fi

test_start "网络菜单防火墙入口进入原生 TUI 防火墙菜单"
native_firewall_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key() { if [[ "${2:-}" == "state" ]]; then TUI_MENU_RESULT=0; else echo 0; fi; }; tui_run_firewall_menu_native() { echo native-firewall-menu; }; tui_run_classic_menu() { echo classic:$1; }; handle_tui_network_security_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$native_firewall_output" == *"native-firewall-menu"* ]] && [[ "$native_firewall_output" != *"classic:firewall_menu"* ]]; then
    test_pass
else
    test_fail "网络菜单仍未切到原生 TUI 防火墙菜单，输出为: $native_firewall_output"
fi

test_start "网络菜单 DNS 入口进入原生 TUI DNS 菜单"
native_dns_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key() { if [[ "${2:-}" == "state" ]]; then TUI_MENU_RESULT=1; else echo 1; fi; }; tui_run_dns_menu_native() { echo native-dns-menu; }; tui_run_classic_menu() { echo classic:$1; }; handle_tui_network_security_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$native_dns_output" == *"native-dns-menu"* ]] && [[ "$native_dns_output" != *"classic:dns_menu"* ]]; then
    test_pass
else
    test_fail "网络菜单仍未切到原生 TUI DNS 菜单，输出为: $native_dns_output"
fi

test_start "网络菜单符号链接入口进入原生 TUI 符号链接菜单"
native_symlink_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key() { if [[ "${2:-}" == "state" ]]; then TUI_MENU_RESULT=2; else echo 2; fi; }; tui_run_symlink_menu_native() { echo native-symlink-menu; }; tui_run_classic_menu() { echo classic:$1; }; handle_tui_network_security_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$native_symlink_output" == *"native-symlink-menu"* ]] && [[ "$native_symlink_output" != *"classic:symlink_menu"* ]]; then
    test_pass
else
    test_fail "网络菜单仍未切到原生 TUI 符号链接菜单，输出为: $native_symlink_output"
fi

test_start "网络菜单 SSH/Fail2ban 入口进入原生 TUI SSH 菜单"
native_ssh_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key() { if [[ "${2:-}" == "state" ]]; then TUI_MENU_RESULT=3; else echo 3; fi; }; tui_run_ssh_fail2ban_menu_native() { echo native-ssh-menu; }; tui_run_classic_menu() { echo classic:$1; }; handle_tui_network_security_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$native_ssh_output" == *"native-ssh-menu"* ]] && [[ "$native_ssh_output" != *"classic:ssh_fail2ban_menu"* ]]; then
    test_pass
else
    test_fail "网络菜单仍未切到原生 TUI SSH/Fail2ban 菜单，输出为: $native_ssh_output"
fi

test_start "原生 TUI 防火墙菜单执行列表动作时正确 cleanup/init"
firewall_action_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key() { if [[ "${2:-}" == "state" ]]; then TUI_MENU_RESULT=2; else echo 2; fi; }; tui_cleanup() { printf "cleanup\\n"; }; tui_init() { printf "init\\n"; }; list_firewall_rules() { printf "firewall-list\\n"; }; handle_tui_firewall_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$firewall_action_output" == $'cleanup\nfirewall-list\ninit' ]]; then
    test_pass
else
    test_fail "原生 TUI 防火墙菜单未正确执行列表动作，输出为: $firewall_action_output"
fi

test_start "原生 TUI DNS 菜单执行白名单动作时正确 cleanup/init"
dns_action_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key() { if [[ "${2:-}" == "state" ]]; then TUI_MENU_RESULT=0; else echo 0; fi; }; tui_cleanup() { printf "cleanup\\n"; }; tui_init() { printf "init\\n"; }; show_dns_whitelist() { printf "dns-whitelist\\n"; }; handle_tui_dns_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$dns_action_output" == $'cleanup\ndns-whitelist\ninit' ]]; then
    test_pass
else
    test_fail "原生 TUI DNS 菜单未正确执行白名单动作，输出为: $dns_action_output"
fi

test_start "主菜单备份入口进入原生 TUI 备份菜单"
native_backup_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key() { if [[ "${2:-}" == "state" ]]; then TUI_MENU_RESULT=3; else echo 3; fi; }; tui_run_backup_menu_native() { echo native-backup-menu; }; tui_run_classic_menu() { echo classic:$1; }; handle_main_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$native_backup_output" == *"native-backup-menu"* ]] && [[ "$native_backup_output" != *"classic:backup_menu"* ]]; then
    test_pass
else
    test_fail "主菜单仍未切到原生 TUI 备份菜单，输出为: $native_backup_output"
fi

test_start "原生 TUI 备份菜单执行列表动作时正确 cleanup/init"
backup_action_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key() { if [[ "${2:-}" == "state" ]]; then TUI_MENU_RESULT=3; else echo 3; fi; }; tui_cleanup() { printf "cleanup\\n"; }; tui_init() { printf "init\\n"; }; list_backup_users() { printf "backup-list\\n"; }; handle_tui_backup_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$backup_action_output" == $'cleanup\nbackup-list\ninit' ]]; then
    test_pass
else
    test_fail "原生 TUI 备份菜单未正确执行列表动作，输出为: $backup_action_output"
fi

test_start "备份菜单更多选项入口进入原生 TUI 详细备份菜单"
native_backup_advanced_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key() { if [[ "${2:-}" == "state" ]]; then TUI_MENU_RESULT=4; else echo 4; fi; }; tui_run_backup_advanced_menu_native() { echo native-backup-advanced-menu; }; tui_run_classic_menu() { echo classic:$1; }; handle_tui_backup_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$native_backup_advanced_output" == *"native-backup-advanced-menu"* ]] && [[ "$native_backup_advanced_output" != *"classic:backup_menu"* ]]; then
    test_pass
else
    test_fail "备份菜单仍未切到原生 TUI 详细备份菜单，输出为: $native_backup_advanced_output"
fi

test_start "原生 TUI 详细备份菜单执行计划列表动作时正确 cleanup/init"
backup_advanced_action_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key() { if [[ "${2:-}" == "state" ]]; then TUI_MENU_RESULT=2; else echo 2; fi; }; tui_cleanup() { printf "cleanup\\n"; }; tui_init() { printf "init\\n"; }; show_backup_schedules() { printf "backup-schedules\\n"; }; handle_tui_backup_advanced_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$backup_advanced_action_output" == $'cleanup\nbackup-schedules\ninit' ]]; then
    test_pass
else
    test_fail "原生 TUI 详细备份菜单未正确执行动作，输出为: $backup_advanced_action_output"
fi

test_start "主菜单报告入口进入原生 TUI 报告菜单"
native_report_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key() { if [[ "${2:-}" == "state" ]]; then TUI_MENU_RESULT=4; else echo 4; fi; }; tui_run_report_stats_menu_native() { echo native-report-menu; }; tui_run_classic_menu() { echo classic:$1; }; handle_main_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$native_report_output" == *"native-report-menu"* ]] && [[ "$native_report_output" != *"classic:report_stats_menu"* ]]; then
    test_pass
else
    test_fail "主菜单仍未切到原生 TUI 报告菜单，输出为: $native_report_output"
fi

test_start "原生 TUI 报告菜单执行生成报告动作时正确 cleanup/init"
report_action_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key() { if [[ "${2:-}" == "state" ]]; then TUI_MENU_RESULT=0; else echo 0; fi; }; tui_cleanup() { printf "cleanup\\n"; }; tui_init() { printf "init\\n"; }; generate_html_report() { printf "report-generate\\n"; }; handle_tui_report_stats_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$report_action_output" == $'cleanup\nreport-generate\ninit' ]]; then
    test_pass
else
    test_fail "原生 TUI 报告菜单未正确执行生成动作，输出为: $report_action_output"
fi

test_start "报告菜单作业统计入口进入原生 TUI 作业统计菜单"
native_job_stats_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key() { if [[ "${2:-}" == "state" ]]; then TUI_MENU_RESULT=2; else echo 2; fi; }; tui_run_job_stats_menu_native() { echo native-job-stats-menu; }; tui_run_classic_menu() { echo classic:$1; }; handle_tui_report_stats_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$native_job_stats_output" == *"native-job-stats-menu"* ]] && [[ "$native_job_stats_output" != *"classic:job_stats_menu"* ]]; then
    test_pass
else
    test_fail "报告菜单仍未切到原生 TUI 作业统计菜单，输出为: $native_job_stats_output"
fi

test_start "报告菜单密码轮换入口进入原生 TUI 密码轮换菜单"
native_rotation_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key() { if [[ "${2:-}" == "state" ]]; then TUI_MENU_RESULT=3; else echo 3; fi; }; tui_run_password_rotation_menu_native() { echo native-rotation-menu; }; tui_run_classic_menu() { echo classic:$1; }; handle_tui_report_stats_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$native_rotation_output" == *"native-rotation-menu"* ]] && [[ "$native_rotation_output" != *"classic:password_rotation_menu"* ]]; then
    test_pass
else
    test_fail "报告菜单仍未切到原生 TUI 密码轮换菜单，输出为: $native_rotation_output"
fi

test_start "报告菜单更多报告入口进入原生 TUI 详细报告菜单"
native_report_detail_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key() { if [[ "${2:-}" == "state" ]]; then TUI_MENU_RESULT=4; else echo 4; fi; }; tui_run_report_menu_native() { echo native-report-detail-menu; }; tui_run_classic_menu() { echo classic:$1; }; handle_tui_report_stats_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$native_report_detail_output" == *"native-report-detail-menu"* ]] && [[ "$native_report_detail_output" != *"classic:report_menu"* ]]; then
    test_pass
else
    test_fail "报告菜单仍未切到原生 TUI 详细报告菜单，输出为: $native_report_detail_output"
fi

test_start "原生 TUI 作业统计菜单执行收集动作时正确 cleanup/init"
job_stats_action_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key() { if [[ "${2:-}" == "state" ]]; then TUI_MENU_RESULT=0; else echo 0; fi; }; tui_cleanup() { printf "cleanup\\n"; }; tui_init() { printf "init\\n"; }; collect_all_job_stats() { printf "job-stats\\n"; }; handle_tui_job_stats_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$job_stats_action_output" == $'cleanup\njob-stats\ninit' ]]; then
    test_pass
else
    test_fail "原生 TUI 作业统计菜单未正确执行动作，输出为: $job_stats_action_output"
fi

test_start "原生 TUI 密码轮换菜单执行状态动作时正确 cleanup/init"
rotation_action_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key() { if [[ "${2:-}" == "state" ]]; then TUI_MENU_RESULT=0; else echo 0; fi; }; tui_cleanup() { printf "cleanup\\n"; }; tui_init() { printf "init\\n"; }; show_password_rotation_status() { printf "rotation-status\\n"; }; handle_tui_password_rotation_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$rotation_action_output" == $'cleanup\nrotation-status\ninit' ]]; then
    test_pass
else
    test_fail "原生 TUI 密码轮换菜单未正确执行动作，输出为: $rotation_action_output"
fi

test_start "原生 TUI 详细报告菜单执行配额报告动作时正确 cleanup/init"
report_detail_action_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key() { if [[ "${2:-}" == "state" ]]; then TUI_MENU_RESULT=2; else echo 2; fi; }; tui_cleanup() { printf "cleanup\\n"; }; tui_init() { printf "init\\n"; }; generate_quota_report() { printf "quota-report\\n"; }; handle_tui_report_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$report_detail_action_output" == $'cleanup\nquota-report\ninit' ]]; then
    test_pass
else
    test_fail "原生 TUI 详细报告菜单未正确执行动作，输出为: $report_detail_action_output"
fi

test_start "主菜单系统维护入口进入原生 TUI 系统菜单"
native_system_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key() { if [[ "${2:-}" == "state" ]]; then TUI_MENU_RESULT=5; else echo 5; fi; }; tui_run_system_menu_native() { echo native-system-menu; }; tui_run_classic_menu() { echo classic:$1; }; handle_main_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$native_system_output" == *"native-system-menu"* ]] && [[ "$native_system_output" != *"classic:system_menu"* ]]; then
    test_pass
else
    test_fail "主菜单仍未切到原生 TUI 系统菜单，输出为: $native_system_output"
fi

test_start "原生 TUI 系统菜单执行系统信息动作时正确 cleanup/init"
system_action_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key() { if [[ "${2:-}" == "state" ]]; then TUI_MENU_RESULT=0; else echo 0; fi; }; tui_cleanup() { printf "cleanup\\n"; }; tui_init() { printf "init\\n"; }; show_system_info() { printf "system-info\\n"; }; handle_tui_system_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$system_action_output" == $'cleanup\nsystem-info\ninit' ]]; then
    test_pass
else
    test_fail "原生 TUI 系统菜单未正确执行系统信息动作，输出为: $system_action_output"
fi

test_start "系统菜单 Systemd Timers 入口进入原生 TUI Timers 菜单"
native_timer_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key() { if [[ "${2:-}" == "state" ]]; then TUI_MENU_RESULT=6; else echo 6; fi; }; tui_run_systemd_timer_menu_native() { echo native-timer-menu; }; tui_run_classic_menu() { echo classic:$1; }; handle_tui_system_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$native_timer_output" == *"native-timer-menu"* ]] && [[ "$native_timer_output" != *"classic:systemd_timer_menu"* ]]; then
    test_pass
else
    test_fail "系统菜单仍未切到原生 TUI Timers 菜单，输出为: $native_timer_output"
fi

test_start "系统菜单更多系统选项入口进入原生 TUI 详细系统菜单"
native_system_detail_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key() { if [[ "${2:-}" == "state" ]]; then TUI_MENU_RESULT=7; else echo 7; fi; }; tui_run_system_details_menu_native() { echo native-system-detail-menu; }; tui_run_classic_menu() { echo classic:$1; }; handle_tui_system_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$native_system_detail_output" == *"native-system-detail-menu"* ]] && [[ "$native_system_detail_output" != *"classic:system_menu"* ]]; then
    test_pass
else
    test_fail "系统菜单仍未切到原生 TUI 详细系统菜单，输出为: $native_system_detail_output"
fi

test_start "系统菜单 VM/GPU 入口进入原生 TUI 计算资源菜单"
native_compute_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key() { if [[ "${2:-}" == "state" ]]; then TUI_MENU_RESULT=8; else echo 8; fi; }; tui_run_compute_menu_native() { echo native-compute-menu; }; tui_run_classic_menu() { echo classic:$1; }; handle_tui_system_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$native_compute_output" == *"native-compute-menu"* ]]; then
    test_pass
else
    test_fail "系统菜单未接入 VM/GPU 原生菜单，输出为: $native_compute_output"
fi

test_start "VM/GPU 菜单执行 GPU 状态动作时正确 cleanup/init"
compute_action_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key() { if [[ "${2:-}" == "state" ]]; then TUI_MENU_RESULT=2; else echo 2; fi; }; tui_cleanup() { printf "cleanup\\n"; }; tui_init() { printf "init\\n"; }; show_gpu_status() { printf "gpu-status\\n"; }; handle_tui_compute_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$compute_action_output" == $'cleanup\ngpu-status\ninit' ]]; then
    test_pass
else
    test_fail "VM/GPU 菜单未正确执行 GPU 状态动作，输出为: $compute_action_output"
fi

test_start "原生 TUI Timers 菜单经 action registry 执行列出动作"
timer_action_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key() { if [[ "${2:-}" == "state" ]]; then TUI_MENU_RESULT=0; else echo 0; fi; }; tui_cleanup() { printf "cleanup\\n"; }; tui_init() { printf "init\\n"; }; action_run() { printf "action:%s:%s\\n" "$1" "$2"; }; handle_tui_systemd_timer_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$timer_action_output" == $'cleanup\naction:system.timers.list:tui\ninit' ]]; then
    test_pass
else
    test_fail "原生 TUI Timers 菜单未正确执行动作，输出为: $timer_action_output"
fi

test_start "原生 TUI 详细系统菜单执行 CPU 信息动作时正确 cleanup/init"
system_detail_action_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key() { if [[ "${2:-}" == "state" ]]; then TUI_MENU_RESULT=0; else echo 0; fi; }; tui_cleanup() { printf "cleanup\\n"; }; tui_init() { printf "init\\n"; }; show_cpu_info() { printf "cpu-info\\n"; }; handle_tui_system_details_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$system_detail_action_output" == $'cleanup\ncpu-info\ninit' ]]; then
    test_pass
else
    test_fail "原生 TUI 详细系统菜单未正确执行动作，输出为: $system_detail_action_output"
fi

test_start "主菜单审计入口进入原生 TUI 审计菜单"
native_audit_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key() { if [[ "${2:-}" == "state" ]]; then TUI_MENU_RESULT=6; else echo 6; fi; }; tui_run_audit_menu_native() { echo native-audit-menu; }; tui_run_classic_menu() { echo classic:$1; }; handle_main_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$native_audit_output" == *"native-audit-menu"* ]] && [[ "$native_audit_output" != *"classic:audit_menu"* ]]; then
    test_pass
else
    test_fail "主菜单仍未切到原生 TUI 审计菜单，输出为: $native_audit_output"
fi

test_start "原生 TUI 审计菜单执行查看日志动作时正确 cleanup/init"
audit_action_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key() { if [[ "${2:-}" == "state" ]]; then TUI_MENU_RESULT=0; else echo 0; fi; }; tui_cleanup() { printf "cleanup\\n"; }; tui_init() { printf "init\\n"; }; view_audit_log() { printf "audit-log\\n"; }; handle_tui_audit_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$audit_action_output" == $'cleanup\naudit-log\ninit' ]]; then
    test_pass
else
    test_fail "原生 TUI 审计菜单未正确执行查看日志动作，输出为: $audit_action_output"
fi

test_start "审计菜单更多选项入口进入原生 TUI 详细审计菜单"
native_audit_detail_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key() { if [[ "${2:-}" == "state" ]]; then TUI_MENU_RESULT=3; else echo 3; fi; }; tui_run_audit_advanced_menu_native() { echo native-audit-detail-menu; }; tui_run_classic_menu() { echo classic:$1; }; handle_tui_audit_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$native_audit_detail_output" == *"native-audit-detail-menu"* ]] && [[ "$native_audit_detail_output" != *"classic:audit_menu"* ]]; then
    test_pass
else
    test_fail "审计菜单仍未切到原生 TUI 详细审计菜单，输出为: $native_audit_detail_output"
fi

test_start "原生 TUI 详细审计菜单执行日志轮转动作时正确 cleanup/init"
audit_detail_action_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key() { if [[ "${2:-}" == "state" ]]; then TUI_MENU_RESULT=2; else echo 2; fi; }; tui_cleanup() { printf "cleanup\\n"; }; tui_init() { printf "init\\n"; }; audit_rotate() { printf "audit-rotate\\n"; }; handle_tui_audit_advanced_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$audit_detail_action_output" == $'cleanup\naudit-rotate\ninit' ]]; then
    test_pass
else
    test_fail "原生 TUI 详细审计菜单未正确执行动作，输出为: $audit_detail_action_output"
fi

test_start "历史安装脚本已移除"
assert_file_not_exists "$PROJECT_ROOT/install.sh" "install.sh 应已删除"

test_start "历史优化入口已移除"
assert_file_not_exists "$PROJECT_ROOT/run_optimized.sh" "run_optimized.sh 应已删除"

test_start "危险修复脚本已移除"
assert_file_not_exists "$PROJECT_ROOT/apply_fixes.sh" "apply_fixes.sh 应已删除"

test_start "v2 兼容入口已移除"
assert_file_not_exists "$PROJECT_ROOT/user_manager_v2.sh" "user_manager_v2.sh 应已删除"

test_start "简化旧 UI 已移除"
assert_file_not_exists "$PROJECT_ROOT/lib/ui_menu_simple.sh" "ui_menu_simple.sh 应已删除"

test_start "source-only 主菜单 handler 在父 shell 持久化 DOWN/HOME/END 菜单状态"
main_handler_state_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; TUI_MENU_ITEMS=(one two three exit); TUI_MENU_INDEX=0; TUI_MENU_SCROLL_OFFSET=0; TUI_MENU_VISIBLE_ITEMS=4; handle_main_menu_key DOWN; down_index="$TUI_MENU_INDEX"; handle_main_menu_key END; end_index="$TUI_MENU_INDEX"; handle_main_menu_key HOME; home_index="$TUI_MENU_INDEX"; printf "%s/%s/%s" "$down_index" "$end_index" "$home_index"' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$main_handler_state_output" == "1/3/0" ]]; then
    test_pass
else
    test_fail "主菜单 handler 未在父 shell 持久化菜单状态，输出为: $main_handler_state_output"
fi

test_start "真实 tui_run 通过确定性 DOWN/q 序列保留状态并退出循环"
tui_run_state_output="$(printf 'DOWN\nq\n' | env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; TUI_RUNNING=true; TUI_REDRAW=false; TUI_MENU_INDEX=0; TUI_MENU_SCROLL_OFFSET=0; TUI_MENU_VISIBLE_ITEMS=3; TUI_MENU_ITEMS=(one two exit); tui_get_size(){ :; }; tui_clear(){ :; }; draw_stub(){ :; }; tui_read_key(){ local key; IFS= read -r key || return 1; printf "%s\n" "$key"; }; handler_stub(){ _tui_handle_menu_key "$1"; local result="${TUI_MENU_RESULT:-}"; if [[ "$result" == "-1" ]]; then TUI_RUNNING=false; fi; }; tui_run draw_stub handler_stub state >/dev/null; printf "%s|%s|%s" "$TUI_MENU_INDEX" "$TUI_RUNNING" "$?"' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$tui_run_state_output" == "1|false|0" ]]; then
    test_pass
else
    test_fail "真实 tui_run 未保留菜单状态或退出循环，输出为: $tui_run_state_output"
fi

test_start "真实数字/ENTER/0/q 经 state bridge 分派主菜单"
main_key_bridge_output="$(env TUI_MANAGER_NO_MAIN=1 TERM= LANG=C LC_ALL=C bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; TUI_MENU_ITEMS=(a b c d e f g h i exit); TUI_MENU_VISIBLE_ITEMS=10; TUI_MENU_INDEX=0; TUI_MENU_SCROLL_OFFSET=0; dispatched=""; record_dispatch(){ [[ -n "$dispatched" ]] && dispatched+=","; dispatched+="$1"; }; tui_run_user_management_menu(){ record_dispatch user; }; tui_run_disk_quota_menu(){ record_dispatch disk; }; handle_main_menu_key 1; TUI_MENU_INDEX=1; handle_main_menu_key ENTER; TUI_RUNNING=true; handle_main_menu_key 0; zero_running="$TUI_RUNNING"; TUI_RUNNING=true; handle_main_menu_key q; printf "%s|zero=%s|quit=%s" "$dispatched" "$zero_running" "$TUI_RUNNING"' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$main_key_bridge_output" == "user,disk|zero=false|quit=false" ]]; then
    test_pass
else
    test_fail "真实数字/ENTER/0/q 未按 state bridge 契约分派，输出为: $main_key_bridge_output"
fi

test_start "manager 不使用命令替换读取 tui_menu_handle_key 结果"
manager_bridge_count="$(grep -Fc 'result=$(tui_menu_handle_key' "$PROJECT_ROOT/tui_manager.sh" 2>/dev/null || true)"
if [[ "$manager_bridge_count" == "0" ]]; then
    test_pass
else
    test_fail "tui_manager.sh 仍有 $manager_bridge_count 处命令替换 bridge"
fi

test_start "用户组菜单使用 state bridge 分发真实动作"
user_group_dispatch_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; state_call_seen=false; dispatched_action=""; tui_menu_handle_key(){ if [[ "${2:-}" == "state" ]]; then state_call_seen=true; TUI_MENU_RESULT=0; else echo 0; fi; }; tui_run_prompt_sequence_action(){ dispatched_action="$1"; }; handle_tui_user_group_menu_key ENTER; printf "%s|%s" "$state_call_seen" "$dispatched_action"' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$user_group_dispatch_output" == "true|add_user_to_group" ]]; then
    test_pass
else
    test_fail "用户组 handler 未使用 state bridge 分发动作，输出为: $user_group_dispatch_output"
fi

test_start "权限菜单使用 state bridge 分发真实动作"
permission_dispatch_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; state_call_seen=false; dispatched_action=""; tui_menu_handle_key(){ if [[ "${2:-}" == "state" ]]; then state_call_seen=true; TUI_MENU_RESULT=0; else echo 0; fi; }; tui_run_prompted_username_action(){ dispatched_action="$2"; }; handle_tui_permission_menu_key ENTER; printf "%s|%s" "$state_call_seen" "$dispatched_action"' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$permission_dispatch_output" == "true|show_user_permissions" ]]; then
    test_pass
else
    test_fail "权限 handler 未使用 state bridge 分发动作，输出为: $permission_dispatch_output"
fi

test_start "SSH/Fail2ban 菜单使用 state bridge 分发真实动作"
ssh_dispatch_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; state_call_seen=false; dispatched_action=""; tui_menu_handle_key(){ if [[ "${2:-}" == "state" ]]; then state_call_seen=true; TUI_MENU_RESULT=0; else echo 0; fi; }; tui_run_workflow_action(){ dispatched_action="$1"; }; handle_tui_ssh_fail2ban_menu_key ENTER; printf "%s|%s" "$state_call_seen" "$dispatched_action"' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$ssh_dispatch_output" == "true|security_baseline_sshd_summary" ]]; then
    test_pass
else
    test_fail "SSH/Fail2ban handler 未使用 state bridge 分发动作，输出为: $ssh_dispatch_output"
fi

test_start "数据菜单同 ID 重绘保留状态，tui_init 后重绘重新加载到 0/0"
data_menu_state_output="$(env TUI_MANAGER_NO_MAIN=1 TERM= LANG=C LC_ALL=C bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; TUI_COLS=120; TUI_LINES=7; tui_get_size(){ TUI_COLS=120; TUI_LINES=7; }; stty(){ :; }; tput(){ :; }; clear(){ :; }; tui_move(){ :; }; tui_fg(){ :; }; tui_bg(){ :; }; tui_reset(){ :; }; tui_reverse(){ :; }; tui_draw_box(){ :; }; tui_statusbar_draw(){ :; }; _tui_draw_modern_header(){ :; }; _tui_draw_modern_statusbar(){ :; }; get_tui_managed_user_count(){ printf "0"; }; _tui_draw_menu report >/dev/null 2>&1; first_ok=false; if [[ "$TUI_ACTIVE_MENU_ID" == "report" ]] && (( ${#TUI_MENU_ITEMS[@]} > 0 )) && (( TUI_MENU_INDEX == 0 && TUI_MENU_SCROLL_OFFSET == 0 )); then first_ok=true; fi; TUI_MENU_INDEX=3; TUI_MENU_SCROLL_OFFSET=3; _tui_draw_menu report >/dev/null 2>&1; same_ok=false; if (( TUI_MENU_INDEX == 3 && TUI_MENU_SCROLL_OFFSET == 3 )); then same_ok=true; fi; tui_init >/dev/null 2>&1; invalidated_ok=false; if [[ -z "$TUI_ACTIVE_MENU_ID" ]] && (( ${#TUI_MENU_ITEMS[@]} == 0 )) && (( TUI_MENU_INDEX == 0 && TUI_MENU_SCROLL_OFFSET == 0 )); then invalidated_ok=true; fi; _tui_draw_menu report >/dev/null 2>&1; reloaded_ok=false; if [[ "$TUI_ACTIVE_MENU_ID" == "report" ]] && (( ${#TUI_MENU_ITEMS[@]} > 0 )) && (( TUI_MENU_INDEX == 0 && TUI_MENU_SCROLL_OFFSET == 0 )); then reloaded_ok=true; fi; printf "%s|%s|%s|%s" "$first_ok" "$same_ok" "$invalidated_ok" "$reloaded_ok"' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$data_menu_state_output" == "true|true|true|true" ]]; then
    test_pass
else
    test_fail "数据菜单生命周期状态不符合契约，输出为: $data_menu_state_output"
fi

test_start "README 不再引用安装脚本"
if ! grep -q 'install.sh' "$PROJECT_ROOT/README.md"; then
    test_pass
else
    test_fail "README 仍引用 install.sh"
fi

test_start "README 不再包含 Installation 章节"
if ! grep -q '^## Installation' "$PROJECT_ROOT/README.md"; then
    test_pass
else
    test_fail "README 仍包含 Installation 章节"
fi

test_start "README 不再提供安装依赖命令"
if ! grep -Eq 'apt-get install|安装依赖|初始化数据目录' "$PROJECT_ROOT/README.md"; then
    test_pass
else
    test_fail "README 仍包含安装使用口径"
fi

test_suite_end
