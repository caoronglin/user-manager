#!/usr/bin/env bash
# 故障注入契约：全部使用函数 mock 和临时目录；禁止真实 useradd/userdel/rsync/sudo。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
export SUDO_NONINTERACTIVE=1
source "$SCRIPT_DIR/test_framework.sh"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/config.sh"
LIB_DIR="$PROJECT_ROOT/lib"
source "$PROJECT_ROOT/lib/user_core.sh"
source "$PROJECT_ROOT/lib/backup_core.sh"
source "$PROJECT_ROOT/lib/controller_user_provisioning.sh"
source "$PROJECT_ROOT/lib/controller_user_lifecycle.sh"
setup_test_env
test_suite_start "Lifecycle failure contracts (no system mutations)"

run_contract() {
    local label="$1" fn="$2"
    test_start "$label"
    if ("$fn"); then
        test_pass
    else
        test_fail "$fn violated its failure-handling contract"
    fi
}

# 任何回滚逻辑都必须通过 priv_* mock；不触碰系统账户。
test_password_failure_rolls_back_account() {
    local logfile="$TEST_TMPDIR/password_rollback.log"
    msg_err() { :; }
    msg_warn() { :; }
    validate_path_safety() { return 0; }
    priv_useradd() { printf 'useradd\n' >>"$logfile"; }
    priv_chpasswd() { cat >/dev/null; return 9; }
    priv_userdel() { printf 'userdel:%s\n' "$*" >>"$logfile"; }
    if create_user lifetest 'NonSecretPassword' "$TEST_TMPDIR/lifetest-home" false >/dev/null 2>&1; then
        return 1
    fi
    grep -qx 'useradd' "$logfile" &&
        grep -qx 'userdel:lifetest' "$logfile" &&
        ! grep -q -- '-r' "$logfile"
}

test_delete_stops_after_backup_failure() {
    local logfile="$TEST_TMPDIR/deletion.log"
    REPLY_INPUT=''
    draw_header() { :; }
    msg_warn() { :; }
    msg_err() { :; }
    read_existing_username() { REPLY_INPUT='lifetest'; }
    read_input() { REPLY_INPUT='lifetest'; }
    confirm_action() { return 0; }
    acquire_lock() { return 0; }
    release_lock() { printf 'unlock\n' >>"$logfile"; }
    manual_backup_user() { printf 'backup_failed\n' >>"$logfile"; return 28; }
    delete_user_all_rules() { printf 'cleanup\n' >>"$logfile"; }
    remove_dns_restrictions() { printf 'dns\n' >>"$logfile"; }
    delete_user() { printf 'DELETE\n' >>"$logfile"; }
    if delete_user_account >/dev/null 2>&1; then
        return 1
    fi
    grep -qx 'backup_failed' "$logfile" &&
        grep -qx 'unlock' "$logfile" &&
        ! grep -Eq 'DELETE|cleanup|dns' "$logfile"
}

test_restore_stops_when_protection_fails() {
    local logfile="$TEST_TMPDIR/restore.log"
    BACKUP_ROOT="$TEST_TMPDIR/backup"
    mkdir -p "$BACKUP_ROOT/lifetest/full_1" "$TEST_TMPDIR/home"
    printf '%s\n' 'original' >"$TEST_TMPDIR/home/data"
    printf '%s\n' 'archived' >"$BACKUP_ROOT/lifetest/full_1/data"
    draw_header() { :; }
    draw_info_card() { :; }
    msg_warn() { :; }
    msg_err() { :; }
    msg_step() { :; }
    confirm_action() { return 0; }
    id() { return 0; }
    get_user_home() { printf '%s/home\n' "$TEST_TMPDIR"; }
    verify_before_restore() { return 0; }
    priv_mkdir() { command mkdir "$@"; }
    priv_rsync() { printf '%s\n' "$*" >>"$logfile"; return 28; }
    if restore_user_backup lifetest full_1 >/dev/null 2>&1; then
        return 1
    fi
    [[ "$(wc -l <"$logfile")" == 1 ]] &&
        ! grep -q -- '--delete' "$logfile" &&
        [[ "$(cat "$TEST_TMPDIR/home/data")" == original ]]
}

test_restore_refuses_unverified_backup() {
    local logfile="$TEST_TMPDIR/restore_verify.log"
    BACKUP_ROOT="$TEST_TMPDIR/backup"
    mkdir -p "$BACKUP_ROOT/lifetest/full_1" "$TEST_TMPDIR/home"
    draw_header() { :; }
    draw_info_card() { :; }
    msg_warn() { :; }
    msg_err() { :; }
    msg_step() { :; }
    confirm_action() { return 0; }
    id() { return 0; }
    get_user_home() { printf '%s/home\n' "$TEST_TMPDIR"; }
    verify_before_restore() { return 1; }
    priv_mkdir() { command mkdir "$@"; }
    priv_rsync() { printf 'rsync\n' >>"$logfile"; return 0; }
    if restore_user_backup lifetest full_1 >/dev/null 2>&1; then
        return 1
    fi
    [[ ! -e "$logfile" ]]
}

