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
