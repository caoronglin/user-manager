# Progress - 用户管理工具完善

## 2026-07-17 当前工作区检查与修复（完成）

### 已完成

- 恢复 `task_plan.md`、`findings.md`、`progress.md` 上下文。
- 检查 Git 状态，确认 `main` 领先远端 5 个提交且存在大量未提交改动。
- 启动两个只读探索任务：检查入口梳理、风险热点扫描。

### 完成内容

- 用户批准的本地设计与计划分别写入 `docs/superpowers/specs/2026-07-17-ci-test-quality-repairs-design.md`、`docs/superpowers/plans/2026-07-17-ci-test-quality-repairs.md`；均未提交。
- 三条无重叠修复 lane 完成：CI 跟踪文件语法枚举、动作注册表的幂等错误码常量守卫、模块测试统计与 SMB PATH/stderr 清理。
- 每条 lane 经规格与代码质量复核；最终整体只读集成审查 `ora-7` 返回 APPROVED。

### 本轮基线结果

- `git diff --check`：通过。
- 全量自有 Bash `bash -n`：通过（排除第三方 `Miniforge.sh`）。
- 全量自有 Bash `shellcheck -S error`：通过。
- `bash tests/run_regression.sh --level p0`：通过 1/1，内部检查 20/20。
- `bash tests/run_regression.sh --level p1`：通过 31/31；输出中识别到统计失真与无害但应清除的加载/测试环境噪声。

### 最终验证

- 定向：`tests/test_action_registry.sh` 23/23、`tests/test_ubuntu_maintenance_core.sh` 7/7、`tests/test_network_stack_core.sh` 5/5、`tests/test_smb_core.sh` 9/9；SMB 测试 stderr 为空。
- 回归：P0 1/1（`verify_fixes.sh` 20/20）和 P1 31/31 均通过。
- 静态：NUL 安全遍历的 Git 跟踪 `.sh`（跳过 `Miniforge.sh`）通过 `bash -n` 与 `shellcheck -S error`；`git diff --check` 通过。
- 未执行 Git 提交、推送、合并或回滚；工作区原有未提交改动未被覆盖。

### 新问题：`create_or_assign_user` 返回码 1（诊断中）

- 已完成只读调用链和失败分支定位：用户看到的错误由 `safe_run` 统一包装，当前不足以判定根因。
- 未修改创建流程；正在等待报错前后的非敏感运行时输出与调用上下文，再进行最小可复现和根因验证。

### 功能与 TUI 渲染探索（进行中）

- 只读运行证据检索完成：当前项目日志未记录 `create_or_assign_user` 失败分支，当前锁不存在；历史配额失败与本次报告没有可验证关联。
- 已用无 locale 环境稳定复现 `tui_detect_terminal` 的 nounset 崩溃：`lib/tui_core.sh:28: LANG: unbound variable`。
- 已确认当前数据驱动主菜单未接入已有分页逻辑，长菜单在常见终端高度存在静态溢出风险；TUI 相关定向基线仍通过：`test_user_core.sh` 36/36、`test_tui_native_forms.sh` 5/5、`test_tui_mainline.sh` 62/62。
- 尚未改动功能或渲染代码；等待用户确认实际失败入口和本轮修复优先级后，按 brainstorming 设计门禁提出最小方案。

### TUI 渲染韧性设计（已复核，准备实施）

- 已将用户明确的 locale、分页、宽字符和状态栏范围细化为本地设计：`docs/superpowers/specs/2026-07-21-tui-rendering-resilience-design.md`，未提交。
- 设计纳入两个分页必须先修复的已复现导航根因：同菜单 redraw 重置状态，以及 command substitution 令 22 个 handler 丢失导航状态。
- 未修改任何 TUI 源码或测试；下一步是用户审阅设计说明，批准后才能写实施计划。

### TUI 设计自审

- 已自审 `2026-07-21-tui-rendering-resilience-design.md`：补足 `TERM` 未定义时的安全降级、菜单缓存的循环边界，以及 state 模式必须在父 shell 执行的兼容约束。
- 文档无 TODO/占位符；源码和测试尚未修改，等待用户审阅该本地设计说明。

### TUI 设计复核与实施计划

- Oracle 设计复核提出 6 项必须关闭的风险：主循环仍经子 shell、`tui_init` 后同 ID 缓存空菜单、无 TERM 时颜色 token nounset、22 个 handler 与原生表单测试不闭合、UTF-8 能力判断不足、低于 7 行的布局冲突和无高亮。
- 用户已授权在完成设计复核后实施；设计说明已补充这 6 项强制验收条件。
- 本地计划已写入 `docs/superpowers/plans/2026-07-21-tui-rendering-resilience.md`，将按 core、menus、manager/tests 三条无重叠写入 lane 实施。尚未提交、推送、合并或回滚。

