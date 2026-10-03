set -uo pipefail
D="$1"
E="$D/abenv-A4"
mkdir -p "$E"
export USER_MANAGER_DATA_BASE="$D/data"
source "$D/lib/config.sh" >/dev/null 2>&1
source "$D/lib/common.sh"
source "$D/lib/access_control.sh"   # privilege.sh 顶部强制要求先 source
source "$D/lib/privilege.sh"
acl_get_current_level() { echo 2; }
rm -f "$E/victim.txt"
# 同一操作、同一入口：矩阵里没有的 resource key，baseline 应被「默认拒绝」挡住
run_with_permission "totally:unknown" "unknown" touch "$E/victim.txt" >/dev/null 2>"$E/err.txt"
rc=$?
printf 'rc=%s\n' "$rc"
printf 'deny_msg=%s\n' "$(sed 's/\x1b\[[0-9;]*m//g' "$E/err.txt" | tr -d '\r\n' | tr -s ' ')"
if [[ -f "$E/victim.txt" ]]; then printf 'EXECUTED=yes file=%s\n' "$E/victim.txt"; else printf 'EXECUTED=no\n'; fi
