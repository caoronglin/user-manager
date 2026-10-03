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
# 退出码：0=通过；1=命中禁止项**或未扫描到任何 .rs 源文件**；2=用法/路径错误。
#
# 空目录必须报错而不是静默通过：本脚本是阻断式门禁，“没扫到文件”既可能是路径传错、
# 也可能是源码被误删/误改名，两种情况下打印 OK 都是**门禁失效**，与 a4762a5 给 CI
# 权限检查加 `checked -eq 0` 守卫是同一类问题。
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
scanned=0

while IFS= read -r -d '' file; do
    scanned=$((scanned + 1))
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

# 遍历结果为空说明门禁本身失效（路径传错 / find 模式失效 / 源码被清空），
# 必须报错而不是静默放过。
if ((scanned == 0)); then
    echo "check_web_security: 未扫描到任何 .rs 源文件（$SRC_DIR），门禁失效，拒绝静默通过" >&2
    exit 1
fi

if ((${#violations[@]} == 0)); then
    echo "check_web_security: OK (no forbidden tokens in $SRC_DIR)"
    exit 0
fi

echo "check_web_security: forbidden constructs detected in $SRC_DIR:" >&2
printf '  %s\n' "${violations[@]}" >&2
exit 1
