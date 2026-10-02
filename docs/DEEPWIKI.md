# User Manager DeepWiki

本项目是一个 Linux 多用户运维管理工具，聚焦用户生命周期管理、配额、备份、防火墙、审计、邮件与企业微信通知，以及运维自动化。业务内核是 Bash，运行时分成两个**权限等级完全不同**的控制面：特权 CLI/TUI 与非特权 Web 控制台 `umweb`。两者之间只有两条通路：系统状态经只读快照单向流向 Web，特权侧事件经 root event spool 单向流向 Web。

## 当前状态（2026-09）

1. 双控制面成型。特权面是 `run.sh`（默认经典 CLI）、`--tui` 原生 TUI、`user_manager.sh` 后端和 14 个 `scripts/rl-*.sh` 独立 CLI；非特权面是 Rust Web 控制台 `umweb`。Web 不参与任何 Linux 系统变更。
2. `run.sh` 默认进入经典 CLI；`--tui` 只在交互式、可光标寻址的 ANSI 终端启动 TUI，`TERM=dumb`、管道和不支持终端会安全回退 CLI。
3. Action Registry 现有 29 个 action（18 `safe` / 11 `dangerous`；14 `both` / 15 `cli`），TUI 与经典 CLI 共用同一张表和同一套错误码约定（0 成功 / 1 参数 / 2 权限 / 3 运行时）。
4. 只读快照层就位。`scripts/rl-snapshot.sh` 是可信 root 采集器，产出脱敏、版本化、原子写的 JSON 快照；`lib/snapshot_ops.sh` 覆盖 Ubuntu/Ops 摘要：系统信息、CPU/内存/PSI、文件系统与 inode、systemd、APT/reboot、AppArmor，单节不可用时降级而不整体失败。
5. Web 控制面覆盖只读系统 API、logs/audit/reports、Web 自身用户与会话、API Token、通知 inbox 与企业微信投递。危险写接口**根本不存在**，命中即 404/405。
6. 跨主机只读层不变：受信任 Inventory、Local/SSH Provider、纯本地 dry-run、系统/GPU 探测、固定远端白名单入口、版本化 KV 输出。
7. 通知链路打通双向。root event spool（`user.created` / `user.disabled`）进入 Web inbox 后投递企业微信；Web 自身事件（`security.login_failed`、`security.token_revoked`、`snapshot.freshness_changed`）走独立 outbox/worker 与固定模板。
8. 回归门禁分层且默认并行：P0 静态冒烟、P1 40 个行为套件、P2 性能基线（按需），另有独立的 Rust crate 与 Shell 安全门禁。
9. 目录持续收敛：历史安装/修复脚本和 v2 兼容入口已清理；受管示例与安全说明位于 `etc/`、`docs/`，退役模块归档在 `archive/lib/`。

## 入口与兼容策略

- 推荐入口：`bash run.sh`（经典 CLI）
- 条件 TUI：`bash run.sh --tui`
- TUI 能力诊断：`bash tui_manager.sh --check-terminal`
- 经典后端入口：`bash user_manager.sh`（薄编排，业务已下沉到 `lib/controller_user_*.sh`）
- 跨主机只读 CLI：`bash scripts/rl-hosts.sh`
- 快照采集器（需 root）：`bash scripts/rl-snapshot.sh`
- Web 控制台：`cd web/backend && cargo run`（非特权，默认 `:8080`）
- Action 清单：`bash scripts/rl-action-list.sh`

说明：

- 经典后端用于复用现有控制器与业务逻辑；SSH 主机层不接入 TUI，也不提供远程写操作。
- 快照采集器由 root 运行，`umweb` 只读其产物；`umweb` 永不执行采集器，也永不加载 `lib/snapshot_*.sh`。
- Web 与 CLI 不共享任何提权通路。需要 root 的操作永远是「Web 展示/记录申请 → 管理员在 CLI/TUI 执行 → Web 展示结果」。

## 关键架构

### 第一阶段优化骨架

第一阶段新增共享层，用于把日志读取、展示适配和 action 调度从具体入口中拆出：

