set -uo pipefail
D="$1"; E="$D/abenv-B1"; mkdir -p "$E"
export USER_MANAGER_DATA_BASE="$D/data"
source "$D/lib/config.sh" >/dev/null 2>&1
source "$D/lib/common.sh"
source "$D/lib/action_registry.sh"
ab_probe_handler() { printf 'HANDLER-EXECUTED\n' > "$E/proof.txt"; }
action_register "probe.dangerous" "探针危险动作" "probe" ab_probe_handler "none" "cli" "dangerous"
printf 'registered_risk=%s\n' "${_ACTION_RISK[probe.dangerous]:-none}"
action_run probe.dangerous cli >/dev/null 2>"$E/err.txt"; rc=$?
printf 'run_rc=%s\n' "$rc"
printf 'stderr=%s\n' "$(tr -d '\r\n' < "$E/err.txt" | tr -s ' ')"
[[ -f "$E/proof.txt" ]] && printf 'EXECUTED=yes proof=%s\n' "$(cat "$E/proof.txt")" || printf 'EXECUTED=no\n'
# 二号探针：一个 safe 动作，作同入口对照
action_register "probe.safe" "探针安全动作" "probe" ab_probe_handler "none" "cli" "safe"
action_run probe.safe cli >/dev/null 2>&1; printf 'safe_run_rc=%s\n' "$?"
