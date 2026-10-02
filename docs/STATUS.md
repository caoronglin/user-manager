# 项目现状（STATUS）

> 核实时间：**2026-10-02**（CST）
> 核实基线：`HEAD = 0f6bee5`（`fix(ui): harden ACL cache and render usage colors`，2026-09-23）
> 核实环境：Linux 容器，工作目录 ext4，非 root（`uid=1001 T25ronglin`），无 Rust 工具链
>
> 本文记录**本次实际执行验证**得到的项目状态。凡未标注为「已核实」的内容，均来自仓库既有文档，**未经本次复核**。
> 本文不构成目标主机部署、GitHub 推送或版本发布证明。

---

## 1. 结论摘要

| 维度 | 状态 |
| --- | --- |
| 架构与安全边界 | 完整，静态门禁全部通过 |
| Bash 业务内核 / 只读快照层 / Web 控制台 | 三部分代码齐备 |
| **Git 工作树** | **严重不干净：97 项未提交改动（80 修改 + 17 未跟踪）** |
| **发布状态** | **v0.2.0 已发布；v0.3.0 的全部代码与文档从未提交、从未推送** |
| **Shell 回归（本机实测）** | **P0 1/1 通过；P1 40 套件中 35 通过、5 失败；P2 按规则跳过** |
| 失败根因 | **已全部定位**，均非业务逻辑缺陷（见第 5 节） |
| 静态门禁（bash -n / ShellCheck / Web 安全门禁 / 敏感文件扫描） | 全部通过 |
| Rust 后端 / 前端构建 | **本环境无法验证**（见 4.2 节） |

**最需要处理的一件事**：P4–P7（v0.3.0）的全部实现、`CHANGELOG.md`、`docs/M1_REPOSITORY_AUDIT.md` 以及整个 `web/frontend/` 仍处于未提交状态，最新文件修改时间为 2026-09-25，已滞留约一周。任何一次 `git checkout` / `git clean` / `git stash` 丢失都会带走数周的工作量。

---

## 2. Git 与工作树状态

### 2.1 分支与远端

| 项 | 值 |
| --- | --- |
| 当前分支 | `main`，领先 `origin/main` **1 个提交**（`0f6bee5`） |
| `origin/main` | `3855ec8`（`fix(user): show password when email is unavailable`） |
| 远端 | `https://github.com/caoronglin/user-manager.git` |
| 远端标签 | `v0.1.0`、`v0.2.0` —— **无 `v0.3.0`** |
| 本地标签 | 仅 `v0.1.0`（`v0.2.0` 未拉到本地） |
| stash | 无 |

### 2.2 未提交改动构成

共 **97 项**：80 个已跟踪文件被修改，17 项未跟踪。

**（a）49 个文件有实际内容变更**，主要分布：

| 区域 | 代表文件 | 变更量 |
| --- | --- | --- |
| 规划文档 | `plan.md` | +2659 / −430 |
| 邮件队列加固 | `lib/rl_mail_queue.sh` | +217 / −73 |
| 主机 Inventory | `lib/host_inventory.sh` | +181 / −56 |
| 快照契约 | `lib/snapshot_core.sh` | +163 / −40 |
| 用户内核（事件 spool） | `lib/user_core.sh` | +160 / −1 |
| 快照测试 | `tests/test_snapshot.sh` | +278 / −14 |
| CI | `.github/workflows/ci.yml` | +69 / −8 |
| Web 加密 | `web/backend/src/crypto.rs` | +287 / −24 |
| 前端 | `web/frontend/`（6 个源文件） | 整目录新增 |

**（b）31 个 `tests/*.sh` 仅有可执行位变更**（100644 → 100755），内容未改。这是 CHANGELOG 0.2.0 中「Restore executable Git modes」的收尾工作。

**（c）17 项完全未跟踪**（从未进入 Git 历史）：