- `lib/env_core.sh`：集中处理运行环境探测与能力判断。
- `lib/action_registry.sh`：注册共享 action ID，并为 TUI / CLI 提供统一调用入口。
- `lib/logs_core.sh`：沉淀日志与 systemd timer 的核心读取逻辑。
- `lib/logs_presenter.sh`：封装日志结果的文本化展示适配。
- `lib/tui_views_logs.sh`：提供 TUI 日志视图，复用共享日志 action。

日志和 systemd timer 是第一批完整迁移对象。此后 `users.list`、`audit.query` / `audit.view` 与 11 个 `smb.*` action 也已接入同一张表，CLI 侧由 `scripts/rl-*.sh` 调用、TUI 侧由视图调用，避免 TUI / CLI 双写与读取逻辑分叉。

### 1) 加载层

- `lib/bootstrap.sh`
  - `um_load_profile full`
  - `um_load_profile minimal`
  - `um_load_profile tui`
  - `um_load_profile remote`

作用：统一模块加载顺序，降低入口脚本重复 source 和顺序耦合风险。

### 2) 控制层

- `lib/controller_main_menu.sh`
  - `main_menu`
  - `controller_start`
- `lib/controller_submenus.sh`
  - `user_management_menu` / `disk_quota_menu` / `network_security_menu`
  - `backup_menu` / `firewall_menu` / `dns_menu` / `report_menu` / `audit_menu` 等
- `lib/controller_user_*.sh`（12 个）
  - listing / lifecycle / groups / limits / provisioning / provisioning_support
  - passwords / password_change / permissions / notifications / workflows / common

作用：主菜单循环、子菜单路由与用户域工作流集中管理，`user_manager.sh` 保持为薄入口。

### 3) 业务层

- 用户与密码：`lib/user_core.sh`
- 配额与磁盘：`lib/quota_core.sh`
- 备份恢复：`lib/backup_core.sh`、`lib/backup_verify.sh`、`lib/backup_excludes.sh`
- 防火墙/DNS：`lib/firewall_core.sh`、`lib/dns_core.sh`
- 资源限制：`lib/resource_core.sh`
- 报告：`lib/report_core.sh`
- 附加域：SMB（`lib/smb_core.sh`）、虚拟机（`lib/vm_core.sh`）、Shell 与软链（`lib/shell_config.sh`、`lib/symlink_core.sh`）、Miniforge 配置（`lib/miniforge_core.sh`）

### 4) 基础能力层

- 权限与访问控制：`lib/privilege.sh`、`lib/access_control.sh`（`archive/lib/privilege_cache.sh` 已归档）
- 并发与异步：`lib/async_core.sh`、`lib/proc_manager.sh`、`lib/lock_core.sh`
- 审计：`lib/audit_core.sh`
- 邮件与企业微信：`lib/email_core.sh`、`lib/email_daemon.sh`、`lib/rl_mail_*.sh`、`lib/rl_wecom_bot_sender.sh`
- 系统观测：`lib/system_core.sh`、`lib/journalctl_core.sh`、`lib/logs_core.sh`、`lib/logs_presenter.sh`、`lib/systemd_timer_core.sh`
- 网络与安全基线：`lib/network_stack_core.sh`、`lib/security_baseline_core.sh`、`lib/ubuntu_maintenance_core.sh`
- 通用工具：`lib/common.sh`、`lib/config.sh`、`lib/env_core.sh`、`lib/action_registry.sh`

### 5) 只读跨主机层

- `lib/host_inventory.sh`：受信任、非执行式 pipe-delimited Inventory；验证普通文件/ACL/父目录、字段和容量边界。
- `lib/execution_plan.sh`：将 action、选择器和 Inventory 编排成稳定计划；`--dry-run` 保证不调用 Provider、SSH、DNS 或能力探测。
- `lib/host_provider.sh`：LocalProvider 和 SSHProvider；只允许 `host.probe` / `gpu.summary`，固定远端命令、专用 known_hosts、严格 host-key 检查和三层超时。
- `lib/host_probe_core.sh` 与 `lib/gpu_core.sh`：输出有版本、受限和非执行的 KV 快照；GPU 依次使用 nvidia-smi、lspci、unsupported 降级。
- `scripts/rl-remote-entry.sh`：部署到远端固定路径的单参数白名单入口；不接受任意命令或额外参数。

