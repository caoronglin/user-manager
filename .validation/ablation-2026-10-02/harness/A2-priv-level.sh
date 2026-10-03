#!/bin/bash
# A2-priv-level.sh - 场景 A2：消融 priv_exec 的权限级别门禁
# 守卫位置：lib/privilege.sh:178-182
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ab_common.sh"
BASE=$(ab_prepare A2-baseline lib scripts)
ABL=$(ab_prepare A2-ablated lib scripts)
ab_ablate "$ABL/lib/privilege.sh" '/[[ "$current_level" -gt "$required_level" ]]; then/,/^        fi$/d' || exit 3
ab_probe "$BASE/probe.sh" <<'PEOF'
set -uo pipefail
D="$1"
export USER_MANAGER_DATA_BASE="$D/data"
export ACL_AUDIT_LOG="$D/data/logs/audit.log"
export AB_STUB_LOG="$D/stub.log"
rm -f "$AB_STUB_LOG"; mkdir -p "$D/data/logs" "$D/stub"
cat > "$D/stub/chmod" <<'EOS'
#!/bin/bash
printf 'chmod %s
' "$*" >> "$AB_STUB_LOG"
EOS
cat > "$D/stub/sudo" <<'EOS'
#!/bin/bash
[[ "${1:-}" == "-n" ]] && shift
printf 'sudo %s
' "$*" >> "$AB_STUB_LOG"
exec "$@"
EOS
chmod +x "$D/stub/chmod" "$D/stub/sudo"
export PATH="$D/stub:$PATH"
source "$D/lib/config.sh" >/dev/null 2>&1
source "$D/lib/common.sh"
source "$D/lib/access_control.sh"
source "$D/lib/privilege.sh"
# 模拟 guest 级调用者（uid>=1000、无 sudo 组 -> ACL_LEVEL_USER=2 也会被拒；这里直接给 3=guest）
acl_get_current_level() { echo 3; }
priv_chmod 0777 "$D/victim" >/dev/null 2>"$D/err.txt"
rc=$?
printf 'rc=%s\n' "$rc"
printf 'deny_msg=%s\n' "$(sed 's/\x1b\[[0-9;]*m//g' "$D/err.txt" | tr '\n' ' ')"
if [[ -s "$AB_STUB_LOG" ]]; then printf 'EXECUTED=yes log=%s\n' "$(tr '\n' ';' < "$AB_STUB_LOG")"; else printf 'EXECUTED=no\n'; fi
if [[ -f "$ACL_AUDIT_LOG" ]]; then printf 'audit=%s\n' "$(grep -o 'PRIV_[A-Z]*' "$ACL_AUDIT_LOG" | tail -1)"; else printf 'audit=none\n'; fi
PEOF
cp "$BASE/probe.sh" "$ABL/probe.sh"
echo "### A2 priv_exec 权限级别门禁  lib/privilege.sh:178-182"
echo "-- baseline --"; bash "$BASE/probe.sh" "$BASE"
echo "-- ablated --"; bash "$ABL/probe.sh" "$ABL"