```text
CHANGELOG.md                           docs/M1_REPOSITORY_AUDIT.md
docs/wecom-native-events.md            etc/tmpfiles.d/
lib/snapshot_ops.sh                    tests/test_event_spool.sh
tests/test_snapshot_ops.sh             web/frontend/
web/backend/src/event_spool.rs         web/backend/src/http/wecom_api.rs
web/backend/src/store/event_spool.rs   web/backend/src/store/snapshot_observer.rs
web/backend/src/store/web_event_delivery.rs
web/backend/src/store/wecom.rs
web/backend/src/web_event_delivery.rs
web/backend/tests/snapshot_store.rs    web/backend/tests/wecom_api.rs
```

> **风险**：`lib/snapshot_ops.sh` 是已注册采集器依赖的模块，`web/backend/src/store/wecom.rs` 等是 P4 的核心实现，`web/frontend/` 是整个前端。若工作树被清理，CI 与部署脚本引用的路径将直接缺失。

---

## 3. 架构现状

项目为**双控制面 + 只读观测层**结构。

```text
CLI/TUI/scripts  ──特权面──>  Linux 用户 / 配额 / SMB / 备份 / 防火墙
        │
        │ scripts/rl-snapshot.sh（root，可信采集器）
        ▼
  版本化 / 脱敏 / 原子写的 JSON 快照
        │
        ▼
  umweb（Rust/Axum，非特权）──只读──>  capability 门控的只读系统 API
        ├── Web 自有 SQLite：web_users / sessions / api_tokens / notifications
        └── 加密 WeCom 设置 + 有界投递历史
        ▲
  React 19 + Vite 8 + Ant Design 6 前端
```

### 3.1 不可动摇的硬约束

Web 面板**永远不拥有、代理或间接获得** root / sudo / capability。系统写操作只允许受信任管理员经本机 CLI/TUI 执行。危险 API **根本不存在**（写方法命中即 404/405），而非返回 403。完整约束见 [`WEB_SECURITY_BOUNDARY.md`](WEB_SECURITY_BOUNDARY.md) 与 `plan.md` 第 0 节。

> 备注：`plan.md` 标题仍写「Ant Design Pro 6.0 / Umi / ProComponents」，实际工程使用 React + Vite + Ant Design 6。该差异已在 `docs/M1_REPOSITORY_AUDIT.md` 与 `web/README.md` 中记录，但 `plan.md` 标题未同步。

### 3.2 规模

| 项 | 数量 |
| --- | --- |
| `lib/*.sh` 模块 | 67 |
| `scripts/*.sh` 独立 CLI 入口 | 18 |
| `tests/*.sh` 测试文件 | 44 |
| P1 回归套件（`P1_SCRIPTS`） | 40 |
| Action Registry 条目 | 29（`safe` 18 / `dangerous` 11；`both` 14 / `cli` 15） |
| Web 后端 Rust 源文件 | 48 |
| 前端源文件 | 6 |

---

## 4. 已核实的验证结果

### 4.1 本次实际执行（2026-10-02）

**Shell 分级回归**：`bash tests/run_regression.sh --level all`

```text
P0  verify_fixes   1/1 通过（内部检查 20/20）
P1  40 套件        35 通过 / 5 失败
P2  性能套件       按默认规则跳过（需 --include-perf）

运行器汇总（含 P0）：36 通过 / 5 失败 / 1 跳过
```

> **计数口径**：`P1_SCRIPTS` 数组实际声明 **40** 个套件。运行器末尾的 `Passed/Failed/Skipped`
> 汇总把 P0 也计入 `PASS_COUNT`，因此「41 个通过」是**全轮次总计**（1 个 P0 + 40 个 P1），
> 而不是 P1 的套件数。仓库既有文档中的「41 个套件通过」沿用的是这个总计口径，
> 容易被误读为 P1 有 41 个套件。`test_rl_mail.sh` 与 `test_rl_wecom.sh` **不在** `P1_SCRIPTS` 中，
> 只能单独执行，即邮件与企业微信专项目前不在 P1 门禁覆盖范围内。

失败套件的子测试明细：

