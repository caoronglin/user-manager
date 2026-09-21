# bats-core 迁移评估（2026-07-21）

> Lane H5 交付物。对应设计文档 `docs/superpowers/specs/2026-07-21-hardening-optimizations-design.md` 中 Lane H5。
> 本文档只做评估与建议，不产生任何对现有文件（`tests/*.sh`、`lib/`、TUI 文件）的修改。
> 试点代码位于 `tests/bats/`（新增目录，独立于现有测试体系）。

## 1. 现状分析：自研测试框架

### 1.1 结构

| 组件 | 说明 |
|---|---|
| `tests/test_framework.sh` | 框架本体：`test_suite_start/end`、`test_start`、`test_pass/test_fail/test_skip/test_todo`，全局计数 `TESTS_RUN/TESTS_PASSED/TESTS_FAILED`；16 种断言（`assert_equals`、`assert_not_equals`、`assert_true/false`、`assert_contains`、`assert_file_(not_)exists`、`assert_dir_exists`、`assert_success/failure`、`assert_return_0/nonzero`、`assert_array_length`、`assert_numeric_equals/greater_than/less_than`）；`setup_test_env/cleanup_test_env`（mktemp + EXIT trap） |
| `tests/test_*.sh`（34 个） | 按模块组织的用例脚本，source `test_framework.sh` 后顺序执行 `test_start` + 断言；32 个文件使用 `test_start`，全库约 395 处用例点 |
| `tests/run_regression.sh` | 分级回归执行器：`--level p0\|p1\|p2\|all`；P0=verify_fixes.sh（静态冒烟），P1=30+ 个模块脚本顺序执行（逐个注入 `SUDO_NONINTERACTIVE=1`、`USER_MANAGER_DATA_BASE`、`USER_MANAGER_BACKUP_ROOT`），P2=perf_test.sh（`--include-perf` 才跑）；按脚本粒度汇总 PASS/FAIL/SKIP，任一失败退出码 1 |

### 1.2 优点

- **零依赖**：纯 bash + 系统自带命令，任何有 bash 的机器（含内网、容器）开箱即用，无需包管理器。
- **单进程顺序执行**：用例间天然共享全局状态与 shell 函数，适合"脚本式"集成测试（如 TUI 的 `coproc`、环境变量注入），写起来门槛低。
- **输出即人读**：彩色、分层的控制台报告，失败原因就地打印，排障直观。
- **粒度灵活**：断言函数失败不中止当前用例（`test_fail` 仅计数），一个用例可串多个断言；`test_skip/test_todo` 支持标记性跳过。
- **分层回归**：`run_regression.sh` 的 P0/P1/P2 与每脚本环境注入，已形成稳定的 CI/手工回归入口，且 `--level` 可裁剪耗时。

### 1.3 缺点

- **无机器可读输出**：只有人类文本；CI 只能靠退出码 + 抓日志，无法产出 TAP/JUnit，与 GitHub Actions / 第三方报告器集成成本高。
- **断言失败不中止用例**：`test_fail` 后同用例后续代码继续跑，可能产生级联失败、同一缺陷重复计数，掩盖真实失败点。
- **无用例隔离**：一个用例的副作用（未清理的变量、临时文件、PATH 修改）会污染后续用例，状态类 bug 极难定位；`setup_test_env` 需手动调用且依赖 EXIT trap。
- **无选择性执行**：只能整文件跑（`bash tests/test_xxx.sh`），无 `--filter` 式按名称筛选；回归只能粗粒度 `--level` 裁剪。
- **无并行**：30+ 脚本串行执行，全量回归耗时长；脚本内部用例也不可并行。
- **计数口径弱**：`TESTS_RUN` 统计的是 `test_start` 调用次数，与"断言通过数/失败数"不是一个维度；`test_suite_end` 的通过率计算存在整型截断（`*100/`）。
- **无超时保护**：用例挂死（如等待 stdin）时整个回归卡住，无 `--timeout` 类兜底。
- **无生命周期钩子**：无标准的 setup/teardown 每用例执行语义（只有手动 `setup_test_env` + 全局 EXIT trap）。

## 2. bats-core 对比

