#!/bin/bash
# regenerate_password_pool.sh - 密码池重新生成工具 v5.0
# 使用新算法生成 8568 个 8 位密码

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# shellcheck disable=SC1091
source "$LIB_DIR/common.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/config.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/access_control.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/privilege.sh"

load_config || { echo "加载配置失败"; exit 1; }

# 密码格式：
#   位置 1-3: 从 ASDFGHJKL 连续选取 3 个 (7 种组合)
#   位置 4:   从 qwertyuiopzxcvbnm 随机选 1 个 (17 种)
#   位置 5-7: 从 1234567890 连续选取 3 个 (8 种组合)
#   位置 8:   从 !@#$%^&*? 随机选 1 个 (9 种)
#   总计: 7 × 17 × 8 × 9 = 8568 个密码

draw_header "密码池重新生成工具"

msg_info "密码格式说明:"
draw_info_card "位置 1-3" "ASDFGHJKL 连续 3 字符 (7 种)"
draw_info_card "位置 4" "qwertyuiopzxcvbnm 随机 1 字符 (17 种)"
draw_info_card "位置 5-7" "1234567890 连续 3 数字 (8 种)"
draw_info_card "位置 8" "!@#\$%^&*? 随机 1 字符 (9 种)"
draw_info_card "总计" "7 × 17 × 8 × 9 = 8568 个"
echo ""

POOL_FILE="$PASSWORD_POOL_FILE"

if [[ -f "$POOL_FILE" ]]; then
    local_count=$(wc -l < "$POOL_FILE")
    msg_warn "当前密码池已有 ${local_count} 个密码"
    if ! confirm_action "是否重新生成密码池？（当前密码池将被覆盖）"; then
        msg_info "操作已取消"
        exit 0
    fi
fi

msg_step "正在生成密码池..."

old_umask=$(umask)
umask 077

UPPER="ASDFGHJKL"
LOWER="qwertyuiopzxcvbnm"
DIGITS="1234567890"
SPECIALS='!@#$%^&*?'

TMP_FILE=$(mktemp) || {
    umask "$old_umask"
    msg_err "无法创建临时文件"
    exit 1
}
trap 'rm -f "$TMP_FILE"; umask "$old_umask"' EXIT

{
    for (( i = 0; i <= ${#UPPER} - 3; i++ )); do
        tri="${UPPER:i:3}"
        for (( j = 0; j < ${#LOWER}; j++ )); do
            lc="${LOWER:j:1}"
            for (( k = 0; k <= ${#DIGITS} - 3; k++ )); do
                dig="${DIGITS:k:3}"
                for (( m = 0; m < ${#SPECIALS}; m++ )); do
                    echo "${tri}${lc}${dig}${SPECIALS:m:1}"
                done
            done
        done
    done
} > "$TMP_FILE"

shuf "$TMP_FILE" > "$POOL_FILE"
chmod 600 "$POOL_FILE" 2>/dev/null || true
rm -f "$TMP_FILE"
umask "$old_umask"
trap - EXIT

TOTAL=$(wc -l < "$POOL_FILE")
msg_ok "密码池生成完成: ${C_BOLD}${TOTAL}${C_RESET} 个密码"
msg_info "文件位置: ${C_CYAN}${POOL_FILE}${C_RESET}"

# 显示几个示例
if [[ "${SHOW_PASSWORDS:-0}" == "1" ]]; then
    msg_step "示例密码（前 5 个）:"
    head -5 "$POOL_FILE" | while read -r pw; do
        echo "    ${C_BCYAN}${pw}${C_RESET}"
    done
    echo ""
else
    msg_warn "示例密码已隐藏输出，设置 SHOW_PASSWORDS=1 可显示"
fi
