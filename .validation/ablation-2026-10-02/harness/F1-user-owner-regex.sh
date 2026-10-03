#!/bin/bash
# F1-user-owner-regex.sh - 场景 F1：lib/user_core.sh:402 owner/group 账户名正则
# 守卫位置：_um_publish_cli_user_event_spool_at 内 [[ "$owner" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ && ... ]]
# 消融方法：把该行两侧正则同时换成恒真 =~ ^.*$，函数其余逻辑（spool 目录、id/getent、chown、原子写）全保留。
# 攻击：前导短横线 -root（chown/id 选项注入面）、路径分隔符 root/../root。
# 观测：PATH 前置「记录型」stub（先记调用再 exec 真二进制，行为零改变），
#       验证恶意值是否越过 :402 抵达 id -u / getent group 的参数位。
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ab_common.sh"

BASE=$(ab_tree_baseline)
ABL=$(ab_tree_ablated F1-ablated)
ab_sub "$ABL/lib/user_core.sh" \
  '=~ ^[A-Za-z_][A-Za-z0-9_.-]*$' \
  '=~ ^.*$' || exit 3

ab_probe "$BASE/abenv-F1/inner.sh" <<'PEOF'
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
PEOF
cp -r "$BASE/abenv-F1" "$ABL/abenv-F1" 2>/dev/null

run() { # run <tree> <label>
  local t="$1" tag="$2" n=0
  rm -rf "$t/abenv-F1/spool"; mkdir -p "$t/abenv-F1/spool"
  for pair in "-root|-root" "root/../root|root/../root" "$(id -un)|$(id -gn)"; do
    n=$((n+1))
    local o="${pair%%|*}" g="${pair##*|}" rc
    local tdir="$t/abenv-F1/$tag-$n"; mkdir -p "$tdir"
    bash "$t/abenv-F1/inner.sh" "$t" "$o" "$g" "$tdir/tr" >/dev/null 2>&1
    rc=$(cut -d= -f2 "$tdir/tr.rc")
    printf '  %-9s case%s owner=[%s] rc=%s id_getent_calls=[%s] json_written=%s\n' \
      "$tag" "$n" "$o" "$rc" "$(tr '\n' ';' < "$tdir/tr.idlog")" \
      "$(find "$t/abenv-F1/spool" -name '*.json' | wc -l)"
  done
}

echo "### F1 owner/group 正则  lib/user_core.sh:402"
echo "-- baseline (未消融) --"; run "$BASE" baseline
echo "-- ablated (正则恒真) --"; run "$ABL" ablated
