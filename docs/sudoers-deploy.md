# sudoers 部署：rl-chpasswd（密码传递加固）

本仓库提供密码修改的最小化专用 wrapper `scripts/rl-chpasswd.sh`，密码只经 stdin
传递，不接收密码参数，避免明文出现在 `ps`、shell 历史与审计日志中。root 权限由
sudoers 规则提供，wrapper 自身不提升权限。

## 前置条件

- 系统使用 `sudo`（Debian/Ubuntu 及派生发行版）。
- 存在 `useradm` 用户组（可自行调整模板中的组名）。
- 仓库位于服务器上（或仅拷贝下述两个文件，保持相对路径无关，因为部署后
  wrapper 安装到 `/usr/local/sbin`，sudoers 只引用该绝对路径）。

## 部署步骤

在仓库根目录以 root 执行：

```bash
# 1. 安装 wrapper（权限 755，属主 root:root）
install -m 0755 -o root -g root scripts/rl-chpasswd.sh /usr/local/sbin/rl-chpasswd

# 2. 安装 sudoers 规则（权限 440，属主 root:root；文件名不得含 . 或 ~）
install -m 0440 -o root -g root etc/sudoers.d/user-manager.example /etc/sudoers.d/user-manager

# 3. 语法校验（必须输出 "parsed OK" 之类通过信息）
visudo -c -f /etc/sudoers.d/user-manager

# 4. 全量校验（可选，确认与主 sudoers 合并无冲突）
visudo -c
```

## 测试

wrapper 的 stdin 协议是**仅密码**（单行），用户名为唯一位置参数；示例用
`read -rsp` 交互读取密码（不回显、不落 shell 历史），`unset` 立即清除：

```bash
# 正向：合法用户名，密码仅经 stdin 传递
read -rsp '密码: ' password; printf '\n'
printf '%s\n' "$password" | sudo /usr/local/sbin/rl-chpasswd alice
unset password

# 反向：root 目标应被拒绝（wrapper 校验 + sudoers 反向规则双重防护）
read -rsp '密码: ' password; printf '\n'
printf '%s\n' "$password" | sudo /usr/local/sbin/rl-chpasswd root; echo "exit=$?"
unset password

# 反向：非法用户名应被拒绝（sudoers 已授权该命令，由 wrapper 用户名白名单拒绝）
read -rsp '密码: ' password; printf '\n'
printf '%s\n' "$password" | sudo /usr/local/sbin/rl-chpasswd 'alice;touch /tmp/pwned'; echo "exit=$?"
unset password

# 反向：多余参数应被拒绝（密码不得作为参数传入）
read -rsp '密码: ' password; printf '\n'
printf '%s\n' "$password" | sudo /usr/local/sbin/rl-chpasswd alice extra; echo "exit=$?"
unset password

# 确认密码不落命令行（无 root 密码的情况下，ps 中仅见用户名）
ps aux | grep rl-chpasswd
```

## 回滚

以 root 执行：

```bash
# 1. 移除 sudoers 规则
rm -f /etc/sudoers.d/user-manager
visudo -c

# 2. 移除 wrapper（可选，取决于是否仍有其他调用方）
rm -f /usr/local/sbin/rl-chpasswd
```

回滚后，`priv_chpasswd` 对已升级的系统将无法再修改密码；仓库内 `lib/privilege.sh`
默认委托该 wrapper，若系统未部署 wrapper 且业务需要，可在 `priv_chpasswd` 中回退
为直接委托 `chpasswd`（不推荐，会重新暴露明文密码传递面）。

## 安全说明

- **只接受 stdin**：wrapper 仅接受 1 个参数（用户名），密码必须来自 stdin，从
  命令行传入密码会被拒绝（参数个数校验），因此密码不会出现在 `ps` 或 sudoers
  审计中。
- **不落盘**：wrapper 与 `priv_chpasswd` 均不将密码写入临时文件、日志或审计记录；
  审计只记录 `PRIV_EXEC <wrapper路径> <用户名>`。
- **环境清理**：wrapper 启动时即固定安全 `PATH=/usr/sbin:/usr/bin:/sbin:/bin`
  与 `LC_ALL=C`（防止 locale 影响用户名正则），并以 `command -v` 解析
  `env`/`chpasswd` 绝对路径（校验为绝对路径，不信任调用者继承的 PATH）；
  读取密码后经无名管道注入 stdin、关闭全部非标准继承 fd（3..63），再
  `exec /usr/bin/env -i PATH=... LC_ALL=C /usr/sbin/chpasswd <用户名>` 替换
  进程，清空 `LD_PRELOAD`/`LD_LIBRARY_PATH`/`BASH_ENV`/`ENV`/`SHELLOPTS`
  等环境注入面，fd 注入面一并关闭。
- **用户名白名单**：用户名字符集由 wrapper 严格校验（`^[a-z_][a-z0-9_-]*$` 且禁止
  `root`）；sudoers 仅做命令级授权 + root 反向防护（`!/usr/local/sbin/rl-chpasswd
  root`，sudoers 最后匹配优先），不依赖命令参数通配符——sudo-rs 明确拒绝命令参数
  通配符（`wildcards are not allowed in command arguments`），因此用户名合法性
  完全由 wrapper 把关。
- **文件权限**：sudoers 文件必须为 root:root 且 0440，否则 `sudo` 拒绝加载；
  部署后应运行 `visudo -c` 验证。
- **sudoers 语法注意**：文件名不得包含 `.`（点）或 `~`，否则被 `sudo` 忽略。
