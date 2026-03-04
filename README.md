# User Manager - Linux Multi-User System Manager

<div align="center">

**English** | [中文](#中文说明)

[![CI](https://github.com/user-manager/user-manager/actions/workflows/ci.yml/badge.svg)](https://github.com/user-manager/user-manager/actions/workflows/ci.yml)
[![ShellCheck](https://img.shields.io/badge/shellcheck-passing-brightgreen)]()
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![Bash](https://img.shields.io/badge/bash-4.0+-blue)]()

**Pure Bash user management for AI/ML multi-user environments**

</div>

---

## 🚀 Features

### Core Functionality

| Category | Features |
|----------|----------|
| **User Management** | Create/Update/Delete users, rename, suspend/resume, password rotation |
| **Resource Quotas** | Disk quotas (via quota), CPU limits, memory limits |
| **Backup & Restore** | Manual/scheduled/batch/parallel backup with rsnapshot |
| **Security** | Firewall rules (UFW), DNS access control, ACL management |
| **AI/ML Ready** | Auto Miniforge installation, conda environment isolation |
| **Monitoring** | Job statistics, resource usage reports, anomaly detection |
| **Email Notifications** | Password delivery, quota warnings, account status |

### Why Choose This?

✅ **Zero Dependencies** - Pure Bash, no Python/Node required  
✅ **AI/ML Optimized** - Built-in Miniforge/conda management  
✅ **Multi-User Isolation** - ACLs, quotas, resource limits  
✅ **Production Ready** - Retry logic, logging, audit trail  
✅ **Lightweight** - No常驻 processes, executes on-demand  

---

## 📦 Installation

### Requirements

- **OS**: Ubuntu 20.04+ / Debian 10+
- **Bash**: 4.0+
- **Required commands**: `awk`, `sed`, `grep`, `id`, `useradd`, `usermod`, `userdel`, `passwd`, `setquota`, `repquota`
- **Optional**: `jq`, `rsnapshot`, `ufw`, `msmtp/sendmail`, `htop`, `tailscale`

### Quick Install

```bash
# Clone repository
git clone https://github.com/user-manager/user-manager.git
cd user-manager

# Verify installation
bash run.sh
```

### Optional: Install Dependencies

```bash
# Recommended packages
sudo apt install jq rsnapshot ufw msmtp htop

# Email setup (example for 163.com)
sudo apt install msmtp msmtp-mta
```

---

## 🎯 Quick Start

### 1. Launch Main Program

```bash
bash run.sh
# or
bash user_manager.sh
```

### 2. Create Your First User

```
Main Menu → 1. Create/Update User
→ Enter username: alice
→ Choose disk: 1 (data01)
→ Install Miniforge? Y
→ Enter email: alice@example.com
→ Send password email? Y
```

### 3. Verify User

```bash
# Check user exists
id alice

# Verify Miniforge
su - alice -c "conda --version"

# Check disk quota
quota -u alice
```

---

## 📁 Project Structure

```
user-manager/
├── user_manager.sh          # Main program (menu-driven)
├── run.sh                    # Entry point
├── Miniforge.sh              # Miniforge installer (~100MB)
├── lib/
│   ├── common.sh             # Core utilities
│   ├── user_core.sh          # User CRUD
│   ├── quota_core.sh         # Quota management
│   ├── backup_core.sh        # Backup/restore
│   ├── email_core.sh         # Email system
│   ├── firewall_core.sh      # UFW management
│   ├── dns_core.sh           # DNS restrictions
│   ├── miniforge_core.sh     # Miniforge installer
│   └── ...
├── data/
│   ├── user_config.json      # User configuration
│   ├── email_config.json     # SMTP settings
│   ├── password_pool.txt     # Password pool (auto-generated)
│   └── ...
├── templates/
│   └── email/                # Email templates
├── scripts/                  # Utility scripts
└── tests/                    # Test framework
```

---

## 🔧 Configuration

### Main Configuration (`lib/config.sh`)

```bash
# Disk quota default
QUOTA_DEFAULT=$((500 * 1024**3))  # 500GB

# Password rotation interval
PASSWORD_ROTATE_INTERVAL_DAYS=90

# Miniforge install path
MINIFORGE_DEFAULT_PATH=".miniforge"
```

### Email Configuration (`data/email_config.json`)

```json
{
  "smtp_server": "smtp.example.com",
  "smtp_port": "587",
  "smtp_user": "noreply@example.com",
  "smtp_password": "your_password",
  "from_address": "noreply@example.com",
  "from_name": "User Manager",
  "use_starttls": true
}
```

⚠️ **Security**: Set permissions to `600`:
```bash
chmod 600 data/email_config.json
```

---

## 📚 Documentation

- **[User Guide](README.md#中文说明)** - Chinese documentation
- **[AGENTS.md](AGENTS.md)** - Development guidelines
- **[WIKI.md](WIKI.md)** - Advanced features
- **[CHANGELOG.md](CHANGELOG.md)** - Version history

---

## 🧪 Testing

### Run Tests

```bash
# Run test framework
bash tests/test_framework.sh

# Run specific test
bash tests/test_user_core.sh

# ShellCheck
shellcheck -x *.sh lib/*.sh scripts/*.sh
```

### CI/CD

GitHub Actions runs on every push:
- ShellCheck static analysis
- Bash syntax validation
- Test suite execution
- Security scans

---

## 🔒 Security

### Sensitive Files

The following files should **NEVER** be committed:
- `data/password_pool.txt`
- `data/email_config.json`
- `data/user_config.json`
- `logs/`

These are excluded via `.gitignore`.

### Best Practices

1. **File Permissions**:
   ```bash
   chmod 600 data/email_config.json
   chmod 600 data/password_pool.txt
   chmod 700 data/
   ```

2. **Password Delivery**: Use email or secure channels
3. **Audit Logs**: Review `logs/` regularly
4. **Minimize Privileges**: Run with least privilege necessary

---

## 🤝 Contributing

We welcome contributions! Please see our [Contributing Guide](.github/PULL_REQUEST_TEMPLATE.md) for details.

### Development Workflow

1. Fork the repo
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit changes (`git commit -m 'Add amazing feature'`)
4. Push to branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

### Code Standards

- Follow [AGENTS.md](AGENTS.md) style guide
- All scripts must pass ShellCheck
- Add tests for new features
- Update documentation

---

## 📊 Roadmap

### v0.3.0 (Q2 2026)
- [ ] Plugin system
- [ ] Web UI (optional)
- [ ] Prometheus metrics export
- [ ] Multi-language support (i18n)

### v0.2.0 (Q1 2026) ✅
- [x] Email system refactor
- [x] Template system
- [x] Audit integration
- [x] CI/CD setup

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).

---

## 🙏 Acknowledgments

- Inspired by Webmin and Ajenti
- Uses [rsnapshot](https://rsnapshot.org/) for backups
- Miniforge from [conda-forge](https://github.com/conda-forge/miniforge)

---

## 📞 Support

- **Issues**: [GitHub Issues](https://github.com/user-manager/user-manager/issues)
- **Discussions**: [GitHub Discussions](https://github.com/user-manager/user-manager/discussions)
- **Email**: support@user-manager.local

---

<div align="center">

**Made with ❤️ for AI/ML research teams**

</div>

---

# 中文说明

<div align="center">

[English](#user-manager---linux-multi-user-system-manager) | **中文**

**面向 AI/ML 多用户环境的纯 Bash 用户管理系统**

</div>

---

## 🚀 功能特性

### 核心功能

| 类别 | 功能 |
|------|------|
| **用户管理** | 创建/更新/删除用户、重命名、暂停/启用、密码轮换 |
| **资源配额** | 磁盘配额（quota）、CPU 限制、内存限制 |
| **备份恢复** | 手动/定时/批量/并行备份（rsnapshot） |
| **安全管理** | 防火墙规则（UFW）、DNS 访问控制、ACL 管理 |
| **AI/ML 就绪** | 自动 Miniforge 安装、conda 环境隔离 |
| **监控报告** | 作业统计、资源使用报告、异常检测 |
| **邮件通知** | 密码投递、配额警告、账户状态通知 |

### 为什么选择？

✅ **零依赖** - 纯 Bash，无需 Python/Node  
✅ **AI/ML 优化** - 内置 Miniforge/conda 管理  
✅ **多用户隔离** - ACL、配额、资源限制  
✅ **生产就绪** - 重试机制、日志、审计追踪  
✅ **轻量级** - 无驻进程，按需执行  

---

## 📦 安装

### 系统要求

- **操作系统**: Ubuntu 20.04+ / Debian 10+
- **Bash**: 4.0+
- **必需命令**: `awk`, `sed`, `grep`, `id`, `useradd`, `usermod`, `userdel`, `passwd`, `setquota`, `repquota`
- **可选**: `jq`, `rsnapshot`, `ufw`, `msmtp/sendmail`, `htop`, `tailscale`

### 快速安装

```bash
# 克隆仓库
git clone https://github.com/user-manager/user-manager.git
cd user-manager

# 验证安装
bash run.sh
```

### 安装依赖（可选）

```bash
# 推荐包
sudo apt install jq rsnapshot ufw msmtp htop

# 邮件配置（以 163 邮箱为例）
sudo apt install msmtp msmtp-mta
```

---

## 🎯 快速开始

### 1. 启动主程序

```bash
bash run.sh
```

### 2. 创建第一个用户

```
主菜单 → 1. 创建/更新用户
→ 输入用户名：alice
→ 选择磁盘：1 (data01)
→ 安装 Miniforge？Y
→ 输入邮箱：alice@example.com
→ 发送邮件通知？Y
```

### 3. 验证用户

```bash
# 检查用户存在
id alice

# 验证 Miniforge
su - alice -c "conda --version"

# 检查磁盘配额
quota -u alice
```

---

## 📚 文档

- **[快速开始](#快速开始)** - 3 步启动
- **[功能菜单](#菜单功能)** - 详细功能说明
- **[配置说明](#配置)** - 配置文件详解
- **[故障排查](#故障排查)** - 常见问题

---

## 🔧 配置说明

### 主配置文件 (`lib/config.sh`)

```bash
# 默认磁盘配额
QUOTA_DEFAULT=$((500 * 1024**3))  # 500GB

# 密码轮换间隔
PASSWORD_ROTATE_INTERVAL_DAYS=90

# Miniforge 安装路径
MINIFORGE_DEFAULT_PATH=".miniforge"
```

### 邮箱配置 (`data/email_config.json`)

```json
{
  "smtp_server": "smtp.163.com",
  "smtp_port": "587",
  "smtp_user": "your_account@163.com",
  "smtp_password": "your_password",
  "from_address": "your_account@163.com",
  "from_name": "用户管理系统",
  "use_starttls": true
}
```

⚠️ **安全**：设置权限为 `600`：
```bash
chmod 600 data/email_config.json
```

---

## 🧪 测试

### 运行测试

```bash
# 运行测试框架
bash tests/test_framework.sh

# 运行特定测试
bash tests/test_user_core.sh

# ShellCheck 检查
shellcheck -x *.sh lib/*.sh scripts/*.sh
```

### 持续集成

GitHub Actions 在每次推送时运行：
- ShellCheck 静态分析
- Bash 语法验证
- 测试套件执行
- 安全扫描

---

## 🔒 安全说明

### 敏感文件

以下文件**绝不**应提交到仓库：
- `data/password_pool.txt`
- `data/email_config.json`
- `data/user_config.json`
- `logs/`

这些已通过 `.gitignore` 排除。

### 安全最佳实践

1. **文件权限**：
   ```bash
   chmod 600 data/email_config.json
   chmod 600 data/password_pool.txt
   chmod 700 data/
   ```

2. **密码传递**：使用邮件或安全渠道
3. **审计日志**：定期检查 `logs/`
4. **最小权限**：使用最少必要权限运行

---

## 🤝 贡献

欢迎贡献！详见 [贡献指南](.github/PULL_REQUEST_TEMPLATE.md)。

### 开发流程

1. Fork 仓库
2. 创建特性分支 (`git checkout -b feature/amazing-feature`)
3. 提交更改 (`git commit -m 'Add amazing feature'`)
4. 推送到分支 (`git push origin feature/amazing-feature`)
5. 创建 Pull Request

### 代码规范

- 遵循 [AGENTS.md](AGENTS.md) 风格指南
- 所有脚本必须通过 ShellCheck
- 为新功能添加测试
- 更新文档

---

## 📊 路线图

### v0.3.0 (2026 年 Q2)
- [ ] 插件系统
- [ ] Web UI（可选）
- [ ] Prometheus 指标导出
- [ ] 多语言支持（i18n）

### v0.2.0 (2026 年 Q1) ✅
- [x] 邮件系统重构
- [x] 模板系统
- [x] 审计集成
- [x] CI/CD 配置

---

## 📄 许可证

本项目采用 [MIT 许可证](LICENSE)。

---

## 🙏 致谢

- 灵感来自 Webmin 和 Ajenti
- 使用 [rsnapshot](https://rsnapshot.org/) 进行备份
- Miniforge 来自 [conda-forge](https://github.com/conda-forge/miniforge)

---

## 📞 支持

- **问题反馈**: [GitHub Issues](https://github.com/user-manager/user-manager/issues)
- **讨论**: [GitHub Discussions](https://github.com/user-manager/user-manager/discussions)
- **邮件**: support@user-manager.local

---

<div align="center">

**专为 AI/ML 研究团队打造 ❤️**

</div>
