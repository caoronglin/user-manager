set -uo pipefail
D="$1"; O="$2"; G="$3"; T="$4"
mkdir -p "$D/abenv-F1/stub"
cat > "$D/abenv-F1/stub/id" <<'SEOF'
#!/bin/bash
printf 'id %s\n' "$*" >> "$IDLOG"
exec /usr/bin/id "$@"
SEOF
cat > "$D/abenv-F1/stub/getent" <<'SEOF'
#!/bin/bash
printf 'getent %s\n' "$*" >> "$IDLOG"
exec /usr/bin/getent "$@"
SEOF
chmod +x "$D/abenv-F1/stub/id" "$D/abenv-F1/stub/getent"
export IDLOG="$T.idlog"; : > "$IDLOG"
export PATH="$D/abenv-F1/stub:$PATH"
source "$D/lib/common.sh" >/dev/null 2>&1
source "$D/lib/user_core.sh" >/dev/null 2>&1
S="$D/abenv-F1/spool"; mkdir -p "$S"
_um_publish_cli_user_event_spool_at "$S" abuser user.created "$O" "$G" >"$T.out" 2>"$T.err"
echo "rc=$?" >"$T.rc"
