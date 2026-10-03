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
