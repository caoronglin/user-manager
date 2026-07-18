# Task Plan - 用户管理工具完善项目

> 状态: ✅ 完成 | 最后更新: 2026-05-02

## 阶段一览

| 阶段 | 内容 | 状态 |
|------|------|------|
| N1 | 修复已发现的代码缺陷 | ✅ 完成 |
| N2 | 安全加固 - eval/source/路径注入 | ✅ 完成 |
| N3 | 测试覆盖增强 | ✅ 完成 |
| N4 | 代码风格统一 | ✅ 完成 |
| N5 | CI/CD 与文档完善 | ✅ 完成 |

## 本次改动文件

| 文件 | 改动 |
|------|------|
| `regenerate_password_pool.sh` | 修复: 删除函数外 local 声明 |
| `lib/backup_core.sh` | 修复: eval → 数组参数方式 |
| `README.md` | 新增: Installation 章节 |
| `.github/workflows/ci.yml` | 改进: 移除无效 ignore |
| `tests/run_regression.sh` | 新增: lock_core + backup_core 测试 |
| `tests/test_lock_core.sh` | 新文件: 18个锁系统测试 |
| `tests/test_backup_core.sh` | 新文件: 8个备份测试 |


## 2026-05-06 模块逻辑验证

| 项目 | 结果 |
|------|------|
| P0 smoke | ✅ 通过 |
| P1 模块回归 | ✅ 16/16 步骤通过 |
| TUI 主线逻辑 | ✅ 46/46 通过 |
| 锁模块逻辑 | ✅ 22/22 通过 |
| 备份模块逻辑 | ✅ 12/12 通过 |
| Shell 语法 | ✅ 通过 |
| ShellCheck error gate | ✅ 通过 |

本轮只修复验证链路暴露的最小问题：备份测试对齐真实接口、锁测试去重加载、回归帮助文案同步。

## 2026-05-07 VM/GPU/Proxy 功能收敛

> 状态: 🚧 进行中 | 分支: `feat/vm-gpu-proxy-management`

### 目标

- 添加最小可落地的虚拟机管理能力，优先基于 `virsh/libvirt` 做状态查询与生命周期操作。
- 添加最小只读显卡管理能力，优先基于 `nvidia-smi`，无 NVIDIA 工具时回退 `lspci`。
- 优化用户创建与 mamba 配置链路，把 `proxy()` 写入用户 `.bashrc` 与 `.zshrc`。
- 收敛备份模块与各模块衔接，保持最小权限包装。
- 去除 README 与运行口径中的“安装功能/安装使用”表达。

### 阶段

| 阶段 | 内容 | 状态 |
|------|------|------|
| V1 | 恢复上下文并确认目标文件 | ✅ 完成 |
| V2 | 为 VM/GPU/proxy/文档口径补 RED 测试 | ✅ 完成 |
| V3 | 实现 core 模块与 TUI/bootstrap/回归接入 | ✅ 完成 |
| V4 | 去安装口径与备份逻辑最小收敛 | ✅ 完成 |
| V5 | bash/shellcheck/相关测试/P1 回归验证 | ✅ 完成 |

### 约束

- 不提交，除非用户明确要求。
- 不回滚既有大量未提交历史改动。
- 不主动轮询尚未收到完成通知的后台探索任务。
- 新增特权命令必须走 `lib/privilege.sh` 白名单/包装。

### 验证结果

- RED：`tests/test_vm_core.sh`、`tests/test_gpu_core.sh`、`tests/test_user_core.sh`、`tests/test_bootstrap_integration.sh`、`tests/test_tui_mainline.sh` 均先按预期失败。
- GREEN：VM/GPU/user/bootstrap/TUI 定向测试全部通过。
- 静态门禁：`bash -n` 与 `shellcheck -S error` 覆盖新增/修改脚本，通过。
- 回归：`bash tests/run_regression.sh --level p1` 通过 18/18；`bash tests/run_regression.sh --level p0` 通过 1/1。

