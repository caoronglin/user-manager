#!/bin/bash
# test_snapshot.sh - P0 Snapshot Contract + Web Security Boundary 测试
#
# 覆盖：schema 信封、secret scrub、原子写、schema 校验、freshness、manifest、
#       采集器端到端，以及「采集器不含特权写命令」的边界检查。
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SNAP_LIB="$PROJECT_ROOT/lib/snapshot_core.sh"
SNAP_GEN="$PROJECT_ROOT/scripts/rl-snapshot.sh"
source "$SCRIPT_DIR/test_framework.sh"
setup_test_env
# 仅加载一次契约库：函数与常量由父 shell 持有，命令替换子 shell 会继承（readonly 不导出，
# 但子 shell 是当前 shell 的 fork，可直接使用，无需也不应在子 shell 内再次 source）。
source "$SNAP_LIB"
test_suite_start "Web Snapshot Contract (P0)"

# 采集器源码中禁止出现的系统写 / 提权命令 token（在非注释代码中）。
# 注意：此处不含裸 `passwd`——它作为 secret 名合法出现在 scrub 正则中；以更精确的 chpasswd 覆盖。
declare -a forbidden_tokens=(
    useradd userdel usermod chpasswd setquota quotaon
    smbpasswd pdbedit visudo systemctl ufw iptables nft
    priv_exec action_run rl-web-exec
)

test_start "快照契约库与采集器存在且采集器可执行"
if [[ -f "$SNAP_LIB" && -f "$SNAP_GEN" && -x "$SNAP_GEN" ]]; then test_pass
else test_fail "缺少 snapshot_core.sh / 可执行的 rl-snapshot.sh"; fi

test_start "采集器源码（去注释）不含特权写/提权命令"
violations=''
# shellcheck disable=SC2016
for tok in "${forbidden_tokens[@]}"; do
    hit="$(grep -vE '^[[:space:]]*#' "$SNAP_LIB" "$SNAP_GEN" 2>/dev/null |
        grep -nE "(^|[^_a-zA-Z.])${tok}([^_a-zA-Z]|$)" || true)"
    [[ -z "$hit" ]] || violations+="${tok} "
done
if [[ -z "$violations" ]]; then test_pass
else test_fail "采集器命中禁止 token: ${violations}"; fi

test_start "契约常量与阈值合理"
if [[ "$SNAPSHOT_SCHEMA_VERSION" =~ ^[0-9]+$ ]] &&
    [[ "$(snapshot_kind_threshold users)" == 300 ]] &&
    [[ "$(snapshot_kind_threshold audit-summary)" == 30 ]] &&
    [[ "$(snapshot_kind_threshold system)" == 60 ]] &&
    snapshot_is_known_kind users &&
    ! snapshot_is_known_kind ../../etc &&
    snapshot_is_filename_safe 'audit-summary' &&
    ! snapshot_is_filename_safe '../evil'; then
    test_pass
else
    test_fail "契约常量/阈值异常"
fi

test_start "build_envelope 构造版本化信封并保留正常字段"
env_out="$(snapshot_build_envelope users local 300 \
    '{"users":[{"username":"alice","home":"/mnt/data01/alice"}],"count":1}')" || env_out=''
if [[ "$(jq -r '.schema_version // empty' <<<"$env_out")" == "$SNAPSHOT_SCHEMA_VERSION" ]] &&
    [[ "$(jq -r '.kind // empty' <<<"$env_out")" == users ]] &&
    [[ "$(jq -r '.data.users[0].username // empty' <<<"$env_out")" == alice ]] &&
    [[ "$(jq -r '.generated_at // empty' <<<"$env_out")" =~ ^[0-9]{4}- ]]; then
    test_pass
else
    test_fail "信封字段异常: $env_out"
fi

test_start "secret scrub：敏感 key 与敏感 value 均脱敏且不回显明文"
# 通过字符串拼接构造私钥标记，避免在受版本控制的测试文件里出现完整私钥头。
pk_marker="-----BEGIN ""RSA PRIVATE KEY-----"
fake_webhook="https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=SECRETKEY123"
scrub_out="$(snapshot_build_envelope smb local 300 "$(jq -cn \
    --arg wh "$fake_webhook" --arg pk "$pk_marker" \
    '{webhook_url: $wh, link: $wh, note: $pk,
      settings: {api_key: "abc", session_id: "xyz", token: "t"},
      keep: "visible-value", nested: {password: "p", ok: 1}}')")" || scrub_out=''
if [[ "$scrub_out" == *"$fake_webhook"* || "$scrub_out" == *SECRETKEY123* ||
    "$scrub_out" == *"$pk_marker"* ]]; then
    test_fail "scrub 后仍存在明文 secret"
