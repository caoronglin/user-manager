#!/bin/bash
# rl-chpasswd.sh - 最小化 chpasswd 专用 wrapper（密码传递加固）
# 用法: rl-chpasswd <username>
# 密码仅从 stdin 读取（单行），不接收密码参数，避免明文出现在 ps/命令行/审计日志。
# 权限提升由 sudoers 提供（%useradm ALL=(root) NOPASSWD: /usr/local/sbin/rl-chpasswd，
# 另有 !/usr/local/sbin/rl-chpasswd root 反向规则；sudo-rs 不支持命令参数通配符，
# 用户名字符集由 wrapper 校验，sudoers 仅命令级授权 + root 反向防护），wrapper 自身不提升权限。
set -euo pipefail

# 固定安全 locale：防止 locale 影响用户名正则（实测 zh_CN.utf8/en_US.utf8 下 é 会匹配
# [a-z] 字符类），统一在 C locale 下执行校验与后续命令。
export LC_ALL=C LANG=C

# 固定安全 PATH：不再信任调用者继承的 PATH（可能被劫持），
# 后续所有外部命令（env/chpasswd）均在固定 PATH 下解析为绝对路径。
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# 在脚本启动时解析 env / chpasswd 绝对路径（仅一次），并校验为绝对路径；
# 解析基于已固定的安全 PATH，杜绝经不可信 PATH 间接执行或传给 chpasswd。
rl_env_bin="$(command -v env || true)"
rl_chpasswd_bin="$(command -v chpasswd || true)"
if [[ "$rl_env_bin" != /* || "$rl_chpasswd_bin" != /* ]]; then
    echo "rl-chpasswd: 无法解析 env/chpasswd 绝对路径（固定 PATH 下应始终存在）" >&2
    exit 1
fi

rl_usage() {
    echo "用法: rl-chpasswd <username>" >&2
    echo "密码从 stdin 读取: printf '%s\\n' \"\$password\" | rl-chpasswd <username>" >&2
}

# 仅接受 1 个参数（用户名）；密码不得作为参数传入
if [[ $# -ne 1 ]]; then
    echo "rl-chpasswd: 仅接受 1 个参数（用户名），密码必须从 stdin 提供" >&2
    rl_usage
    exit 1
fi

rl_user="$1"

# 用户名白名单校验（用户名字符集仅由 wrapper 把关；LC_ALL=C 下正则不受 locale 影响）
if [[ ! "$rl_user" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    echo "rl-chpasswd: 非法用户名 '$rl_user'" >&2
    exit 1
fi

# 禁止修改 root 密码（sudoers 反向规则之外的双重防护）
if [[ "$rl_user" == "root" ]]; then
    echo "rl-chpasswd: 禁止修改 root 密码" >&2
    exit 1
fi

# 从 stdin 读取密码（单行；IFS= 保留前导/尾随空白）
IFS= read -r rl_password || {
    echo "rl-chpasswd: 无法从 stdin 读取密码" >&2
    exit 1
}

if [[ -z "$rl_password" ]]; then
    echo "rl-chpasswd: 密码不能为空" >&2
    exit 1
fi

# 构造受控 stdin：将 "user:password" 经无名管道注入 fd 0（不落盘、不落命令行/ps），
# 之后 exec 替换进程，chpasswd 直接从 fd 0 读取；密码仅存在于该管道中，进程退出即消失。
exec 0< <(printf '%s:%s\n' "$rl_user" "$rl_password")

# 关闭全部非标准继承 fd（3..63；保留 0/1/2）：fd 是 env -i 不清理的注入面
# （env -i 只清环境变量不清 fd），exec 前显式关闭，新进程仅持有受控的 0/1/2。
for rl_fd in {3..63}; do
    eval "exec $rl_fd>&- 2>/dev/null" || true
done

# exec 替换进程（"exec 前关闭多余 fd"的落实）：env -i 清空 LD_PRELOAD/BASH_ENV/ENV/
# SHELLOPTS 等环境注入面，固定安全 PATH 与 C locale；命令行仅含用户名（密码只存在于
# stdin 管道，不落命令行/ps/审计日志）。
exec "$rl_env_bin" -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C "$rl_chpasswd_bin" "$rl_user"
