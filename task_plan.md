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
