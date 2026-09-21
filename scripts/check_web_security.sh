#!/bin/bash
# check_web_security.sh - Web Rust 源码安全门禁（plan.md 14.1/14.2/14.3）
#
# 目标：作为阻断式门禁，验证 web/backend/src 里的**生产代码**不含：
#   - 提权原语：sudo / su / pkexec / doas / setuid / setgid / CAP_*；
#   - 系统管理命令：useradd/userdel/usermod/chpasswd/setquota/quotaon/systemctl/
#     ufw/iptables/nft/smbpasswd/pdbedit/visudo/mount/umount/reboot/shutdown；
#   - 任意 shell/命令：任何 std::process::Command::new（P1 立场：Web 零外部进程派生）。
#
# 实现：先剥离注释再匹配，避免文档注释（说明“我们禁止 X”）误报。
# 退出码：0=通过；1=命中禁止项；2=用法/路径错误。
set -Eeuo pipefail
IFS=$'\n\t'

SRC_DIR="${1:-web/backend/src}"

if [[ ! -d "$SRC_DIR" ]]; then
    # 没有 web 源码目录时视为无事可做（例如纯 Bash 回归场景）。
    echo "check_web_security: src dir not found: $SRC_DIR (skip)" >&2
    exit 2
fi

# 提权 / 系统管理命令 token（词边界；在剥离注释后的代码中匹配）。
declare -a forbidden_tokens=(
    sudo su pkexec doas setuid setgid
    CAP_SYS_ADMIN CAP_SETUID CAP_SETGID CAP_DAC_OVERRIDE CAP_SYS_PTRACE CAP_NET_ADMIN
    useradd userdel usermod chpasswd setquota quotaon quotacheck
    systemctl ufw iptables nft firewall-cmd smbpasswd pdbedit visudo
    mount umount reboot shutdown modprobe chown
)

# 任意进程派生的硬禁止（P1：Web 不 fork shell/命令）。
declare -a forbidden_patterns=(
    'Command::new'
    'std::process::Command'
)

declare -a violations=()

while IFS= read -r -d '' file; do
    # 剥离行注释（// 到行尾）与块注释（/* ... */）后再匹配。
    stripped="$(perl -0pe 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g' "$file" 2>/dev/null || sed -E 's://.*$::' "$file")"

    for tok in "${forbidden_tokens[@]}"; do
        if grep -nE "(^|[^A-Za-z0-9_])${tok}([^A-Za-z0-9_]|$)" <<<"$stripped" >/dev/null 2>&1; then
            violations+=("${file}: token '${tok}'")
        fi
    done
    for pat in "${forbidden_patterns[@]}"; do
        if grep -nF -- "$pat" <<<"$stripped" >/dev/null 2>&1; then
            violations+=("${file}: pattern '${pat}'")
        fi
    done
done < <(find "$SRC_DIR" -type f -name '*.rs' -print0 2>/dev/null | sort -z)

if ((${#violations[@]} == 0)); then
    echo "check_web_security: OK (no forbidden tokens in $SRC_DIR)"
    exit 0
fi

echo "check_web_security: forbidden constructs detected in $SRC_DIR:" >&2
printf '  %s\n' "${violations[@]}" >&2
exit 1
