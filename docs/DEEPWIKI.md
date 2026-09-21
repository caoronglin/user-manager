# User Manager DeepWiki

本项目是一个基于 Bash 的 Linux 多用户管理工具，聚焦用户生命周期管理、配额、备份、防火墙、审计、邮件通知以及运维自动化。

## 当前状态（2026-08）

1. `run.sh` 默认进入经典 CLI；`--tui` 只在交互式、可光标寻址的 ANSI 终端启动 TUI，`TERM=dumb`、管道和不支持终端会安全回退 CLI。
2. 控制层已进一步解耦：TUI 首页负责导航，经典控制器仍承担完整业务菜单与工作流。
3. 新增 SSH-FIRST 只读主机基础：受信任的 Inventory、Local/SSH Provider、纯本地 dry-run、系统/GPU 探测、固定远端白名单入口和版本化 KV 输出。
4. 回归门禁已分层：P0/P1/P2 级别测试可执行，P1 覆盖 TUI 终端降级和远程基础层。
5. 目录持续收敛：已清理历史安装/修复脚本和 v2 兼容入口；受管示例和安全说明位于 `etc/hosts.conf.example`、`docs/REMOTE_HOSTS.md`。

## 入口与兼容策略

- 推荐入口：`bash run.sh`（经典 CLI）
- 条件 TUI：`bash run.sh --tui`
- TUI 能力诊断：`bash tui_manager.sh --check-terminal`
- 经典后端入口：`user_manager.sh`
- 跨主机只读 CLI：`scripts/rl-hosts.sh`

说明：经典后端用于复用现有控制器与业务逻辑；SSH 主机层不接入 TUI，也不提供远程写操作。

## 关键架构

### 第一阶段优化骨架

第一阶段新增共享层，用于把日志读取、展示适配和 action 调度从具体入口中拆出：

- `lib/env_core.sh`：集中处理运行环境探测与能力判断。
- `lib/action_registry.sh`：注册共享 action ID，并为 TUI / CLI 提供统一调用入口。
- `lib/logs_core.sh`：沉淀日志与 systemd timer 的核心读取逻辑。
- `lib/logs_presenter.sh`：封装日志结果的文本化展示适配。
- `lib/tui_views_logs.sh`：提供 TUI 日志视图，复用共享日志 action。

日志和 systemd timer 是第一批完整迁移对象。目前少量 users / audit 查询类 action 已作为示例接入，其他业务工作流仍保留现有实现，后续再逐步迁移到 action registry，减少 TUI / CLI 双写与读取逻辑分叉。

### 1) 加载层

- lib/bootstrap.sh
  - um_load_profile full
  - um_load_profile minimal
  - um_load_profile tui
  - um_load_profile remote

作用：统一模块加载顺序，降低入口脚本重复 source 和顺序耦合风险。

### 2) 控制层

- lib/controller_main_menu.sh
  - main_menu
  - controller_start
- lib/controller_submenus.sh
  - user_management_menu / disk_quota_menu / network_security_menu
  - backup_menu / firewall_menu / dns_menu / report_menu / audit_menu 等

作用：主菜单循环、子菜单路由与启动编排集中管理，主程序更轻量。

### 3) 业务层

- 用户与密码：lib/user_core.sh
- 配额与磁盘：lib/quota_core.sh
- 备份恢复：lib/backup_core.sh, lib/backup_verify.sh
- 防火墙/DNS：lib/firewall_core.sh, lib/dns_core.sh
- 资源限制：lib/resource_core.sh
- 报告：lib/report_core.sh

### 4) 基础能力层

- 权限与访问控制：lib/privilege.sh, lib/access_control.sh（archive/lib/privilege_cache.sh 已归档）
- 异步执行：lib/async_core.sh, lib/proc_manager.sh
- 审计：lib/audit_core.sh
- 邮件：lib/email_core.sh, lib/email_daemon.sh
- 通用工具：lib/common.sh, lib/config.sh

### 5) 只读跨主机层

