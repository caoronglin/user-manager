#!/bin/bash
# E1-smb-share-validate.sh - 场景 E1：lib/smb_core.sh 共享名校验与共享路径处理
# 守卫位置：lib/smb_core.sh:228 —— [[ "$1" =~ ^[A-Za-z0-9_.-]+$ ]]（_smb_valid_share_name）
# 消融方法：把该正则换成恒真 [[ -n "$1" ]]，函数保留、报错消息保留、写共享段能力保留。
# 攻击：1) 非法共享名 bad/name  2) 纯点号共享名 ..  3) 路径穿越 path=../../etc
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ab_common.sh"

BASE=$(ab_tree_baseline)
ABL=$(ab_tree_ablated E1-ablated)
ab_sub "$ABL/lib/smb_core.sh" \
  '[[ "$1" =~ ^[A-Za-z0-9_.-]+$ ]]' \
  '[[ -n "$1" ]] # ABLATION: 恒真，共享名字符集守卫被移除' || exit 3

ab_probe "$BASE/abenv-E1/probe.sh" <<'PEOF'
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
PEOF
cp -r "$BASE/abenv-E1" "$ABL/abenv-E1" 2>/dev/null

echo "### E1 共享名/路径校验  lib/smb_core.sh:228"
echo "-- baseline (未消融) --"; bash "$BASE/abenv-E1/probe.sh" "$BASE"
echo "-- ablated (共享名守卫恒真) --"; bash "$ABL/abenv-E1/probe.sh" "$ABL"
