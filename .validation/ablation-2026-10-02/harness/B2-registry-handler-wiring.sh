#!/bin/bash
# B2-registry-handler-wiring.sh - 场景 B2：registry 与 handler 的一致性审计
# 这不是消融，是只读接线审计：已注册但无 handler / 有 handler 但未注册。
# 方法：静态提取 lib/*.sh 里的函数定义名，与 action_register_defaults 的 handler 列比对，
#       避免 source 全部模块（backup_core.sh / email_daemon.sh 依赖不满足会提前 return）。
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ab_common.sh"
BASE=$(ab_tree_baseline)
LOG="$AB_LOGS/B2-wiring.txt"
DEF="$AB_LOGS/B2-defined-funcs.txt"

grep -hoE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)[[:space:]]*\{' "$BASE"/lib/*.sh "$BASE"/scripts/*.sh 2>/dev/null \
  | sed -E 's/[[:space:]]*\(\)[[:space:]]*\{//; s/^[[:space:]]+//; s/[[:space:]]+$//' \
  | sort -u > "$DEF"

{
  echo "### B2 registry <-> handler 接线审计  lib/action_registry.sh:364-393"
  echo "defined_functions=$(wc -l < "$DEF")"
  D="$BASE"
  source "$D/lib/config.sh" >/dev/null 2>&1
  source "$D/lib/action_registry.sh"
  action_register_defaults_once
  total=0; missing=0
  for id in "${!_ACTION_HANDLER[@]}"; do
    total=$((total+1))
    h="${_ACTION_HANDLER[$id]}"
    grep -qxF "$h" "$DEF" || { missing=$((missing+1)); printf 'REGISTERED_NO_HANDLER %s -> %s\n' "$id" "$h"; }
  done
  printf 'TOTAL=%d MISSING_HANDLER=%d\n' "$total" "$missing"
  for f in $(grep -xE 'rl_action_[a-z_]+_cli' "$DEF"); do
    found=0
    for id in "${!_ACTION_HANDLER[@]}"; do
      [[ "${_ACTION_HANDLER[$id]}" == "$f" ]] && { found=1; break; }
    done
    [[ $found -eq 0 ]] && printf 'HANDLER_NOT_REGISTERED %s\n' "$f"
  done
  printf 'REVERSE_SCAN_DONE\n'
} > "$LOG" 2>&1
grep -E 'REGISTERED_NO_HANDLER|^TOTAL=|HANDLER_NOT_REGISTERED|REVERSE_SCAN|defined_functions' "$LOG" | head -20
echo "evidence: $LOG"
