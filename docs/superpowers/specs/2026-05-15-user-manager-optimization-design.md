# user-manager 优化设计

日期：2026-05-15  
状态：待审阅  
基线提交：`3dd1c06 chore: establish optimization baseline`

## 背景

当前项目已经切到原生 Bash TUI 主线，`run.sh` 默认进入 `tui_manager.sh`，`run.sh --no-tui` 进入 `user_manager.sh`。这条双入口路线是对的，但代码边界还不够稳：`tui_manager.sh` 仍承担菜单循环、业务适配、日志视图和部分原生表单；`bootstrap.sh` 与 TUI 自己的补充加载清单重复；日志读取分散在 `journalctl_core.sh`、`system_core.sh`、`tui_manager.sh` 和经典 CLI 控制器里。

这轮优化以中等范围推进。第一阶段不追求一次迁完所有模块，而是先搭出能承载后续迁移的骨架：统一加载和环境探测、统一 action 分发、统一日志服务，同时让 TUI 和无 TUI 两个版本都能接入。用户已经确认可以破坏旧菜单编号和旧交互，设计会优先新架构和新体验，但仍保留必要的迁移说明，避免测试和使用方式完全失控。

## 目标

1. 保留 TUI 和无 TUI 两个版本，但让两者复用同一套业务动作和日志读取能力。
2. 合并模块加载清单，减少 `bootstrap.sh` 与 TUI 私有加载逻辑漂移。
3. 增加本机环境适配层，统一探测 `journalctl`、`systemctl`、`jq`、`ufw`、`rsnapshot`、`nvidia-smi`、`virsh` 等能力。
4. 把日志读取做成第一批样板模块，覆盖启动日志、失败服务、服务近期日志、启动错误对比、系统文件日志和认证失败日志。
5. 为用户、审计、备份、网络、systemd timer、VM/GPU、邮件、报告等功能预留统一 action 分组。
6. 简化大文件职责，特别是逐步瘦身 `tui_manager.sh`，让它回到 TUI app loop 和顶层调度。
7. 补必要注释和测试，优先说明模块边界、输入输出协议、降级行为。

## 非目标

1. 第一阶段不重写全部业务模块。
2. 第一阶段不强求兼容所有旧菜单编号。
3. 不引入 Python、Node 或外部 TUI 框架；仍使用原生 Bash/shell 能力。
4. 不自动安装系统依赖，只探测能力并给出降级提示。
5. 不把日志核心改成强依赖 JSON 或 `jq`。`jq` 可用于配置增强，但日志读取基础路径必须能在无 `jq` 环境运行。

## 总体架构

第一阶段采用四层结构：

```text
run.sh
  ├─ user_manager.sh / app_cli.sh       # 无 TUI 模式
  └─ tui_manager.sh / app_tui.sh        # TUI 模式

lib/bootstrap.sh                        # 唯一模块加载入口
lib/env_core.sh                         # 本机环境与依赖探测
lib/action_registry.sh                  # TUI/CLI 共用动作表
lib/logs_core.sh                        # 统一日志读取服务
lib/logs_presenter.sh                   # CLI/TUI 可复用格式化输出

TUI 层
  ├─ tui runtime/widgets/dialogs
  ├─ tui menus/views
  └─ action 调用适配

CLI 层
  ├─ menu controller
  └─ action 调用适配
```

`run.sh` 只负责模式选择。TUI 和 CLI 可以继续使用现有入口文件名，也可以在后续引入 `app_tui.sh`、`app_cli.sh`，但第一阶段不强制更名。重点是让入口变薄，让业务动作从菜单脚本里移到共享 action 层。

## 模块与文件边界

### 加载与环境层

`lib/bootstrap.sh` 保留为唯一加载入口。当前 profile 与 `tui_manager.sh` 的额外加载清单需要合并，TUI/CLI 只声明需要的 profile，不再各自维护模块列表。

新增 `lib/env_core.sh`，职责是探测本机能力：

```bash
env_has_command journalctl
env_has_systemd
env_capability_summary
env_require_capability systemd
```

它不执行业务动作，不替代 `config.sh`，也不自动安装依赖。它只回答“当前机器能做什么”。TUI 和 CLI 都用它生成一致的降级提示。

`lib/config.sh` 继续负责默认路径、阈值和环境变量覆盖。`load_config` 里创建目录、初始化日志、清理旧密码池等副作用可以保留，但需要补注释，标明它是初始化函数而不是纯配置读取。

`lib/shell_config.sh` 需要整理 bash、zsh、fish 的验证逻辑。当前 fish 支持不完整，第一阶段至少要让验证逻辑覆盖 fish，或明确标记 fish 为可选能力。

### 动作层