## 2026-05-07 bash-language-server / 无 TUI / 中断输出

> 状态: ✅ 完成 | 分支: `feat/vm-gpu-proxy-management`

### 目标

- 使用已安装的 `bash-language-server` 重新验证 Bash LSP。
- 为统一入口开发无 TUI 路径。
- 优化 TUI 中断 shell 输出，避免 trap 中 `return` 带来的噪声。

### 阶段

| 阶段 | 内容 | 状态 |
|------|------|------|
| Q1 | 重新运行 LSP 诊断 | ✅ 完成 |
| Q2 | 探索 no-TUI 与中断输出路径 | ✅ 完成 |
| Q3 | 补 RED 测试 | ✅ 完成 |
| Q4 | 最小实现 `--no-tui`/`--cli` 与中断 trap | ✅ 完成 |
| Q5 | LSP/bash/shellcheck/P0/P1 验证 | ✅ 完成 |

### 验证结果

- LSP：全仓库 `.sh` 扫描 50 个文件，0 errors；仅有既有 shellcheck warning/info。
- 定向测试：`bash tests/test_tui_mainline.sh` 53/53 通过。
- 静态门禁：`bash -n run.sh lib/tui_core.sh tests/test_tui_mainline.sh` 通过；`shellcheck -S error` 通过。
- 回归：`bash tests/run_regression.sh --level p0` 1/1 通过；`bash tests/run_regression.sh --level p1` 18/18 通过。

## 2026-07-17 当前工作区检查与修复

> 状态: ✅ 完成 | 分支: `main` | 工作区: 已有大量未提交改动

### 目标

- 识别当前仓库可复现的语法、静态检查、测试或集成问题。
- 先确认根因，再用最小改动修复，并补充必要的回归覆盖。
- 保留现有未提交工作，不执行回滚、提交或推送。

### 阶段

| 阶段 | 内容 | 状态 |
|------|------|------|
| C1 | 恢复上下文、确认检查入口与工作区边界 | ✅ 完成 |
| C2 | 运行最小基线检查并定位根因 | ✅ 完成 |
| C3 | 按独立问题域实施最小修复 | ✅ 完成 |
| C4 | 运行针对性与必要回归验证 | ✅ 完成 |
| C5 | 诊断 `create_or_assign_user` 返回码 1 | 🚧 等待运行时错误上下文 |

### 约束

- 不回滚或覆盖现有未提交改动。
- 不提交、不推送，除非用户明确要求。
- 修复前必须有稳定复现或明确静态证据。
- 后台探索任务完成前不轮询；只处理不重叠的本地基线工作。

### C1 结果

- 项目是 Linux/Bash 用户管理工具；正式检查入口为 `tests/run_regression.sh`。
- P0 为最小内置基线，P1 为核心模块回归，P2 为显式启用的性能测试。
- 当前工作区未提交变更须完整保留；本轮不使用回滚类 Git 操作。

### C2 当前基线

- `git diff --check`：通过。
- 自有 Bash 脚本（排除第三方 `Miniforge.sh`）`bash -n`：通过。
- 自有 Bash 脚本 `shellcheck -S error`：通过。
- `bash tests/run_regression.sh --level p0`：通过（1/1；内部检查 20/20）。

### C2 根因结论

- P1 行为回归通过 31/31，但发现两类测试质量问题：
  - `tests/test_ubuntu_maintenance_core.sh` 在 7 个 `test_start` 中调用了 21 次 `test_pass`；`tests/test_network_stack_core.sh` 为 5/13。根因是单个测试案例内连续调用多个会递增全局通过计数的 `assert_*`。
  - `tests/test_smb_core.sh` 先将 `PATH` 设为无命令目录、后调用未使用绝对路径的 `mkdir`，导致测试通过时仍输出“mkdir: 未找到命令”。
