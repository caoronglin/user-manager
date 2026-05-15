# User Manager

基于 Bash 的 Linux 多用户管理工具，覆盖用户生命周期管理、磁盘配额、备份、防火墙、审计与邮件通知等常见运维场景。

## Overview

- 统一入口：`run.sh`（默认进入 TUI 主线）
- TUI 主程序：`tui_manager.sh`
- 经典后端入口：`user_manager.sh`
- 分级回归：`tests/run_regression.sh`

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
