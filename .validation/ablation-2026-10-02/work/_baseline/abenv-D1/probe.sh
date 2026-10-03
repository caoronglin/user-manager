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
