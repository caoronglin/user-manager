# 用户与系统管理器 Wiki

## 目录

1. [概述](#概述)
2. [快速开始](#快速开始)
3. [功能模块](#功能模块)
4. [系统维护功能](#系统维护功能)
5. [权限系统](#权限系统)
6. [配置说明](#配置说明)
7. [常见问题](#常见问题)

---

## 概述

用户与系统管理器是一个 Bash 脚本套件，用于管理 Ubuntu/Debian 系统上的用户、资源、备份和安全。

### 版本信息

- **当前版本**: v0.2.1
- **发布日期**: 2026-03-03
- **支持系统**: Ubuntu/Debian

### 主要特性

- 📦 用户管理 (创建/删除/修改/配额)
- 💾 备份与恢复
- 🔒 防火墙与 DNS 控制
- 📊 系统监控与分析
- 🔐 密码轮换
- 🐍 Miniforge 自动安装

---

## 快速开始

### 安装

```bash
# 克隆或下载项目
cd /opt
git clone <repository> user_manager
cd user_manager

# 运行主程序
bash run.sh
```

### 依赖检查

```bash
# 必需依赖
sudo apt-get install -y jq awk sed grep

# 可选依赖
sudo apt-get install -y htop btop rsnapshot ufw msmtp
```

---

## 功能模块

### 1. 用户管理

| 功能 | 描述 |
|------|------|
| 创建用户 | 自动配置配额、Miniforge |
| 删除用户 | 清理所有关联资源 |
| 修改密码 | 单用户或批量修改 |
| 重命名用户 | 自动迁移所有配置 |
| 暂停/启用 | 临时禁用账户 |

### 2. 资源管理

| 功能 | 描述 |
|------|------|
| 配额设置 | 磁盘空间限制 |
| CPU 限制 | systemd cgroup 控制 |
| 内存限制 | 防止内存滥用 |

### 3. 备份系统

```bash
# 手动备份
bash run.sh → 选择 "备份与恢复" → "手动备份用户"

# 定时备份
# 系统会自动创建 cron 任务
```

---

## 系统维护功能

### 新增功能 (v0.2.1)

#### 1. 系统信息概览

显示完整的系统硬件和软件信息：

```
系统: Dell Inc. PowerEdge R740
BIOS: 2.8.1
操作系统: Ubuntu 22.04.3 LTS
内核版本: 5.15.0-91-generic
启动模式: UEFI
```

#### 2. 内存信息 (dmidecode)

使用 `dmidecode -t memory` 获取详细内存信息：

```
━━━ 内存设备 #1 ━━━
大小: 32 GB
定位器: DIMM_A1
类型: DDR4
速度: 3200 MT/s
制造商: Samsung
━━━ 系统内存概览 ━━━
总内存: 128GB
已使用: 45GB
可用: 83GB
```

#### 3. btop 资源监控

现代化的系统资源监控工具：
- CPU 使用率和频率
- 内存和 Swap 使用
- 磁盘 I/O
- 网络流量
- 进程列表

```bash
# 安装 btop
sudo apt-get install -y btop

# 启动监控
bash run.sh → 系统维护 → 启动 btop 监控
```

#### 4. 硬件健康检查

自动检测硬件问题：

- CPU 温度监控
- 风扇状态
- 电池状态 (笔记本)
- 磁盘 SMART 健康状态
- 内存 ECC 错误

#### 5. 系统日志分析

自动分析多个日志源：

```
━━━ Journalctl 错误日志 ━━━
━━━ Syslog 错误记录 ━━━
━━━ 内核日志错误 ━━━
━━━ 日志统计 ━━━
Syslog 错误数: 127
内核日志错误数: 15
Journalctl 错误数: 42
```

#### 6. 崩溃原因分析

诊断系统崩溃和异常：

- 系统崩溃转储 (`/var/crash`)
- 内核恐慌 (Kernel Panic)
- 硬件错误 (MCE)
- OOM 杀手记录
- 服务失败
- 磁盘错误

---

## 权限系统

### 权限级别

| 级别 | 数值 | 描述 |
|------|------|------|
| root | 0 | 超级用户，无限制 |
| admin | 1 | 管理员，大部分特权操作 |
| user | 2 | 普通用户，有限操作 |
| guest | 3 | 访客，只读操作 |

### 命令白名单

所有特权命令必须在白名单中定义：

```bash
# lib/privilege.sh
readonly -A PRIV_CMD_WHITELIST=(
    ["useradd"]="$ACL_LEVEL_ADMIN"
    ["dmidecode"]="$ACL_LEVEL_ADMIN"
    ["smartctl"]="$ACL_LEVEL_ADMIN"
    # ...
)
```

### 审计日志

所有特权操作都会记录到审计日志：

```
/var/log/audit.log
```

---

## 配置说明

### 主配置文件

| 文件 | 描述 |
|------|------|
| `data/user_config.json` | 用户配置 |
| `data/email_config.json` | 邮件设置 |
| `data/password_pool.txt` | 密码池 |
| `data/dns_whitelist.txt` | DNS 白名单 |

### 模块配置

编辑 `lib/config.sh` 修改默认值：

```bash
DATA_BASE="/mnt"
QUOTA_DEFAULT=$((500 * 1024**3))  # 500GB
PASSWORD_ROTATE_INTERVAL_DAYS=90
```

---

## 常见问题

### Q: 如何查看系统崩溃原因？

```bash
bash run.sh → 系统维护 → 崩溃原因分析
```

### Q: 如何查看内存详细信息？

```bash
bash run.sh → 系统维护 → 内存信息 (dmidecode)
```

### Q: 如何监控系统资源？

```bash
# 方式1: 使用 btop (推荐)
bash run.sh → 系统维护 → 启动 btop 监控

# 方式2: 使用 htop
bash run.sh → 系统维护 → 启动 htop 监控
```

### Q: 如何检查硬件健康？

```bash
bash run.sh → 系统维护 → 硬件健康检查
```

### Q: 密码池在哪里？

```bash
# 密码池位置
data/password_pool.txt

# 重新生成密码池
bash regenerate_password_pool.sh
```

### Q: 如何修改权限配置？

编辑 `lib/privilege.sh` 中的 `PRIV_CMD_WHITELIST` 数组。

---

## 文件结构

```
/home/crl/code/user/
├── user_manager.sh           # 主程序
├── run.sh                     # 入口脚本
├── regenerate_password_pool.sh # 密码池生成
├── lib/
│   ├── common.sh             # 通用工具
│   ├── config.sh             # 配置管理
│   ├── access_control.sh     # 权限控制
│   ├── privilege.sh          # 特权操作
│   ├── system_core.sh        # 系统维护
│   ├── user_core.sh          # 用户管理
│   ├── quota_core.sh         # 配额管理
│   ├── backup_core.sh        # 备份恢复
│   ├── firewall_core.sh      # 防火墙
│   ├── dns_core.sh           # DNS 控制
│   └── ...
├── data/
│   ├── user_config.json      # 用户配置
│   ├── password_pool.txt     # 密码池
│   └── created_users.txt     # 操作日志
└── logs/                      # 日志目录
```

---

## 更新日志

### v0.2.1 (2026-03-03)

**新增功能:**
- ✨ btop 资源监控集成
- ✨ 内存信息显示 (dmidecode)
- ✨ 系统日志分析
- ✨ 崩溃原因诊断
- ✨ 硬件健康检查
- 🔐 权限最小化 (ACL 四级权限)
- 🎨 现代化玻璃拟态 UI

**改进:**
- 📦 模块化解耦设计
- 📝 完善 WIKI 文档

---

## 支持

如有问题，请检查：
1. 日志文件: `logs/` 目录
2. 系统日志分析功能
3. 权限配置: `lib/privilege.sh`