| 维度 | 自研框架 | bats-core |
|---|---|---|
| 输出 | 彩色人类文本 | 默认 pretty + `--tap`（TAP14）；bats ≥1.11 支持 `--formatter junit`；机器可读 |
| 断言 | `assert_*` 函数（失败仅计数） | 每个 `@test` 独立用例：`run <cmd>` + `$status/$output` + `[ ]`/`[[ ]]`（零依赖），或可选 `bats-assert` 的 `assert_success/assert_output`；**首个失败即中止该用例** |
| 用例组织 | `test_start "name"` 顺序执行 | `@test "name" { ... }` 块；每个 `@test` 在独立子 shell 运行，天然隔离 |
| 动态注册 | 无（手写每用例） | 生成 `@test` 块，或 bats ≥1.11 用 `bats_test_function` 在测试内动态调用其他测试函数，支持数据驱动批量用例 |
| 生命周期 | `setup_test_env` + EXIT trap（手动） | 标准 `setup()`/`teardown()`（每用例）、`setup_file()`/`teardown_file()`（每文件） |
| 并行 | 无 | `bats --jobs N`（bats ≥1.2，按文件并行；用例隔离使其安全） |
| 筛选 | 无 | `bats --filter <regex>` 按测试名筛选；`-f` 亦可 |
| 跳过 | `test_skip`（仅打印） | `skip "reason"`（计入 skipped，非失败） |
| CI | 退出码 + 文本日志 | 非零退出码 + TAP/JUnit，GitHub Actions 原生消费（taptap / junit formatter） |
| 依赖 | 无 | 需安装 bats-core（apt/源码/npm 均可）；`bats-assert` 等为可选增强 |
| 环境注入 | `run_regression.sh` 逐个 `env VAR=... bash script` | `env VAR=... bats tests/bats/`（bats 子进程继承环境），或测试内显式设置 |

## 3. 迁移收益与风险

### 3.1 收益

1. **标准断言体系**：`run` + `$status/$output` 是事实标准，新成员/社区示例可直接复用；失败即停，失败点精确。
2. **用例隔离**：子 shell 执行消除状态污染，回归结果可复现。
3. **并行提速**：`--jobs` 对纯函数模块套件收益明显（当前 P1 串行 30+ 脚本）。
4. **定向调试**：`--filter` 可只跑某个函数相关用例，替代"整文件跑 + grep"。
5. **CI 友好**：TAP/JUnit 输出 + 退出码，GitHub Actions 现成集成。
6. **社区生态**：bats-assert/bats-support/bats-file 等官方插件；文档与 bug 修复活跃。

### 3.2 风险

1. **改写成本（最大）**：34 个测试文件、约 395 个用例点需逐个改写为 `@test` 块；大量用例依赖跨用例共享状态（`ENV_FORCE_*`、mock 变量、临时目录），迁移时必须重构为 `setup()` 初始化或 `export`，工作量 ≈ 重写而非平移。估算：纯函数模块约 0.5–1 人日/文件，TUI 套件更高。
2. **计数/语义差异**：自研"一用例多断言、失败继续" vs bats"一 @test 一用例、失败即停"，历史通过率与失败数不可直接对比；`TESTS_RUN` 与 bats 用例数是不同口径。迁移验收需要"bats 用例数 ≥ 原断言覆盖"的新基准。
3. **TUI 套件 stdin 驱动兼容性**：现有 TUI 测试用 `echo ... | tui_manager.sh`、heredoc、`coproc` 驱动交互；bats 的 `run` 不直接接受管道（需 `run bash -c 'printf ... | tui'` 或显式重定向），且 TUI 测试在脚本中穿插 `test_start` 与大量全局状态，是迁移成本最高、收益最低的部分。
4. **无外部依赖约束**：仓库无包管理器（无 apt/brew/npm 声明链），bats 必须系统安装（`sudo apt-get install -y bats`）或 vendor 进仓库；离线/内网环境安装受限；CI 需要新增安装步骤，与"零依赖开箱即跑"的现状冲突。
5. **双轨维护成本**：迁移期间两套框架并存，断言风格与阅读习惯不一致，新人需要同时掌握两套。
6. **版本差异**：`bats_test_function`（1.11+）、junit formatter（1.11+）、`--jobs`（1.2+）等特性依赖版本，需锁定最低版本（建议 ≥1.10）。

## 4. 分阶段迁移建议

### 阶段 0：试点（本次交付；运行验证待 bats 安装后补齐）

- 交付：`tests/bats/test_env_core.bats`（env_core 模块，8 个真实行为断言，source 真实 `lib/env_core.sh`，通过 PATH 注入与 `ENV_FORCE_SYSTEMD` 钩子 mock 外部环境）+ `tests/bats/README.md` + 本文档。
- 约束：不修改任何现有文件；不接入 `run_regression.sh`。
- **退出条件**：bats 安装成功且 `bats tests/bats/` 全绿（该两项本机未满足，待补）；试点断言覆盖 env_core 主要行为（`env_capability_summary` 因依赖多系统命令暂未迁移）；未触碰现有文件（本 lane 产出仅新增）。

