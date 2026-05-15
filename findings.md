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
