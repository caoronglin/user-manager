#!/bin/bash
# A5-priv-level.sh - 场景 A5（重做 A2）：消融 priv_exec 的权限级别门禁
# 守卫位置：lib/privilege.sh:172-182
# 关键约束：只删「级别比较 + 拒绝」，保留 PRIV_CMD_WHITELIST 数组、priv_get_required_level
#           与 priv_chmod/priv_exec 等 wrapper —— 能力必须保留。
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ab_common.sh"

BASE=$(ab_tree_baseline)
ABL=$(ab_tree_ablated A5-ablated)
ab_drop_block "$ABL/lib/privilege.sh" \
  '        if [[ "$current_level" -gt "$required_level" ]]; then' \
  '        fi' || exit 3

ab_probe "$BASE/abenv-A5/probe.sh" <<'PEOF'
set -uo pipefail
D="$1"
E="$D/abenv-A5"
mkdir -p "$E/stub" "$D/data/logs"
export USER_MANAGER_DATA_BASE="$D/data"
export ACL_AUDIT_LOG="$D/data/logs/audit.log"
export AB_STUB_LOG="$E/stub.log"
rm -f "$AB_STUB_LOG"
cat > "$E/stub/sudo" <<'EOS'
#!/bin/bash
printf 'sudo %s\n' "$*" >> "$AB_STUB_LOG"
[[ "${1:-}" == "-n" ]] && shift
exec "$@"
EOS
cat > "$E/stub/chmod" <<'EOS'
#!/bin/bash
printf 'chmod %s\n' "$*" >> "$AB_STUB_LOG"
exit 0
EOS
chmod +x "$E/stub/sudo" "$E/stub/chmod"
export PATH="$E/stub:$PATH"
source "$D/lib/config.sh" >/dev/null 2>&1
source "$D/lib/common.sh"; source "$D/lib/access_control.sh"; source "$D/lib/privilege.sh"
acl_get_current_level() { echo 2; }        # 伪装普通用户 ACL_LEVEL_USER=2
priv_exec chmod 700 "$E/target" >/dev/null 2>"$E/err.txt"
rc=$?
printf 'rc=%s\n' "$rc"
printf 'deny_msg=%s\n' "$(sed 's/\x1b\[[0-9;]*m//g' "$E/err.txt" | tr -d '\r\n' | tr -s ' ')"
if [[ -s "$AB_STUB_LOG" ]]; then
  printf 'EXECUTED=yes log=%s\n' "$(tr '\n' ';' < "$AB_STUB_LOG")"
else
  printf 'EXECUTED=no\n'
fi
[[ -f "$ACL_AUDIT_LOG" ]] && printf 'audit=%s\n' "$(grep -o 'PRIV_[A-Z]*' "$ACL_AUDIT_LOG" | tail -1)" || printf 'audit=none\n'
PEOF
cp -r "$BASE/abenv-A5" "$ABL/abenv-A5" 2>/dev/null
echo "### A5 priv_exec 权限级别门禁  lib/privilege.sh:172-182"
echo "-- baseline (未消融) --"; bash "$BASE/abenv-A5/probe.sh" "$BASE"
echo "-- ablated (仅删级别比较块) --"; bash "$ABL/abenv-A5/probe.sh" "$ABL"
