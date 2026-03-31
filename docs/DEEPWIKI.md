# User Manager - Linux多用户管理系统

一个功能完整的Linux用户管理系统，提供用户管理、配额控制、备份恢复、防火墙管理、邮件通知等功能。

## 项目概述

### 核心功能

| 模块 | 功能 | 文件 |
|------|------|------|
| **用户管理** | 创建/删除/修改用户、密码管理 | `lib/user_core.sh` |
| **磁盘配额** | 设置/查看磁盘配额 | `lib/quota_core.sh` |
| **备份恢复** | 增量备份、校验验证 | `lib/backup_core.sh`, `lib/backup_verify.sh` |
| **防火墙** | UFW规则管理、端口映射 | `lib/firewall_core.sh` |
| **邮件系统** | 异步发送、模板渲染 | `lib/email_core.sh`, `lib/email_daemon.sh` |
| **权限管理** | 四级权限、命令白名单 | `lib/privilege.sh`, `lib/access_control.sh` |
| **异步任务** | SQLite队列、后台处理 | `lib/async_core.sh`, `lib/proc_manager.sh` |

### 系统架构

```
user_manager.sh (主入口)
    ├── lib/
    │   ├── common.sh        # 核心工具、消息、锁机制
    │   ├── config.sh        # 配置常量
    │   ├── privilege.sh     # 权限封装层
    │   ├── async_core.sh    # 异步任务框架
    │   ├── proc_manager.sh  # 进程管理
    │   ├── email_core.sh    # 邮件发送
    │   ├── email_daemon.sh  # 邮件守护进程
    │   ├── backup_core.sh   # 备份功能
    │   ├── backup_verify.sh # 备份验证
    │   ├── firewall_core.sh # 防火墙管理
    │   ├── shell_config.sh  # Shell配置
    │   └── ...其他模块
    ├── data/               # 数据文件
    ├── templates/          # 模板文件
    └── logs/              # 日志文件
```

## 快速开始

### 依赖安装

```bash
# Ubuntu/Debian
sudo apt install -y sqlite3 jq msmtp msmtp-mta
```

### 运行

```bash
# 交互式菜单
bash run.sh
```

### 启动邮件守护进程

```bash
bash lib/email_daemon.sh start
bash lib/email_daemon.sh status
bash lib/email_daemon.sh stop
```

## API 参考

### 异步任务框架

```bash
task_id=$(async_submit "email" '{"to":"user@example.com"}')
async_status "$task_id"
async_wait "$task_id" 60
```

### 邮件发送

```bash
queue_id=$(send_password_email_async "alice" "password" "alice@example.com")
check_email_sent "$queue_id"
email_queue_stats
```

### 细粒度锁

```bash
acquire_user_lock "$username"
acquire_user_read_lock "$username"
acquire_user_write_lock "$username"
```

### 备份验证

```bash
generate_backup_checksum "/backup/path"
verify_backup_integrity "/backup/path"
verify_before_restore "/backup/path"
```

### 防火墙管理

```bash
validate_ipv4 "192.168.1.1"
detect_rule_conflicts "8080" "tcp" "alice"
delete_port_rule_safe "alice" "8080" "tcp"
```

### 权限检查

```bash
check_permission "user" "create"
require_permission "firewall" "add"
run_with_permission "backup" "restore" restore_backup "/path"
```

## 配置

### 邮件配置 (data/email_config.json)

```json
{
  "smtp_host": "smtp.example.com",
  "smtp_port": 587,
  "from_address": "admin@example.com"
}
```

## 版本历史

- **v0.3.0** (2024-03-31): TUI改造、异步框架、邮件优化、备份验证、防火墙增强
- **v0.2.0**: 配额管理、备份系统
- **v0.1.0**: 基础用户管理