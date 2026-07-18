# Findings - 代码审计

> 审计日期: 2026-05-02 | 状态: 所有发现已处理

## 已修复

### 1. `regenerate_password_pool.sh:71` - 函数外 local ✅
删除函数外错误使用的 `local count`。

### 2. `backup_core.sh` heredoc 内 eval ✅
字符串拼接+eval → 数组参数: `rsync "${RSYNC_ARGS[@]}"`

## 设计确认

- set 选项模式: 库文件不设 set 不覆盖调用方 — 正确 ✅
- source 路径: 全部基于系统控制路径，安全 ✅
- eval: 已完全消除 ✅

## 测试改善

- 新增 `test_lock_core.sh` (18用例)
- 新增 `test_backup_core.sh` (8用例)
- 测试覆盖模块: 16 → 18


## 2026-05-06 模块逻辑验证发现

- 新增备份测试原先覆盖了不存在的 `generate_backup_script`/`verify_backup_exists` 等接口，已改为覆盖真实接口：`generate_exclude_file`、`show_backup_status`、`list_backup_users`、`_safe_cleanup_backups`、`update_backup_index`、`show_backup_chain`、`configure_backup_schedule` 输入校验。
- `test_lock_core.sh` 重复 source `lock_core.sh` 会触发 `FINE_LOCK_DIR` 只读变量告警；实际 `common.sh` 已加载锁模块，已删除重复 source。
- `tests/run_regression.sh --help` 的 P1 描述落后于实际测试集合，已同步到 tui/lock/backup 覆盖范围。

## 2026-05-07 VM/GPU/Proxy 初始发现

- 当前工作区在开始前已有大量历史修改与删除，不能执行回滚类操作；新工作已切到 `feat/vm-gpu-proxy-management`。
- `README.md` 仍包含 `## Installation` 章节，需要移除安装步骤，仅保留运行与测试口径。
- 待确认并修改的核心文件：`lib/miniforge_core.sh`、`lib/user_core.sh`、`lib/bootstrap.sh`、`lib/tui_menus.sh`、`tui_manager.sh`、`lib/privilege.sh`、`tests/run_regression.sh`。
- 后台探索任务尚未收到完成通知，暂不读取 `background_output`，避免轮询与重复搜索。

## 2026-05-07 实现发现

- VM 生命周期命令采用 `virsh list --all`、`domstate`、`start`、`shutdown`、`reboot`、`destroy`、`autostart`，写操作经 `priv_virsh`。
- GPU 查询优先 `nvidia-smi --query-gpu=index,name,driver_version,memory.total --format=csv,noheader,nounits`，无 NVIDIA 工具时回退 `lspci`。
- `git grep` 在测试环境中会因线程创建失败导致私钥内容扫描漏报；已改为基于 `git ls-files` 的逐文件 `grep -nI -E`。
- `bash-language-server` 未安装，LSP 诊断不可用；本项目 Bash 验证以 `bash -n` 与 `shellcheck -S error` 作为实际门禁。
- Oracle 复核发现 `ensure_user_proxy_function` 原先会用普通 redirection 写用户 rc 文件，非 root 管理员场景会失败；已改为优先 `priv_touch` + `priv_tee -a`，并用测试断言覆盖。

## 2026-05-07 无 TUI 与中断输出发现

- 用户安装 `bash-language-server` 后，LSP 诊断可用；全仓库 `.sh` 扫描 50 个文件，0 errors。
- `run.sh` 是唯一顶层入口门面；原先仅 `exec bash tui_manager.sh "$@"`，没有用户可见的 `--no-tui`/`--cli` 分流。
- 经典非 TUI 路径已存在于 `user_manager.sh` → `controller_start` → `main_menu`，因此最小实现是让 `run.sh --no-tui|--cli` 转发到 `user_manager.sh`。
- TUI 主循环原先使用 `trap 'tui_cleanup; return 0' INT TERM EXIT`；脚本 trap 内 `return` 有产生 shell 噪声的风险，且绕开公共中断提示。
- 最小修正是新增 `tui_handle_interrupt` 并在 `tui_run` 中用 `trap 'tui_handle_interrupt' INT TERM` 与 `trap 'tui_cleanup' EXIT` 分离中断处理和退出清理。

## 2026-07-17 当前工作区初始发现