elif [[ "$(jq -r '.data.webhook_url // empty' <<<"$scrub_out")" == '***REDACTED***' ]] &&
    [[ "$(jq -r '.data.link // empty' <<<"$scrub_out")" == '***REDACTED_WEBHOOK***' ]] &&
    [[ "$(jq -r '.data.note // empty' <<<"$scrub_out")" == '***REDACTED_KEY***' ]] &&
    [[ "$(jq -r '.data.settings.api_key // empty' <<<"$scrub_out")" == '***REDACTED***' ]] &&
    [[ "$(jq -r '.data.nested.password // empty' <<<"$scrub_out")" == '***REDACTED***' ]] &&
    [[ "$(jq -r '.data.keep // empty' <<<"$scrub_out")" == 'visible-value' ]] &&
    [[ "$(jq -r '.data.nested.ok' <<<"$scrub_out")" == 1 ]]; then
    test_pass
else
    test_fail "scrub 结果异常: $scrub_out"
fi

test_start "validate：合法通过；缺字段/错版本/非对象拒绝"
val_ok=0
(
    set -Eeuo pipefail
    good="$(snapshot_build_envelope users local 300 '{"users":[]}')"
    printf '%s' "$good" | snapshot_validate_json || exit 1
    printf '%s' '{"kind":"users"}' | snapshot_validate_json && exit 1 || true
    bad_ver="$(printf '%s' "$good" | jq '.schema_version = 999')"
    printf '%s' "$bad_ver" | snapshot_validate_json && exit 1 || true
    printf '%s' '[]' | snapshot_validate_json && exit 1 || true
    exit 0
) && val_ok=1
if ((val_ok == 1)); then test_pass
else test_fail "validate 边界判定异常"; fi

# ---- 原子写 / freshness / manifest ----
test_start "atomic_install：写入 0640、无残留临时文件、可原子覆盖"
atomic_res="$(
    set -Eeuo pipefail
    SNAPSHOT_DIR="$TEST_TMPDIR/snapA"
    snapshot_build_envelope users local 300 '{"n":1}' | snapshot_atomic_install users || exit 1
    snapshot_build_envelope users local 300 '{"n":2}' | snapshot_atomic_install users || exit 1
    mode="$(stat -c '%a' "$SNAPSHOT_DIR/users.json")"
    leftovers="$(find "$SNAPSHOT_DIR" -maxdepth 1 -name '.*.json.*' | wc -l)"
    val="$(jq -r '.data.n' "$SNAPSHOT_DIR/users.json")"
    printf '%s|%s|%s' "$mode" "$leftovers" "$val"
)" || atomic_res=''
if [[ "$atomic_res" == '640|0|2' ]]; then test_pass
else test_fail "atomic_install 异常: $atomic_res"; fi

test_start "atomic_install 拒绝路径穿越类型名"
if ! (
    set -Eeuo pipefail
    SNAPSHOT_DIR="$TEST_TMPDIR/snapA"
    printf '{}' | snapshot_atomic_install '../../etc/passwd'
) >/dev/null 2>&1 && [[ ! -e "$TEST_TMPDIR/etc" ]]; then
    test_pass
else
    test_fail "路径穿越类型名未被拒绝"
fi

test_start "freshness：新鲜/过期/缺失三种状态正确"
fresh_res="$(
    set -Eeuo pipefail
    SNAPSHOT_DIR="$TEST_TMPDIR/snapA"
    now="$(date -u +%s)"
    f1="$(snapshot_freshness_json users "$now")"
    old="$(date -u -d "@$((now - 600))" '+%Y-%m-%dT%H:%M:%SZ')"
    jq -c --arg g "$old" '.generated_at = $g' "$SNAPSHOT_DIR/users.json" >"$SNAPSHOT_DIR/quota.json"
    chmod 0640 "$SNAPSHOT_DIR/quota.json"
    f2="$(snapshot_freshness_json quota "$now")"
    f3="$(snapshot_freshness_json system "$now")"
    printf '%s;%s;%s' \
        "$(jq -r '[.present,.fresh,(.age_seconds != null)] | @csv' <<<"$f1")" \
        "$(jq -r '[.present,.fresh] | @csv' <<<"$f2")" \
        "$(jq -r '[.present,.fresh] | @csv' <<<"$f3")"
)" || fresh_res=''
if [[ "$fresh_res" == 'true,true,true;true,false;false,false' ]]; then test_pass
else test_fail "freshness 异常: $fresh_res"; fi

test_start "manifest 聚合元数据且 overall 计算正确"
manifest_res="$(
    set -Eeuo pipefail
    SNAPSHOT_DIR="$TEST_TMPDIR/snapM"
    for k in users quota resources smb hosts gpu system audit-summary; do
        snapshot_emit "$k" local '{}' >/dev/null || exit 1
    done
    snapshot_manifest_write || exit 1
    jq -r '"\(.overall),\(.snapshots|length),\(.snapshots[0].kind)"' "$SNAPSHOT_DIR/manifest.json"
)" || manifest_res=''
if [[ "$manifest_res" == 'fresh,8,users' ]]; then test_pass
else test_fail "manifest 异常: $manifest_res"; fi

