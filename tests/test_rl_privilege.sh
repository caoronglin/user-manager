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
: >"$rl_sudo_log"
: >"$rl_cmd_log"

cat >"$rl_stub_dir/sudo" <<'EOS'
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

cat >"$rl_stub_dir/systemctl" <<'EOS'
#!/bin/bash
printf 'systemctl %s\n' "$*" >> "$RL_CMD_LOG"
EOS
chmod +x "$rl_stub_dir/systemctl"

cat >"$rl_stub_dir/setquota" <<'EOS'
#!/bin/bash
printf 'setquota %s\n' "$*" >> "$RL_CMD_LOG"
EOS
chmod +x "$rl_stub_dir/setquota"

cat >"$rl_stub_dir/repquota" <<'EOS'
#!/bin/bash
printf 'repquota %s\n' "$*" >> "$RL_CMD_LOG"
EOS
chmod +x "$rl_stub_dir/repquota"

for rl_cmd in chpasswd passwd chage gzip gunzip userdel deluser smbpasswd pdbedit; do
    cat >"$rl_stub_dir/$rl_cmd" <<'EOS'
#!/bin/bash
rl_cmd_name="$(basename "$0")"
printf '%s %s\n' "$rl_cmd_name" "$*" >> "$RL_CMD_LOG"
# 只有明确需要从 stdin 接收密码的命令才消费 stdin；否则会继承测试进程的 stdin 并挂死。
if [[ "$rl_cmd_name" == "chpasswd" ]]; then
    cat >> "$RL_CMD_LOG"
elif [[ "$rl_cmd_name" == "smbpasswd" && "${1:-}" == "-a" ]]; then
    cat >> "$RL_CMD_LOG"
fi
EOS
    chmod +x "$rl_stub_dir/$rl_cmd"
done

export PATH="$rl_stub_dir:$PATH"
export RL_SUDO_LOG="$rl_sudo_log"
export RL_CMD_LOG="$rl_cmd_log"
export SUDO_NONINTERACTIVE=0

# rl-chpasswd wrapper 测试桩：模拟 scripts/rl-chpasswd.sh（stdin 读"仅密码"、精确断言
# 期望密码值（拒绝拼接/篡改值）、不落盘）
cat >"$rl_stub_dir/rl-chpasswd" <<'EOS'
#!/bin/bash
printf 'rl-chpasswd user=%s\n' "$1" >> "$RL_CMD_LOG"
IFS= read -r rl_stub_pass
[[ "$rl_stub_pass" == "$RL_EXPECTED_PASS" ]] || exit 1
EOS
chmod +x "$rl_stub_dir/rl-chpasswd"
export RL_EXPECTED_PASS="Secret123!"
# 让 priv_chpasswd 委托测试桩（wrapper 路径在 source privilege.sh 时解析；普通赋值不导出，
# 避免污染子 shell 继承环境）
RL_CHPASSWD_WRAPPER="$rl_stub_dir/rl-chpasswd"

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
: >"$rl_sudo_log"
if rl_priv_exec mkdir -p "$TEST_TMPDIR/priv_exec_dir" >/dev/null 2>&1 &&
    grep -q "sudo mkdir -p $TEST_TMPDIR/priv_exec_dir" "$rl_sudo_log"; then
    test_pass
else
    test_fail "rl_priv_exec 未通过 sudo 调用 mkdir"
fi

test_start "rl_priv_write_file: 通过 tee 写入内容"
rl_write_target="$TEST_TMPDIR/rl_priv_write.txt"
: >"$rl_sudo_log"
if rl_priv_write_file "$rl_write_target" "hello privilege" &&
    [[ "$(<"$rl_write_target")" == "hello privilege" ]] &&
    grep -q "sudo tee $rl_write_target" "$rl_sudo_log"; then
    test_pass
else
    test_fail "rl_priv_write_file 未通过 tee 写入目标文件"
fi

test_start "rl_priv_systemctl: 委托 systemctl"
: >"$rl_sudo_log"
: >"$rl_cmd_log"
if rl_priv_systemctl restart sshd >/dev/null 2>&1 &&
    grep -q "sudo systemctl restart sshd" "$rl_sudo_log" &&
    grep -q "systemctl restart sshd" "$rl_cmd_log"; then
    test_pass
else
    test_fail "rl_priv_systemctl 未正确委托 systemctl"
fi