完整配置与安全边界见 [`REMOTE_HOSTS.md`](REMOTE_HOSTS.md)。

### 6) 只读快照层

Web 不直接读取系统，也不执行任何查询命令；系统状态只经由版本化 JSON 快照被观测。

- `lib/snapshot_core.sh`：快照契约库。定义 `SNAPSHOT_SCHEMA_VERSION`、信封结构、`snapshot_scrub` 脱敏、临时文件 + `fsync` + `rename` 原子写、schema 校验、freshness 阈值与 manifest。只被采集器调用。
- `lib/snapshot_ops.sh`：Ubuntu/Ops 摘要采集。系统信息、CPU 使用率、内存、PSI（`some`/`full`）、文件系统与 inode、systemd 状态、APT 待更新与 reboot 需求、AppArmor 状态；单节失败降级为空节并标注原因。
- `scripts/rl-snapshot.sh`：可信采集器。由 root 经 systemd timer 或受信 CLI 运行；只调用只读 Core 查询，不调用 `action_run` / `priv_exec` / `useradd` / `setquota` / `smbpasswd` / `pdbedit<写>`。产物 `root:umweb 0640`，目录 `0750`。
- 部署单元：`etc/systemd/system/um-snapshot.service`、`etc/systemd/system/um-snapshot.timer`、`etc/tmpfiles.d/user-manager-web.conf`。

`umweb` 侧只做两件事：只读打开快照目录、校验信封与 freshness，并把 stale/缺失显式暴露给前端，不做任何修复写入。

完整边界见 [`WEB_SECURITY_BOUNDARY.md`](WEB_SECURITY_BOUNDARY.md)。

### 7) Web 控制面（`umweb`）

非特权的 Rust Web 控制台，定位是**认证、展示、查询、审计、通知与只读观测**，不是浏览器版 root 运维终端。

- 技术栈：Rust + axum + tokio + rusqlite + Argon2id + TOTP；前端 React 19 + Vite 8 + Ant Design 6。**未**采用原计划的 Umi / ProComponents。
- 目录：`web/backend/src`（38 个源文件：auth / http / store 三层 + config / state / error / crypto / telemetry / event_spool / web_event_delivery）、`web/backend/tests`（10 个集成测试）、`web/frontend/src`（6 个文件）。
- 不可动摇的硬约束：
  - Web 永不提权：无 root、无 sudoers、无 setuid/setgid、无 Linux capability、无特权 socket；
  - Web 不执行任何 Linux 系统写操作，也不 fork 任意 shell / 命令 / SSH；
  - 危险 API（users / smb / hosts / system 写）**不存在**，路由表里没有，命中即 404/405；
  - 系统数据只经只读快照观测；
  - 能力模型（capability allowlist）默认拒绝，角色到能力是白名单映射；
  - Web 自身身份、会话、令牌与企业微信配置走独立数据库与独立 secret master key。
- 门禁：`scripts/check_web_security.sh` 对 `web/backend/src` 做**阻断式**扫描，禁止提权原语、系统管理命令和 `std::process::Command::new`；已接入 CI 与 `tests/run_regression.sh`。
- systemd 沙箱：`etc/systemd/system/umweb.service`（`NoNewPrivileges=yes`、空 `CapabilityBoundingSet=`、`PrivateTmp=yes`）。

技术细节、模块职责、运行方式与验收状态见 [`web/README.md`](../web/README.md)。

## 通知链路

两条彼此独立、来源不同的通路：

1. **特权侧 → Web → 企业微信**：CLI/TUI 写入 root-owned event spool（当前仅 `user.created`、`user.disabled`）。`umweb` 以只读方式、逐文件校验后消费，写入 inbox 并按五分钟「事件类型 + 用户」去重后投递企业微信。投递使用固定模板，有界重试（网络错误 / 超时 / 429 / 5xx），不外发密码等敏感内容。
2. **Web 自身事件 → 企业微信**：`security.login_failed`、`security.token_revoked`、`snapshot.freshness_changed` 走独立 outbox 与独立非特权 worker。inbox 插入与 outbox 插入共享同一事务；outbox 只保留幂等引用、随机投递 ID、事件枚举与状态。消息正文仅由事件枚举生成，标题、摘要、目标、来源、用户名、IP、令牌标识都不进入负载。详见 [`wecom-native-events.md`](wecom-native-events.md)。

