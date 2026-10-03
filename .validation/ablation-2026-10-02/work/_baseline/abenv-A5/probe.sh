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