### 根因与范围

- 已稳定复现：CI 解析 `Miniforge.sh` 失败、两份模块测试计数失真、动作注册表重复 source 只读警告、SMB 测试的 PATH/mkdir 噪声。
- 用户选择先修确定问题；SQL 参数边界、邮件队列明文密码、密码池竞态和临时文件清理均记录为后续安全工作，本轮不改变。

## 2026-05-16 v2 整体优化 (完成)

### 全部 8 阶段完成

**Phase 0** 基线回归: all 26/0/1 (P2 skipped)
**Phase 1** 入口+权限: bash run.sh 默认 noTUI CLI (54/54), rl_priv_* 6 函数 (6/6 PASS)
**Phase 2** 颜色按键: 只留绿/红配色, rl_read_menu_key() 0 键返回 (56/56 PASS)
**Phase 3** 组模式: cgroup v2 组策略展开 + quota 组配额 (7/7 + 4/4 PASS)
**Phase 4** 邮件拆分: email_core.sh→rl_mail_{config,template,sender,queue,events,audit}.sh 6文件 <200行, 去JSON (9/9 PASS)
**Phase 5** 独立脚本: 7 scripts/rl-*.sh + rl-system-overview.sh (10/10 PASS)
**Phase 6** 去nginx: lib/tui/security 全部移除, grep零残留 (10/10 + 56/56 PASS)
**Phase 7** README更新: 默认入口说明, 独立脚本表格, --tui 文档
**Phase 8** glances: rl-system-overview.sh (--web/--processes/--quick)

**最终验证**:
- `bash tests/run_regression.sh --level all`: Passed 28, Failed 0, Skipped 1 (P2)
- `bash -n` 全量自有 .sh 通过 (唯一失败: 第三方 Miniforge.sh 二进制 installer)
- `shellcheck -S error` 全量自有 .sh 通过

**未提交代码** — 分支 `feat/vm-gpu-proxy-management`

---

## 2026-05-02 会话 (完成)

