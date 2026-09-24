# User Manager

基于 Bash 的 Linux 多用户管理工具，覆盖用户生命周期管理、磁盘配额、备份、防火墙、审计与邮件通知等常见运维场景。

## Overview

- 统一入口：`run.sh`（默认进入 noTUI CLI 菜单）
- CLI 主程序：`user_manager.sh`
- TUI 可选界面：`tui_manager.sh`（通过 `--tui` 启用）
- 分级回归：`tests/run_regression.sh`

## 入口模式

- `bash run.sh`：默认进入 noTUI 经典 CLI 菜单。
- `bash run.sh --tui`：在支持 ANSI 光标定位的交互终端中进入原生 Bash TUI；`TERM=dumb`、管道或不支持的终端会提示原因并安全回退经典 CLI。
- `bash run.sh --no-tui` 或 `bash run.sh --cli`：兼容显式进入 noTUI。
- 无 TUI 模式下，压 0 或 q 直接返回上级菜单，无需回车。

## 独立 CLI 脚本

常用功能提供独立脚本，可直接调用无需启动完整菜单：

| 脚本 | 说明 |
| --- | --- |
| `scripts/rl-user-list.sh` | 列出所有托管用户 |
| `scripts/rl-user-create.sh` | 创建新用户 |
| `scripts/rl-user-quota.sh` | 磁盘配额设置/查询 |
| `scripts/rl-user-resource.sh` | cgroup v2 资源限制 |
| `scripts/rl-mail-test.sh` | 测试邮件发送 |
| `scripts/rl-backup-run.sh` | 触发用户备份 |
| `scripts/rl-audit-query.sh` | 审计日志查询 |
| `scripts/rl-smb-manage.sh` | SMB/Samba 账户与共享管理 |
| `scripts/rl-snapshot.sh` | Web 只读快照采集器（可信采集器，供 umweb 只读） |
| `scripts/rl-action-list.sh` | 列出/导出 Action 注册表，校验 handler |
| `scripts/rl-system-overview.sh` | 系统概览 (glances) |
| `scripts/rl-hosts.sh` | 本机/SSH 主机能力与 GPU 只读探测 |
| `scripts/rl-remote-entry.sh` | 供受管 SSH 主机调用的只读白名单入口 |

Action ID 完整列表见 `lib/action_registry.sh` 中 `action_register_defaults()` 函数。常用 action：

| Action ID | 说明 | 模式 | 风险 |
| --- | --- | --- | --- |
| `logs.boot` | 查看本次启动日志 | both | safe |
| `logs.failed_services` | 查看失败服务状态 | both | safe |
| `logs.service_recent` | 查看指定服务近期日志 | both | safe |
| `logs.boot_error_diff` | 对比启动错误日志变化 | both | safe |
| `logs.system_file_tail` | 查看传统系统日志文件尾部 | both | safe |
| `logs.auth_failures` | 查看认证失败记录 | both | safe |
| `system.timers.list` | 列出 systemd timers | both | safe |
| `system.timers.logs` | 查看 timer 相关日志 | both | safe |
| `host.probe` | 本机系统能力只读探测 | cli | safe |
| `gpu.summary` | GPU 结构化只读摘要 | cli | safe |
| `users.list` | 查看托管用户 | both | safe |
| `users.create` | 创建用户 | cli | dangerous |
| `users.quota` | 用户配额操作 | cli | dangerous |
| `users.resource` | 用户资源限制操作 | cli | dangerous |
| `mail.test` | 发送测试邮件 | cli | safe |
| `backup.run` | 执行用户备份 | cli | dangerous |
| `audit.query` | 查询审计日志 | cli | safe |
| `audit.view` | 查看审计日志 | both | safe |
| `smb.status` | SMB 服务状态 | both | safe |
| `smb.list` | 列出 SMB 用户 | both | safe |
| `smb.show` | 查看用户 SMB 状态 | both | safe |
| `smb.password` | 设置/创建 SMB 密码 | cli | dangerous |
| `smb.disable` | 禁用 SMB 用户 | cli | dangerous |
| `smb.enable` | 启用 SMB 用户 | cli | dangerous |
| `smb.remove` | 移除 SMB 用户 | cli | dangerous |
| `smb.shares` | 列出 SMB 共享 | both | safe |
| `smb.share.add` | 新增 SMB 共享 | cli | dangerous |
| `smb.share.remove` | 移除 SMB 共享 | cli | dangerous |
| `smb.include` | 主配置 include 托管配置 (status/ensure) | cli | dangerous |

