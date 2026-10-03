#!/bin/bash
# A4-permission-default-deny.sh - 场景 A4（重做）：消融 check_permission 的默认拒绝
# 守卫位置：lib/privilege.sh:406 —— ${PERMISSION_MATRIX[$key]:-$ACL_LEVEL_ADMIN}
#            未知 resource:action 落到 ADMIN(1)；改为 GUEST(3)（数值最大=要求最低）即默认放行。
# 能力保留：run_with_permission / require_permission / PERMISSION_MATRIX 全部不动。
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ab_common.sh"

BASE=$(ab_tree_baseline)
ABL=$(ab_tree_ablated A4-ablated)
ab_sub "$ABL/lib/privilege.sh" \
  'local required_level="${PERMISSION_MATRIX[$key]:-$ACL_LEVEL_ADMIN}"' \
  'local required_level="${PERMISSION_MATRIX[$key]:-$ACL_LEVEL_GUEST}" # ABLATION' || exit 3

ab_probe "$BASE/abenv-A4/probe.sh" <<'PEOF'
set -uo pipefail
D="$1"
E="$D/abenv-A4"
mkdir -p "$E"
export USER_MANAGER_DATA_BASE="$D/data"
source "$D/lib/config.sh" >/dev/null 2>&1
source "$D/lib/common.sh"
source "$D/lib/access_control.sh"   # privilege.sh 顶部强制要求先 source
source "$D/lib/privilege.sh"
acl_get_current_level() { echo 2; }
rm -f "$E/victim.txt"
# 同一操作、同一入口：矩阵里没有的 resource key，baseline 应被「默认拒绝」挡住
run_with_permission "totally:unknown" "unknown" touch "$E/victim.txt" >/dev/null 2>"$E/err.txt"
rc=$?
printf 'rc=%s\n' "$rc"
printf 'deny_msg=%s\n' "$(sed 's/\x1b\[[0-9;]*m//g' "$E/err.txt" | tr -d '\r\n' | tr -s ' ')"
if [[ -f "$E/victim.txt" ]]; then printf 'EXECUTED=yes file=%s\n' "$E/victim.txt"; else printf 'EXECUTED=no\n'; fi
PEOF
cp -r "$BASE/abenv-A4" "$ABL/abenv-A4" 2>/dev/null
echo "### A4 check_permission 默认拒绝  lib/privilege.sh:406"
echo "-- baseline (未消融) --"; bash "$BASE/abenv-A4/probe.sh" "$BASE"
echo "-- ablated (默认级别 ADMIN -> GUEST) --"; bash "$ABL/abenv-A4/probe.sh" "$ABL"
