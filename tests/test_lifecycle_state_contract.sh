#!/usr/bin/env bash
# 额外状态契约：仅临时文件与 mock 特权函数，无真实系统更改。
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
export SUDO_NONINTERACTIVE=1
source "$SCRIPT_DIR/test_framework.sh"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/config.sh"
LIB_DIR="$PROJECT_ROOT/lib"
source "$PROJECT_ROOT/lib/quota_core.sh"
source "$PROJECT_ROOT/lib/user_core.sh"
source "$PROJECT_ROOT/lib/backup_core.sh"
source "$PROJECT_ROOT/lib/controller_user_provisioning.sh"
source "$PROJECT_ROOT/lib/controller_user_lifecycle.sh"
setup_test_env
test_suite_start "Lifecycle state contracts"

check_contract() {
    local title="$1" fn="$2"
    test_start "$title"
    if ("$fn"); then test_pass; else test_fail "$fn"; fi
}
test_disabled_rename() {
    local logfile="$TEST_TMPDIR/rename.log"
    mkdir -p "$TEST_TMPDIR/rename_old"
    DISABLED_USERS_FILE="$TEST_TMPDIR/disabled.txt"
    printf 'olduser\treason\t2026-10-01\t2026-10-20\t/bin/bash\tactive\t-1\tsuspend\n' >"$DISABLED_USERS_FILE"
    USER_CONFIG_FILE="$TEST_TMPDIR/no-config"
    JOB_STATS_DIR="$TEST_TMPDIR/no-stats"
    read_existing_username() { REPLY_INPUT=olduser; }
    read_username() { REPLY_INPUT=newuser; }
    draw_header() { :; }
    draw_info_card() { :; }
    msg_step() { :; }
    msg_ok() { :; }
    msg_err() { :; }
    confirm_action() { return 0; }
    acquire_lock() { return 0; }
    release_lock() { :; }
    id() { [[ "$1" == olduser ]]; }
    get_user_home() { printf '%s/rename_old\n' "$TEST_TMPDIR"; }
    _um_user_lock_state() { printf locked; }
    priv_usermod() { printf '%s\n' "$*" >>"$logfile"; }
    priv_mv() { command mv "$@"; }
    getent() { return 2; }
    priv_iptables() { return 1; }
    priv_ufw() { return 1; }
    record_user_event() { :; }
    rename_user_account >/dev/null 2>&1 || return 1
    [[ -d "$TEST_TMPDIR/newuser" && ! -d "$TEST_TMPDIR/rename_old" ]] || return 1
    grep -Fq "newuser"$'\t' "$DISABLED_USERS_FILE" &&
        ! grep -Fq "olduser"$'\t' "$DISABLED_USERS_FILE" &&
        ! grep -qx -- '-U newuser' "$logfile"
}
test_active_rename() {
    local logfile="$TEST_TMPDIR/rename_active.log"
    mkdir -p "$TEST_TMPDIR/active_old"
    DISABLED_USERS_FILE="$TEST_TMPDIR/no-disabled"
    USER_CONFIG_FILE="$TEST_TMPDIR/no-config"
    JOB_STATS_DIR="$TEST_TMPDIR/no-stats"
    read_existing_username() { REPLY_INPUT=activeold; }
    read_username() { REPLY_INPUT=activenew; }
    draw_header() { :; }
    draw_info_card() { :; }
    msg_step() { :; }
    msg_ok() { :; }
    msg_err() { :; }
    confirm_action() { return 0; }
    acquire_lock() { return 0; }
    release_lock() { :; }
    id() { [[ "$1" == activeold ]]; }
    get_user_home() { printf '%s/active_old\n' "$TEST_TMPDIR"; }
    _um_user_lock_state() { printf active; }
    priv_usermod() { printf '%s\n' "$*" >>"$logfile"; }
    priv_mv() { command mv "$@"; }
    getent() { return 2; }
    priv_iptables() { return 1; }
    priv_ufw() { return 1; }
    record_user_event() { :; }
    rename_user_account >/dev/null 2>&1 &&
        grep -qx -- '-U activenew' "$logfile"
}
test_restore_without_verify() {
    local logfile="$TEST_TMPDIR/restore-called"
    BACKUP_ROOT="$TEST_TMPDIR/before-restore"
    mkdir -p "$BACKUP_ROOT/lifetest/full_1" "$TEST_TMPDIR/restore-home"
    printf archive >"$BACKUP_ROOT/lifetest/full_1/f"
    draw_header() { :; }
    draw_info_card() { :; }
    msg_warn() { :; }
    msg_err() { :; }
    confirm_action() { return 0; }
    id() { return 0; }
    get_user_home() { printf '%s/restore-home\n' "$TEST_TMPDIR"; }
    unset -f verify_before_restore 2>/dev/null || true
    priv_rsync() { echo called >>"$logfile"; }
    if restore_user_backup lifetest full_1 >/dev/null 2>&1; then return 1; fi
    [[ ! -e "$logfile" ]]
}
test_checksum() {
    BACKUP_ROOT="$TEST_TMPDIR/checksum"
    mkdir -p "$BACKUP_ROOT/lifetest/full_1"
    printf original >"$BACKUP_ROOT/lifetest/full_1/a.bam"
    msg_step() { :; }
    msg_ok() { :; }
    msg_err() { :; }
    msg_warn() { :; }
    source "$PROJECT_ROOT/lib/backup_verify.sh"
    if verify_before_restore "$BACKUP_ROOT/lifetest/full_1" >/dev/null 2>&1; then return 1; fi
    generate_backup_checksum "$BACKUP_ROOT/lifetest/full_1" >/dev/null 2>&1 || return 1
    verify_before_restore "$BACKUP_ROOT/lifetest/full_1" >/dev/null 2>&1 || return 1
    printf corrupted >"$BACKUP_ROOT/lifetest/full_1/a.bam"
    if verify_before_restore "$BACKUP_ROOT/lifetest/full_1" >/dev/null 2>&1; then return 1; fi
}
test_unquotaed_account() {
    DATA_BASE="$TEST_TMPDIR/data"
    ALL_DISKS=(6 7)
    USERNAMES_CACHE=""
    USERNAMES_CACHE_TIME=0
    USERNAME_PATTERN='^[a-zA-Z_][a-zA-Z0-9_.-]*$'
    getent() {
        if [[ "$#" == 1 && "$1" == passwd ]]; then
            printf 'studentx:x:2001:2001::%s/data06/studentx:/bin/bash\n' "$DATA_BASE"
        elif [[ "$#" == 2 && "$2" == studentx ]]; then
            printf 'studentx:x:2001:2001::%s/data06/studentx:/bin/bash\n' "$DATA_BASE"
        else return 2; fi
    }
    get_user_home() { printf '%s/data06/studentx\n' "$DATA_BASE"; }
    mountpoint() { return 0; }
    priv_repquota() { return 1; }
    [[ "$(get_managed_usernames)" == studentx ]]
}
check_contract "重命名保留停用状态及锁" test_disabled_rename
check_contract "正常用户重命名后恢复登录状态" test_active_rename
check_contract "校验模块未加载时拒绝恢复" test_restore_without_verify
check_contract "校验和缺失/篡改时拒绝恢复" test_checksum
check_contract "无配额记录的账户仍被发现" test_unquotaed_account
cleanup_test_env
test_suite_end
