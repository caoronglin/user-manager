#!/bin/bash
# test_tui_native_forms.sh - TUI 原生表单流程测试

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"

test_suite_start "TUI Native Forms"

test_start "tui_manager 导出原生高频表单函数"
if env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; declare -F tui_run_create_or_assign_user_native >/dev/null && declare -F tui_run_modify_user_quota_native >/dev/null' _ "$PROJECT_ROOT" >/dev/null 2>&1; then
    test_pass
else
    test_fail "缺少原生高频表单函数"
fi

test_start "用户菜单创建入口切到原生表单流程"
entry_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key(){ echo 0; }; tui_run_create_or_assign_user_native(){ echo native-provision; }; tui_run_workflow_action(){ echo legacy:$1; }; handle_tui_user_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$entry_output" == *"native-provision"* ]] && [[ "$entry_output" != *"legacy:create_or_assign_user"* ]]; then
    test_pass
else
    test_fail "创建/更新用户仍未切到原生表单流程，输出为: $entry_output"
fi

test_start "原生创建/更新用户流程执行真实后端时正确 cleanup/init"
provision_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; acquire_lock(){ return 0; }; release_lock(){ printf "unlock\n"; }; tui_prompt_input(){ case "$2" in 用户名) REPLY_INPUT="alice" ;; 手动密码) REPLY_INPUT="Secret123" ;; 磁盘编号) REPLY_INPUT="1" ;; 配额*) REPLY_INPUT="" ;; esac; return 0; }; tui_prompt_select(){ REPLY_INPUT="手动输入密码"; TUI_PROMPT_INDEX=1; return 0; }; tui_confirm(){ return 0; }; validate_username(){ return 0; }; id(){ return 1; }; _resolve_provision_target(){ printf "01|/mnt/data01|/mnt/data01/alice\n"; }; _resolve_provision_quota(){ printf "%s\n" $((500*1024*1024*1024)); }; df(){ printf "Filesystem 1B-blocks Used Available Use%% Mounted on\n/dev/mock 1000 100 900 10%% /mnt/data01\n"; }; bytes_to_human(){ printf "900G\n"; }; create_user(){ printf "create:%s:%s:%s:%s\n" "$1" "$2" "$3" "$4"; }; set_user_quota(){ printf "quota:%s:%s:%s\n" "$1" "$2" "$3"; }; priv_chown(){ :; }; priv_chmod(){ :; }; priv_usermod(){ :; }; _send_password_notification(){ printf "notify:%s:%s\n" "$1" "$3"; }; record_user_event(){ printf "event:%s\n" "$1"; }; format_password_display(){ printf "hidden\n"; }; show_passwords_enabled(){ return 1; }; tui_cleanup(){ printf "cleanup\n"; }; tui_init(){ printf "init\n"; }; tui_run_create_or_assign_user_native' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$provision_output" == *$'cleanup\ncreate:alice:Secret123:/mnt/data01/alice:true\nquota:alice:536870912000:/mnt/data01\nnotify:alice:账户创建\nevent:alice\nunlock\ninit'* ]]; then
    test_pass
else
    test_fail "原生创建/更新用户流程未正确执行，输出为: $provision_output"
fi

test_start "磁盘菜单配额入口切到原生表单流程"
quota_entry_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; tui_menu_handle_key(){ echo 1; }; tui_run_modify_user_quota_native(){ echo native-quota; }; tui_run_workflow_action(){ echo legacy:$1; }; handle_tui_disk_quota_menu_key ENTER' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$quota_entry_output" == *"native-quota"* ]] && [[ "$quota_entry_output" != *"legacy:modify_user_quota"* ]]; then
    test_pass
else
    test_fail "调整用户配额仍未切到原生表单流程，输出为: $quota_entry_output"
fi

test_start "原生配额修改流程执行真实后端时正确 cleanup/init"
quota_output="$(env TUI_MANAGER_NO_MAIN=1 bash -c 'set -uo pipefail; source "$1/tui_manager.sh"; idx=0; prompt_vals=(alice 1T); tui_prompt_input(){ REPLY_INPUT="${prompt_vals[$idx]}"; ((idx++)); return 0; }; validate_username(){ return 0; }; id(){ return 0; }; get_user_home(){ printf "/mnt/data01/alice\n"; }; get_user_mountpoint(){ printf "/mnt/data01\n"; }; get_user_quota_info(){ printf "107374182400:536870912000\n"; }; bytes_to_gb(){ awk "BEGIN {printf \"%.0f\", $1/1073741824}"; }; parse_quota_input(){ printf "%s\n" $((1024*1024*1024*1024)); }; tui_confirm(){ return 0; }; set_user_quota(){ printf "quota:%s:%s:%s\n" "$1" "$2" "$3"; }; record_user_event(){ printf "event:%s\n" "$1"; }; draw_info_card(){ :; }; draw_header(){ :; }; draw_usage_bar(){ :; }; get_usage_color(){ printf ""; }; tui_cleanup(){ printf "cleanup\n"; }; tui_init(){ printf "init\n"; }; tui_run_modify_user_quota_native' _ "$PROJECT_ROOT" 2>/dev/null || true)"
if [[ "$quota_output" == *$'cleanup\nquota:alice:1099511627776:/mnt/data01\nevent:alice\ninit'* ]]; then
    test_pass
else
    test_fail "原生配额修改流程未正确执行，输出为: $quota_output"
fi

test_suite_end
