#!/bin/bash
# C2-snapshot-fail-closed.sh - 场景 C2：快照写失败关闭
# 守卫位置：lib/snapshot_core.sh:298-301 —— mktemp 失败即 exit 1（临时文件 + 原子安装契约）
# 消融方法：把 mktemp 失败后的 exit 1 换成 tmp="$file"（跳过临时文件、直写目标）。
#           写快照的能力完整保留，移除的只是「失败即中止 + 原子替换」这道守卫。
# 失败注入：PATH 前置 stub mktemp 恒返回非零，稳定制造 mktemp 失败。
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ab_common.sh"

BASE=$(ab_tree_baseline)
ABL=$(ab_tree_ablated C2-ablated)
ab_sub "$ABL/lib/snapshot_core.sh" \
  '    tmp="$(mktemp -- "./.${kind}.json.XXXXXX")" || {' \
  '    tmp="$file" || { # ABLATION: 跳过临时文件与原子安装' || exit 3

ab_probe "$BASE/abenv-C2/probe.sh" <<'PEOF'
set -uo pipefail
D="$1"; E="$D/abenv-C2"; mkdir -p "$E/stub"
export USER_MANAGER_DATA_BASE="$D/data"
SN="$E/snap"; rm -rf "$SN"; mkdir -p "$SN"
export USER_MANAGER_SNAPSHOT_DIR="$SN"
# 失败注入：mktemp 恒失败
cat > "$E/stub/mktemp" <<'EOS'
#!/bin/bash
echo "C2-INJECTED: mktemp unavailable" >&2
exit 1
EOS
chmod +x "$E/stub/mktemp"
export PATH="$E/stub:$PATH"
source "$D/lib/config.sh" >/dev/null 2>&1
source "$D/lib/common.sh"
source "$D/lib/snapshot_core.sh"
snapshot_ensure_dir "$SN" >/dev/null 2>&1
printf 'PREVIOUS-GOOD-CONTENT\n' > "$SN/manifest.json"
chmod 0644 "$SN/manifest.json"
if printf 'NEW-PAYLOAD\n' | snapshot_atomic_install manifest >/dev/null 2>"$E/err.txt"; then w=0; else w=$?; fi
printf 'write_rc=%s\n' "$w"
printf 'write_err=%s\n' "$(tr -d '\r\n' < "$E/err.txt" | tr -s ' ')"
if [[ -f "$SN/manifest.json" ]]; then
  printf 'EXISTING_SNAPSHOT=intact content=%s\n' "$(tr -d '\r\n' < "$SN/manifest.json")"
elif [[ -e "$SN/manifest.json" ]]; then
  printf 'EXISTING_SNAPSHOT=truncated_empty size=%s\n' "$(wc -c < "$SN/manifest.json")"
else
  printf 'EXISTING_SNAPSHOT=deleted\n'
fi
PEOF
cp -r "$BASE/abenv-C2" "$ABL/abenv-C2" 2>/dev/null
echo "### C2 快照写失败关闭  lib/snapshot_core.sh:298-301"
echo "-- baseline (未消融) --"; bash "$BASE/abenv-C2/probe.sh" "$BASE"
echo "-- ablated (吞掉 mktemp 失败, 直写目标) --"; bash "$ABL/abenv-C2/probe.sh" "$ABL"
