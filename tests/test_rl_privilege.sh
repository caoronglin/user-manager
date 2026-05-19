#!/bin/bash
# test_rl_privilege.sh - rl_priv_* 统一权限封装层测试

set -uo pipefail

rl_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rl_project_root="$(dirname "$rl_script_dir")"

# shellcheck source=tests/test_framework.sh
source "$rl_script_dir/test_framework.sh"

setup_test_env

rl_stub_dir="$TEST_TMPDIR/bin"
rl_sudo_log="$TEST_TMPDIR/sudo.log"
rl_cmd_log="$TEST_TMPDIR/cmd.log"
rl_audit_log="$TEST_TMPDIR/audit/audit.log"
mkdir -p "$rl_stub_dir" "$(dirname "$rl_audit_log")"
: > "$rl_sudo_log"
: > "$rl_cmd_log"

cat > "$rl_stub_dir/sudo" <<'EOS'
#!/bin/bash
printf 'sudo %s\n' "$*" >> "$RL_SUDO_LOG"
if [[ "${1:-}" == "-n" ]]; then
    shift
fi
if [[ "${1:-}" == "-u" ]]; then
    shift 2
fi
"$@"
EOS
chmod +x "$rl_stub_dir/sudo"

cat > "$rl_stub_dir/systemctl" <<'EOS'
#!/bin/bash
printf 'systemctl %s\n' "$*" >> "$RL_CMD_LOG"
EOS
chmod +x "$rl_stub_dir/systemctl"

cat > "$rl_stub_dir/setquota" <<'EOS'
#!/bin/bash
printf 'setquota %s\n' "$*" >> "$RL_CMD_LOG"
EOS
chmod +x "$rl_stub_dir/setquota"

cat > "$rl_stub_dir/repquota" <<'EOS'
#!/bin/bash
printf 'repquota %s\n' "$*" >> "$RL_CMD_LOG"
EOS
chmod +x "$rl_stub_dir/repquota"

for rl_cmd in chpasswd passwd chage gzip gunzip userdel deluser; do
    cat > "$rl_stub_dir/$rl_cmd" <<'EOS'
#!/bin/bash
rl_cmd_name="$(basename "$0")"
printf '%s %s\n' "$rl_cmd_name" "$*" >> "$RL_CMD_LOG"
if [[ "$rl_cmd_name" == "chpasswd" ]]; then
    cat >> "$RL_CMD_LOG"
fi
EOS
    chmod +x "$rl_stub_dir/$rl_cmd"
done

export PATH="$rl_stub_dir:$PATH"
export RL_SUDO_LOG="$rl_sudo_log"
export RL_CMD_LOG="$rl_cmd_log"
export SUDO_NONINTERACTIVE=0

# privilege.sh 启动时需要 access_control.sh 中的 ACL 常量。
ACL_LEVEL_ROOT=0
ACL_LEVEL_ADMIN=100
ACL_LEVEL_USER=200
ACL_LEVEL_GUEST=300
ACL_AUDIT_LOG="$rl_audit_log"

is_root() { return 1; }
msg_err() { return 0; }
msg_warn() { return 0; }
acl_get_current_level() { printf '%s\n' "$ACL_LEVEL_ADMIN"; }
acl_audit_log() { return 0; }

# shellcheck source=lib/privilege.sh
source "$rl_project_root/lib/privilege.sh"

test_suite_start "rl_privilege wrappers"

test_start "rl_priv_can_sudo: sudo 可用时返回成功"
if rl_priv_can_sudo; then
    test_pass
else
    test_fail "sudo stub 存在时应返回 0"
fi

test_start "rl_priv_can_sudo: sudo 不可用时返回失败"
rl_original_path="$PATH"
rl_empty_path="$TEST_TMPDIR/empty-path"
mkdir -p "$rl_empty_path"
PATH="$rl_empty_path"
if ! rl_priv_can_sudo; then
    test_pass
else
    test_fail "PATH 中无 sudo 时应返回 1"
fi
PATH="$rl_original_path"