新增 `lib/action_registry.sh`。每个 action 至少包含：

```text
id              例如 logs.boot
label           显示名称
group           logs/users/system/audit 等
handler         实际函数名
requires        所需能力，如 journalctl/systemd/root
modes           tui、cli、both
risk            safe、privileged、destructive
```

基础函数：

```bash
action_register
action_exists
action_run
action_list_by_group
action_describe
```

第一阶段实际迁移这些动作：

```text
logs.boot
logs.failed_services
logs.service_recent
logs.boot_error_diff
logs.system_file_tail
logs.auth_failures
system.timers.list
system.timers.logs
```

同时注册少量用户和审计示例动作，证明 registry 能承载其他模块，但不在第一阶段大规模迁移用户生命周期、备份、网络、VM/GPU、邮件和报告。

### 日志层

`lib/journalctl_core.sh` 继续保留，负责 journalctl 相关细节。新增 `lib/logs_core.sh`，对外提供统一接口：

```bash
logs_get_boot_entries [--boot -1|0] [--priority err..alert]
logs_get_failed_units
logs_get_service_recent <unit> [--lines N]
logs_get_boot_error_diff
logs_get_system_file_tail [--file PATH] [--lines N]
logs_get_auth_failures [--lines N]
logs_get_capability_status
```

`logs_core.sh` 只取数据，不绘制菜单，不读取用户输入。它内部复用 `journalctl_core.sh`，并尊重现有的 `JOURNALCTL_BIN`、`SYSTEMCTL_BIN` mock 变量。可以新增 `LOGS_SYSTEM_LOG`、`LOGS_AUTH_LOG` 之类变量，方便测试和本机适配。

新增 `lib/logs_presenter.sh`，负责输出格式：

```bash
logs_present_cli <action_id> [args...]
logs_present_tui <action_id> [args...]
logs_format_empty_state <reason>
logs_format_capability_warning <capability>
```

CLI 输出包含标题、来源、状态和正文。TUI 输出为可滚动文本或分页列表，至少支持查看、返回、刷新和清晰错误提示。

### TUI 层

`lib/tui_core.sh` 暂时保留为基础 runtime。后续可以拆出 `lib/tui_dialogs.sh`、`lib/tui_widgets.sh`、`lib/tui_runtime.sh`，但第一阶段只在日志视图需要时新增 `lib/tui_views_logs.sh`。

`tui_manager.sh` 第一阶段只做方向性瘦身：

- 保留主循环；
- 日志和系统诊断菜单改为 `action_run`；
- `run_log_viewer` 迁到 `lib/tui_views_logs.sh`，或保留同名包装函数调用新实现；
- 暂不批量迁移用户、审计、备份等页面。

### CLI 层

`user_manager.sh` 继续作为无 TUI 入口。`controller_main_menu.sh`、`controller_submenus.sh` 的日志和 systemd timer 相关菜单改为 action 调用。旧文本菜单可以保留，但输出由 `logs_presenter.sh` 统一生成。

## 日志读取数据流

新数据流：

```text
TUI 菜单 / CLI 菜单
        │
        ▼
action_run logs.*
        │
        ▼
logs_presenter.sh
        │
        ▼
logs_core.sh
        │
        ├─ journalctl_core.sh
        ├─ system_core.sh / 系统日志文件
        └─ env_core.sh 能力探测
```

日志来源按能力降级：

```text
1. journalctl/systemd
   - boot logs
   - failed units
   - service recent logs
   - boot error diff

2. 传统日志文件
   - /var/log/syslog
   - /var/log/messages
   - /var/log/auth.log
   - /var/log/kern.log

3. 项目本地日志
   - logs/system.log
   - logs/security.log
   - logs/audit.log

4. 空状态说明
   - 无 systemd、无 journalctl、无权限或日志文件不存在
```

为了保持 Bash 原生，`logs_core.sh` 可以使用简单文本协议返回元信息和正文：

```text
__LOGS_META__ status=ok source=journalctl title=Failed systemd units
__LOGS_BODY__
ssh.service failed at boot
nginx.service inactive after reload
```

presenter 解析该协议，分别生成 CLI 文本或 TUI 页面。这个协议比 JSON 更适合当前项目：依赖少，测试容易，shell 里处理也直接。

## 其他功能完善策略

第一阶段把日志作为样板，同时给其他功能明确落点。

| 功能 | 第一阶段处理方式 |
|---|---|
| 用户生命周期 | 注册少量示例 action，复用现有 handler |
| 密码池 | 检查敏感目录保护和配置注释，不重做生成逻辑 |
| 审计/安全 | 注册入口，补依赖降级提示 |
| 备份/恢复 | 纳入 action 分组设计，后续迁移 |
| 防火墙/DNS | 纳入 env 能力探测 |
| systemd timer | 与日志一起优先迁移 |
| VM/GPU | 纳入依赖探测和 action 分组，后续迁移 |
| 邮件通知 | 纳入 action 分组和配置说明 |
| 报告导出 | 纳入 action 分组，后续迁移 |