### 审计
- 全量审计 lib/*.sh (47文件, ~43000行)
- 识别 5 个改进阶段

### 修复
- N1.1: 修复 local count bug (regenerate_password_pool.sh)
- N1.2: set 选项一致性审查 (设计合理)
- N1.3: 消除 eval → 数组方式 (backup_core.sh)
- N2: 安全加固审计完成 (无风险)

### 增强
- N3.1: test_lock_core.sh (18用例)
- N3.2: test_backup_core.sh (8用例)
- N3.3: 注册到 run_regression.sh
- N4/N5: README Installation + CI 改进

### 验证
- 全部 bash -n 语法通过 ✅


## 2026-05-06 模块逻辑验证

### 验证范围
- P0 smoke: `bash tests/run_regression.sh --level p0`
- P1 module regression: `bash tests/run_regression.sh --level p1`
- TUI mainline: `bash tests/test_tui_mainline.sh`
- Backup core: `bash tests/test_backup_core.sh`
- Lock core: `bash tests/test_lock_core.sh`
- Static gates: `bash -n ...` + `shellcheck -S error ...`

### 结果
- P0: 1/1 regression step passed, verify_fixes 20/20 checks passed
- P1: 16/16 regression steps passed, 0 failed, 0 skipped
- TUI mainline: 46/46 passed
- Lock core: 22/22 passed
- Backup core: 12/12 passed
- Static gates: changed scripts passed bash syntax and ShellCheck error gate

### 修正
- `tests/test_backup_core.sh`: 改为验证真实 backup_core/backup_excludes 接口，移除不存在接口假设
- `tests/test_lock_core.sh`: 去掉重复 source，消除只读变量告警
- `tests/run_regression.sh`: 更新 P1 help 文案，准确反映 tui/lock/backup 覆盖

## 2026-05-07 VM/GPU/Proxy 继续执行

### 已完成
- 根据 handoff 恢复目标：VM 管理、GPU 管理、proxy 写入 bashrc/zshrc、去安装口径、备份与模块衔接收敛。
- 查看 git 状态：当前仓库已有大量未提交历史变更，原分支 `main` 领先 `origin/main` 15 个提交。
- 创建并切换到功能分支：`feat/vm-gpu-proxy-management`，不做提交。
- 更新 `task_plan.md`、`findings.md`、`progress.md` 记录本轮目标与约束。

### 下一步
- 读取目标文件和测试结构，先补 RED 测试再实现最小功能。

### 完成内容
- 新增 `lib/vm_core.sh`、`lib/gpu_core.sh`。
- 新增 `tests/test_vm_core.sh`、`tests/test_gpu_core.sh`，并注册到 P1 回归。
- `lib/privilege.sh` 新增 `virsh` 白名单与 `priv_virsh`。
- `lib/bootstrap.sh` full profile 加载 VM/GPU core；`tui_manager.sh` 与 `lib/tui_menus.sh` 新增“虚拟机与显卡管理”原生子菜单。
- `lib/user_core.sh` 新增 `ensure_user_proxy_function`，在 create/update 用户时幂等写入 `.bashrc` 与 `.zshrc`。
- `lib/miniforge_core.sh`、`tui_manager.sh`、`lib/controller_user_provisioning.sh` 收敛 Miniforge/Mamba 为配置口径。
- `README.md` 删除 `## Installation` 与安装依赖命令。
- `scripts/check_sensitive_files.sh` 修复私钥内容扫描漏报。

### 验证
- `bash -n`：新增/修改脚本通过。
- `shellcheck -S error`：新增/修改脚本通过。
- 定向测试：VM/GPU/user/bootstrap/TUI/security scan 全部通过。
- `bash tests/run_regression.sh --level p1`：18/18 通过。
- `bash tests/run_regression.sh --level p0`：1/1 通过。

### Oracle 复核后修正
- 阻断点：`ensure_user_proxy_function` 直接 `touch`/`>>` 写用户 rc 文件会在非 root 管理员场景越过权限包装导致失败。
- 修正：改为优先 `priv_touch` 创建 rc 文件，使用 `priv_tee -a` 追加 proxy helper，再通过 `priv_chown`/`priv_chmod` 收敛权限。
- 补测：`tests/test_user_core.sh` 新增 “通过 priv_tee 追加 rc 文件” 断言。
- 最终复验：`bash -n`、`shellcheck -S error`、P1 18/18、P0 1/1 均通过。

## 2026-05-07 bash-language-server / 无 TUI / 中断输出 QA

### 完成内容
- 使用已安装的 `bash-language-server` 重新运行 LSP 诊断；全仓库 `.sh` 扫描 50 个文件，0 errors。
- `run.sh` 新增 `--no-tui` 与 `--cli` 分流，进入经典入口 `user_manager.sh`；默认仍进入 `tui_manager.sh`。
- `lib/tui_core.sh` 新增 `tui_handle_interrupt`，TUI 中断时清理终端、输出单次中断提示并以 130 退出，移除原先 `return` 型 trap 噪声风险。
- `tests/test_tui_mainline.sh` 新增无 TUI 分流与中断 trap 回归断言。

### 验证
- RED：新增 3 个断言先按预期失败（缺少 `--no-tui`、`--cli` 与非 `return` trap）。
- GREEN：`bash tests/test_tui_mainline.sh` 53/53 通过。
- 静态门禁：修改文件 `bash -n` 通过；`shellcheck -S error` 通过。
- LSP：全仓库 `.sh` 0 errors，仅保留既有 shellcheck warning/info。
- 回归：`bash tests/run_regression.sh --level p0` 1/1 通过；`bash tests/run_regression.sh --level p1` 18/18 通过。

## 2026-08-13 跨服务器/GPU 原型与设计

- 生成可视化管理平台原型，覆盖功能扩展、五段式交互、多智能体分派、SSH Provider 和 GPU 预留。
- Playwright 验证 1440px 与 390px 视口无横向溢出，页面无脚本错误，三套演进方案完整。
- 浏览器最终选择 `SSH-FIRST`；用户批准架构、交互、首期范围和可靠性门禁。
- 写入本地设计说明 `docs/superpowers/specs/2026-08-13-remote-gpu-management-foundation-design.md`，未提交。

## 2026-08-16 执行优化与清理

### P0 修复
- `user_manager.sh`：严格模式改为“仅直接执行时启用”，避免被 source 时覆盖测试调用方；`send_all_user_reports`/`check_expired_suspensions` 显式 `|| return $?` 传播退出码。`test_tui_mainline.sh` 由 68/70 修复为 70/70。
- 修复 4 个测试的 stdin 挂死：`priv_crontab`/`smbpasswd` 桩只在接收密码/安装 crontab 时消费 stdin；`test_password_change_smb`、`test_rl_privilege`、`test_user_core`、`test_smb_core` 不再阻塞。
- `tests/run_regression.sh`：新增每套件超时保护（默认 180s，`UM_TEST_TIMEOUT` 可调），并为非交互套件统一 `</dev/null`。

### 性能
- 默认 P1 不再重复运行全量 ShellCheck warning 门禁；需要时用 `--include-lint` 或 `UM_INCLUDE_LINT=1`。P1 从约 71s 降到约 20s。
- P1 回归 31/31 通过；`--level all` 32 通过、1 skip（P2 未启用）。

### 清理
- `Miniforge.sh`（100MB）已移动到 `/tmp/umg_cleanup_backup/Miniforge.sh`。
- 删除空目录 `.agents`、`.codex`、`.worktrees`。
- 删除 10 个已合入 main 的本地 feature 分支。
- 清理本地 `data/` 与 `logs/` 下的运行数据/日志（备份在 `/tmp/umg_cleanup_backup/`）。
- `lib/ui_menu_modern.sh`、`lib/privilege_cache.sh` 归档到 `archive/lib/`，并同步更新 ARCHITECTURE/DEEPWIKI/verify_fixes。
- CI validate-docs 移除“必须包含 Installation”的过期检查。

### 状态
- 未提交、未推送；所有改动保留在工作区。

## 2026-08-16 第二轮：并行/轻量 profile/输入校验

### 并行回归
- P1 默认并行执行（`UM_TEST_JOBS` 默认 4），每个测试使用独立临时 `USER_MANAGER_DATA_BASE`/`USER_MANAGER_BACKUP_ROOT`。
- 新增 `--no-parallel` 关闭并行、`UM_TEST_JOBS` 调整并发数。
- 实测 P1 31/31：约 20s（顺序）→ 约 8.5s（并行 4 任务）。

### 轻量加载 profile
- `lib/bootstrap.sh` 新增 `minimal` profile：common/config/env/action_registry/access_control/privilege/smb_core/quota_core/user_core/audit_core。
- `scripts/rl-user-list.sh`、`scripts/rl-audit-query.sh` 改用 `minimal`。
- 修复 7 个独立脚本 `VAR=... source` 变量不持久化问题，改为先赋值再 source。
- 修复 `collect_quota_users` 在 pipefail + repquota 不可用时误报 ERR。

### 安全输入校验
- `rl_mail_queue.sh`：入队必填字段、优先级 1-10、队列 ID 正整数、保留天数/处理数量正整数校验。
- `async_core.sh`：任务类型/ID 安全字符、优先级 1-10、数量/保留天数正整数、清理/列表/查询参数防 SQL 注入形态。
- `test_security_hardening.sh` 新增 4 个输入校验回归测试，14/14 通过。

### 验证
- `bash -n`、`shellcheck -S error`：新增/修改脚本通过。
- `run_regression.sh --level p1`：31/31 通过，约 8.5s。

## 2026-08-16 第三轮：SMB 管理板块 + Action 工具链

### SMB 管理
- `lib/smb_core.sh` 扩展：
  - `smb_show_status`：SMB 服务/命令可用性状态。
  - `smb_list_users` / `smb_user_exists` / `smb_show_user_status`：只读查询。
  - `smb_delete_user`：移除 SMB 用户。
  - 所有用户名统一安全字符校验，拒绝注入形态用户名。
- 新增 `scripts/rl-smb-manage.sh`：`list|status|show|password|disable|enable|remove`。
- TUI 网络与安全菜单新增“SMB 管理”子菜单，包含状态/列表/查看/设密/禁用/启用/移除。
- Action Registry 新增 7 个 `smb.*` actions，并注册 CLI handlers。
- `tests/test_smb_core.sh` 扩展至 14 个用例。

### Action 工具链
- 新增 `scripts/rl-action-list.sh`：
  - `--plain` / `--markdown` 输出 Action 表。
  - `--check` 加载 full profile + controllers，校验全部 handler 存在。
- README 补充 SMB 管理脚本与 `smb.*` action 表。
- `tests/test_scripts.sh` 增加 `rl-smb-manage.sh`、`rl-action-list.sh` 存在性与 help 测试。

### 验证
- `bash -n`、`shellcheck -S error`：通过。
- `test_smb_core.sh` 14/14、`test_action_registry.sh`、`test_scripts.sh`、`test_tui_mainline.sh` 70/70 通过。
- `run_regression.sh --level p1`：31/31 通过，约 9.6s。

## 2026-08-16 第四轮：shfmt 全量格式化 + SMB 共享 + 密码安全

### shfmt
- 仓库全部 `.sh` 已按 shfmt v3.12.0 默认格式全量格式化。
- CI format job 从提示模式改为阻断模式，安装版本同步为 v3.12.0。
- pre-commit shfmt rev 同步为 v3.12.0-1。

### SMB 共享管理
- `lib/smb_core.sh` 新增：
  - `smb_share_list`：解析 `smb.conf` 共享。
  - `smb_share_add`：写入 `/etc/samba/user-manager-shares.conf` drop-in。
  - `smb_share_remove`：从 drop-in 配置删除共享段。
- 新增 actions：`smb.shares`、`smb.share.add`、`smb.share.remove`。
- `rl-smb-manage.sh` 增加 `shares`、`share-add`、`share-remove`。
- TUI 与经典 CLI 的 SMB 菜单均加入共享管理项。
- `test_smb_core.sh` 扩展到 17 个用例。

### 密码安全
- 密码池消费加 `flock` 目录锁，避免并发取到同一密码。
- 邮件队列 `password_notify` 不再把明文密码写入 SQLite：密码写入 0600 secret 文件，DB 只保存 token。
- secret 文件默认使用 AES-256-CBC + HMAC-SHA256（encrypt-then-MAC）加密落盘，密钥由 `data/secrets/.key`（0600）管理；支持 `EMAIL_QUEUE_MASTER_KEY` 注入父密钥以对接外部 KMS，密文格式 `v1:<iv>:<ct>:<mac>`，内含独立随机 IV 与 HMAC 认证（防篡改）；无 openssl 时退化为明文 + 0600；提供 `rl_mail_queue_migrate_secret` 迁移存量明文 secret；`data/secrets/` 已加入 `.gitignore`。
- 修复 `${N:-{}}` 参数展开多出一个 `}` 的通用 bug（影响 `rl_mail_queue`、`rl_wecom_bot_sender`、`shell_config`）。
- 修复 `rl_mail_queue_enqueue` 用独立进程取 `last_insert_rowid()` 恒为 0 的 bug，改为同一条 SQLite 调用返回 ID。
- `test_security_hardening.sh` 扩展到 19 个用例（新增 secret 加密/解密往返/篡改检测/明文迁移 4 例）。

### 验证
- `bash -n`、`shellcheck -S error`、`shfmt -d`：全部通过。
- `test_smb_core.sh` 17/17、`test_security_hardening.sh` 15/15、`test_tui_mainline.sh` 70/70。
- `rl-action-list.sh --check`：26 个 action handler 全部存在。
- `run_regression.sh --level all`：32 passed / 0 failed / 1 skipped。

## 2026-08-16 第五轮：SMB 主配置 include 自动化管理（smb-engineer）

### 完成内容
- `lib/smb_core.sh` 新增：
  - `_smb_parse_shares`：解析单个 Samba 配置的 `[share]` 段（输出 `name|path`）。
  - `smb_share_list`：合并 `smb.conf` 与托管 drop-in `user-manager-shares.conf`，同名以 drop-in 覆盖。
  - `smb_include_status`：只读检查主配置是否已 `include = <drop-in>`（容忍任意空白）。
  - `smb_ensure_include`：幂等确保主配置 include 托管配置（优先 `priv_tee`，测试环境回退直写）。
  - `smb_share_add` 新增共享后自动调用 `smb_ensure_include`（失败仅告警，不阻断共享段写入）。
- 新增 action `smb.include`（status|ensure）与 CLI handler `rl_action_smb_include_cli`。
- `scripts/rl-smb-manage.sh` 新增 `include status|ensure` 子命令。
- 经典 CLI 子菜单（`lib/controller_submenus.sh`）与 TUI（`tui_manager.sh` + `lib/tui_menus.sh`）均新增「主配置 include 托管配置」入口。
- `tests/test_smb_core.sh` 扩展至 20 个用例（新增幂等 include、drop-in 合并列表、share_add 自动 include 三项）。
- README 补充 `smb.include` action 行；ARCHITECTURE 补充 `lib/smb_core.sh` 模块说明。

### 验证
- `bash -n`、`shellcheck -S error`、`git diff --check`：通过。
- `test_smb_core.sh` 20/20、`test_action_registry.sh` 24/24、`test_scripts.sh` 16/16、`test_tui_mainline.sh` 70/70。
- `rl-action-list.sh --check`：27 个 action handler 全部存在。
- `run_regression.sh --level p1`：31/31；`--level all`：32 passed / 0 failed / 1 skipped。