test_start "rl_priv_exec: 委托 priv_exec 并调用 sudo"
: > "$rl_sudo_log"
if rl_priv_exec mkdir -p "$TEST_TMPDIR/priv_exec_dir" >/dev/null 2>&1 && \
    grep -q "sudo mkdir -p $TEST_TMPDIR/priv_exec_dir" "$rl_sudo_log"; then
    test_pass
else
    test_fail "rl_priv_exec 未通过 sudo 调用 mkdir"
fi

test_start "rl_priv_write_file: 通过 tee 写入内容"
rl_write_target="$TEST_TMPDIR/rl_priv_write.txt"
: > "$rl_sudo_log"
if rl_priv_write_file "$rl_write_target" "hello privilege" && \
    [[ "$(<"$rl_write_target")" == "hello privilege" ]] && \
    grep -q "sudo tee $rl_write_target" "$rl_sudo_log"; then
    test_pass
else
    test_fail "rl_priv_write_file 未通过 tee 写入目标文件"
fi

test_start "rl_priv_systemctl: 委托 systemctl"
: > "$rl_sudo_log"
: > "$rl_cmd_log"
if rl_priv_systemctl restart sshd >/dev/null 2>&1 && \
    grep -q "sudo systemctl restart sshd" "$rl_sudo_log" && \
    grep -q "systemctl restart sshd" "$rl_cmd_log"; then
    test_pass
else
    test_fail "rl_priv_systemctl 未正确委托 systemctl"
fi

test_start "rl_priv_setquota / rl_priv_repquota: 委托配额命令"
: > "$rl_sudo_log"
: > "$rl_cmd_log"
if rl_priv_setquota -u alice 100 200 0 0 /home >/dev/null 2>&1 && \
    rl_priv_repquota -a >/dev/null 2>&1 && \
    grep -q "sudo setquota -u alice 100 200 0 0 /home" "$rl_sudo_log" && \
    grep -q "sudo repquota -a" "$rl_sudo_log" && \
    grep -q "setquota -u alice 100 200 0 0 /home" "$rl_cmd_log" && \
    grep -q "repquota -a" "$rl_cmd_log"; then
    test_pass
else
    test_fail "rl_priv_setquota 或 rl_priv_repquota 未正确委托"
fi

test_start "priv_chpasswd: 白名单允许并通过 sudo 委托 chpasswd"
: > "$rl_sudo_log"
: > "$rl_cmd_log"
if printf 'alice:Secret123!\n' | priv_chpasswd >/dev/null 2>&1 && \
    grep -q "sudo chpasswd" "$rl_sudo_log" && \
    grep -q "chpasswd" "$rl_cmd_log" && \
    grep -q "alice:Secret123!" "$rl_cmd_log"; then
    test_pass
else
    test_fail "priv_chpasswd 未通过白名单或未委托 chpasswd"
fi

test_start "priv_passwd: 白名单允许并通过 sudo 委托 passwd"
: > "$rl_sudo_log"
: > "$rl_cmd_log"
if priv_passwd -l alice >/dev/null 2>&1 && \
    grep -q "sudo passwd -l alice" "$rl_sudo_log" && \
    grep -q "passwd -l alice" "$rl_cmd_log"; then
    test_pass
else
    test_fail "priv_passwd 未通过白名单或未委托 passwd"
fi

test_start "priv_chage: 白名单允许并通过 sudo 委托账户过期设置"
: > "$rl_sudo_log"
: > "$rl_cmd_log"
if declare -F priv_chage >/dev/null 2>&1 && \
    priv_chage -E 0 alice >/dev/null 2>&1 && \
    priv_chage -E -1 alice >/dev/null 2>&1 && \
    grep -q "sudo chage -E 0 alice" "$rl_sudo_log" && \
    grep -q "sudo chage -E -1 alice" "$rl_sudo_log" && \
    grep -q "chage -E 0 alice" "$rl_cmd_log" && \
    grep -q "chage -E -1 alice" "$rl_cmd_log"; then
    test_pass
else
    test_fail "priv_chage 不存在或未委托 chage"
fi

