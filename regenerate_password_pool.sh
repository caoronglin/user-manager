#!/bin/bash
# regenerate_password_pool.sh - 密码池重新生成工具 v6.0
# 每次执行使用时间戳生成新的密码池，自动清理旧池
#   逻辑不变：3位连续大写 + 1位小写 + 3位连续数字 + 1位特殊字符 = 8568 个

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

draw_header "密码池重新生成工具（时间戳模式）"

msg_info "每次执行生成带时间戳的新密码池，旧池自动保留最近 ${PASSWORD_POOL_KEEP} 个"
echo ""

# 密码格式：
#   位置 1-3: 从 ASDFGHJKL 连续选取 3 个 (7 种组合)
#   位置 4:   从 qwertyuiopzxcvbnm 随机选 1 个 (17 种)
#   位置 5-7: 从 1234567890 连续选取 3 个 (8 种组合)
#   位置 8:   从 !@#$%^&*? 随机选 1 个 (9 种)
#   总计: 7 × 17 × 8 × 9 = 8568 个密码

draw_info_card "密码格式" "3大写+1小写+3数字+1特殊字符"
draw_info_card "总密码数" "8568 个"
draw_info_card "命名规则" "password_pool_YYYYMMDD_HHMMSS.txt"
draw_info_card "旧池保留" "最近 ${PASSWORD_POOL_KEEP} 个"
echo ""

# shellcheck disable=SC1091
source "$LIB_DIR/user_core.sh"

# 强制生成新密码池
msg_step "正在生成新的密码池..."
new_pool=$(generate_password_pool) || {
    msg_err "密码池生成失败"
    exit 1
}

TOTAL=$(wc -l < "$new_pool")
msg_ok "密码池生成完成: ${C_BOLD}${TOTAL}${C_RESET} 个密码"
msg_info "文件位置: ${C_CYAN}${new_pool}${C_RESET}"

# 清理旧密码池
cleanup_old_password_pools "$PASSWORD_POOL_KEEP"

# 显示几个示例
if [[ "${SHOW_PASSWORDS:-0}" == "1" ]]; then
    msg_step "示例密码（前 5 个）:"
    head -5 "$new_pool" | while read -r pw; do
        echo "    ${C_BCYAN}${pw}${C_RESET}"
    done
    echo ""
else
    msg_warn "示例密码已隐藏输出，设置 SHOW_PASSWORDS=1 可显示"
fi

# 列出密码池目录状态
echo ""
msg_info "密码池目录: ${C_CYAN}${PASSWORD_POOL_DIR}${C_RESET}"
count=$(ls "$PASSWORD_POOL_DIR"/password_pool_*.txt 2>/dev/null | wc -l || echo 0)
draw_info_card "当前池数量" "${count} 个"
