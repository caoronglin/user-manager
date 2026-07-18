#!/bin/bash
# test_smb_core.sh - SMB/Samba 同步核心测试
# shellcheck disable=SC2218,SC2123,SC2034

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"

setup_test_env

source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/config.sh"
source "$PROJECT_ROOT/lib/smb_core.sh"

rl_smb_bin_dir="$TEST_TMPDIR/bin"
rl_smb_log="$TEST_TMPDIR/smb_calls.log"
mkdir -p "$rl_smb_bin_dir"
: > "$rl_smb_log"

cat > "$rl_smb_bin_dir/smbpasswd" <<'EOS'
#!/bin/bash
exit 0
EOS
chmod +x "$rl_smb_bin_dir/smbpasswd"

old_path="$PATH"
export PATH="$rl_smb_bin_dir:$PATH"

# Stub priv_smbpasswd: first call (-s) fails, second call (-a -s) succeeds
# Controlled by RL_SMBPASSWD_MODE: "existing" = -s succeeds, "new" = -s fails then -a -s succeeds, "fail" = both fail
priv_smbpasswd() {
    printf 'smbpasswd %s\n' "$*" >> "$rl_smb_log"
    local rl_lines=0
    while IFS= read -r _; do
        rl_lines=$((rl_lines + 1))
    done
    if (( rl_lines > 0 )); then
        printf 'stdin-lines:%s\n' "$rl_lines" >> "$rl_smb_log"
    fi
    local mode="${RL_SMBPASSWD_MODE:-existing}"
    local rc="${RL_SMBPASSWD_RC:-0}"
    if [[ "$rc" != "0" ]]; then
        return "$rc"
    fi
    if [[ "$*" == "-s "* ]]; then
        [[ "$mode" == "existing" ]] && return 0
        return 1
    fi
    if [[ "$*" == "-a -s "* ]]; then
        [[ "$mode" == "new" || "$mode" == "fail" ]] && [[ "$mode" != "fail" ]] && return 0
        return 1
    fi
    if [[ "$*" == "-d "* || "$*" == "-e "* ]]; then
        return "${RL_SMBPASSWD_DISABLE_RC:-0}"
    fi
    return 0
}

msg_err() { printf 'ERR:%s\n' "$*"; }
msg_warn() { printf 'WARN:%s\n' "$*"; }

test_suite_start "SMB Core"

test_start "smb_set_password: 无 smbpasswd 时跳过且不调用特权命令"
: > "$rl_smb_log"
no_smb_bin_dir="$TEST_TMPDIR/no-smb-bin"
mkdir -p "$no_smb_bin_dir"
smb_stderr_file="$TEST_TMPDIR/smb_set_password.stderr"
: > "$smb_stderr_file"
PATH="$no_smb_bin_dir"
if smb_set_password alice 'Secret123!' >/dev/null 2>"$smb_stderr_file" && [[ ! -s "$rl_smb_log" ]] && [[ ! -s "$smb_stderr_file" ]]; then
    test_pass
else
    test_fail "无 smbpasswd 时应跳过 SMB 同步且无输出，stderr: $(<"$smb_stderr_file")"
fi
PATH="$rl_smb_bin_dir:$old_path"

test_start "smb_set_password: 已有 SMB 用户时调用 smbpasswd -s"
: > "$rl_smb_log"
RL_SMBPASSWD_MODE=existing
unset RL_SMBPASSWD_RC
if smb_set_password alice 'Secret123!' >/dev/null 2>&1 && \
   grep -q '^smbpasswd -s alice$' "$rl_smb_log" && \
   grep -q '^stdin-lines:2$' "$rl_smb_log" && \
   ! grep -q '^-a -s' "$rl_smb_log"; then
    test_pass
else
    test_fail "已有 SMB 用户时未调用 smbpasswd -s，日志: $(cat "$rl_smb_log")"
fi

test_start "smb_set_password: 新 SMB 用户时回退到 smbpasswd -a -s"
: > "$rl_smb_log"
RL_SMBPASSWD_MODE=new
if smb_set_password alice 'Secret123!' >/dev/null 2>&1 && \
   grep -q '^smbpasswd -s alice$' "$rl_smb_log" && \
   grep -q '^smbpasswd -a -s alice$' "$rl_smb_log"; then
    test_pass
else
    test_fail "新 SMB 用户时未回退到 smbpasswd -a -s，日志: $(cat "$rl_smb_log")"
fi

test_start "smb_set_password: SMB 命令失败时返回失败且输出不含明文密码"
: > "$rl_smb_log"
RL_SMBPASSWD_MODE=fail
RL_SMBPASSWD_RC=7
rl_output="$(smb_set_password alice 'Secret123!' 2>&1 || true)"
if [[ "$rl_output" != *'Secret123!'* ]] && ! smb_set_password alice 'Secret123!' >/dev/null 2>&1; then
    test_pass
else
    test_fail "SMB 失败时应返回失败且不输出明文密码，输出: $rl_output"
fi
unset RL_SMBPASSWD_RC
RL_SMBPASSWD_MODE=existing

test_start "smb_disable_user: 有 smbpasswd 时调用 smbpasswd -d"
: > "$rl_smb_log"
if smb_disable_user alice >/dev/null 2>&1 && grep -q '^smbpasswd -d alice$' "$rl_smb_log"; then
    test_pass
else
    test_fail "未调用 smbpasswd -d alice"
fi

test_start "smb_disable_user: smbpasswd -d 失败时仍返回成功(用户可能不存在)"
: > "$rl_smb_log"
RL_SMBPASSWD_DISABLE_RC=1
if smb_disable_user alice >/dev/null 2>&1; then
    test_pass
else
    test_fail "smbpasswd -d 失败时应返回成功(用户可能不存在)"
fi
unset RL_SMBPASSWD_DISABLE_RC

test_start "smb_enable_existing_user: 调用 smbpasswd -e"
: > "$rl_smb_log"
if smb_enable_existing_user alice >/dev/null 2>&1 && grep -q '^smbpasswd -e alice$' "$rl_smb_log"; then
    test_pass
else
    test_fail "未调用 smbpasswd -e alice"
fi

test_start "smb_enable_existing_user: smbpasswd -e 失败且用户不存在时返回成功"
: > "$rl_smb_log"
# Override priv_smbpasswd to simulate "Failed to find entry"
priv_smbpasswd() {
    printf 'smbpasswd %s\n' "$*" >> "$rl_smb_log"
    if [[ "$*" == "-e "* ]]; then
        echo "Failed to find entry for user" >&2
        return 1
    fi
    return 0
}
if smb_enable_existing_user alice >/dev/null 2>&1; then
    test_pass
else
    test_fail "smbpasswd -e 失败且用户不存在时应返回成功"
fi

test_start "_smb_sync_password: smb_core 未加载时静默返回0"
# Temporarily undef smb_set_password
unset -f smb_set_password 2>/dev/null || true
if _smb_sync_password alice 'Secret123!' 2>/dev/null; then
    test_pass
else
    test_fail "_smb_sync_password 在 smb_set_password 未定义时应返回0"
fi
# Restore by re-sourcing
source "$PROJECT_ROOT/lib/smb_core.sh"

PATH="$old_path"
cleanup_test_env
test_suite_end