- 当前分支为 `main`，相对 `origin/main` 领先 5 个提交。
- 工作区已有 20 个跟踪文件被修改，并有 `.slim/`、`docs/ARCHITECTURE.md`、`lib/smb_core.sh`、`tests/test_password_change_smb.sh`、`tests/test_smb_core.sh` 等未跟踪内容。
- 本轮必须将这些内容视为用户既有工作，只做精确、可验证的增量修复。
- 既有记录显示项目主要门禁包括 Bash 语法、ShellCheck 与分级回归测试，但当前真实命令和测试集合仍需从仓库现状重新确认。

## 2026-07-17 基线检查结果

- `git diff --check` 未发现空白错误。
- 排除第三方二进制安装器 `Miniforge.sh` 后，所有已跟踪与未忽略的 Bash 脚本均通过 `bash -n`。
- 同一范围通过 `shellcheck -S error`。
- P0 冒烟通过：`bash tests/run_regression.sh --level p0` 返回 1/1，`verify_fixes.sh` 内部 20/20。
- 尚未发现可复现缺陷；继续用 P1 行为回归与独立风险扫描寻找问题证据。

## 2026-07-17 根因确认与修复范围

### 本轮确定修复项

1. `.github/workflows/ci.yml` 的语法检查遍历了 `Miniforge.sh`；该文件在 ELF 负载开始处无法通过 `bash -n`，CI 会确定失败。
2. `tests/test_ubuntu_maintenance_core.sh`（7 run/21 pass）和 `tests/test_network_stack_core.sh`（5 run/13 pass）在单个 `test_start` 后多次调用断言，导致全局 passed 计数大于 tests run。
3. `lib/action_registry.sh` 无条件重新声明 `readonly RL_ERR_*`；重复 source 时输出只读变量错误，虽不使测试失败但破坏干净加载。
4. `tests/test_smb_core.sh` 在将 `PATH` 清空为测试目录后才调用 `mkdir`，产生预期外的“mkdir: 未找到命令”噪声。

### 已核实但延期的安全项

- `async_core.sh` 和 `rl_mail_queue.sh` 中的任务/队列 ID、优先级、分页数和保留天数缺少入口格式验证；当前未发现 CLI/TUI 直达路径，但作为可 source 的公共 Shell API 仍需后续安全硬化。
- 当前邮件队列正常业务路径对字符串字段已有 SQL 单引号转义，队列 ID 从 SQLite 自增整数取得；本轮不调整数据库格式、队列数据或邮件通知语义。

### 更正

- `docs/DEEPWIKI.md` 已存在且被 Git 跟踪，CI 的 required-docs 检查当前不会因它失败。此前“文档目录不存在”的初步判断已排除。

## 2026-07-17 最小修复完成与复验

- CI 语法门禁改为使用 `git ls-files -z -- '*.sh'` 枚举跟踪文件、NUL 安全读取、仅跳过 `Miniforge.sh`，并通过 `set -o pipefail` 保证枚举失败或 `bash -n` 失败能令步骤失败。
- 动作注册表的错误码常量现在可重复 source 而不输出 stderr；可写错值会校正并锁定，错误 readonly 或未赋值 readonly 会给出明确诊断并拒绝加载；实现对 nounset 安全。
- 两份模块测试的通过计数与测试案例数重新一致：Ubuntu 维护 7/7、Network Stack 5/5；SMB 缺少 `smbpasswd` 的测试路径没有 stderr 噪声且仍为 9/9。
- 全新验证通过：动作注册表 23/23、P0 1/1（内置检查 20/20）、P1 31/31、全量跟踪 Shell 的 `bash -n` 和 `shellcheck -S error`、`git diff --check`。
- 最终 Oracle 集成审查结论为 APPROVED，无阻断问题；延期的 SQL 参数边界、队列与密码安全项没有混入本轮。

## 2026-07-17 `create_or_assign_user` 返回码 1 初步诊断

- 用户报告的文字来自 `lib/common.sh` 的 `safe_run` 统一包装，无法单独说明 `create_or_assign_user` 的具体失败原因。
- 函数定义位于 `lib/controller_user_provisioning.sh`；其显式失败路径包括锁、输入校验、密码获取/校验、目标磁盘解析、确认取消、创建或更新用户，以及附加用户组配置。
- 当前没有真正执行完整交互工作流的回归测试；`test_bootstrap_integration.sh` 只验证该函数已导出。
- 该控制器文件不在当前未提交修改列表中；但依赖的 `user_core.sh`、`privilege.sh`、`bootstrap.sh` 等有既有未提交改动，不能在没有实际 stderr/输入上下文时归因于此前的 CI/测试质量修复。
- 等待完整非敏感终端输出、入口路径、账户是否已存在、输入选择以及锁/挂载状态后继续根因定位；不得在此之前猜测性修改创建流程。
