# User Manager DeepWiki

本项目是一个基于 Bash 的 Linux 多用户管理工具，聚焦用户生命周期管理、配额、备份、防火墙、审计、邮件通知以及运维自动化。

## 当前状态（2026-04）

1. 统一入口已切到 TUI 主线：`run.sh` 默认启动 `tui_manager.sh`。
2. 控制层已进一步解耦：TUI 首页负责导航，经典控制器仍承担完整业务菜单与工作流。
3. 回归门禁已分层：P0/P1/P2 级别测试可执行。
4. 目录持续收敛：已清理历史安装/修复脚本和 v2 兼容入口。

## 入口与兼容策略

- 推荐入口：run.sh
- TUI 主程序：tui_manager.sh
- 经典后端入口：user_manager.sh

说明：经典后端用于复用现有控制器与业务逻辑。

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
  - um_load_profile tui

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

- 权限与访问控制：lib/privilege.sh, lib/access_control.sh, lib/privilege_cache.sh
- 异步执行：lib/async_core.sh, lib/proc_manager.sh
- 审计：lib/audit_core.sh
- 邮件：lib/email_core.sh, lib/email_daemon.sh
- 通用工具：lib/common.sh, lib/config.sh

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
│   ├── ui_menu_modern.sh
│   ├── ui_modern.sh
│   └── miniforge_core.sh
├── tests/
│   ├── run_regression.sh
│   ├── test_bootstrap_integration.sh
│   ├── test_user_core.sh
│   ├── test_audit_integration.sh
│   ├── test_proc_manager.sh
│   └── test_framework.sh
├── docs/
│   └── DEEPWIKI.md
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
- lib/ui_optimized.sh
- optimization_summary.sh

## 后续建议

1. 继续将 user_manager.sh 中业务操作函数按域迁出（例如 user/password/quota 子控制器）。
2. 将 common.sh 按职责拆成 ui/lock/validate 工具模块并保留兼容包装。
3. 继续收紧特权命令执行边界，逐步将 `run_privileged` 收敛到更小的安全面。