| 套件 | 通过/总数 | 失败子测试 |
| --- | --- | --- |
| `test_scripts.sh` | 7/19 | 12 —— 全部为「脚本不存在或不可执行」 |
| `test_event_spool.sh` | 7/11 | 4 —— 全部为 publisher 调用失败 |
| `test_snapshot.sh` | 24/25 | 1 —— 「采集器存在且可执行」 |
| `test_rl_privilege.sh` | 18/19 | 1 —— wrapper 直接调用被拒 |
| `test_remote_cli.sh` | 8/9 | 1 —— 「缺少可执行主机入口」 |
| **合计** | **64/83** | **19** |

**静态门禁**（全部通过）：

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| Shell 语法 | `bash -n`（Git 跟踪的全部 `.sh`） | 通过 |
| ShellCheck error gate | `shellcheck --severity=error` | 通过 |
| Web 安全门禁 | `bash scripts/check_web_security.sh web/backend/src` | `OK (no forbidden tokens)` |
| 敏感文件扫描 | `bash scripts/check_sensitive_files.sh .` | `No sensitive tracked files detected` |

**对照修复验证**：执行 `chmod +x scripts/*.sh` 后重跑，`test_scripts.sh` 19/19、`test_snapshot.sh` 25/25、`test_remote_cli.sh` 9/9、`test_rl_privilege.sh` 19/19 —— **72 个子测试全部转绿**。验证后已恢复原有文件权限，工作树未留下改动。

### 4.2 本环境无法验证的部分

以下结论**沿用仓库既有文档，本次未复验**，不应据此认为当前仍然通过：

| 项 | 原因 |
| --- | --- |
| Rust fmt / Clippy / 65 项后端测试 | 环境无 `cargo` / `rustc` |
| 前端 `npm ci` + 生产构建 | `~/.npmrc` 指向 `registry.npmmirror.com`，且 npm 缓存位于只读文件系统（`EROFS`）。注：仓库 `package-lock.json` 内 110 条 `resolved` 全部为 `registry.npmjs.org`，仓库本身无镜像问题 |
| 目标主机部署验收 | 无目标 Ubuntu 主机 |
| 真实企业微信 webhook 投递 | 无凭据，未发送任何外部消息 |
| 完整 WCAG / 读屏器审计 | 尚未进行 |

---

## 5. 已知问题

### P0-1　`scripts/*.sh` 丢失可执行位（导致 4 个套件、18 个子测试失败）

**现象**：`test_scripts.sh` 12/19 失败，报「`scripts/rl-xxx.sh` 不存在或不可执行」。`test_snapshot.sh`、`test_remote_cli.sh`、`test_rl_privilege.sh` 各 1 例失败，同源。

**根因**：两个层面。

1. **Git 索引层**：`scripts/` 下 18 个入口中有 16 个在索引里是 `100644`，只有 `check_web_security.sh` 和 `rl-snapshot.sh` 是 `100755`。CHANGELOG 0.2.0 声称已「恢复 CLI 入口的可执行 Git 模式」，但该恢复工作只覆盖了 `tests/*.sh`（工作树中 31 个测试文件确有 100644 → 100755 的待提交变更），**`scripts/` 未被纳入**。
2. **工作树层**：`scripts/rl-hosts.sh`、`scripts/rl-remote-entry.sh`、`scripts/rl-snapshot.sh` 以及 `lib/snapshot_core.sh` 的实际权限是 `600`，比索引还严格。其中 `lib/snapshot_core.sh` 与 `scripts/rl-snapshot.sh` 在本次工作树中发生了 `100755 → 100644` 的回退。

历史背景：根入口 `run.sh`、`user_manager.sh`、`tui_manager.sh` 的执行位早在 2026-03 至 2026-05 间就已被移除（`3dd1c06`、`7d36186`、`3a09519`），属长期遗留。

**影响**：这些脚本**无法被直接执行**，只能 `bash scripts/rl-xxx.sh` 调用。CI 的「Check file permissions」目前只输出 `Warning`，不阻断，因此该问题会长期潜伏。

