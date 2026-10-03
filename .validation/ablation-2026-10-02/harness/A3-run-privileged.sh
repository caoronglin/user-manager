#!/bin/bash
# A3-run-privileged.sh - 场景 A3（重做）：消融 run_privileged 的 shell trampoline 拒绝
# 守卫位置：lib/common.sh:93-99（保留 :89-92「选项作为命令名」守卫，sudo 执行能力不动）
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ab_common.sh"

BASE=$(ab_tree_baseline)
ABL=$(ab_tree_ablated A3-ablated)
ab_drop_block "$ABL/lib/common.sh" \
  '    case "$cmd" in' \
  '    esac' || exit 3

ab_probe "$BASE/abenv-A3/probe.sh" <<'PEOF'
set -uo pipefail
D="$1"
E="$D/abenv-A3"
mkdir -p "$E/stub"
export USER_MANAGER_DATA_BASE="$D/data"
export AB_STUB_LOG="$E/stub.log"
rm -f "$AB_STUB_LOG"
cat > "$E/stub/sudo" <<'EOS'
#!/bin/bash
printf 'sudo %s\n' "$*" >> "$AB_STUB_LOG"
[[ "${1:-}" == "-n" ]] && shift
exec "$@"
EOS
chmod +x "$E/stub/sudo"
export PATH="$E/stub:$PATH"
source "$D/lib/config.sh" >/dev/null 2>&1
source "$D/lib/common.sh"
out=$(run_privileged bash -c 'echo TRAMPOLINE-EXECUTED' 2>&1); rc=$?
printf 'rc=%s\n' "$rc"
printf 'out=%s\n' "$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r' | tr '\n' ' ')"
if [[ -s "$AB_STUB_LOG" ]]; then
  printf 'EXECUTED=yes log=%s\n' "$(tr '\n' ';' < "$AB_STUB_LOG")"
else
  printf 'EXECUTED=no\n'
fi
PEOF
cp -r "$BASE/abenv-A3" "$ABL/abenv-A3" 2>/dev/null
echo "### A3 run_privileged shell trampoline 拒绝  lib/common.sh:93-99"
echo "-- baseline (未消融) --"; bash "$BASE/abenv-A3/probe.sh" "$BASE"
echo "-- ablated (删 case trampoline 块) --"; bash "$ABL/abenv-A3/probe.sh" "$ABL"
