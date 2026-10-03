#!/bin/bash
# A1-priv-whitelist.sh - 场景 A1：消融 priv_exec 的 PRIV_CMD_WHITELIST 门禁
# 守卫位置：lib/privilege.sh:166-170
# 消融方法：方法1（复制 lib/+scripts/ 到 .validation 隔离副本后用 sed 删除白名单检查块）
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ab_common.sh"

BASE=$(ab_prepare A1-baseline lib scripts)
ABL=$(ab_prepare A1-ablated lib scripts)
ab_ablate "$ABL/lib/privilege.sh" '/if ! priv_check_whitelist "$cmd"; then/,/^        fi$/d' || exit 3

ab_probe "$BASE/probe.sh" <<'PEOF'
set -uo pipefail
D="$1"
export USER_MANAGER_DATA_BASE="$D/data"
export ACL_AUDIT_LOG="$D/data/logs/audit.log"
export AB_STUB_LOG="$D/stub.log"
rm -f "$AB_STUB_LOG"; mkdir -p "$D/data/logs" "$D/stub"
cat > "$D/stub/curl" <<'EOS'
#!/bin/bash
printf 'curl %s
' "$*" >> "$AB_STUB_LOG"
EOS
cat > "$D/stub/sudo" <<'EOS'
#!/bin/bash
[[ "${1:-}" == "-n" ]] && shift
printf 'sudo %s
' "$*" >> "$AB_STUB_LOG"
exec "$@"
EOS
chmod +x "$D/stub/curl" "$D/stub/sudo"
export PATH="$D/stub:$PATH"
source "$D/lib/config.sh" >/dev/null 2>&1
source "$D/lib/common.sh"
source "$D/lib/access_control.sh"
source "$D/lib/privilege.sh"
acl_get_current_level() { echo 0; }
priv_exec curl "http://example.invalid/x" >/dev/null 2>"$D/err.txt"
rc=$?
printf 'rc=%s\n' "$rc"
printf 'deny_msg=%s\n' "$(tr -d '\r' < "$D/err.txt" | sed 's/\x1b\[[0-9;]*m//g' | tr '\n' ' ')"
if [[ -s "$AB_STUB_LOG" ]]; then
  printf 'EXECUTED=yes log=%s\n' "$(tr '\n' ';' < "$AB_STUB_LOG")"
else
  printf 'EXECUTED=no\n'
fi
if [[ -f "$ACL_AUDIT_LOG" ]]; then
  printf 'audit=%s\n' "$(grep -o 'PRIV_[A-Z]*' "$ACL_AUDIT_LOG" | tail -1)"
else
  printf 'audit=none\n'
fi
PEOF
cp "$BASE/probe.sh" "$ABL/probe.sh"

echo "### A1 priv_exec 白名单门禁  lib/privilege.sh:166-170"
echo "-- baseline (未消融) --"; bash "$BASE/probe.sh" "$BASE"
echo "-- ablated (删除白名单检查块) --"; bash "$ABL/probe.sh" "$ABL"
