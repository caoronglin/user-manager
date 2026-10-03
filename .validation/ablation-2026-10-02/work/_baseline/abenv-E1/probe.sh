set -uo pipefail
D="$1"; E="$D/abenv-E1"; mkdir -p "$E"
export SMB_CONF="$E/smb.conf" SMB_SHARES_CONF="$E/shares.conf"
: >"$SMB_SHARES_CONF"
source "$D/lib/smb_core.sh"
try() { # try <name> <path>
  local n="$1" p="$2" err rc
  err=$(smb_share_add "$n" "$p" 2>&1); rc=$?
  printf 'add name=[%s] path=[%s] rc=%s err=%s\n' "$n" "$p" "$rc" "$err"
}
try 'bad/name' '/srv/data'
printf 'conf_after_badname:\n'; grep -c '^\[bad/name\]' "$SMB_SHARES_CONF"
try '..' '/srv/data'
printf 'conf_after_dotdot:\n'; grep -c '^\[\.\.\]' "$SMB_SHARES_CONF"
try 'trav' '../../etc'
printf 'conf_after_trav:\n'; grep -c '^   path = ../../etc$' "$SMB_SHARES_CONF"
