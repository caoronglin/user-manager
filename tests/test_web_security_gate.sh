#!/bin/bash
# tests/test_web_security_gate.sh — 验证 `scripts/check_web_security.sh` 门禁逻辑（plan.md 14.1-14.3）
#
# 该门禁是 P1 中**当前环境可完整验证**的安全子项：确认 Web Rust 源码（去注释、词边界）
# 不含提权/系统管理命令/任意进程派生；并确认注释与合法标识符（如 axum 的
# with_graceful_shutdown）不会误报。

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/test_framework.sh"
setup_test_env
test_suite_start "Web security gate"

GATE="$PROJECT_ROOT/scripts/check_web_security.sh"

test_start "门禁脚本存在且可执行"
if [[ -x "$GATE" ]]; then
    test_pass
else test_fail "缺少可执行的 check_web_security.sh"; fi

test_start "真实骨架 web/backend/src 通过门禁"
if bash "$GATE" "$PROJECT_ROOT/web/backend/src" >/dev/null 2>&1; then
    test_pass
else test_fail "骨架源码未通过自身门禁"; fi

test_start "干净源码通过"
mkdir -p "$TEST_TMPDIR/src"
printf 'fn main() { let x = 1 + 1; println!("{}", x); }\n' >"$TEST_TMPDIR/src/ok.rs"
if bash "$GATE" "$TEST_TMPDIR/src" >/dev/null 2>&1; then
    test_pass
else test_fail "干净源码被误判"; fi

test_start "注释中的禁止词不触发（先剥注释）"
mkdir -p "$TEST_TMPDIR/src_c"
printf '// sudo systemctl useradd Command::new setuid\nfn f() {}\n' >"$TEST_TMPDIR/src_c/only_comment.rs"
if bash "$GATE" "$TEST_TMPDIR/src_c" >/dev/null 2>&1; then
    test_pass
else test_fail "注释内容被误判为违规"; fi

test_start "代码中的进程派生被捕获（Command::new）"
mkdir -p "$TEST_TMPDIR/src_bad"
printf 'fn f() { let _ = std::process::Command::new("/bin/sh"); }\n' >"$TEST_TMPDIR/src_bad/cmd.rs"
if ! bash "$GATE" "$TEST_TMPDIR/src_bad" >/dev/null 2>&1; then
    test_pass
else test_fail "Command::new 未被捕获"; fi

test_start "代码中的系统命令 token 被捕获（systemctl）"
mkdir -p "$TEST_TMPDIR/src_sys"
printf 'fn f() { let s = "systemctl restart x"; }\n' >"$TEST_TMPDIR/src_sys/sys.rs"
if ! bash "$GATE" "$TEST_TMPDIR/src_sys" >/dev/null 2>&1; then
    test_pass
else test_fail "systemctl token 未被捕获"; fi

test_start "合法标识符 with_graceful_shutdown 不误报（词边界）"
mkdir -p "$TEST_TMPDIR/src_api"
printf 'async fn go() { axum::serve(l, app).with_graceful_shutdown(sig()).await; }\n' >"$TEST_TMPDIR/src_api/api.rs"
if bash "$GATE" "$TEST_TMPDIR/src_api" >/dev/null 2>&1; then
    test_pass
else test_fail "with_graceful_shutdown 被误报"; fi

test_start "空目录不得空转通过（门禁失效必须报错）"
# 回归缺陷：目录存在但没有任何 .rs 时，脚本曾打印 OK 并返回 0，
# 使「源码被清空 / 路径传错」与「源码干净」不可区分。
mkdir -p "$TEST_TMPDIR/src_empty"
if bash "$GATE" "$TEST_TMPDIR/src_empty" >/dev/null 2>&1; then
    test_fail "空目录被静默判为通过（门禁空转）"
else test_pass; fi

test_start "目录不存在时返回 2（跳过语义，供 CI 区分）"
if bash "$GATE" "$TEST_TMPDIR/does_not_exist" >/dev/null 2>&1; then
    test_fail "缺失目录未按跳过语义处理"
else
    rc=$?
    if [[ "$rc" -eq 2 ]]; then test_pass; else test_fail "缺失目录退出码应为 2，实际 $rc"; fi
fi

cleanup_test_env
test_suite_end