test_start "priv_gzip / priv_gunzip: 白名单允许并委托压缩命令"
: > "$rl_sudo_log"
: > "$rl_cmd_log"
if priv_gzip -f "$TEST_TMPDIR/archive.log" >/dev/null 2>&1 && \
    priv_gunzip -f "$TEST_TMPDIR/archive.log.gz" >/dev/null 2>&1 && \
    grep -q "sudo gzip -f $TEST_TMPDIR/archive.log" "$rl_sudo_log" && \
    grep -q "sudo gunzip -f $TEST_TMPDIR/archive.log.gz" "$rl_sudo_log" && \
    grep -q "gzip -f $TEST_TMPDIR/archive.log" "$rl_cmd_log" && \
    grep -q "gunzip -f $TEST_TMPDIR/archive.log.gz" "$rl_cmd_log"; then
    test_pass
else
    test_fail "priv_gzip 或 priv_gunzip 未通过白名单委托"
fi

test_start "priv_deluser: 函数存在并委托 deluser/userdel"
: > "$rl_sudo_log"
: > "$rl_cmd_log"
if declare -F priv_deluser >/dev/null 2>&1 && \
    priv_deluser alice sudo >/dev/null 2>&1 && \
    { grep -q "sudo deluser alice sudo" "$rl_sudo_log" || grep -q "sudo userdel alice sudo" "$rl_sudo_log"; } && \
    { grep -q "deluser alice sudo" "$rl_cmd_log" || grep -q "userdel alice sudo" "$rl_cmd_log"; }; then
    test_pass
else
    test_fail "priv_deluser 不存在或未委托 deluser/userdel"
fi

test_start "sudo 不作为通用特权命令暴露在白名单或 wrapper 中"
if ! priv_check_whitelist sudo && ! declare -F priv_sudo >/dev/null 2>&1; then
    test_pass
else
    test_fail "sudo 仍可作为通用 priv_exec 命令或 priv_sudo wrapper 使用"
fi

test_start "as_user: 受控 sudo -u 不依赖 priv_sudo 白名单"
# shellcheck source=lib/resource_core.sh
source "$rl_project_root/lib/resource_core.sh"
: > "$rl_sudo_log"
: > "$rl_cmd_log"
priv_sudo() { printf 'priv_sudo %s\n' "$*" >> "$rl_cmd_log"; return 1; }
id() { [[ "${1:-}" == "alice" ]]; }
if as_user alice true >/dev/null 2>&1 && \
    grep -q "sudo -u alice true" "$rl_sudo_log" && \
    ! grep -q "priv_sudo" "$rl_cmd_log"; then
    test_pass
else
    test_fail "as_user 未使用受控 sudo -u，或仍依赖 priv_sudo"
fi
unset -f priv_sudo id

test_start "check_permission: 使用数字权限级别且方向为 current <= required"
if (
    rl_mock_permission_level="$ACL_LEVEL_ADMIN"
    get_current_permission_level() { printf '%s\n' "$rl_mock_permission_level"; }
    check_permission user create && \
        rl_mock_permission_level="$ACL_LEVEL_USER" && \
        ! check_permission user create && \
        check_permission user update && \
        rl_mock_permission_level="$ACL_LEVEL_GUEST" && \
        check_permission user read && \
        ! check_permission system modify
); then
    test_pass
else
    test_fail "权限矩阵仍使用字符串权限或比较方向不正确"
fi

test_start "check_permission: 通过 acl_get_current_level 获取真实当前权限"
permission_chain_rc="$(env bash -c 'set -uo pipefail
ACL_LEVEL_ROOT=0
ACL_LEVEL_ADMIN=1
ACL_LEVEL_USER=2
ACL_LEVEL_GUEST=3
ACL_AUDIT_LOG="$1/audit.log"
is_root() { return 1; }
msg_err() { return 0; }
msg_warn() { return 0; }
acl_audit_log() { return 0; }
acl_get_current_level() { printf "%s\n" "$ACL_LEVEL_ADMIN"; }
source "$2/lib/privilege.sh"
check_permission system modify
printf "%s" "$?"' _ "$TEST_TMPDIR" "$rl_project_root" 2>/dev/null || true)"
if [[ "$permission_chain_rc" == "0" ]]; then
    test_pass
else
    test_fail "check_permission 未通过 acl_get_current_level 获取管理员权限，退出码: $permission_chain_rc"
fi

cleanup_test_env
test_suite_end