**修复**：

```bash
chmod +x scripts/*.sh                         # 工作树
git update-index --chmod=+x scripts/rl-*.sh   # 索引，纳入提交
```

并建议将 CI `security` job 的权限检查由 Warning 升级为阻断。

### P0-2　`test_event_spool.sh` 依赖小写首字母的用户名

**现象**：4 个子测试失败，publisher 一律返回非零。失败签名一致：正向用例因 publisher 返回非零而失败，反向用例因「publisher 恰好拒绝了所有输入」而通过。

**根因**：`lib/user_core.sh:398` 对 owner/group 施加 `^[a-z_][a-zA-Z0-9_-]*$`，要求**首字符小写**。测试以 `$(id -un)` / `$(id -gn)` 作为 owner/group 传入；本机账户为 `T25ronglin`（大写 `T` 开头），因而被判定非法。已用 `set -x` 跟踪确认：函数在 owner 正则校验处直接 `return 1`，从未创建 spool 目录。

**这不是产品缺陷**：生产调用固定传 `root umweb`（见 `lib/user_core.sh:480`），不受影响。测试自身也把 `Alice` 列入非法用户名用例，即**产品与测试都假定用户名小写开头**。

**为何 CI 不暴露**：GitHub Actions 以 `runner` 执行，全小写，故通过。只有本地账户名不满足该假设时才失败。

**修复方向**（二选一）：

- 测试侧：改用固定的小写 owner/group，或在用例中按账户名跳过；
- 产品侧：将 owner/group 校验放宽为 `^[A-Za-z_][A-Za-z0-9_.-]*$`。这两个值仅由 root 侧代码常量传入，放宽的实际安全收益有限，但能消除「测试结果依赖执行者用户名」这一隐患。

### P0-3　`CHANGELOG.md` 把未发布的 v0.3.0 记为已发布

**现象**：`CHANGELOG.md` 顶部是空的 `## Unreleased`，其下直接是 `## 0.3.0 — 2026-09-25`，带完整变更条目与「Validation」段落，格式与已发布版本完全一致。

**实际情况**：

- 远端标签只有 `v0.1.0`、`v0.2.0`，**无 `v0.3.0`**；
- `CHANGELOG.md` 本身是**未跟踪文件**，从未进入 Git 历史；
- 支撑 0.3.0 的全部代码同样处于未提交状态。

README 的表述（「GitHub 当前已发布版本仍为 `v0.2.0`；`v0.3.0` 候选版已准备」）与 Git 事实一致，与 `CHANGELOG.md` 的表述**相互矛盾**。

**修复（本次已应用）**：已将 `CHANGELOG.md` 该节改名为 `## 0.3.0 (unreleased — 未提交/未打 tag/未推送)`，并加注状态说明，指出远端仅有两个 tag、本文件未进入 Git 历史、Validation 段落来自干净克隆环境。

> 另：README 中「全仓 Shell 回归现为 41 个套件通过、0 个失败」一句与本文实测不符，已改为区分「干净克隆的记录」与「当前工作树的实测结果」，并指向本文。

### P1-1　文档时效性

- `docs/ARCHITECTURE.md` 停留在 2026-08-31，未包含 Web 控制台。
- `task_plan.md` 顶部标注「✅ 完成 | 最后更新: 2026-05-02」，正文却含 2026-05-07 起的进行中条目，状态自相矛盾。
- `progress.md` 最新条目为 2026-07-21，落后于实际进度。
- `.ai-memory/project_memory.md` 最新决策为 2026-08-31（SSH 只读基础），未覆盖 9 月的快照层与 Web 工作。
- `plan.md` 标题与实际技术栈不符（见 3.1 节备注）。

### P1-2　门禁覆盖缺口

