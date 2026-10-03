#!/bin/bash
# B1-action-risk.sh - 场景 B1：action registry 的 safe/dangerous 分类是否在执行前被强制
# 守卫位置：lib/action_registry.sh:60（risk 入参）、:72（写入 _ACTION_RISK）
# 消融方法：把 risk 入参默认值固化为 "safe"，抹掉 dangerous 分类的登记能力；
#           handler 注册、action_run 分发、requires 检查全部保留。
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ab_common.sh"

BASE=$(ab_tree_baseline)
ABL=$(ab_tree_ablated B1-ablated)
ab_sub "$ABL/lib/action_registry.sh" \
  'local requires="${5:-none}" modes="${6:-both}" risk="${7:-safe}"' \
  'local requires="${5:-none}" modes="${6:-both}" risk="safe" # ABLATION: 分类被抹平' || exit 3

ab_probe "$BASE/abenv-B1/probe.sh" <<'PEOF'
set -uo pipefail
D="$1"; E="$D/abenv-B1"; mkdir -p "$E"
export USER_MANAGER_DATA_BASE="$D/data"
source "$D/lib/config.sh" >/dev/null 2>&1
source "$D/lib/common.sh"
source "$D/lib/action_registry.sh"
ab_probe_handler() { printf 'HANDLER-EXECUTED\n' > "$E/proof.txt"; }
action_register "probe.dangerous" "探针危险动作" "probe" ab_probe_handler "none" "cli" "dangerous"
printf 'registered_risk=%s\n' "${_ACTION_RISK[probe.dangerous]:-none}"
action_run probe.dangerous cli >/dev/null 2>"$E/err.txt"; rc=$?
printf 'run_rc=%s\n' "$rc"
printf 'stderr=%s\n' "$(tr -d '\r\n' < "$E/err.txt" | tr -s ' ')"
[[ -f "$E/proof.txt" ]] && printf 'EXECUTED=yes proof=%s\n' "$(cat "$E/proof.txt")" || printf 'EXECUTED=no\n'
# 二号探针：一个 safe 动作，作同入口对照
action_register "probe.safe" "探针安全动作" "probe" ab_probe_handler "none" "cli" "safe"
action_run probe.safe cli >/dev/null 2>&1; printf 'safe_run_rc=%s\n' "$?"
PEOF
cp -r "$BASE/abenv-B1" "$ABL/abenv-B1" 2>/dev/null
echo "### B1 action risk 分类强制  lib/action_registry.sh:60,72"
echo "-- baseline (未消融) --"; bash "$BASE/abenv-B1/probe.sh" "$BASE"
echo "-- ablated (risk 恒为 safe) --"; bash "$ABL/abenv-B1/probe.sh" "$ABL"