这样做的重点是先统一“入口、能力探测、动作分发、展示协议”。业务模块可以一批一批迁，不会每迁一个模块都重做一套 TUI/CLI glue。

## 错误处理与降级

错误分四类处理：

1. 能力缺失：例如无 `journalctl`、无 `systemctl`、无 `nvidia-smi`。action 层先检查 `requires`，presenter 给出可读提示。
2. 权限不足：例如读取系统日志或管理服务需要 root。action 标记 `risk=privileged` 或 `requires=root`，运行前给出提示。
3. 输入错误：例如服务名为空。handler 返回非零状态和短错误信息，不直接退出主程序。
4. 空数据：例如没有失败服务或日志文件为空。输出空状态，不视为失败。

TUI 任何 action 失败后必须回到可操作界面，不能留下坏掉的终端状态。CLI 失败时返回非零状态，并打印简短原因。

## 测试与验收

第一阶段新增或扩展这些测试：

```text
tests/test_env_core.sh
tests/test_action_registry.sh
tests/test_logs_core.sh
tests/test_logs_presenter.sh
tests/test_tui_logs_view.sh
tests/test_tui_mainline.sh
tests/test_journalctl_core.sh
tests/test_systemd_timer_core.sh
```

验收标准：

1. `bash -n` 覆盖新增和修改的 shell 文件。
2. `tests/run_regression.sh --level p1` 通过，或设计文档明确列出被新交互替代的旧断言。
3. 缺 `journalctl`、缺 `systemctl`、缺 `jq` 时，日志和系统功能有明确降级提示。
4. TUI 模式能进入日志视图、返回、刷新，并在错误时恢复终端。
5. CLI 模式能运行相同日志动作，输出包含来源、状态和正文。
6. action id 不存在时返回清晰错误。
7. 敏感目录 `data/password_pools/` 不进入 Git，安全扫描不报新增敏感文件。

## 迁移说明

本轮允许破坏旧菜单编号和部分旧函数调用。实际实施时仍建议遵守三条规则：

1. `./run.sh` 和 `./run.sh --no-tui` 继续可用。
2. 对测试依赖的旧函数名，如果迁移成本低，可以保留包装函数；如果保留会拖累结构，就更新测试。
3. 文档里列出旧菜单到新 action id 的映射，方便用户适应。

示例映射：

| 旧能力 | 新 action id |
|---|---|
| 查看启动日志 | `logs.boot` |
| 列出失败服务 | `logs.failed_services` |
| 诊断服务日志 | `logs.service_recent` |
| 对比启动错误 | `logs.boot_error_diff` |
| 查看系统日志文件 | `logs.system_file_tail` |
| 查看认证失败 | `logs.auth_failures` |
| 列出 systemd timers | `system.timers.list` |
| 查看 timer 日志 | `system.timers.logs` |

## 分阶段计划概览

详细实施计划由 writing-plans 生成。这里先给出阶段边界：

1. 第 1 阶段：建立 `env_core`、`action_registry`、`logs_core`、`logs_presenter`，迁移日志和 systemd timer 相关入口。
2. 第 2 阶段：把用户、审计、安全、备份、网络模块逐步注册为 action，减少 TUI/CLI 双写。
3. 第 3 阶段：拆分 `tui_manager.sh` 和 `tui_core.sh`，把视图、dialog、runtime 分开。
4. 第 4 阶段：整理文档、安装/本机适配说明、回归测试和敏感文件扫描。

## 风险

1. action registry 设计过重，会让 Bash 代码变复杂。缓解方式：先用简单数组/分隔符，不做复杂 DSL。
2. 新旧菜单并存期间容易重复。缓解方式：第一阶段只迁移日志和 systemd timer，其他模块先登记分组，不急着迁。
3. TUI 生命周期容易被 action 输出破坏。缓解方式：TUI action 统一走 presenter，禁止底层函数直接清屏或读取按键。
4. 本机环境差异大。缓解方式：所有外部命令都通过 env 探测和可 mock 变量进入测试。

## 设计结论

第一阶段采用平衡骨架方案：建立统一加载/环境层、统一 action 层、统一日志服务层。日志和 systemd timer 是第一批迁移对象，其他功能同步纳入 action 分组和环境探测。TUI 与无 TUI 都保留，但业务动作向共享层收敛。旧交互可以被新结构替代，但 `run.sh` 双入口继续可用。