`tests/test_rl_mail.sh` 与 `tests/test_rl_wecom.sh` **不在** `run_regression.sh` 的 `P1_SCRIPTS` 数组中，只能单独执行。而邮件队列（`lib/rl_mail_queue.sh`，本次改动 +217/−73，含认证加密与旧格式迁移）与企业微信投递正是本轮 v0.3.0 的改动重点。

这意味着：**P1 全绿并不代表邮件与企业微信链路被门禁覆盖**。建议将这两个套件纳入 `P1_SCRIPTS`，或在 CI 中显式单独运行。

### P1-3　工作树卫生

- 存在 15 个 `*.bak` 备份文件（含 `README.md.bak`、`tui_manager.sh.bak`、`lib/tui_core.sh.bak` 等）。`.gitignore:36` 已忽略 `*.bak`，均未跟踪，但持续干扰检索。
- `data/` 含运行时产物（`created_users.txt`、`logs/`、`report/`、`secrets/`），已正确排除在版本控制外。

---

## 6. 发布边界与待办

### 6.1 已达成

- 架构与安全边界完整，静态门禁全绿；
- 双控制面 + 只读快照层实现齐备，静态检查无越权痕迹；
- 29 个 Action 与 18 个独立 CLI 入口的功能面在 P1 回归中通过（除 P0-1 / P0-2 所述问题外）。

### 6.2 阻塞发布

1. **提交工作树**（P0-3 的前置）：先落地 97 项改动并拆分合理提交，这是其余所有事项的前提。
2. **修复 P0-1**：恢复 `scripts/*.sh` 可执行位，并把 CI 权限检查升级为阻断。
3. ~~**修正 P0-3**：`CHANGELOG.md` 的版本状态表述。~~ **本次已完成**，剩余动作是提交后打 tag。
4. **重新执行完整验证**：在干净克隆中跑通 `tests/run_regression.sh --level all`、Rust 门禁与前端构建，取得可发布的 CI 证据。

### 6.3 部署前必须完成（既有文档已记录，本次未验证）

1. 在目标 Ubuntu 主机验证 `umweb` 的组成员、sudoers、capability、`systemd` 属性、数据库与密钥属主权限、只读快照权限，以及 `um-snapshot.timer` 运行状态；
2. 真实企业微信 webhook 投递验收；
3. 完整 WCAG / 读屏器审计。

---

## 7. 文档地图

| 文档 | 内容 | 时效 |
| --- | --- | --- |
| [`STATUS.md`](STATUS.md) | 本文：现状、已核实结果、已知问题 | 2026-10-02 |
| [`../CHANGELOG.md`](../CHANGELOG.md) | 版本变更记录 | 见 P0-3 |
| [`../plan.md`](../plan.md) | Web 化实施规划与不可违反的架构约束 | 活跃 |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | 架构设计与功能说明 | 2026-08-31，缺 Web |
| [`DEEPWIKI.md`](DEEPWIKI.md) | 模块分层、目录结构、回归说明 | 2026-10-02 已刷新 |
| [`WEB_SECURITY_BOUNDARY.md`](WEB_SECURITY_BOUNDARY.md) | Web 非特权边界、快照 schema、secret 脱敏 | 活跃 |
| [`M1_REPOSITORY_AUDIT.md`](M1_REPOSITORY_AUDIT.md) | 仓库审计与 P0–P7 阶段完成度 | 2026-09-24 |
| [`wecom-native-events.md`](wecom-native-events.md) | WeCom 原生事件投递与隐私边界 | 2026-09-24 |
| [`REMOTE_HOSTS.md`](REMOTE_HOSTS.md) | SSH 主机与 GPU 只读探测 | 活跃 |
| [`../web/README.md`](../web/README.md) | Web 控制台（`umweb`） | 2026-09-25 |
| [`../README.md`](../README.md) | 入口、Action 表、快速开始 | 活跃 |

### 相关但已过时的过程文档

`task_plan.md`、`progress.md`、`findings.md`、`.ai-memory/project_memory.md` 记录 2026-05 至 08 的开发过程，**不反映当前状态**，仅作历史参考。