已知限制：worker 假定一个 SQLite 库只由一个 `umweb` 进程持有，不做跨进程租约；企业微信侧不提供幂等键，极端情况下可能重复投递。

## 目录结构（精简后）

代码库规模：`lib/` 67 个模块、`scripts/` 18 个脚本、`tests/` 44 个 `.sh`（42 个套件 + 框架 + 执行器）、`web/backend` 48 个 Rust 文件、`web/frontend/src` 6 个文件。下列按域分组，模块名后省略 `.sh`。

~~~text
user/
├── run.sh                    # 主入口：默认经典 CLI，--tui 启动原生 TUI
├── user_manager.sh           # 经典 CLI 编排（薄入口）
├── tui_manager.sh            # 原生 TUI 主循环
├── verify_fixes.sh           # P0 静态 / 加载冒烟
├── perf_test.sh              # P2 性能基线
├── lib/                      # 67 个模块，按域分组（下列为代表模块）
│   ├── 加载与控制
│   │   ├── bootstrap.sh  env_core.sh  config.sh  common.sh
│   │   ├── action_registry.sh  async_core.sh  proc_manager.sh
│   │   ├── controller_main_menu.sh  controller_submenus.sh
│   │   └── controller_user_*.sh        # 12 个用户域子控制器
│   ├── 用户与资源
│   │   ├── user_core.sh  quota_core.sh  resource_core.sh
│   │   ├── shell_config.sh  symlink_core.sh  miniforge_core.sh
│   ├── 备份
│   │   └── backup_core.sh  backup_verify.sh  backup_excludes.sh
│   ├── 网络与安全
│   │   ├── firewall_core.sh  dns_core.sh  network_stack_core.sh
│   │   └── security_baseline_core.sh  smb_core.sh  vm_core.sh
│   ├── 日志 / 审计 / 报告
│   │   ├── logs_core.sh  logs_presenter.sh  journalctl_core.sh
│   │   ├── audit_core.sh  report_core.sh  systemd_timer_core.sh
│   │   └── system_core.sh  ubuntu_maintenance_core.sh
│   ├── 邮件与企业微信
│   │   ├── email_core.sh  email_daemon.sh
│   │   ├── rl_mail_config.sh  rl_mail_template.sh  rl_mail_queue.sh
│   │   ├── rl_mail_sender.sh  rl_mail_events.sh  rl_mail_audit.sh
│   │   └── rl_wecom_bot_sender.sh
│   ├── 权限与并发
│   │   └── privilege.sh  access_control.sh  lock_core.sh
│   ├── 只读跨主机
│   │   └── host_inventory.sh  host_provider.sh  execution_plan.sh
│   │       host_probe_core.sh  gpu_core.sh
│   ├── 只读快照
│   │   └── snapshot_core.sh  snapshot_ops.sh
│   └── TUI
│       └── tui_core.sh  tui_menus.sh  tui_views_logs.sh  ui_modern.sh
├── scripts/                  # 14 个 rl-*.sh 独立 CLI + 4 个辅助脚本
│   ├── rl-user-create.sh  rl-user-list.sh  rl-user-quota.sh
│   ├── rl-user-resource.sh  rl-chpasswd.sh  rl-smb-manage.sh
│   ├── rl-backup-run.sh  rl-audit-query.sh  rl-mail-test.sh
│   ├── rl-system-overview.sh  rl-hosts.sh  rl-snapshot.sh
│   ├── rl-remote-entry.sh  rl-action-list.sh
│   └── check_web_security.sh  check_sensitive_files.sh
│       normalize_echo_output.sh  verify_email_config.sh
├── tests/                    # 42 个套件 + 框架 + 执行器
│   ├── run_regression.sh  test_framework.sh
│   ├── test_bootstrap_integration.sh  test_user_core.sh
│   ├── test_action_registry.sh  test_quota_core.sh  test_resource_core.sh
│   ├── test_host_inventory.sh  test_host_provider.sh
│   ├── test_execution_plan.sh  test_remote_cli.sh
│   ├── test_snapshot.sh  test_snapshot_ops.sh  test_event_spool.sh
│   ├── test_web_security_gate.sh  test_web_deploy_boundary.sh
│   ├── test_tui_core.sh  test_tui_logs_view.sh  test_tui_mainline.sh
│   ├── test_tui_native_forms.sh  test_scripts.sh  test_security_*.sh
│   └── bats/                 # Bats 迁移评估目录
├── web/
│   ├── README.md
│   ├── backend/              # Rust：axum + tokio + rusqlite + Argon2id + TOTP
│   │   ├── Cargo.toml  Cargo.lock  deny.toml
│   │   ├── src/              # 38 个源文件
│   │   │   ├── main.rs  lib.rs  config.rs  state.rs  error.rs
│   │   │   ├── telemetry.rs  crypto.rs  event_spool.rs
│   │   │   ├── auth/         # password / session / csrf / mfa / rbac
│   │   │   │                 # rate_limit / guard / mod
│   │   │   ├── http/         # routes / middleware / read_api / admin_api
│   │   │   │                 # logs_api / audit_api / reports_api
│   │   │   │                 # notifications_api / wecom_api / tokens_api
│   │   │   │                 # response / mod
│   │   │   ├── store/        # SQLite schema 与数据访问
│   │   │   └── web_event_delivery.rs
│   │   └── tests/            # 10 个集成测试
│   └── frontend/             # React 19 + Vite 8 + Ant Design 6
│       ├── package.json  vite.config.js  index.html
│       └── src/              # main.jsx / App.jsx / pages.jsx / ui.jsx
│                            # api.js / styles.css
├── docs/
│   ├── DEEPWIKI.md  ARCHITECTURE.md  WEB_SECURITY_BOUNDARY.md
│   ├── REMOTE_HOSTS.md  M1_REPOSITORY_AUDIT.md  wecom-native-events.md
│   └── sudoers-deploy.md  bats-migration-assessment.md
├── etc/
│   ├── hosts.conf.example
│   ├── sudoers.d/user-manager.example
│   ├── systemd/system/umweb.service
│   ├── systemd/system/um-snapshot.service
│   ├── systemd/system/um-snapshot.timer
│   └── tmpfiles.d/user-manager-web.conf
├── data/                     # 运行期数据：审计、日志、报表、密码池、secret
├── templates/email/          # 邮件与通知模板
├── archive/lib/              # 退役模块，无运行时引用
│   ├── ui_menu_modern.sh
│   └── privilege_cache.sh
└── logs/
~~~

