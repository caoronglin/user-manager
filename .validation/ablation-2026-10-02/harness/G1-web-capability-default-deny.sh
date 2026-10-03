#!/bin/bash
# G1-web-capability-default-deny.sh - 场景 G1：web/backend capability 默认拒绝（**静态消融**）
# 守卫位置：web/backend/src/auth/rbac.rs:15-17 —— .unwrap_or(Capabilities { allowed: BTreeSet::new() })
# 消融方法：把「未知角色 → 空集合」换成「未知角色 → 全集 KNOWN_CAPS」，只改守卫分支，不改消费链。
# 硬约束：本机无 cargo/rustc，禁止编译验证，因此只能 STATIC-ONLY，绝不出具 GUARD-ACTIVE。
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ab_common.sh"

R=$(git -C "$AB_ROOT" rev-parse --short HEAD)
echo "### G1 capability 默认拒绝  web/backend/src/auth/rbac.rs:15-17   基线 $R"

echo '-- 0. 工具链检查 --'
for t in cargo rustc rustup; do
  if command -v "$t" >/dev/null 2>&1; then echo "  $t: PRESENT"; else echo "  $t: MISSING"; fi
done
if ! command -v cargo >/dev/null 2>&1; then
  echo '  => 无 Rust 工具链，本场景只能静态消融 + 静态判定（STATIC-ONLY）'
fi

echo '-- 1. 静态消融：把默认拒绝分支换成 allow-all --'
OUT="$AB_WORK/G1-ablated"
rm -rf "$OUT"; mkdir -p "$OUT"
cp -a "$AB_ROOT/web/backend/src/auth/rbac.rs" "$OUT/rbac.orig"
cp -a "$AB_ROOT/web/backend/src/auth/rbac.rs" "$OUT/rbac.ablated"
ab_sub "$OUT/rbac.ablated" \
  'allowed: std::collections::BTreeSet::new(),' \
  'allowed: std::collections::BTreeSet::from(KNOWN_CAPS.iter().map(|s| s.to_string())), # ABLATION-STATIC: 未知角色由空集合改为全集' \
  || exit 3
diff -u "$OUT/rbac.orig" "$OUT/rbac.ablated" | sed -n '3,12p' | sed 's/^/    /'

echo '-- 2. 守卫消费链静态追踪（未消融源码）--'
grep -n 'unwrap_or(Capabilities' "$AB_ROOT/web/backend/src/auth/rbac.rs" | sed 's/^/    rbac: /'
grep -n 'rbac::capabilities_for' "$AB_ROOT/web/backend/src/auth/guard.rs" | sed 's/^/    guard: /'
grep -n 'pub fn require' "$AB_ROOT/web/backend/src/auth/guard.rs" | sed 's/^/    guard: /'
printf '    require_callers=%s\n' "$(grep -rn 'auth.require(' "$AB_ROOT/web/backend/src/http" --include='*.rs' | wc -l)"

echo '-- 3. 判定 --'
echo '  STATIC-ONLY：无 cargo/rustc，消融后代码未编译、未运行，无任何运行时观测。'
echo '  可断言的只有静态事实：默认拒绝分支存在于 rbac.rs:15-17，且被 guard.rs:89→:100 消费。'
echo '  不可断言：消融后是否真的放行、是否编译通过。禁止据此出具 GUARD-ACTIVE。'
