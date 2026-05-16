# User Manager

基于 Bash 的 Linux 多用户管理工具，覆盖用户生命周期管理、磁盘配额、备份、防火墙、审计与邮件通知等常见运维场景。

## Overview

- 统一入口：`run.sh`（默认进入 TUI 主线）
- TUI 主程序：`tui_manager.sh`
- 经典后端入口：`user_manager.sh`
- 分级回归：`tests/run_regression.sh`

## TUI 与无 TUI 模式

- `./run.sh`：进入原生 Bash TUI。
- `./run.sh --no-tui` 或 `./run.sh --cli`：进入无 TUI 菜单。
- 第一阶段优化后，日志相关能力通过共享 action ID 运行。TUI 和 CLI 使用同一套读取逻辑，只是展示方式不同。
- 缺少 `journalctl` / `systemctl` 时，程序会回落传统日志文件或显示空状态，不会自动安装依赖。

日志与 systemd timer 相关 action ID：

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