## 回归与验证

回归执行器是 `tests/run_regression.sh`，默认执行 `p0 + p1`。

### 分级含义

- **P0**：静态与加载冒烟。运行 `verify_fixes.sh`，验证模块加载顺序与基础环境，不进入业务路径。
- **P1**：核心行为回归。覆盖加载、用户、配额、资源、权限、备份、SMB、密码变更、审计、进程管理、日志、安全基线、安全加固、TUI、systemd timer、lock、跨主机只读、快照契约与 Ops 快照、Web 安全门禁与部署边界。
- **P2**：性能基线。执行根目录 `perf_test.sh`，默认跳过并标记为 skipped，需显式开启。
- **all**：`p0 + p1`，在设置 `--include-perf` 时追加 `p2`。

### P1 套件清单

P1 由 `run_regression.sh` 的 `P1_SCRIPTS` 数组定义，共 40 个套件：

~~~text
test_action_registry.sh           test_audit_integration.sh
test_backup_core.sh               test_bootstrap_integration.sh
test_env_core.sh                  test_event_spool.sh
test_execution_plan.sh            test_gpu_core.sh
test_host_inventory.sh            test_host_provider.sh
test_journalctl_core.sh           test_lock_core.sh
test_logs_core.sh                 test_logs_presenter.sh
test_network_stack_core.sh        test_password_change_smb.sh
test_proc_manager.sh              test_quota_core.sh
test_remote_cli.sh                test_report_core.sh
test_resource_core.sh             test_rl_privilege.sh
test_scripts.sh                   test_security_baseline_core.sh
test_security_hardening.sh        test_security_scan.sh
test_shell_config_core.sh         test_smb_core.sh
test_snapshot.sh                  test_snapshot_ops.sh
test_systemd_timer_core.sh        test_tui_core.sh
test_tui_logs_view.sh             test_tui_mainline.sh
test_tui_native_forms.sh          test_ubuntu_maintenance_core.sh
test_user_core.sh                 test_vm_core.sh
test_web_deploy_boundary.sh       test_web_security_gate.sh
~~~

