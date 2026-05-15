#!/bin/bash
# test_proc_manager.sh - 进程管理器安全与可靠性测试
# shellcheck disable=SC1091

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"

setup_test_env

export PROC_RUN_DIR="$TEST_TMPDIR/run"
export LOG_DIR="$TEST_TMPDIR/logs"

source "$PROJECT_ROOT/lib/proc_manager.sh"

json_get() {
    local file="$1"
    local field="$2"

    if command -v jq &>/dev/null; then
        jq -r --arg field "$field" '.[$field] // empty' "$file"
    elif command -v python3 &>/dev/null; then
        python3 - "$file" "$field" <<'PY'
import json
import sys

with open(sys.argv[1], 'r', encoding='utf-8') as fh:
    data = json.load(fh)

value = data.get(sys.argv[2], '')
if value is None:
    value = ''
print(value)
PY
    else
        awk -v field="$field" '
            match($0, "^[[:space:]]*\"" field "\"[[:space:]]*:[[:space:]]*") {
                value = substr($0, RLENGTH + 1)
                sub(/[[:space:]]*,?[[:space:]]*$/, "", value)
                if (value ~ /^"/) {
                    sub(/^"/, "", value)
                    sub(/"$/, "", value)
                    gsub(/\\n/, "\n", value)
                    gsub(/\\r/, "\r", value)
                    gsub(/\\t/, "\t", value)
                    gsub(/\\"/, "\"", value)
                    gsub(/\\\\/, "\\", value)
                }
                print value
                exit
            }
        ' "$file"
    fi
}

test_suite_start "Proc Manager Security"

test_start "proc_manager: 源码中不再使用 eval"
if ! grep -Eq '(^|[^[:alnum:]_])eval[[:space:]]' "$PROJECT_ROOT/lib/proc_manager.sh"; then
    test_pass
else
    test_fail "proc_manager.sh 仍包含 eval"
fi

test_start "proc_init: 支持通过 PROC_RUN_DIR 重定向运行目录"
assert_dir_exists "$PROC_PID_DIR" "应在测试临时目录下创建 PID 目录"

test_start "proc_update_status: 保留包含空格和冒号的字段"
proc_id="proc_parse_case"
pid_file="$PROC_PID_DIR/${proc_id}.json"
cat > "$pid_file" <<'EOF'
{
  "id": "proc_parse_case",
  "name": "nightly backup",
  "pid": 4321,
  "description": "task: nightly backup",
  "status": "running",
  "started_at": "2026-04-19 12:00:00",
  "timeout_at": "2026-04-19 13:00:00",
  "parent_pid": 99
}
EOF

if proc_update_status "$proc_id" "$PROC_STATUS_COMPLETED" "done: ok"; then
    updated_name=$(json_get "$pid_file" "name")
    updated_description=$(json_get "$pid_file" "description")
    updated_extra=$(json_get "$pid_file" "extra")

    if [[ "$updated_name" == "nightly backup" && "$updated_description" == "task: nightly backup" && "$updated_extra" == "done: ok" ]]; then
        test_pass
    else
        test_fail "字段被错误截断: name='$updated_name' description='$updated_description' extra='$updated_extra'"
    fi
else
    test_fail "proc_update_status 执行失败"
fi

test_start "proc_update_status: 不执行 JSON 字段中的命令替换"
proc_id="proc_injection_case"
pid_file="$PROC_PID_DIR/${proc_id}.json"
marker_file="$TEST_TMPDIR/eval_marker"
cat > "$pid_file" <<EOF
{
  "id": "proc_injection_case",
  "name": "\$(touch $marker_file)",
  "pid": 5678,
  "description": "literal",
  "status": "running",
  "started_at": "2026-04-19 12:00:00",
  "timeout_at": "2026-04-19 13:00:00",
  "parent_pid": 100
}
EOF

if proc_update_status "$proc_id" "$PROC_STATUS_FAILED" "safe"; then
    if [[ ! -f "$marker_file" ]]; then
        test_pass
    else
        test_fail "检测到命令注入副作用: $marker_file"
    fi
else
    test_fail "proc_update_status 执行失败"
fi

test_start "proc_update_status: 无 jq/python3 时仍可使用 shell fallback"
proc_id="proc_fallback_case"
pid_file="$PROC_PID_DIR/${proc_id}.json"
cat > "$pid_file" <<'EOF'
{
  "id": "proc_fallback_case",
  "name": "fallback worker",
  "pid": 6789,
  "description": "fallback: shell only",
  "status": "running",
  "started_at": "2026-04-19 12:00:00",
  "timeout_at": "2026-04-19 13:00:00",
  "parent_pid": 101
}
EOF

fallback_bin="$TEST_TMPDIR/fallback_bin"
mkdir -p "$fallback_bin"
for cmd in awk date mktemp mv rm mkdir chmod; do
    ln -sf "$(command -v "$cmd")" "$fallback_bin/$cmd"
done

original_path="$PATH"
PATH="$fallback_bin"
if proc_update_status "$proc_id" "$PROC_STATUS_COMPLETED" "fallback ok"; then
    PATH="$original_path"
    fallback_name=$(json_get "$pid_file" "name")
    fallback_extra=$(json_get "$pid_file" "extra")
    if [[ "$fallback_name" == "fallback worker" && "$fallback_extra" == "fallback ok" ]]; then
        test_pass
    else
        test_fail "shell fallback 写回结果不正确: name='$fallback_name' extra='$fallback_extra'"
    fi
else
    PATH="$original_path"
    test_fail "shell fallback 执行失败"
fi

test_start "proc_start: 可执行当前 shell 中定义的函数"
helper_marker="$TEST_TMPDIR/proc_helper_marker"
# shellcheck disable=SC2317
proc_test_helper() {
    printf 'ok' > "$helper_marker"
}

proc_id="$(proc_start "proc_helper" "proc_test_helper" 5 2>/dev/null || true)"
if [[ -n "$proc_id" ]] && proc_wait "$proc_id" 5 >/dev/null 2>&1 && [[ -f "$helper_marker" ]]; then
    test_pass
else
    test_fail "proc_start 未能执行当前 shell 函数"
fi
unset -f proc_test_helper

cleanup_test_env

test_suite_end
