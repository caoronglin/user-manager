#!/bin/bash
# test_runtime_dir_contract.sh - 运行时目录 DATA_DIR / LOG_DIR 注入契约测试
#
# 覆盖 lib/config.sh 的目录覆盖契约：
#   - 默认值与历史行为一致（<repo>/data、<repo>/logs）
#   - USER_MANAGER_DATA_DIR / USER_MANAGER_LOG_DIR 注入生效，且派生路径跟随
#   - 空值视为未设置并回退默认
#   - 相对路径按「不强制」边界原样接受
#   - init_directories 对不存在的注入路径负责创建，创建失败即返回非 0
#   - USER_MANAGER_DATA_BASE（家目录挂载点根）与 DATA_DIR 互不干扰
#   - source config.sh 不回写 USER_MANAGER_DATA_DIR（:- 而非 := 的意义）
#
# 并发安全：所有断言只在子进程与 $TEST_TMPDIR 内进行，不写 <repo>/data、<repo>/logs，
# 因此可在 run_regression.sh 的 4 路并行下与其他套件共存。
# 契约文档：docs/superpowers/specs/2026-10-02-runtime-dir-injection-design.md

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_SH="$PROJECT_ROOT/lib/config.sh"

# shellcheck source=tests/test_framework.sh
source "$SCRIPT_DIR/test_framework.sh"

setup_test_env

test_suite_start "Runtime Dir Contract"

# 1. 默认值：未注入时回退到源码树内的默认位置，且为绝对路径
test_start '未注入时 DATA_DIR / LOG_DIR 回退到源码树内的默认位置'
default_out="$(env -u USER_MANAGER_DATA_DIR -u USER_MANAGER_LOG_DIR bash -c '
    set -uo pipefail
    source "$1"
    printf "%s\n%s\n%s\n" "$DATA_DIR" "$LOG_DIR" "$REPORT_DIR"
' _ "$CONFIG_SH" 2>/dev/null)"
if [[ "$default_out" == "$PROJECT_ROOT/data"$'\n'"$PROJECT_ROOT/logs"$'\n'"$PROJECT_ROOT/data/report" ]]; then
    test_pass
else
    test_fail "默认取值与预期不符: $default_out"
fi

