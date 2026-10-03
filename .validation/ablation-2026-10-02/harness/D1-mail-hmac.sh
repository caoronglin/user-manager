#!/bin/bash
# D1-mail-hmac.sh - 场景 D1：rl_mail_queue 的 HMAC-SHA256 完整性校验
# 守卫位置：lib/rl_mail_queue.sh:243 —— [[ "$rl_mac_calc" == "$rl_mac_expected" ]] || exit 1
# 消融方法：把该比较换成恒真（:），其余全部保留：
#           base64 解码、IV 长度校验、hex 格式正则、openssl 解密、encrypt-then-MAC 顺序全部不动。
# 攻击：把 v2 密文的 ciphertext 翻转一个字节，重算 IV 保持不变，MAC 字段保持原始值。
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ab_common.sh"

BASE=$(ab_tree_baseline)
ABL=$(ab_tree_ablated D1-ablated)
ab_sub "$ABL/lib/rl_mail_queue.sh" \
  '        [[ "$rl_mac_calc" == "$rl_mac_expected" ]] || exit 1' \
  '        : # ABLATION: 恒真，HMAC 比对被移除' || exit 3

ab_probe "$BASE/abenv-D1/probe.sh" <<'PEOF'
set -uo pipefail
D="$1"; E="$D/abenv-D1"; mkdir -p "$E"
export USER_MANAGER_DATA_BASE="$D/data"
source "$D/lib/config.sh" >/dev/null 2>&1
source "$D/lib/common.sh"
source "$D/lib/rl_mail_queue.sh"
DEK="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
PLAINTEXT="SMTP_PASSWORD_TOP_SECRET"
CT="$(rl_mail_secret_encrypt "$PLAINTEXT" "$DEK")" || { echo "ENCRYPT_FAILED"; exit 1; }
printf 'ciphertext_prefix=%s...\n' "${CT:0:40}"
# 未篡改：必须成功（两侧都应成功，证明能力保留）
if OUT="$(rl_mail_secret_decrypt "$CT" "$DEK" 2>/dev/null)"; then r1=0; else r1=1; fi
printf 'intact_rc=%s out=%s\n' "$r1" "$OUT"
# 篡改：翻转 ciphertext 的一个字节，MAC 字段保持原值
IFS=':' read -r VER IV B64 MAC <<<"$CT"
RAW="$(printf '%s' "$B64" | openssl base64 -d -A | od -An -v -tx1 | tr -d '[:space:]')"
# 翻转第 1 个 AES 块（偏移 0 字节）的一个字节：
# CBC 下只污染第 0/1 块明文，末块 padding 完好，openssl 解密会成功但产出可预测的垃圾明文。
# 这正是 HMAC 唯一能挡住、而 padding 校验挡不住的 CBC 篡改攻击面。
OFF=0
B0="${RAW:$((OFF*2)):2}"
if [[ "$B0" == "00" ]]; then NB="ff"; else NB="00"; fi
NEWR="${RAW:0:$((OFF*2))}$NB${RAW:$((OFF*2+2))}"
TAMPERED="$VER:$IV:$(printf '%s' "$NEWR" | xxd -r -p | openssl base64 -A):$MAC"
if OUT2="$(rl_mail_secret_decrypt "$TAMPERED" "$DEK" 2>/dev/null)" && [[ -n "$OUT2" ]]; then
  r2=0; ACCEPTS=yes; PLAINTEXT_OUT="$(printf '%s' "$OUT2" | tr -d '\r\n')"
else
  r2=1; ACCEPTS=no; PLAINTEXT_OUT=""
fi
printf 'tamper_rc=%s ACCEPTED_TAMPER=%s\n' "$r2" "$ACCEPTS"
printf 'tamper_plaintext=%s\n' "$PLAINTEXT_OUT"
PEOF
cp -r "$BASE/abenv-D1" "$ABL/abenv-D1" 2>/dev/null
echo "### D1 HMAC 完整性  lib/rl_mail_queue.sh:243"
echo "-- baseline (未消融) --"; bash "$BASE/abenv-D1/probe.sh" "$BASE"
echo "-- ablated (HMAC 比对恒真) --"; bash "$ABL/abenv-D1/probe.sh" "$ABL"
