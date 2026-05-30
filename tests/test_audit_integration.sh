#!/bin/bash
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$TEST_DIR")"

export SUDO_NONINTERACTIVE="${SUDO_NONINTERACTIVE:-1}"
export USER_MANAGER_DATA_BASE="${USER_MANAGER_DATA_BASE:-$PROJECT_ROOT/data}"
export USER_MANAGER_BACKUP_ROOT="${USER_MANAGER_BACKUP_ROOT:-$PROJECT_ROOT/data/backup}"

test_data_dir="/tmp/test_audit_data_$$"
export DATA_DIR="$test_data_dir"

fake_bin_dir="$(mktemp -d)"
logger_capture="$test_data_dir/logger_capture.log"
logger_args_capture="$test_data_dir/logger_args.log"
systemd_capture="$test_data_dir/systemd_capture.log"
systemd_args_capture="$test_data_dir/systemd_args.log"
export PATH="$fake_bin_dir:$PATH"

source "$PROJECT_ROOT/tests/test_framework.sh"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/audit_core.sh"

write_fake_logger() {
    local exit_code="${1:-0}"
    cat > "$fake_bin_dir/logger" <<EOF
#!/bin/bash
printf '%s\n' "\$*" > "$logger_args_capture"
cat > "$logger_capture"
exit $exit_code
EOF
    chmod +x "$fake_bin_dir/logger"
}

write_fake_systemd_cat() {
    local exit_code="${1:-0}"
    cat > "$fake_bin_dir/systemd-cat" <<EOF
#!/bin/bash
printf '%s\n' "\$*" > "$systemd_args_capture"
cat > "$systemd_capture"
exit $exit_code
EOF
    chmod +x "$fake_bin_dir/systemd-cat"
}

reset_fake_journal_tools() {
    rm -f "$fake_bin_dir/logger" "$fake_bin_dir/systemd-cat"
    rm -f "$logger_capture" "$logger_args_capture" "$systemd_capture" "$systemd_args_capture"
}

test_suite_start "Audit System Integration"

test_start "audit_init creates log directory"
if audit_init && [[ -d "$AUDIT_LOG_DIR" ]]; then
    test_pass
else
    test_fail "审计目录创建失败"
fi

test_start "audit_log writes to file"
audit_log "TEST_OP" "test_target" "SUCCESS" "test details"
if [[ -f "$AUDIT_LOG_FILE" ]] && grep -q "TEST_OP" "$AUDIT_LOG_FILE"; then
    test_pass
else
    test_fail "审计日志写入失败"
fi

test_start "audit_log appends detailed context"
audit_log "DETAIL_TEST" "detail_target" "SUCCESS" "detail text" "alice"
detail_line="$(grep 'DETAIL_TEST' "$AUDIT_LOG_FILE" | tail -1)"
if [[ "$detail_line" == *"context{"* ]] && \
   [[ "$detail_line" == *"pid="* ]] && \
   [[ "$detail_line" == *"cwd="* ]] && \
   [[ "$detail_line" == *"source_ip="* ]]; then
    test_pass
else
    test_fail "审计日志缺少详细上下文: $detail_line"
fi

test_start "audit_success records success"
audit_success "SUCCESS_TEST" "success_target"
if grep -q "SUCCESS" "$AUDIT_LOG_FILE"; then
    test_pass
else
    test_fail "审计成功记录失败"
fi

test_start "audit_failure records failure"
audit_failure "FAILURE_TEST" "failure_target"
if grep -q "FAILURE" "$AUDIT_LOG_FILE"; then
    test_pass
else
    test_fail "审计失败记录失败"
fi

test_start "audit_backend_mode defaults to file"
unset AUDIT_LOG_BACKEND USER_MANAGER_AUDIT_BACKEND
if [[ "$(audit_backend_mode)" == "file" ]]; then
    test_pass
else
    test_fail "默认后端不是 file"
fi

test_start "audit_backend_mode accepts journald and both"
AUDIT_LOG_BACKEND="journald"
mode_one="$(audit_backend_mode)"
AUDIT_LOG_BACKEND="both"
mode_two="$(audit_backend_mode)"
if [[ "$mode_one" == "journald" && "$mode_two" == "both" ]]; then
    test_pass
else
    test_fail "后端模式解析失败"
fi
unset AUDIT_LOG_BACKEND USER_MANAGER_AUDIT_BACKEND

test_start "audit_build_journal_fields includes required keys"
journal_payload="$(audit_build_journal_fields "CREATE" "demo" "SUCCESS" "created account" "alice" "host=test-host;pid=123;ppid=45;actor=alice;uid=1000;euid=0;sudo_user=root;logname=alice;cwd=/srv/app;tty=pts/1;source_ip=10.0.0.8;session=7;shell=/bin/bash")"
if [[ "$journal_payload" == *$'MESSAGE=created account'* ]] \
    && [[ "$journal_payload" == *$'PRIORITY=6'* ]] \
    && [[ "$journal_payload" == *$'USERMGR_ACTION=CREATE'* ]] \
    && [[ "$journal_payload" == *$'TARGET=demo'* ]] \
    && [[ "$journal_payload" == *$'RESULT=SUCCESS'* ]] \
    && [[ "$journal_payload" == *$'ACTOR=alice'* ]] \
    && [[ "$journal_payload" == *$'USERMGR_PID=123'* ]] \
    && [[ "$journal_payload" == *$'USERMGR_CWD=/srv/app'* ]] \
    && [[ "$journal_payload" == *$'USERMGR_SOURCE_IP=10.0.0.8'* ]]; then
    test_pass
else
    test_fail "journald 字段不完整"
fi

test_start "audit_write_journal_entry prefers logger journald"
reset_fake_journal_tools
write_fake_logger 0
write_fake_systemd_cat 0
payload="$(audit_build_journal_fields "UPDATE" "target-a" "SUCCESS" "detail-a" "bob")"
if audit_write_journal_entry "$payload" && [[ -f "$logger_capture" ]] && grep -q -- "--journald" "$logger_args_capture" && [[ ! -f "$systemd_capture" ]]; then
    test_pass
else
    test_fail "未优先使用 logger --journald"
fi

test_start "audit_write_journal_entry falls back to systemd-cat"
reset_fake_journal_tools
write_fake_logger 1
write_fake_systemd_cat 0
payload="$(audit_build_journal_fields "DELETE" "target-b" "FAILURE" "detail-b" "carol")"
if audit_write_journal_entry "$payload" && [[ -f "$systemd_capture" ]] && grep -q "DELETE" "$systemd_capture"; then
    test_pass
else
    test_fail "systemd-cat fallback 失败"
fi

test_start "audit_log writes file and journald in both mode"
reset_fake_journal_tools
write_fake_logger 0
AUDIT_LOG_BACKEND="both"
audit_log "BOTH_TEST" "target-c" "SUCCESS" "detail-c" "dave"
if grep -q "BOTH_TEST" "$AUDIT_LOG_FILE" && [[ -f "$logger_capture" ]] && grep -q "USERMGR_ACTION=BOTH_TEST" "$logger_capture"; then
    test_pass
else
    test_fail "both 模式未同时写入 file 和 journald"
fi
unset AUDIT_LOG_BACKEND USER_MANAGER_AUDIT_BACKEND

reset_fake_journal_tools
rm -rf "$fake_bin_dir"
rm -rf "$test_data_dir"
test_suite_end