# ---- 端到端采集器（新进程，独立 source） ----
test_start "采集器端到端：生成全部快照、目录 0750、无残留临时文件"
e2e_rc=0
env USER_MANAGER_DATA_BASE="$TEST_TMPDIR/data" bash "$SNAP_GEN" \
    --out "$TEST_TMPDIR/snapE2E" >/dev/null 2>&1 || e2e_rc=$?
e2e_ok=1
for k in users quota resources smb hosts gpu system audit-summary manifest; do
    [[ -s "$TEST_TMPDIR/snapE2E/${k}.json" ]] || e2e_ok=0
    jq -e . "$TEST_TMPDIR/snapE2E/${k}.json" >/dev/null 2>&1 || e2e_ok=0
done
dir_mode="$(stat -c '%a' "$TEST_TMPDIR/snapE2E" 2>/dev/null || echo 000)"
tmp_left="$(find "$TEST_TMPDIR/snapE2E" -maxdepth 1 -name '.*.json.*' 2>/dev/null | wc -l)"
if ((e2e_rc == 0 && e2e_ok == 1 && dir_mode == 750 && tmp_left == 0)); then test_pass
else test_fail "e2e 异常 rc=$e2e_rc ok=$e2e_ok mode=$dir_mode tmp=$tmp_left"; fi

test_start "采集器输出全部通过 schema 校验且不含明文私钥"
all_valid=1
secret_leak=0
for k in users quota resources smb hosts gpu system audit-summary; do
    f="$TEST_TMPDIR/snapE2E/${k}.json"
    # shellcheck disable=SC2016
    if ! jq -e --argjson v "$SNAPSHOT_SCHEMA_VERSION" '
        (.schema_version == $v) and (.generated_at|type=="string")
        and (.source|length>0) and has("data")' "$f" >/dev/null 2>&1; then
        all_valid=0
    fi
    if grep -qE '-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----' "$f" 2>/dev/null; then secret_leak=1; fi
done
if ((all_valid == 1 && secret_leak == 0)); then test_pass
else test_fail "快照校验/secret 异常 valid=$all_valid leak=$secret_leak"; fi

test_start "采集器：未知类型返回退出码 2，不产出文件"
unknown_rc=0
env USER_MANAGER_DATA_BASE="$TEST_TMPDIR/data" bash "$SNAP_GEN" \
    --out "$TEST_TMPDIR/snapBad" firewall >/dev/null 2>&1 || unknown_rc=$?
if ((unknown_rc == 2)) && [[ ! -e "$TEST_TMPDIR/snapBad/firewall.json" ]]; then test_pass
else test_fail "未知类型未按预期拒绝 rc=$unknown_rc"; fi

test_start "采集器：--dry-run 打印信封且不落盘"
dry_out="$(env USER_MANAGER_DATA_BASE="$TEST_TMPDIR/data" bash "$SNAP_GEN" \
    --out "$TEST_TMPDIR/snapDry" --dry-run users 2>/dev/null || true)"
if [[ "$dry_out" == *'"kind":"users"'* || "$dry_out" == *'"kind": "users"'* ]] &&
    [[ ! -e "$TEST_TMPDIR/snapDry/users.json" ]]; then
    test_pass
else
    test_fail "dry-run 异常: $dry_out"
fi

test_start "采集器：--manifest-only 仅刷新 manifest，不重写业务快照"
mo_rc=0
before="$TEST_TMPDIR/snapE2E/users.json"
mtime_before="$(stat -c '%Y' "$before")"
sleep 1
env USER_MANAGER_DATA_BASE="$TEST_TMPDIR/data" bash "$SNAP_GEN" \
    --out "$TEST_TMPDIR/snapE2E" --manifest-only >/dev/null 2>&1 || mo_rc=$?
mtime_after="$(stat -c '%Y' "$before")"
if ((mo_rc == 0 && mtime_before == mtime_after)) && [[ -s "$TEST_TMPDIR/snapE2E/manifest.json" ]]; then
    test_pass
else
    test_fail "manifest-only 异常 rc=$mo_rc mtime $mtime_before->$mtime_after"
fi

test_start "REMOTE_HOSTS 边界未变：仍仅 host.probe / gpu.summary"
remote_entry="$PROJECT_ROOT/scripts/rl-remote-entry.sh"
boundary_ok=1
bash "$remote_entry" host.probe >/dev/null 2>&1 || boundary_ok=0
if bash "$remote_entry" users.create >/dev/null 2>&1; then boundary_ok=0; fi
if bash "$remote_entry" 'host.probe;id' >/dev/null 2>&1; then boundary_ok=0; fi
if ((boundary_ok == 1)); then test_pass
else test_fail "REMOTE_HOSTS 白名单边界被破坏"; fi

cleanup_test_env
test_suite_end