- `lib/action_registry.sh` 重复 source 时无条件重复声明 `readonly RL_ERR_*`，Bash 会输出四条“只读变量”警告。
- `.github/workflows/ci.yml` 的 Bash 语法循环包含二进制自解压安装器 `Miniforge.sh`；`bash -n Miniforge.sh` 已稳定复现 ELF 内容处语法失败。
- 文档门禁本身可用：`docs/DEEPWIKI.md` 已跟踪且存在；先前“文档缺失”判断不成立。`docs/ARCHITECTURE.md` 仍为现有未跟踪用户文件，未纳入本轮修改。

### 已确认范围与延期项

- 用户选择“先修确定问题”：仅修复 CI 的 `Miniforge.sh` 排除、两份测试的统计/输出质量、动作注册表重复 source 噪声，并增加对应回归保障。
- `async_core.sh` 与 `rl_mail_queue.sh` 的未验证 SQLite 参数边界、密码队列明文存储、密码池并发竞态、临时文件异常清理均不在本轮范围；不得趁本次修改改变其业务语义。

### C3 书面设计

- 用户已批准“最小定点修复”方向。
- 设计文件已本地写入 `docs/superpowers/specs/2026-07-17-ci-test-quality-repairs-design.md`，未提交；待用户书面评审后进入实施计划阶段。
- 用户已确认书面设计并授权执行；实施计划已本地写入 `docs/superpowers/plans/2026-07-17-ci-test-quality-repairs.md`，不提交。

### C3 实施结果

- `.github/workflows/ci.yml` 的 Shell 语法检查改为 NUL 安全遍历 Git 跟踪的 `*.sh`，精确跳过第三方二进制安装器 `Miniforge.sh`；`pipefail` 保证枚举或语法检查失败都会传递为 CI 非零退出。
- `lib/action_registry.sh` 新增错误码常量守卫：重复 source 静默、可写预定义值会归一并锁定、错误或未赋值 readonly 值明确拒绝，且在 `set -u` 下安全。
- `tests/test_action_registry.sh` 覆盖重复 source 的 stderr、注册表保留、可写/readonly/nounset 常量边界与既有分发返回码。
- Ubuntu 与 Network 模块测试将多条件断言聚合为每个 `test_start` 一次结果，统计由 7/21、5/13 分别恢复为 7/7、5/5；未修改通用测试框架。
- SMB 测试在覆盖 `PATH` 前创建无命令目录，并断言无 `smbpasswd` 分支成功且 stderr 为空，保留 9/9 行为。

### C4 验证结果

- 定向：动作注册表 23/23、Ubuntu 维护 7/7、Network Stack 5/5、SMB 9/9；SMB 测试进程 stderr 为空。
- 回归：`bash tests/run_regression.sh --level p0` 通过 1/1（内部 `verify_fixes.sh` 20/20）；`bash tests/run_regression.sh --level p1` 通过 31/31。
- 静态门禁：NUL 安全枚举的 Git 跟踪 Shell（跳过 `Miniforge.sh`）均通过 `bash -n`；同范围 `shellcheck -S error` 通过；`git diff --check` 通过。
- 最终只读集成审查：`ora-7` 于 2026-07-17 返回 APPROVED，未发现本轮范围内的阻断问题或延期安全项业务变更。
- 未执行 Git 提交、推送、合并或回滚；既有未提交工作保持原样。

### C5 当前诊断

- `safe_run` 仅将下游非零状态统一显示为“函数 `create_or_assign_user` 执行失败（返回码：1）”，该信息本身不包含具体失败分支。
- 已定位直接失败分支：实例锁、取消/非法用户名、密码池/手动密码、磁盘解析与挂载、用户组输入、确认取消、创建/更新用户、用户组配置。
- 尚无完整运行时输出、输入序列或目标账户状态，不能安全归因或实施修复；等待用户提供报错前后的非敏感输出。
