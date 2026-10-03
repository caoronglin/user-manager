#!/bin/bash
# C1-snapshot-symlink.sh - 场景 C1：快照层符号链接拒绝
# 守卫位置：lib/snapshot_core.sh:181（resolve_safe_path 逐段 -L 检查）
#            lib/snapshot_core.sh:290-293 / 321-324（目标文件 -L 拒绝）
# 消融方法：只删 :181 的 -L 早退，保留 snapshot_ensure_dir / enter_safe_dir / 原子安装全部能力。
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ab_common.sh"

BASE=$(ab_tree_baseline)
ABL=$(ab_tree_ablated C1-ablated)
ab_sub "$ABL/lib/snapshot_core.sh" \
  '            [[ -L "$current" ]] && return 1' \
  '            : # ABLATION: 取消逐段符号链接拒绝' || exit 3

ab_probe "$BASE/abenv-C1/probe.sh" <<'PEOF'
set -uo pipefail
D="$1"; E="$D/abenv-C1"; mkdir -p "$E"
export USER_MANAGER_DATA_BASE="$D/data"
# 真实目标 + 指向它的符号链接
rm -rf "$E/real" "$E/link"; mkdir -p "$E/real"
ln -s "$E/real" "$E/link"
export USER_MANAGER_SNAPSHOT_DIR="$E/link"
source "$D/lib/config.sh" >/dev/null 2>&1
source "$D/lib/common.sh"
source "$D/lib/snapshot_core.sh"
out=$(snapshot_resolve_safe_path "$USER_MANAGER_SNAPSHOT_DIR" 2>&1); rc=$?
printf 'resolve_rc=%s\n' "$rc"
printf 'resolve_out=%s\n' "$(printf '%s' "$out" | tr -d '\r\n' | tr -s ' ')"
# 完整写路径：经符号链接目录写一份 manifest
if printf '{"v":1}\n' | snapshot_atomic_install manifest >/dev/null 2>"$E/err.txt"; then w=0; else w=$?; fi
printf 'write_rc=%s\n' "$w"
printf 'write_err=%s\n' "$(tr -d '\r\n' < "$E/err.txt" | tr -s ' ')"
if [[ -f "$E/real/manifest.json" ]]; then
  printf 'EXECUTED=yes real_file=%s content=%s\n' "$E/real/manifest.json" "$(tr -d '\r\n' < "$E/real/manifest.json")"
else
  printf 'EXECUTED=no\n'
fi
PEOF
cp -r "$BASE/abenv-C1" "$ABL/abenv-C1" 2>/dev/null
echo "### C1 快照层符号链接拒绝  lib/snapshot_core.sh:181"
echo "-- baseline (未消融) --"; bash "$BASE/abenv-C1/probe.sh" "$BASE" 2>/dev/null || bash "$BASE/abenv-C1/probe.sh" "$BASE"
echo "-- ablated (删 :181 的 -L 早退) --"; bash "$ABL/abenv-C1/probe.sh" "$ABL"
