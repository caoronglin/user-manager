# User Manager

基于 Bash 的 Linux 多用户管理工具，覆盖用户生命周期管理、磁盘配额、备份、防火墙、审计与邮件通知等常见运维场景。

## Overview

- 统一入口：`run.sh`（默认进入 noTUI CLI 菜单）
- CLI 主程序：`user_manager.sh`
- TUI 可选界面：`tui_manager.sh`（通过 `--tui` 启用）
- 分级回归：`tests/run_regression.sh`

## 入口模式

- `bash run.sh`：默认进入 noTUI 经典 CLI 菜单。
- `bash run.sh --tui`：进入原生 Bash TUI 界面。
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
| `scripts/rl-system-overview.sh` | 系统概览 (glances) |

以下仅列第一批日志与 systemd timer action ID，不代表完整 registry：

| Action ID | 说明 |
| --- | --- |
| `logs.boot` | 查看本次启动日志 |
| `logs.failed_services` | 查看失败服务状态 |
| `logs.service_recent` | 查看指定服务近期日志 |
| `logs.boot_error_diff` | 对比启动错误日志变化 |
| `logs.system_file_tail` | 查看传统系统日志文件尾部 |
| `logs.auth_failures` | 查看认证失败记录 |
| `system.timers.list` | 列出 systemd timers |
| `system.timers.logs` | 查看 timer 相关日志 |

## Quick Start

使用统一入口启动：

```bash
bash run.sh
```

## Testing

运行完整分级回归：

```bash
bash tests/run_regression.sh --level all
```

仅运行核心行为回归：

```bash
bash tests/run_regression.sh --level p1
```

运行敏感文件与密钥扫描：

```bash
bash scripts/check_sensitive_files.sh .
```

## Documentation

- 架构、入口和回归说明：[`docs/DEEPWIKI.md`](docs/DEEPWIKI.md)
- PR 模板与提交流程：[`.github/PULL_REQUEST_TEMPLATE.md`](.github/PULL_REQUEST_TEMPLATE.md)
