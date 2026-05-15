# Progress - 用户管理工具完善

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