test_start "rl_priv_setquota / rl_priv_repquota: 委托配额命令"
: >"$rl_sudo_log"
: >"$rl_cmd_log"
if rl_priv_setquota -u alice 100 200 0 0 /home >/dev/null 2>&1 &&
    rl_priv_repquota -a >/dev/null 2>&1 &&
    grep -q "sudo setquota -u alice 100 200 0 0 /home" "$rl_sudo_log" &&
    grep -q "sudo repquota -a" "$rl_sudo_log" &&
    grep -q "setquota -u alice 100 200 0 0 /home" "$rl_cmd_log" &&
    grep -q "repquota -a" "$rl_cmd_log"; then
    test_pass
else
    test_fail "rl_priv_setquota 或 rl_priv_repquota 未正确委托"
fi

test_start "priv_chpasswd: 从 stdin 读取 user:password 并委托 rl-chpasswd wrapper（密码不落日志）"
: >"$rl_sudo_log"
: >"$rl_cmd_log"
if printf 'alice:Secret123!\n' | priv_chpasswd >/dev/null 2>&1 &&
    grep -q "rl-chpasswd" "$rl_sudo_log" &&
    grep -q "rl-chpasswd user=alice" "$rl_cmd_log" &&
    ! grep -q "Secret123!" "$rl_sudo_log" &&
    ! grep -q "Secret123!" "$rl_cmd_log"; then
    test_pass
else
    test_fail "priv_chpasswd 未从 stdin 委托 rl-chpasswd wrapper，或密码泄漏到 sudo/cmd 日志"
fi

test_start "priv_chpasswd: stdin 密码精确传递（拼接/篡改值被 wrapper 桩拒绝）"
: >"$rl_sudo_log"
: >"$rl_cmd_log"
# 桩断言 stdin 必须等于精确密码 Secret123!（不含 user 前缀、未被篡改）；
# 若 priv_chpasswd 误传 "alice:Secret123!" 或改写密码，桩退出 1 → priv_chpasswd 返回非零
if printf 'alice:Secret123!\n' | priv_chpasswd >/dev/null 2>&1 &&
    grep -q "rl-chpasswd user=alice" "$rl_cmd_log" &&
    ! grep -q "alice:Secret123!" "$rl_cmd_log"; then
    test_pass
else
    test_fail "priv_chpasswd 未精确传递密码（桩未收到期望值或密码带 user 前缀落日志）"
fi

test_start "priv_chpasswd: wrapper 非零退出沿管道返回"
: >"$rl_sudo_log"
: >"$rl_cmd_log"
if ! printf 'alice:WrongPass!\n' | priv_chpasswd >/dev/null 2>&1; then
    test_pass
else
    test_fail "wrapper 拒绝（密码不匹配期望值）时 priv_chpasswd 应返回非零"
fi

test_start "rl-chpasswd.sh 直接调用: 参数数/非法用户名/root/空 stdin/空密码均拒绝"
rl_real_wrapper="$rl_project_root/scripts/rl-chpasswd.sh"
rl_reject_ok=0
if [[ -f "$rl_real_wrapper" ]]; then
    # 参数个数错误（2 个参数）
    if "$rl_real_wrapper" alice extra </dev/null >/dev/null 2>&1; then rl_reject_ok=1; fi
    # 非法用户名（含 é；LC_ALL=zh_CN.utf8 下也须拒绝，验证固定 C locale 的正则）
    if printf 'x:pw\n' | LC_ALL=zh_CN.utf8 "$rl_real_wrapper" 'bobé' >/dev/null 2>&1; then rl_reject_ok=1; fi
    # 非法用户名（含 ; 元字符）
    if printf 'x:pw\n' | "$rl_real_wrapper" 'alice;touch /tmp/pwned' >/dev/null 2>&1; then rl_reject_ok=1; fi
    # root 目标
    if printf 'x:pw\n' | "$rl_real_wrapper" root >/dev/null 2>&1; then rl_reject_ok=1; fi
    # 空 stdin
    if "$rl_real_wrapper" alice </dev/null >/dev/null 2>&1; then rl_reject_ok=1; fi
    # 空密码
    if printf '\n' | "$rl_real_wrapper" alice >/dev/null 2>&1; then rl_reject_ok=1; fi
    # é 场景必须走"非法用户名"拒绝路径（错误消息校验，而非 chpasswd 失败）
    rl_err="$(printf 'x:pw\n' | LC_ALL=zh_CN.utf8 "$rl_real_wrapper" 'bobé' 2>&1 >/dev/null || true)"
    if [[ "$rl_err" != *"非法用户名"* ]]; then rl_reject_ok=1; fi
else
    rl_reject_ok=1
fi
if [[ "$rl_reject_ok" -eq 0 ]]; then
    test_pass
else
    test_fail "rl-chpasswd.sh 未拒绝参数数错误/非法用户名(含 é)/root/空 stdin/空密码"
fi