## 跨主机只读探测

首期 SSH-FIRST 主机层仅支持系统能力与 GPU 摘要的**只读**探测。它使用非执行式 Inventory、专用 known_hosts、严格主机密钥校验和固定远端白名单命令；不接受密码、私钥路径或任意远端命令。

```bash
# 准备受管示例后，先验证，再纯本地试运行
install -d -m 700 data
install -m 600 etc/hosts.conf.example data/hosts.conf
bash scripts/rl-hosts.sh validate
bash scripts/rl-hosts.sh probe group:gpu --dry-run
```

实际 SSH 执行前，必须通过带外渠道核验并登记每个主机 ID 对应的密钥到 `data/ssh_known_hosts`。完整的配置、部署前提、安全边界、输出协议和示例见 [`docs/REMOTE_HOSTS.md`](docs/REMOTE_HOSTS.md)。

## Quick Start

使用统一入口启动：

```bash
bash run.sh
```

## Web 控制台与只读快照（P0–P7 实现状态）

Rust 后端提供 Web 用户/MFA/会话/token 管理、只读系统 API、审计/日志/报表、通知 inbox，以及企业微信配置、固定模板测试投递和投递历史。`web/frontend` 已有 React/Vite/Ant Design 页面，生产构建通过。系统状态快照还包含 Ubuntu、CPU/内存/压力、文件系统/inode、systemd、APT/reboot 和 AppArmor 的只读摘要。

可信采集器 `scripts/rl-snapshot.sh` 生成脱敏、版本化、原子的 JSON 快照，非特权 Web 服务 `umweb` 只读这些数据。Web 不持有 root/sudo/capability，也不执行 Linux 系统写操作。

CLI 用户创建/禁用事件现由 root event spool 只读送入 inbox，并按配置投递企业微信；相同事件类型与用户五分钟内只投递一次。当前生产者覆盖 `user.created`、`user.disabled`，事件目录中的登录安全和快照状态事件尚无生产者。

`v0.2.0` 已推送到 GitHub 并发布。尚未完成的验收包括前端浏览器视觉/响应式/无障碍检查、目标机服务与文件权限验证，以及在标准 root-owned `/tmp` 环境复跑 3 个 Host/SSH 回归套件。代码已发布但尚未部署；阶段详情和验证记录见 [`plan.md`](plan.md) 与 [`docs/M1_REPOSITORY_AUDIT.md`](docs/M1_REPOSITORY_AUDIT.md)。

```bash
# 手动生成全部快照到默认目录（部署时由 root + systemd timer 运行）
bash scripts/rl-snapshot.sh
# 生成到自定义目录并查看（调试）
bash scripts/rl-snapshot.sh --out /tmp/snap --dry-run users
```

安全边界、快照 schema、secret 脱敏与只读权限约定见：
[`docs/WEB_SECURITY_BOUNDARY.md`](docs/WEB_SECURITY_BOUNDARY.md)。

## Testing

运行完整分级回归：

```bash
bash tests/run_regression.sh --level all
```

仅运行核心行为回归：

```bash
bash tests/run_regression.sh --level p1
```

默认 P1 不重复跑全量 ShellCheck（CI 已有独立 ShellCheck job）；如需本地执行 ShellCheck warning 门禁：

```bash
bash tests/run_regression.sh --level p1 --include-lint
```

每个测试套件默认带 180 秒超时保护，可通过 `UM_TEST_TIMEOUT` 调整：

```bash
UM_TEST_TIMEOUT=300 bash tests/run_regression.sh --level p1
```

P1 默认并行执行（每个测试使用独立临时数据目录），并发数默认 4；如需关闭并行或调整并发：

```bash
bash tests/run_regression.sh --level p1 --no-parallel
UM_TEST_JOBS=8 bash tests/run_regression.sh --level p1
```

运行敏感文件与密钥扫描：

```bash
bash scripts/check_sensitive_files.sh .
```

## Documentation

- 架构设计与功能说明：[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
- 架构、入口和回归说明：[`docs/DEEPWIKI.md`](docs/DEEPWIKI.md)
- SSH 主机与 GPU 只读探测：[`docs/REMOTE_HOSTS.md`](docs/REMOTE_HOSTS.md)
- PR 模板与提交流程：[`.github/PULL_REQUEST_TEMPLATE.md`](.github/PULL_REQUEST_TEMPLATE.md)