### 阶段 1：按模块分批迁移非 TUI 套件

- 顺序（按纯函数程度从高到低）：`env_core` → `shell_config` → `lock_core`/`backup_core`/`smb_core`/`journalctl_core` → `user_core`/`quota_core`/`privilege`/`audit` → 其余非 TUI 模块。
- 每批做法：新建 `tests/bats/test_<module>.bats`，先写等价断言再对照旧文件逐条核对；依赖外部命令的用例用临时目录 PATH 注入 mock；依赖环境的用例用 `ENV_FORCE_*`/显式 env。
- **退出条件**（每批）：bats 用例数 ≥ 旧文件 `test_start` 数；`bats tests/bats/` 全绿；旧 `test_<module>.sh` 仍由 `run_regression.sh` 运行且结果一致（双轨对照 ≥2 次回归）。

### 阶段 2：TUI 套件

- 前提：阶段 1 完成且双轨对照稳定。
- 做法：先写 `tests/bats/helpers/tui_input.bats` 辅助层（`run bash -c 'printf ... | tui_manager.sh'`、`coproc` 驱动模式），再逐文件迁移 `test_tui_core`/`test_tui_mainline`/`test_tui_native_forms`/`test_tui_logs_view`。
- **退出条件**：TUI 用例在 bats 下行为与原套件一致（含超时与挂死场景验证）；stdin 驱动模式在 CI 非交互环境通过。

### 阶段 3：决策点（废弃自研框架 或 保留双轨）

- **废弃路径**：阶段 1+2 全部完成、CI 连续 ≥4 周全绿、`run_regression.sh` 改为调用 `bats tests/bats/`（或退役），`tests/test_framework.sh` 与旧 `test_*.sh` 冻结归档。前置条件：CI 可安装 bats（apt 源可用或 vendor）。
- **双轨路径**：`run_regression.sh` 与自研框架保持现状不动，bats 作为新增的平行测试通道（非 TUI 纯函数模块），长期共存。
- **退出条件**：协调者依据本评估（尤其 TUI 迁移成本与依赖约束）拍板；无论哪条路径，均需一次全量 `--level all` 回归确认无回归。

## 5. 结论建议

**推荐保持双轨，不全面迁移。**

理由：

1. 自研框架已稳定运行且满足"零依赖、开箱即跑"的核心约束；本仓库无包管理器，bats 引入即破坏该约束，离线环境不可用。
2. 迁移的主要收益（并行、TAP、隔离）集中在**非 TUI 纯函数模块**——这部分可用 bats 试点平行覆盖，不必整体迁移即可获益。
3. TUI 套件（4 个文件）迁移成本最高（stdin 驱动 + 全局状态重构）而收益最低（本就无法并行、输出本就人读），留在自研框架更合适。
4. 计数口径差异使"全面迁移"的验收基准需要重建，风险大于收益。

**行动项（若采纳）**：按阶段 1 顺序，以 `tests/bats/` 为固定目录持续增量补充非 TUI 模块的 bats 套件；`run_regression.sh` 与 `tests/test_framework.sh` 永不删除；CI 中 bats 作为附加 job（安装后运行 `bats tests/bats/`），失败不阻塞主回归；TUI 维持自研框架。

## 6. 本试点运行结果（2026-07-21）

- 本机 **未安装 bats**（`bats --version` → command not found），试点文件未实际运行；阶段 0 退出条件中「bats 安装成功且 `bats tests/bats/` 全绿」两项待补（安装 `sudo apt-get install -y bats` 后执行验证）。
- 安装命令：`sudo apt-get install -y bats`（Ubuntu/Debian；源码方式见 `tests/bats/README.md`）。
- 语法校验说明：`bash -n` 不适用于 `.bats` 文件（`@test` 为 bats 语法扩展，非 bash 语法）；本试点无独立辅助函数脚本，`lib/env_core.sh` 引用路径已人工核对（`BATS_TEST_DIRNAME` 计算，见 `tests/bats/test_env_core.bats` 头部注释）。
- 验证补充：`tests/bats/test_env_core.bats` 覆盖 env_core 主要行为；`env_capability_summary` 因依赖多系统命令（journalctl/systemctl/jq/ufw 等探测）暂未迁移；bats 侧另有真实命令/函数检测、PATH mock 外部命令、空与未注册能力、`env_require_capability` 等新增断言（模拟脚本逐条执行 23 条断言全部通过）。
