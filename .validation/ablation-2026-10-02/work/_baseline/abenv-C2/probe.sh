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
