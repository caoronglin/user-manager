# tests/bats/ — bats-core 试点目录（阶段 0）

> Lane H5（bats-core 迁移评估）交付物。背景见 `docs/bats-migration-assessment.md`。
> 本目录与现有 `tests/*.sh` 自研框架**完全隔离**：不 source `test_framework.sh`，不修改、不接入 `tests/run_regression.sh`。

## 目录内容

| 文件 | 说明 |
|---|---|
| `test_env_core.bats` | env_core 模块试点：8 个 `@test`（含子断言共 23 条），source 真实 `lib/env_core.sh`；通过临时目录注入 PATH mock 外部命令，通过 `ENV_FORCE_SYSTEMD` 钩子 mock 系统环境 |
| `README.md` | 本文件 |

## 安装 bats-core

仓库无包管理器，bats 需系统级安装。Ubuntu/Debian：

```bash
sudo apt-get install -y bats
bats --version   # 建议 >= 1.10（1.11+ 才有 bats_test_function / junit formatter）
```

无 apt 权限或离线环境（源码安装，需 git 与 make）：

```bash
git clone https://github.com/bats-core/bats-core.git /tmp/bats-core
cd /tmp/bats-core
./install.sh /usr/local   # 或 ./install.sh "$HOME/.local" 并加入 PATH
```

其他方式：`brew install bats-core`（macOS）。

## 运行

在仓库根目录执行：

```bash
bats tests/bats/                      # 运行全部试点
bats tests/bats/test_env_core.bats    # 运行单文件
bats --tap tests/bats/                # TAP 输出（CI/机器可读）
bats --filter env_capability tests/bats/   # 按测试名正则筛选
bats --jobs 4 tests/bats/             # 并行（试点用例互相隔离，可安全并行）
```

预期结果（待 bats 安装后验证）：8 个 `@test` 全部通过（`status=0`）。失败时查看对应 `@test` 内的 `$status`/`$output` 断言。

## 试点约定（后续阶段 1 新增模块请遵循）

1. **零外部依赖**：不引入 `bats-assert`/`bats-support`，断言一律使用 `run` + `$status`/`$output` + `[ ]`/`[[ ]]`。
2. **引用真实 lib**：路径由 `BATS_TEST_DIRNAME` 推算（如 `source "${PROJECT_ROOT}/lib/env_core.sh"`），禁止复制实现。
3. **mock 外部命令**：`setup()` 中 `mktemp -d` 建临时目录，生成可执行假命令后注入 `PATH`，`teardown()` 清理；**不要** mock 被测试函数本身。
4. **mock 系统环境**：优先使用 lib 自带的 `ENV_FORCE_*` 钩子（如 `ENV_FORCE_SYSTEMD`），避免依赖真实系统状态。
5. **用例隔离**：每个 `@test` 独立子 shell；需要跨用例共享的变量在 `setup()` 中初始化或显式 `export`。
6. **不触碰现有文件**：本目录只增不改；`run_regression.sh` 与 `test_framework.sh` 永不修改。

## CI 集成（未来，非本阶段）

阶段 1 若推进，在 `.github/workflows/ci.yml` 增加独立 job：`sudo apt-get install -y bats && bats tests/bats/`，失败不阻塞主回归（双轨对照期）。