- `lib/host_inventory.sh`：受信任、非执行式 pipe-delimited Inventory；验证普通文件/ACL/父目录、字段和容量边界。
- `lib/execution_plan.sh`：将 action、选择器和 Inventory 编排成稳定计划；`--dry-run` 保证不调用 Provider、SSH、DNS 或能力探测。
- `lib/host_provider.sh`：LocalProvider 和 SSHProvider；只允许 `host.probe`/`gpu.summary`，固定远端命令、专用 known_hosts、严格 host-key 检查和三层超时。
- `lib/host_probe_core.sh` 与 `lib/gpu_core.sh`：输出有版本、受限和非执行的 KV 快照；GPU 依次使用 nvidia-smi、lspci、unsupported 降级。
- `scripts/rl-remote-entry.sh`：部署到远端固定路径的单参数白名单入口；不接受任意命令或额外参数。

完整配置与安全边界见 [`REMOTE_HOSTS.md`](REMOTE_HOSTS.md)。

## 目录结构（精简后）

~~~text
user/
├── run.sh
├── user_manager.sh
├── tui_manager.sh
├── verify_fixes.sh
├── lib/
│   ├── bootstrap.sh
│   ├── controller_main_menu.sh
│   ├── controller_submenus.sh
│   ├── common.sh
│   ├── config.sh
│   ├── user_core.sh
│   ├── quota_core.sh
│   ├── backup_core.sh
│   ├── backup_verify.sh
│   ├── firewall_core.sh
│   ├── dns_core.sh
│   ├── email_core.sh
│   ├── email_daemon.sh
│   ├── audit_core.sh
│   ├── async_core.sh
│   ├── proc_manager.sh
│   ├── resource_core.sh
│   ├── report_core.sh
│   ├── system_core.sh
│   ├── shell_config.sh
│   ├── symlink_core.sh
│   ├── tui_core.sh
│   ├── host_inventory.sh
│   ├── host_provider.sh
│   ├── execution_plan.sh
│   ├── host_probe_core.sh
│   ├── ui_modern.sh
│   └── miniforge_core.sh
├── archive/lib/
│   ├── ui_menu_modern.sh
│   └── privilege_cache.sh
├── tests/
│   ├── run_regression.sh
│   ├── test_bootstrap_integration.sh
│   ├── test_user_core.sh
│   ├── test_audit_integration.sh
│   ├── test_proc_manager.sh
│   ├── test_host_inventory.sh
│   ├── test_host_provider.sh
│   ├── test_execution_plan.sh
│   ├── test_remote_cli.sh
│   └── test_framework.sh
├── docs/
│   ├── DEEPWIKI.md
│   └── REMOTE_HOSTS.md
├── etc/
│   └── hosts.conf.example
├── data/
├── logs/
└── templates/
~~~

## 回归与验证

### 分级回归

- P0：verify_fixes.sh（加载与静态冒烟）
- P1：核心行为回归
  - tests/test_bootstrap_integration.sh
  - tests/test_user_core.sh
  - tests/test_audit_integration.sh
  - tests/test_proc_manager.sh
  - tests/test_host_inventory.sh
  - tests/test_host_provider.sh
  - tests/test_execution_plan.sh
  - tests/test_remote_cli.sh
- P2：性能基线（按需启用）

### 一键执行

~~~bash
bash tests/run_regression.sh
bash tests/run_regression.sh --level p1
bash tests/run_regression.sh --level all --include-perf
bash scripts/check_sensitive_files.sh .
~~~

## 近期目录清理结果

已删除无引用历史文件：

- lib/miniforge_core.sh.backup
- lib/ui_menu_modern.sh.backup
- lib/ui_modern.sh.backup2
- lib/ui_menu_fixed.sh

已归档无运行时引用模块：

- archive/lib/ui_menu_modern.sh
- archive/lib/privilege_cache.sh
- lib/ui_optimized.sh
- optimization_summary.sh

## 后续建议

1. 继续将 user_manager.sh 中业务操作函数按域迁出（例如 user/password/quota 子控制器）。
2. 将 common.sh 按职责拆成 ui/lock/validate 工具模块并保留兼容包装。
3. 继续收紧特权命令执行边界，逐步将 `run_privileged` 收敛到更小的安全面。
4. 若扩展远端能力，先定义版本化 stdin 协议或服务器端 forced-command，保持 SSH Provider 的固定命令边界。
