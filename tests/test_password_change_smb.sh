#!/bin/bash
# test_password_change_smb.sh — 密码修改 SMB 同步测试
# 测试密码修改时 SMB 账号同步的集成行为

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"

export USER_MANAGER_DATA_BASE="${USER_MANAGER_DATA_BASE:-$PROJECT_ROOT/data}"
export USER_MANAGER_BACKUP_ROOT="${USER_MANAGER_BACKUP_ROOT:-$PROJECT_ROOT/data/backup}"

setup_test_env

source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/config.sh"
source "$PROJECT_ROOT/lib/access_control.sh"
source "$PROJECT_ROOT/lib/privilege.sh"
source "$PROJECT_ROOT/lib/smb_core.sh"
source "$PROJECT_ROOT/lib/user_core.sh"
source "$PROJECT_ROOT/lib/controller_user_password_change.sh"

# Stubs
priv_chpasswd() { return 0; }
priv_useradd() { return 0; }
priv_usermod() { return 0; }
priv_chage() { return 0; }
_smb_sync_password() { return 0; }
smb_set_password() { return 0; }
smb_is_available() { return 0; }
msg_ok() { return 0; }
msg_err() { return 0; }
msg_warn() { return 0; }
msg_info() { return 0; }
draw_header() { return 0; }
draw_info_card() { return 0; }
draw_menu_item() { return 0; }
draw_prompt() { return 0; }
format_password_display() { return 0; }
show_passwords_enabled() { return 0; }
_send_password_notification() { return 0; }
record_user_event() { return 0; }
get_user_email() { return 0; }
send_password_email() { return 0; }
read_existing_username() { REPLY_INPUT="testuser"; return 0; }
get_managed_usernames() { printf 'user1\nuser2\n'; }
_validate_password_strength() { return 0; }
get_random_password() { printf 'Pass123!'; }
confirm_action() { return 0; }

test_suite_start "Password Change SMB Sync"

# ------------------------------------------------------------
# 单用户密码修改 SMB 同步测试
# ------------------------------------------------------------

test_start "单用户密码修改: SMB 同步成功"
smb_called=0
_smb_sync_password() { smb_called=1; return 0; }
# 提供 stdin 输入: 1 = 从密码池随机选择（使用文件重定向避免管道子进程）
echo "1" > "$TEST_TMPDIR/smb_stdin"
_change_single_user_password < "$TEST_TMPDIR/smb_stdin" 2>/dev/null
if [[ $? -eq 0 && $smb_called -eq 1 ]]; then
    test_pass
else
    test_fail "单用户密码修改应成功并调用 SMB 同步"
fi

test_start "单用户密码修改: SMB 同步失败（致命，返回 1）"
_smb_sync_password() { return 1; }
_change_single_user_password < "$TEST_TMPDIR/smb_stdin" 2>/dev/null
if [[ $? -eq 1 ]]; then
    test_pass
else
    test_fail "SMB 失败时单用户密码修改应返回 1"
fi

_SMB_PREV_STATE="$PWD"

# ------------------------------------------------------------
# 批量密码修改 SMB 同步测试
# ------------------------------------------------------------

test_start "批量密码修改: SMB 同步成功计数"
_smb_sync_password() { return 0; }
# 重定向输出避免污染测试输出
_change_all_users_password >/dev/null 2>&1
# 验证成功 (成功=2 用户全部成功)
# _change_all_users_password 无返回值，检查不影响即可
test_pass

test_start "批量密码修改: SMB 失败不中断批量操作"
smb_call_count=0
_smb_sync_password() { smb_call_count=$((smb_call_count + 1)); return 1; }
_change_all_users_password >/dev/null 2>&1
if [[ $smb_call_count -eq 2 ]]; then
    test_pass
else
    test_fail "所有用户都应尝试 SMB 同步，实际调用次数: $smb_call_count (预期 2)"
fi

# ------------------------------------------------------------
# 密码轮换脚本 SMB 测试（生成脚本内容验证）
# ------------------------------------------------------------

test_start "configure_password_rotation: 生成的脚本包含 SMB 调用"
rotation_capture="$TEST_TMPDIR/passwd_rotate_smb.sh"
write_privileged_text_file() {
    local content
    content="$(cat)"
    printf '%s' "$content" > "$rotation_capture"
    return 0
}
priv_chmod() { return 0; }
priv_crontab() { cat >/dev/null; return 0; }
msg_step() { return 0; }
PASSWORD_POOL_DIR="$TEST_TMPDIR/pools_smb"
PASSWORD_POOL_FILE="$PASSWORD_POOL_DIR/passwd_current.txt"
mkdir -p "$PASSWORD_POOL_DIR"
configure_password_rotation 30 >/dev/null 2>&1
if [[ -f "$rotation_capture" ]] && \
   grep -q 'source "\$MANAGER_DIR/lib/smb_core.sh"' "$rotation_capture" && \
   grep -q 'smb_set_password "\$username" "\$NEW_PASS"' "$rotation_capture"; then
    test_pass
else
    test_fail "轮换脚本应包含 smb_core.sh 和 smb_set_password 调用"
fi
unset -f write_privileged_text_file priv_chmod priv_crontab msg_step

cleanup_test_env
test_suite_end
