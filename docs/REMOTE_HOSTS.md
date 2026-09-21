# 只读跨主机与 GPU 探测

本项目提供一个 **SSH-FIRST、无常驻 Agent** 的只读基础层，适合从管理机统一查看本机和少量远端 Linux 主机的系统能力与 GPU 概览。

> 首期只支持 `host.probe` 与 `gpu.summary`。它不创建用户、不修改配额、不变更 SMB/防火墙/备份配置，也不分发密钥、写 sudoers 或自动部署远端脚本。

## 运行前提

- 管理机：Ubuntu 24.04+、Bash 5+、OpenSSH client 和 `timeout`。
- 远端：已由受信任管理员部署同版本项目至固定路径 `/opt/user-manager/`，入口为 `/opt/user-manager/scripts/rl-remote-entry.sh`。
- 远端入口文件、其 `scripts/`/项目父目录必须不允许远端登录用户写入；本期不会自动安装或验证部署。
- 使用 SSH public-key 或 SSH agent 认证。Inventory 不接受密码、私钥路径、任意 SSH 选项或任意远端命令。

## 配置主机清单

从受管示例开始：

```bash
install -d -m 700 data
install -m 600 etc/hosts.conf.example data/hosts.conf
```

编辑 `data/hosts.conf` 时保留精确表头：

```text
host_id|display_name|provider|address|port|user|groups|tags|enabled
local|当前主机|local||||local|builtin|yes
compute-01|GPU 计算节点 01|ssh|gpu-01.example.net|22|ops|gpu,prod|rack-a|yes
```

字段规则：

- `host_id`：稳定 ASCII ID；远端主机 ID 也用作 `HostKeyAlias`。
- `provider`：仅 `local` 或 `ssh`。
- `address`：SSH 主机名、IPv4 或 IPv6 字面量；不接受 SSH alias、`@`、空白、前导 `-` 或 shell/SSH 选项形态。
- `port`：十进制 `1..65535`；`user` 为保守 SSH/Linux 用户名。
- `groups` 和 `tags`：逗号分隔的 ASCII 标识；`enabled=no` 的主机不会被选择或执行。
- 该文件必须是当前用户或 root 拥有的普通文件，不能是符号链接，且不能被组或其他用户写入。运行时还会检查大小、ACL 和父目录链。

## 带外登记 SSH 主机密钥

Provider 使用独立的 `data/ssh_known_hosts`，不读取系统或用户的 known_hosts，并强制：

```text
StrictHostKeyChecking=yes
UserKnownHostsFile=data/ssh_known_hosts
GlobalKnownHostsFile=/dev/null
HostKeyAlias=<host_id>
-F /dev/null
```

因此，先通过控制台、变更系统或其他受认证渠道核验远端主机指纹，再由管理员把已核验的**公钥行**写入该文件。键名必须等于 Inventory 的 `host_id`：

```bash
install -m 600 /dev/null data/ssh_known_hosts
# 仅在已经带外核验公钥和 SHA256 指纹后追加：
printf '%s\n' 'compute-01 ssh-ed25519 AAAA...经核验的公钥...' >> data/ssh_known_hosts
chmod 600 data/ssh_known_hosts
ssh-keygen -F compute-01 -f data/ssh_known_hosts
```

不要把 `ssh-keyscan` 的网络结果当作身份验证本身；它可用于采集候选公钥，但必须先与独立可信渠道比对。未知或变化的密钥不会被自动接受或写入文件。

可针对临时受控位置使用：

```bash
bash scripts/rl-hosts.sh --known-hosts /secure/path/known_hosts validate
```

## 使用方式

先进行纯本地验证与试运行：

```bash
bash scripts/rl-hosts.sh validate
bash scripts/rl-hosts.sh list
bash scripts/rl-hosts.sh probe group:gpu --dry-run
```

实际只读探测：

```bash
bash scripts/rl-hosts.sh probe local
bash scripts/rl-hosts.sh probe compute-01
bash scripts/rl-hosts.sh probe all
bash scripts/rl-hosts.sh gpu group:gpu
```

`--dry-run` 只加载 Inventory、展开目标并打印计划：不会调用 Provider、SSH、DNS、远端能力探测或更改 known_hosts。每批最多 20 个启用目标，按 Inventory 顺序串行执行；一台主机失败不会阻止后续主机。

输出采用固定的 `key=value` 协议，便于自动化消费：`plan.*` 描述计划，`result.*` 描述每台主机，`summary.*` 描述最终汇总。不要使用 `source` 或 `eval` 解析输出。退出码语义为：

| 退出码 | 含义 |
| --- | --- |
| 0 | 全部成功 |
| 1 | 至少一台主机失败或不可达 |
| 2 | 参数、动作白名单或计划错误 |
| 4 | 没有失败，但至少一台能力不支持（例如没有 GPU） |
| 5 / 6 | Provider/传输或协议错误 |

## 安全执行边界

- 客户端只会在代码内从两条**完整常量**远端命令中选择：
  `/opt/user-manager/scripts/rl-remote-entry.sh host.probe` 与
  `/opt/user-manager/scripts/rl-remote-entry.sh gpu.summary`。
  OpenSSH 最终以远端命令文本运行，因此没有把用户输入、Inventory 展示字段或路径拼入远端命令。
- 连接使用 `BatchMode=yes`，禁用口令/键盘交互、转发、ProxyCommand、ProxyJump、RemoteCommand 和用户 SSH config；无密钥或认证失败不会弹出交互式密码提示。
- 设置连接超时、ServerAlive 和每主机动作总超时；超时后不自动重试，并继续后续主机。
- `host.probe` 仅报告系统、架构、Bash、systemd/cgroup 和可用 GPU 后端。`gpu.summary` 优先使用 `nvidia-smi`，失败时降级 `lspci`，再降级为 `unsupported`。不读取环境变量、`/proc/*/cmdline` 或完整命令行；进程名称只保留首个短 token。
- Provider 对远端 stdout 实施版本、字段、重复键、控制字符、行数与总字节校验；异常输出标记为 `PROTOCOL_ERROR`，不会作为 shell 代码执行。

## TUI 与 SSH 终端

全屏 TUI 需要交互式 stdin/stdout、非 `TERM=dumb` 终端和 `tput cup` 光标寻址能力。可检查当前环境：

```bash
bash tui_manager.sh --check-terminal
```

在 `TERM=dumb`、管道或不支持全屏控制序列的 SSH 会话中，`bash run.sh --tui` 会显示原因并自动回退到经典 CLI；默认 `bash run.sh` 本来就是经典 CLI。

## 当前边界

本层不提供 GPU 调度、预约、MIG、容器隔离、公平共享、跨主机事务/回滚、自动故障转移、并发批量执行、远端脚本自动部署或 SSH 密钥登记。后续任何需要动态远端参数的功能必须先设计版本化 stdin 协议或服务端 forced command，不能扩展为任意 SSH 命令执行。