test_start '默认 DATA_DIR / LOG_DIR 为绝对路径'
if [[ "$default_out" == /* ]]; then
    test_pass
else
    test_fail "默认取值不是绝对路径: $default_out"
fi

# 2. 环境变量注入生效，且派生的数据/日志路径一并跟随
test_start 'USER_MANAGER_DATA_DIR / USER_MANAGER_LOG_DIR 注入后 DATA_DIR / LOG_DIR 跟随'
injected="$TEST_TMPDIR/injected"
mkdir -p "$injected"
inject_out="$(env USER_MANAGER_DATA_DIR="$injected/data" USER_MANAGER_LOG_DIR="$injected/logs" bash -c '
    set -uo pipefail
    source "$1"
    printf "%s\n%s\n%s\n%s\n%s\n" \
        "$DATA_DIR" "$LOG_DIR" "$DISABLED_USERS_FILE" "$SYMLINK_LOG" "$REPORT_DIR"
' _ "$CONFIG_SH" 2>/dev/null)"
expected_inject="$injected/data"$'\n'"$injected/logs"$'\n'"$injected/data/disabled_users.txt"$'\n'"$injected/logs/symlink.log"$'\n'"$injected/data/report"
if [[ "$inject_out" == "$expected_inject" ]]; then
    test_pass
else
    test_fail "注入后取值与预期不符: $inject_out"
fi

# 3. 空值视为未设置
test_start 'USER_MANAGER_DATA_DIR 为空字符串时回退默认值'
empty_out="$(env USER_MANAGER_DATA_DIR= USER_MANAGER_LOG_DIR= bash -c '
    set -uo pipefail
    source "$1"
    printf "%s\n%s\n" "$DATA_DIR" "$LOG_DIR"
' _ "$CONFIG_SH" 2>/dev/null)"
if [[ "$empty_out" == "$PROJECT_ROOT/data"$'\n'"$PROJECT_ROOT/logs" ]]; then
    test_pass
else
    test_fail "空值未回退默认值: $empty_out"
fi

# 4. 相对路径边界：库内不强制绝对路径，原样接受。
# 记录该边界以免后续误以为已强制；若将来要强制，此用例应同步改为断言拒绝。
test_start '相对路径按当前契约被原样接受（库内不强制绝对路径）'
rel_out="$(cd "$TEST_TMPDIR" && env USER_MANAGER_DATA_DIR=relative/data bash -c '
    set -uo pipefail
    source "$1"
    printf "%s\n" "$DATA_DIR"
' _ "$CONFIG_SH" 2>/dev/null)"
if [[ "$rel_out" == "relative/data" ]]; then
    test_pass
else
    test_fail "相对路径取值与契约不符: $rel_out"
fi

# 5. init_directories 对不存在的注入路径负责创建
test_start 'init_directories 为不存在的注入路径创建全部运行时目录'
created="$TEST_TMPDIR/created"
mkdir -p "$created"
if env USER_MANAGER_DATA_DIR="$created/data" USER_MANAGER_LOG_DIR="$created/logs" bash -c '
    set -uo pipefail
    source "$1"
    msg_err() { printf "%s\n" "$1" >&2; }
    init_directories
' _ "$CONFIG_SH" >/dev/null 2>&1 &&
    [[ -d "$created/data" && -d "$created/data/report" && -d "$created/data/job_stats" &&
        -d "$created/data/password_pools" && -d "$created/logs" ]]; then
    test_pass
else
    test_fail "init_directories 未创建全部目录: $(find "$created" -type d 2>/dev/null | tr '\n' ' ')"
fi

# 6. 创建失败必须关闭（返回非 0），不得静默继续
test_start '注入不可创建的路径时 init_directories 返回非 0'
if [[ "$(id -u)" == "0" ]]; then
    # root 会绕过目录权限，该构造不成立；显式跳过而非静默通过。
    test_skip '以 root 运行，权限构造不成立'
else
    readonly_parent="$TEST_TMPDIR/readonly_parent"
    mkdir -p "$readonly_parent"
    chmod 0555 "$readonly_parent"
    rc_output="$(env USER_MANAGER_DATA_DIR="$readonly_parent/data" USER_MANAGER_LOG_DIR="$readonly_parent/logs" bash -c '
        set -uo pipefail
        source "$1"
        msg_err() { printf "%s\n" "$1" >&2; }
        init_directories
        printf "rc=%s\n" "$?"
    ' _ "$CONFIG_SH" 2>/dev/null)"
    chmod 0755 "$readonly_parent"
    if [[ "$rc_output" == "rc=0" ]]; then
        test_fail '不可写父目录下 init_directories 仍返回 0'
    else
        test_pass
    fi
fi

# 7. USER_MANAGER_DATA_BASE 是家目录挂载点根，不得影响 DATA_DIR / LOG_DIR。
# 断言方式是对比「设置」与「不设置」两次运行的目录取值，不断言具体路径：
# run_p1_one 会注入 USER_MANAGER_DATA_DIR，硬编码默认值会把「运行器注入了
# 数据目录」误判为「DATA_BASE 污染了目录契约」。
test_start 'USER_MANAGER_DATA_BASE 不改变 DATA_DIR / LOG_DIR'
probe_dirs() {
    env -u USER_MANAGER_DATA_DIR -u USER_MANAGER_LOG_DIR "$@" bash -c '
        set -uo pipefail
        source "$1"
        printf "%s|%s|%s" "$DATA_DIR" "$LOG_DIR" "$DATA_BASE"
    ' _ "$CONFIG_SH" 2>/dev/null
}
base_absent="$(probe_dirs)"
base_present="$(probe_dirs USER_MANAGER_DATA_BASE="$TEST_TMPDIR/mnt")"
base_absent_dirs="${base_absent%|*}"
base_present_dirs="${base_present%|*}"
base_present_value="${base_present##*|}"
if [[ -n "$base_absent_dirs" && "$base_absent_dirs" == "$base_present_dirs" &&
    "$base_present_value" == "$TEST_TMPDIR/mnt" ]]; then
    test_pass
else
    test_fail "USER_MANAGER_DATA_BASE 污染了目录契约: unset=[$base_absent_dirs] set=[$base_present_dirs]"
fi

# 8. source config.sh 不得创建 USER_MANAGER_DATA_DIR。
# 这是选用 ${VAR:-default} 而非 ${VAR:=default} 的唯一可观测差异：
# := 会在未注入时把默认值回写进环境变量名，之后调用方再改写 DATA_DIR 就与陈旧值脱节。
test_start 'source config.sh 不回写 USER_MANAGER_DATA_DIR（:- 语义）'
writeback_out="$(env -u USER_MANAGER_DATA_DIR bash -c '
    set -uo pipefail
    source "$1"
    if [[ -z "${USER_MANAGER_DATA_DIR+x}" ]]; then
        printf "unset"
    else
        printf "set:%s" "$USER_MANAGER_DATA_DIR"
    fi
' _ "$CONFIG_SH" 2>/dev/null)"
if [[ "$writeback_out" == "unset" ]]; then
    test_pass
else
    test_fail "config.sh 回写了 USER_MANAGER_DATA_DIR: $writeback_out"
fi

# 9. 重复 source 稳定：DATA_DIR 始终由环境变量重新派生，不被上一次的取值污染
test_start '重复 source config.sh 时 DATA_DIR 由环境变量重新派生'
twice_out="$(env USER_MANAGER_DATA_DIR="$TEST_TMPDIR/data" bash -c '
    set -uo pipefail
    source "$1"
    first="$DATA_DIR"
    source "$1"
    printf "%s\n%s\n" "$first" "$DATA_DIR"
' _ "$CONFIG_SH" 2>/dev/null)"
if [[ "$twice_out" == "$TEST_TMPDIR/data"$'\n'"$TEST_TMPDIR/data" ]]; then
    test_pass
else
    test_fail "重复 source 语义不稳定: $twice_out"
fi

test_suite_end