test_bulk_backup_returns_failure() {
    BACKUP_ROOT="$TEST_TMPDIR/bulk"
    local home="$TEST_TMPDIR/bulk-home" log="$TEST_TMPDIR/bulk-run.log"
    mkdir -p "$home" "$BACKUP_ROOT"
    draw_header() { :; }
    draw_info_card() { :; }
    msg_warn() { :; }
    msg_err() { :; }
    msg_step() { :; }
    msg_info() { :; }
    print_exclude_summary() { :; }
    bytes_to_human() { echo '0B'; }
    confirm_action() { return 0; }
    get_managed_usernames() { echo 'lifetest'; }
    get_user_home() { printf '%s\n' "$home"; }
    id() { return 0; }
    priv_mkdir() { command mkdir "$@"; }
    build_rsync_exclude_args() { return 0; }
    write_privileged_text_file() { cat >"$1"; }
    priv_tee() { [[ "${1:-}" == '-a' ]] && cat >>"$2"; }
    priv_rsync() { printf 'failed\n' >>"$log"; return 28; }
    record_user_event() { return 0; }
    if backup_all_users >/dev/null 2>&1; then
        return 1
    fi
    grep -qx 'failed' "$log"
}

test_privileged_group_denied() {
    local logfile="$TEST_TMPDIR/group.log"
    msg_err() { :; }
    msg_ok() { :; }
    require_user() { return 0; }
    ensure_user_group() { printf 'ensure:%s\n' "$1" >>"$logfile"; }
    priv_usermod() { printf 'usermod\n' >>"$logfile"; }
    record_user_event() { :; }
    if add_user_to_group lifetest sudo >/dev/null 2>&1; then
        return 1
    fi
    [[ ! -e "$logfile" ]] || return 1
    add_user_to_group lifetest research >/dev/null 2>&1 &&
        grep -qx 'ensure:research' "$logfile" &&
        grep -qx 'usermod' "$logfile"
}

test_provisioning_does_not_report_success_without_quota() {
    local logfile="$TEST_TMPDIR/provision.log"
    REPLY_INPUT=''
    msg_err() { :; }
    msg_info() { :; }
    msg_ok() { :; }
    msg_warn() { :; }
    msg_step() { :; }
    draw_header() { :; }
    draw_prompt() { :; }
    draw_menu_item() { :; }
    draw_info_card() { :; }
    acquire_lock() { return 0; }
    release_lock() { printf 'unlock\n' >>"$logfile"; }
    validate_username() { return 0; }
    id() { return 1; }
    get_random_password() { echo 'TestPass123!'; }
    show_passwords_enabled() { return 1; }
    format_password_display() { echo '[redacted]'; }
    _display_available_data_disks() { :; }
    read_input() {
        if [[ "$1" == "选择磁盘编号" ]]; then
            REPLY_INPUT=6
        else
            REPLY_INPUT=''
        fi
    }
    _resolve_provision_target() { printf '06|%s/data06|%s/home\n' "$TEST_TMPDIR" "$TEST_TMPDIR"; }
    _resolve_provision_quota() { echo 1024; }
    bytes_to_human() { echo '1KiB'; }
    bytes_to_gb() { echo '0'; }
    confirm_action() { [[ "$1" == '确认继续？' ]]; }
    create_user() { printf 'created\n' >>"$logfile"; }
    apply_user_groups() { return 0; }
    priv_chown() { return 0; }
    priv_chmod() { return 0; }
    priv_usermod() { return 0; }
    set_user_quota() { printf 'quota_failed\n' >>"$logfile"; return 2; }
    _send_password_notification() { printf 'NOTIFIED\n' >>"$logfile"; }
    record_user_event() { printf 'EVENT\n' >>"$logfile"; }
    df() { printf 'Filesystem 1B-blocks Used Available Use%% Mounted on\nmock 4096 1 4095 1%% /mnt/data06\n'; }
    if create_or_assign_user <<<'lifetest
1' >/dev/null 2>&1; then
        return 1
    fi
    grep -qx 'created' "$logfile" &&
        grep -qx 'quota_failed' "$logfile" &&
        grep -qx 'unlock' "$logfile" &&
        ! grep -Eq 'NOTIFIED|EVENT' "$logfile"
}

run_contract "密码初始化失败撤销账户且不删除主目录" test_password_failure_rolls_back_account
run_contract "删除前备份失败禁止删除及关联清理" test_delete_stops_after_backup_failure
run_contract "恢复前保护备份失败禁止覆盖恢复" test_restore_stops_when_protection_fails
run_contract "备份校验失败禁止恢复" test_restore_refuses_unverified_backup
run_contract "批量备份部分失败返回非零退出码" test_bulk_backup_returns_failure
run_contract "普通用户组入口拒绝 sudo 等高权限组" test_privileged_group_denied
run_contract "配额设置失败禁止上报账户创建完成" test_provisioning_does_not_report_success_without_quota

cleanup_test_env
test_suite_end
