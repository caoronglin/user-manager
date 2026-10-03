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
