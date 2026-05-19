#!/bin/bash
# test_security_baseline_core.sh - SSH/fail2ban 安全基线模块测试
# shellcheck disable=SC1091

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"

setup_test_env

export TEST_BIN_DIR="$TEST_TMPDIR/bin"
mkdir -p "$TEST_BIN_DIR"
export PATH="$TEST_BIN_DIR:$PATH"

export SECURITY_BASELINE_ETC_DIR="$TEST_TMPDIR/etc"
export SECURITY_BASELINE_SSH_CONFIG="$SECURITY_BASELINE_ETC_DIR/ssh/sshd_config"
export SECURITY_BASELINE_SSHD_DROPIN_DIR="$SECURITY_BASELINE_ETC_DIR/ssh/sshd_config.d"
export SECURITY_BASELINE_FAIL2BAN_JAIL_DIR="$SECURITY_BASELINE_ETC_DIR/fail2ban/jail.d"

mkdir -p "$SECURITY_BASELINE_SSHD_DROPIN_DIR" "$SECURITY_BASELINE_FAIL2BAN_JAIL_DIR"

cat > "$SECURITY_BASELINE_SSH_CONFIG" <<'EOF'
# base
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication no
Include /ignored/by/test/*.conf
EOF

cat > "$SECURITY_BASELINE_SSHD_DROPIN_DIR/00-base.conf" <<'EOF'
PasswordAuthentication no
EOF

cat > "$SECURITY_BASELINE_SSHD_DROPIN_DIR/99-hardening.conf" <<'EOF'
PermitRootLogin prohibit-password
PubkeyAuthentication yes
EOF

cat > "$TEST_BIN_DIR/fail2ban-client" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_TMPDIR/fail2ban-client.log"
if [[ "$1" == "status" && $# -eq 1 ]]; then
    cat <<'OUT'
Status
|- Number of jail: 3
`- Jail list: sshd, recidive
OUT
elif [[ "$1" == "status" && "$2" == "sshd" ]]; then
    cat <<'OUT'
Status for the jail: sshd
|- Filter
|  |- Currently failed: 2
|  `- Total failed: 12
`- Actions
   |- Currently banned: 1
   `- Total banned: 3
OUT
else
    exit 1
fi
EOF
chmod +x "$TEST_BIN_DIR/fail2ban-client"

cat > "$TEST_BIN_DIR/systemctl" <<'EOF'
#!/bin/bash
if [[ "$1" == "is-enabled" ]]; then
    echo enabled
elif [[ "$1" == "is-active" ]]; then
    echo active
elif [[ "$1" == "status" ]]; then
    echo "Active: active (running)"
elif [[ "$1" == "enable" ]]; then
    printf 'enable %s\n' "$*" >> "$TEST_TMPDIR/systemctl.log"
elif [[ "$1" == "restart" ]]; then
    printf 'restart %s\n' "$*" >> "$TEST_TMPDIR/systemctl.log"
else
    exit 1
fi
EOF
chmod +x "$TEST_BIN_DIR/systemctl"

cat > "$TEST_BIN_DIR/journalctl" <<'EOF'
#!/bin/bash
cat <<'OUT'
Apr 20 10:00:00 host sshd[111]: Failed password for invalid user admin from 203.0.113.10 port 55001 ssh2
Apr 20 10:01:00 host sshd[112]: Connection closed by authenticating user root 203.0.113.11 port 55002 [preauth]
OUT
EOF
chmod +x "$TEST_BIN_DIR/journalctl"

source "$PROJECT_ROOT/lib/security_baseline_core.sh"

test_suite_start "Security Baseline Core"

test_start "模块可加载并导出核心函数"
if declare -F security_baseline_get_sshd_effective_value >/dev/null && \
   declare -F security_baseline_show_fail2ban_status >/dev/null && \
   declare -F security_baseline_write_fail2ban_sshd_jail >/dev/null && \
   declare -F security_baseline_fail2ban_list_jails >/dev/null; then
    test_pass
else
    test_fail "security_baseline_core.sh 未正确导出核心函数"
fi

test_start "解析 sshd_config 与 sshd_config.d 最终关键项"
permit_value="$(security_baseline_get_sshd_effective_value PermitRootLogin)"
password_value="$(security_baseline_get_sshd_effective_value PasswordAuthentication)"
pubkey_value="$(security_baseline_get_sshd_effective_value PubkeyAuthentication)"
if [[ "$permit_value" == "prohibit-password" && "$password_value" == "no" && "$pubkey_value" == "yes" ]]; then
    test_pass
else
    test_fail "解析结果不正确: PermitRootLogin=$permit_value PasswordAuthentication=$password_value PubkeyAuthentication=$pubkey_value"
fi

test_start "生成 sshd 安全基线摘要"
summary_output="$(security_baseline_sshd_summary)"
if [[ "$summary_output" == *"PermitRootLogin=prohibit-password"* ]] && [[ "$summary_output" == *"PasswordAuthentication=no"* ]] && [[ "$summary_output" == *"PubkeyAuthentication=yes"* ]]; then
    test_pass
else
    test_fail "sshd 摘要未包含预期关键项"
fi

test_start "写入最小 fail2ban sshd jail 配置"
if security_baseline_write_fail2ban_sshd_jail "600" "600" "5m" >/dev/null 2>&1; then
    jail_file="$SECURITY_BASELINE_FAIL2BAN_JAIL_DIR/sshd.local"
    if [[ -f "$jail_file" ]] && grep -q '^enabled = true$' "$jail_file" && grep -q '^maxretry = 5$' "$jail_file"; then
        test_pass
    else
        test_fail "jail 文件不存在或内容不正确"
    fi
else
    test_fail "写入 fail2ban sshd jail 失败"
fi

test_start "应用 jail 时触发 fail2ban enable 与 restart"
rm -f "$TEST_TMPDIR/systemctl.log"
if security_baseline_configure_fail2ban_sshd_jail "600" "600" "5m" >/dev/null 2>&1; then
    systemctl_log="$(<"$TEST_TMPDIR/systemctl.log")"
    if [[ "$systemctl_log" == *"enable enable fail2ban"* ]] && [[ "$systemctl_log" == *"restart restart fail2ban"* ]]; then
        test_pass
    else
        test_fail "未记录预期的 systemctl enable/restart"
    fi
else
    test_fail "配置 fail2ban sshd jail 失败"
fi

test_start "展示 fail2ban 状态输出包含 sshd jail 信息"
status_output="$(security_baseline_show_fail2ban_status)"
if [[ "$status_output" == *"Jail list: sshd"* ]] && [[ "$status_output" == *"Currently banned: 1"* ]]; then
    test_pass
else
    test_fail "fail2ban 状态输出不完整"
fi

test_start "列出全部 fail2ban jail 名称"
jail_list_output="$(security_baseline_fail2ban_list_jails)"
if [[ "$jail_list_output" == $'sshd\nrecidive' ]]; then
    test_pass
else
    test_fail "jail 列表解析不正确: $jail_list_output"
fi

test_start "查看指定 fail2ban jail 状态"
target_jail_output="$(security_baseline_fail2ban_show_jail_status sshd)"
if [[ "$target_jail_output" == *"Status for the jail: sshd"* ]] && [[ "$target_jail_output" == *"Currently banned: 1"* ]]; then
    test_pass
else
    test_fail "指定 jail 状态输出不正确"
fi

test_start "查看 sshd jail 状态 helper"
sshd_status_output="$(security_baseline_fail2ban_show_sshd_status)"
if [[ "$sshd_status_output" == *"Status for the jail: sshd"* ]]; then
    test_pass
else
    test_fail "sshd jail helper 未返回预期状态"
fi

test_start "查看最近认证失败优先读取 journalctl"
auth_output="$(security_baseline_show_recent_auth_failures 5)"
if [[ "$auth_output" == *"Failed password for invalid user admin"* ]]; then
    test_pass
else
    test_fail "未读取到预期认证失败日志"
fi

cleanup_test_env

test_suite_end