test_start "priv_passwd: 白名单允许并通过 sudo 委托 passwd"
: >"$rl_sudo_log"
: >"$rl_cmd_log"
if priv_passwd -l alice >/dev/null 2>&1 &&
    grep -q "sudo passwd -l alice" "$rl_sudo_log" &&
    grep -q "passwd -l alice" "$rl_cmd_log"; then
    test_pass
else
    test_fail "priv_passwd 未通过白名单或未委托 passwd"
fi

test_start "priv_chage: 白名单允许并通过 sudo 委托账户过期设置"
: >"$rl_sudo_log"
: >"$rl_cmd_log"
if declare -F priv_chage >/dev/null 2>&1 &&
    priv_chage -E 0 alice >/dev/null 2>&1 &&
    priv_chage -E -1 alice >/dev/null 2>&1 &&
    grep -q "sudo chage -E 0 alice" "$rl_sudo_log" &&
    grep -q "sudo chage -E -1 alice" "$rl_sudo_log" &&
    grep -q "chage -E 0 alice" "$rl_cmd_log" &&
    grep -q "chage -E -1 alice" "$rl_cmd_log"; then
    test_pass
else
    test_fail "priv_chage 不存在或未委托 chage"
fi

test_start "priv_smbpasswd / priv_pdbedit: 白名单允许并通过 sudo 委托 Samba 命令"
: >"$rl_sudo_log"
: >"$rl_cmd_log"
if declare -F priv_smbpasswd >/dev/null 2>&1 &&
    declare -F priv_pdbedit >/dev/null 2>&1 &&
    printf 'Secret123!\nSecret123!\n' | priv_smbpasswd -a -s alice >/dev/null 2>&1 &&
    priv_smbpasswd -d alice >/dev/null 2>&1 &&
    priv_smbpasswd -e alice >/dev/null 2>&1 &&
    priv_pdbedit -L alice >/dev/null 2>&1 &&
    grep -q "sudo smbpasswd -a -s alice" "$rl_sudo_log" &&
    grep -q "sudo smbpasswd -d alice" "$rl_sudo_log" &&
    grep -q "sudo smbpasswd -e alice" "$rl_sudo_log" &&
    grep -q "sudo pdbedit -L alice" "$rl_sudo_log" &&
    grep -q "smbpasswd -a -s alice" "$rl_cmd_log" &&
    grep -q "smbpasswd -d alice" "$rl_cmd_log" &&
    grep -q "smbpasswd -e alice" "$rl_cmd_log" &&
    grep -q "pdbedit -L alice" "$rl_cmd_log"; then
    test_pass
else
    test_fail "priv_smbpasswd 或 priv_pdbedit 未通过白名单委托 Samba 命令"
fi

test_start "priv_gzip / priv_gunzip: 白名单允许并委托压缩命令"
: >"$rl_sudo_log"
: >"$rl_cmd_log"
if priv_gzip -f "$TEST_TMPDIR/archive.log" >/dev/null 2>&1 &&
    priv_gunzip -f "$TEST_TMPDIR/archive.log.gz" >/dev/null 2>&1 &&
    grep -q "sudo gzip -f $TEST_TMPDIR/archive.log" "$rl_sudo_log" &&
    grep -q "sudo gunzip -f $TEST_TMPDIR/archive.log.gz" "$rl_sudo_log" &&
    grep -q "gzip -f $TEST_TMPDIR/archive.log" "$rl_cmd_log" &&
    grep -q "gunzip -f $TEST_TMPDIR/archive.log.gz" "$rl_cmd_log"; then
    test_pass
else
    test_fail "priv_gzip 或 priv_gunzip 未通过白名单委托"
fi

test_start "priv_deluser: 函数存在并委托 deluser/userdel"
: >"$rl_sudo_log"
: >"$rl_cmd_log"
if declare -F priv_deluser >/dev/null 2>&1 &&
    priv_deluser alice sudo >/dev/null 2>&1 &&
    { grep -q "sudo deluser alice sudo" "$rl_sudo_log" || grep -q "sudo userdel alice sudo" "$rl_sudo_log"; } &&
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
: >"$rl_sudo_log"
: >"$rl_cmd_log"
priv_sudo() {
    printf 'priv_sudo %s\n' "$*" >>"$rl_cmd_log"
    return 1
}
id() { [[ "${1:-}" == "alice" ]]; }
if as_user alice true >/dev/null 2>&1 &&
    grep -q "sudo -u alice true" "$rl_sudo_log" &&
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
    check_permission user create &&
        rl_mock_permission_level="$ACL_LEVEL_USER" &&
        ! check_permission user create &&
        check_permission user update &&
        rl_mock_permission_level="$ACL_LEVEL_GUEST" &&
        check_permission user read &&
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