`tests/` 下另有三个文件不在 P1 数组中，需要时单独执行：`test_rl_mail.sh`、`test_rl_wecom.sh`（邮件与企业微信专项）和 `test_framework.sh`（断言框架，被各套件 source）。

### 并行与超时

P1 默认并行执行。每个套件使用独立的 `mktemp -d` 临时数据目录，互不干扰，单套件超时即判失败。

- `UM_TEST_JOBS`：并行作业数，默认 `4`。
- `UM_TEST_TIMEOUT`：单套件超时秒数，默认 `180`。
- `--no-parallel`：串行执行 P1，便于定位竞态或逐条观察输出。

### 一键执行

~~~bash
bash tests/run_regression.sh                              # p0 + p1
bash tests/run_regression.sh --level p0                   # 只跑静态冒烟
bash tests/run_regression.sh --level p1                   # 只跑行为回归
bash tests/run_regression.sh --level p1 --no-parallel     # 串行
bash tests/run_regression.sh --level all --include-perf   # 追加 P2 性能基线
bash tests/run_regression.sh --include-lint               # 额外启用 ShellCheck 告警门禁
UM_TEST_JOBS=8 UM_TEST_TIMEOUT=300 bash tests/run_regression.sh --level p1
~~~

`--include-lint` 通过 `UM_INCLUDE_LINT` 传给 `test_scripts.sh`，把 ShellCheck 告警门禁并入静态检查，默认不开启。

### 独立执行

单个套件可直接运行，输出更完整，适合定位失败：

~~~bash
bash tests/test_snapshot.sh
bash tests/test_snapshot_ops.sh
bash tests/test_web_security_gate.sh
bash tests/test_rl_mail.sh
bash tests/test_rl_wecom.sh
~~~

### Web 侧验证链

Web 控制面有独立的验证链，不在 Shell 回归内：

~~~bash
bash scripts/check_web_security.sh web/backend/src    # 阻断式源码门禁
bash scripts/check_sensitive_files.sh .               # 仓库敏感文件扫描
cd web/backend && cargo fmt --all -- --check
cd web/backend && cargo clippy --locked --all-targets -- -D warnings
cd web/backend && cargo test --locked
cd web/frontend && npm ci && npm run build
~~~

CI（`.github/workflows/ci.yml`）按 job 划分 shellcheck、Rust、前端构建与 Shell 回归，安全门禁为独立阻断 job。Web 侧的具体验收状态与已知限制见 [`web/README.md`](../web/README.md) 与 [`M1_REPOSITORY_AUDIT.md`](M1_REPOSITORY_AUDIT.md)。

## 近期目录清理结果

已删除无引用历史文件：

- `lib/miniforge_core.sh.backup`
- `lib/ui_menu_modern.sh.backup`
- `lib/ui_modern.sh.backup2`
- `lib/ui_menu_fixed.sh`

已归档无运行时引用模块：

- `archive/lib/ui_menu_modern.sh`
- `archive/lib/privilege_cache.sh`
- `lib/ui_optimized.sh`
- `optimization_summary.sh`

## 后续建议

1. 继续把残余共享工具从 `lib/common.sh` 拆成 ui / lock / validate 独立模块，并保留兼容包装。
2. 继续收紧特权命令执行边界，逐步把 `run_privileged`（`lib/common.sh`）收敛到更小的安全面。
3. 若扩展远端能力，先定义版本化 stdin 协议或服务器端 forced-command，保持 SSH Provider 的固定命令边界。
4. Web 侧推进目标机部署与真实企业微信 webhook 验收；当前 worker 假定单个 SQLite 库只由一个 `umweb` 实例持有，多实例共享场景需要显式租约。
5. Action Registry 仍有部分 TUI 业务工作流未迁移，迁移时保持 `cli` / `both` 模式与错误码约定不变。
