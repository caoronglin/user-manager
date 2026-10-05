# 项目现状（STATUS）

> 核实时间：**2026-10-05**（CST）。2026-10-03 复验运行时目录注入契约 + SMB 加固 + 门禁修复；
> 2026-10-05 追加前端生产构建实测（§4.3，证伪了此前「缓存只读」的理由）与两项前端修复
> 核实基线：`main` 包含本轮新增的 5 个提交（见 §2.1.3）
> **Git 工作树：干净。** `main` 领先 `origin/main` **19 个提交**，**未推送**。
> 提交计数口径：本文所有「N 个提交」一律锚定到 `8d99219` 实测值；该提交之后若有新提交，按锚点递增理解，不回改本文数字。
> 本轮提交前工作树为 11 个已跟踪文件被修改 + 4 项未跟踪
> （`tests/test_runtime_dir_contract.sh`、`docs/ablation/`、`docs/audit/`、`.validation/`），
> 现已全部入库；另有 1 份设计文档因 `.gitignore:56` 忽略整个 `docs/superpowers/`
> 而不在 `git status` 中，已用 `git add -f` 纳入（`850a807`）。
> 对比基线：`0f6bee5`（2026-10-02 整理前的 `main`）
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
| **Git 工作树** | **干净**；`main` 领先 `origin/main` **19 个提交**（截至 `8d99219`），未推送 |
| **发布状态** | **v0.2.0 已发布；v0.3.0 已提交到本地 `main`，尚未推送或打 tag** |
| **Shell 回归（本机实测）** | **P0 1/1 通过；P1 43 套件全绿；P2 按规则跳过** |
| 已知缺陷 | **P0-1 / P0-2 / P0-3 / P2-1 / P2-2 均已修复**；CI 权限门禁与 validate-docs 章节检查已阻断化；`umweb` 无 root 拒绝启动为**已接受的纵深防御缺口**（P1-5，未修，理由见第 5 节） |
| 静态门禁（bash -n / ShellCheck / Web 安全门禁 / 敏感文件扫描） | 全部通过 |
| Rust 后端 | **本环境无法验证**（无 `cargo` / `rustc`，见 4.2 节） |
| 前端生产构建 | **本环境已验证通过**（2026-10-05，见 4.3 节） |

**本轮已完成**：整理前工作树有 97 项未提交改动（最新文件修改时间停在 2026-09-25，滞留约一周），其中包含整个 `web/frontend/`、`lib/snapshot_ops.sh` 与 8 个 Web 后端模块，全部从未进入 Git 历史。现已拆为 6 个提交落地到本地 `main`（`74cdbc1`…`abc6946`），**在那轮结束时**工作树干净；此后又追加 7 个提交（§2.1.2），并产生了当前这批未提交改动（见文首）。**尚未推送，也未打 `v0.3.0` tag。**

---

## 2. Git 与工作树状态

### 2.1 分支与远端

| 项 | 值 |
| --- | --- |
| 当前分支 | `main`，领先 `origin/main` **19 个提交**（截至 `8d99219`，含整理前的旧 HEAD `0f6bee5`） |
| `origin/main` | `3855ec8`（`fix(user): show password when email is unavailable`） |
| 远端 | `https://github.com/caoronglin/user-manager.git` |
| 远端标签 | `v0.1.0`、`v0.2.0` —— **无 `v0.3.0`** |
| 本地标签 | 仅 `v0.1.0`（`v0.2.0` 未拉到本地） |
| stash | 无 |
| 工作树 | **干净**（本轮 5 个提交已全部落地） |
| 推送状态 | **未推送**，本地 19 个提交（截至 `8d99219`）尚未到达 `origin/main` |

> **计数订正（2026-10-03）**：本文此前在摘要写「13」、在 §2.1 写「7」，两处都与
> `git rev-list --count origin/main..HEAD` 的实测值不符。本轮 5 个提交入库后实测为 **19**
> = 整理阶段 6（§2.1.1）+ 后续 7（§2.1.2）+ 本轮 5（§2.1.3）+ 整理前的旧 HEAD `0f6bee5`。

### 2.1.1 整理阶段的 6 个提交

> 标题原写「本轮提交的 7 个提交」，但表内只有 6 行；第 7 个是后续的 `1317c44`，已移入 §2.1.2。

| 提交 | 说明 |
| --- | --- |
| `74cdbc1` | `chore(tests)` 恢复 31 个测试套件可执行位 |
| `6df7b18` | `feat(shell)` 只读快照层、Ubuntu Ops 采集、root event spool |
| `9cc731d` | `feat(web)` WeCom 管理 API、快照新鲜度观察、React 控制台 |
| `7b6427b` | `ci(deploy)` Rust/前端/文档/格式门禁与 umweb 部署边界加固 |
| `2563059` | `docs` 项目现状、架构文档刷新与版本状态修正 |
| `abc6946` | `fix(shell)` 恢复 `scripts/` 入口可执行位（修复 P0-1） |

### 2.1.2 整理之后的 7 个提交

| 提交 | 说明 |
| --- | --- |
| `1317c44` | `docs` 同步 P0-1 修复后的实测结果 |
| `0c82afc` | `docs` 新增完成进度与未完成项清单（`docs/PROGRESS.md`） |
| `87a74da` | `fix(shell)` owner/group 校验误用 Linux 用户名规则（修复 P0-2） |
| `b5c469d` | `fix(tests)` `test_security_hardening` 向仓库内 `logs/email.log` 追加写入 |
| `a4762a5` | `ci` 邮件与企业微信链路纳入 P1 门禁，权限检查升级为阻断 |
| `91706e1` | `docs` 修正技术栈表述并补全 Web 架构 |
| `62f00fc` | `docs` 同步两个缺陷修复与门禁收紧后的实测结果 |

### 2.1.3 本轮（2026-10-03）新增的 5 个提交

> 表内 5 个提交截至 `8d99219`。其后仅有修正本节自身矛盾的文档提交，不计入本表。

| 提交 | 说明 |
| --- | --- |
| `850a807` | `feat(shell)` 运行时目录注入契约：`DATA_DIR` / `LOG_DIR` 可被 `USER_MANAGER_*` 重定向，配套 10 例契约测试与设计文档 |
| `9fe6296` | `fix(smb)` 共享路径可向 smb.conf 注入指令、共享名按正则匹配致误删共享段（见 P2-1） |
| `807114a` | `ci` Web 安全门禁空转守卫 + 两处永不阻断的检查 + `.validation/*` 排除（见 P2-2） |
| `cdabb37` | `docs` 收录独立审计与守卫消融实验产物（含 `.validation/`） |
| `8d99219` | `docs` 本文与 `PROGRESS.md` / `ARCHITECTURE.md` / `DEEPWIKI.md` 的事实订正 |

### 2.2 整理前的未提交改动构成（已全部提交）

整理前工作树有 **97 项**未提交改动：80 个已跟踪文件被修改，17 项未跟踪。以下构成记录当时的状况，现已全部落地。

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
| `tests/*.sh` 测试文件 | 45（43 个 P1 套件 + 1 个 P0 `verify_fixes` + `test_framework.sh` 框架） |
| P1 回归套件（`P1_SCRIPTS`） | 43 |
| Action Registry 条目 | 29（`safe` 18 / `dangerous` 11；`both` 14 / `cli` 15） |
| Web 后端 Rust 源文件 | 38（`web/backend/src/**/*.rs`；另有 10 个位于 `web/backend/tests/`） |
| 前端源文件 | 6 |

---

## 4. 已核实的验证结果

### 4.1 本次实际执行（2026-10-02）

**Shell 分级回归**：`bash tests/run_regression.sh --level all`

```text
P0  verify_fixes   1/1 通过（内部检查 20/20）
P1  43 套件        43 通过 / 0 失败
P2  性能套件       按默认规则跳过（需 --include-perf）

运行器汇总（含 P0）：44 通过 / 0 失败 / 1 跳过
```

P1 全绿。套件数由 40 增至 42 是因为 `test_rl_mail.sh` 与 `test_rl_wecom.sh`
已纳入门禁（见 5.1）；由 42 增至 43 是因为 `test_runtime_dir_contract.sh`
已纳入门禁（见 P1-3 勘误）。

> **计数口径**：`P1_SCRIPTS` 数组当前声明 **43** 个套件。运行器末尾的
> `Passed/Failed/Skipped` 汇总把 P0 也计入 `PASS_COUNT`，因此「44 个通过」是
> **全轮次总计**（1 个 P0 + 43 个 P1），不是 P1 的套件数。仓库既有文档中沿用的
> 「41 个套件通过」是 2026-10-02 补入门禁前的口径（当时 P1 为 40），容易被误读为
> P1 有 41 个套件。

本轮无失败套件。历史对照数据（`HEAD = 2563059`，修复 P0-1 之前）：

| 套件 | 通过/总数 | 失败子测试 |
| --- | --- | --- |
| `test_scripts.sh` | 7/19 | 12 —— 全部为「脚本不存在或不可执行」 |
| `test_event_spool.sh` | 7/11 | 4 —— publisher 调用失败（P0-2） |
| `test_snapshot.sh` | 24/25 | 1 —— 「采集器存在且可执行」 |
| `test_rl_privilege.sh` | 18/19 | 1 —— wrapper 直接调用被拒 |
| `test_remote_cli.sh` | 8/9 | 1 —— 「缺少可执行主机入口」 |
| **合计** | **64/83** | **19** |

### 4.1.1 本轮修复的两个真实缺陷

| 缺陷 | 影响 | 提交 |
| --- | --- | --- |
| `user_core.sh` owner/group 误用 Linux 用户名规则 | 账户名大写开头时事件发布全失败，4 个子测试红 | `87a74da` |
| `test_security_hardening.sh` 向仓库内 `logs/email.log` 追加 | 跨套件共享写入点，工作区无上限增长 | `b5c469d` |

**静态门禁**（全部通过）：

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| Shell 语法 | `bash -n`（Git 跟踪的全部 `.sh`） | 通过 |
| ShellCheck error gate | `shellcheck --severity=error` | 通过 |
| Web 安全门禁 | `bash scripts/check_web_security.sh web/backend/src` | `OK (no forbidden tokens)`（空目录改为报错，见 P2-2） |
| 敏感文件扫描 | `bash scripts/check_sensitive_files.sh .` | `No sensitive tracked files detected` |
| 入口可执行位 | CI `security` job（读 Git 索引 mode） | `checked=23, missing=0` |
| CI YAML 可解析 | `python3 -c "import yaml;yaml.safe_load(...)"` | 7 个 job 均可解析 |

**P0-1 修复效果**：`abc6946` 恢复 `scripts/` 可执行位后，上述 4 个套件全部转绿（`test_scripts.sh` 19/19、`test_snapshot.sh` 25/25、`test_remote_cli.sh` 9/9、`test_rl_privilege.sh` 19/19，**72 个子测试**），P1 由 35/40 提升到 39/40。

> **并行执行下的偶发失败**：修复后的首次完整回归出现 `test_web_security_gate.sh` 与
> `test_ubuntu_maintenance_core.sh` 两例失败，但两者单独运行均为全绿，第二次完整回归
> 也未复现。其中 `test_ubuntu_maintenance_core.sh` 本轮没有任何改动。这说明 P1 默认的
> 4 路并行在本机负载下存在偶发抖动，**单次回归结果不足以判定**，定位问题时应对失败套件
> 单独重跑。

> **新增抖动观察**：`test_runtime_dir_contract.sh` 第 8 例曾在 4 路并行下 FAIL、单跑 PASS，
> 后续两次连跑均绿。与上面同属一类并行抖动，定位时同样先单跑再下结论。

> **抖动根因线索（2026-10-03）**：本机多次出现**与并发无关**的进程/线程创建失败——
> `find` 报 `failed to spawn thread: Os { code: 11, kind: WouldBlock }`，
> `shellcheck` 报 `internal error: Ticker: Failed to spawn thread`、
> `scripts/check_sensitive_files.sh` 报 `fork: retry: 资源暂时不可用`，
> 而**同一条命令稍后重跑即全部通过**。这说明至少有一部分「4 路并行偶发失败、单跑全绿」
> 来自**本机进程/线程资源耗尽（EAGAIN）**，而不是套件逻辑缺陷。
> 触发阈值尚未定位，但以后定位这类抖动，应先看失败输出里有没有 spawn/fork/资源类错误，
> 再去怀疑测试代码或被测实现。

### 4.2 本环境无法验证的部分

以下结论**沿用仓库既有文档，本次未复验**，不应据此认为当前仍然通过：

> **2026-10-05 订正**：本表原有「前端 `npm ci` + 生产构建」一行，理由写的是 npm 缓存位于
> 只读文件系统（`EROFS`）。该结论**经实测证伪**并已移出本表：缓存目录
> `~/.npm` 属主可写，`npm ci` 与 `npm run build` 均成功。真实障碍与结论见 §4.3。

| 项 | 原因 |
| --- | --- |
| Rust fmt / Clippy / 65 项后端测试 | 环境无 `cargo` / `rustc` |
| 目标主机部署验收 | 无目标 Ubuntu 主机 |
| 真实企业微信 webhook 投递 | 无凭据，未发送任何外部消息 |
| 完整 WCAG / 读屏器审计 | 尚未进行 |

### 4.3 前端生产构建（2026-10-05 实际执行，已通过）

此前记为「本环境无法验证」，理由是 npm 缓存只读（`EROFS`）。**该理由经实测证伪**。
本节记录真实障碍与复现方式。

| 步骤 | 命令 | 结果 |
| --- | --- | --- |
| 缓存可写性 | `ls -ld ~/.npm` | `drwxr-xr-x T25ronglin T`，属主可写 |
| 依赖安装 | `npm ci --no-audit --no-fund` | 退出码 0，4 秒，85 个包 |
| 生产构建 | `RAYON_NUM_THREADS=16 npm run build` | 退出码 0，363 ms |
| 产物 | — | `index.html` 0.58 kB；CSS 23.78 kB（gzip 6.00）；JS 1,121.30 kB（gzip 356.47） |

**两个真实障碍**（都不是「无法构建」）：

1. **既有 `node_modules` 是残缺的。** 体检 83 个包，其中 **33 个**的 `package.json` 声明入口
   指向的文件不存在——`@rc-component/resize-observer` 只有 6 个文件，`es/index` 与
   `lib/index` 均缺失，而 `antd/es/avatar/Avatar.js` 正好 import 它，rolldown 报
   `failed to resolve import`。`npm install` 见到目录已存在便不重装，必须
   `rm -rf node_modules && npm ci` 才能修好。症状极具迷惑性：**报错指向 antd，真因在依赖树残缺**。
2. **rolldown 的 rayon 线程池在本容器初始化 EAGAIN**（`Resource temporarily unavailable`；
   `nproc=256`、`ulimit -u=3807322` 都很宽松，cgroup 未挂载）。把 `RAYON_NUM_THREADS` 设为
   非 1 值即可绕过（实测 16 正常）；设 1 反而因单线程打包 antd 全量而超时。

**一个被实测推翻的假设**：产物 1.1 MB 曾被怀疑是 `import { ... } from 'antd'` 具名 barrel
导入未 tree-shake，把 DatePicker / Calendar / Upload 等未使用组件一并打包。改为
`antd/es/<module>` 按需引入后构建通过，但**体积与未使用组件探针结果均无变化**
（gzip 356.46 → 356.47 kB；`Select date`、`Transfer`、`QRCode` 等文案照旧命中）——
那些字符串来自 `antd/es/locale/en_US.js` 这一个整包（antd 6 的 locale 含全部组件文案），
不是组件代码。该改动**已回滚**，barrel 导入保持原样。记录在此以免重复走同一条弯路。

---

## 5. 已知问题

### P2-1　本轮（2026-10-03）已修复：SMB 共享入参校验缺失

消融实验场景 E1（`lib/smb_core.sh:228` 共享名校验）在实跑边界值时暴露了两个**静态审计未抓到**的缺陷。
两者都在 `smb_share_add()` / `smb_share_remove()` 的入参上，写入目标是 root 拥有的
`/etc/samba/user-manager-shares.conf`。

| 缺陷 | 定级 | 实际后果（已用 `62f00fc` 原始代码复现） | 修复 |
| --- | --- | --- | --- |
| 共享路径无任何校验（仅 `[[ -n "$path" ]]`） | **P2** | ① **配置注入**：路径含换行时，后续内容变成 smb.conf 的**新指令行**。实测传入 `"/srv/ok\n   writable = yes"` 后 drop-in 里真的出现了 `writable = yes`，即把只读共享变成可写共享；理论上可注入任意指令。② **路径越界**：`../../etc` 原样写入，使本应只管 `/srv` 的操作可指向任意路径。 | 新增 `_smb_valid_share_path()`：必须绝对路径、不得含控制字符（换行/回车/制表）、不得含 `.` / `..` 路径段 |
| 共享名匹配未按字面量 | **P2**（原估 P3） | 共享名被直接拼进 `grep` / `awk` 正则，`.` 是通配符：**`smb_share_remove a.b` 会连带删除 `[axb]` 段**。实测在原始代码上 `a.b` 与 `axb` 两个共享，删除 `a.b` 后两个段全没了。另 `.` / `..` / `---` 因字符类含 `.` 与 `+` 而被放行。 | 匹配改为 `index()` 字面量比较（新增 `_smb_share_section_exists()`）；共享名额外要求至少含一个字母/数字/下划线 |

**为什么值得当场修**：可利用面确实有限——Web 侧没有 SMB 写路由，`smb.share.add` 是
`dangerous` 且只经本机 CLI/TUI 调用，所以**不构成越权**。但第 ① 条不需要攻击者：
TUI 输入框粘贴带换行的路径、或任何把未清洗变量透传给 `rl-action.sh` 的脚本，都会静默
把共享改成可写。修复共 4 处代码 + 4 条回归用例（`tests/test_smb_core.sh` 现 24/24）。

**验证方式**：4 条新用例对 `62f00fc` 原始 `smb_core.sh` **全部 FAIL**，对修复后代码全部 PASS
（不是同义反复测试）。本环境可完整验证，无需 cargo。

### P2-2　本轮（2026-10-03）已修复：三个失效门禁

| 门禁 | 原行为 | 修复 |
| --- | --- | --- |
| `scripts/check_web_security.sh` | 目录存在但无任何 `.rs` 时打印 `OK (no forbidden tokens)` 并返回 **0** —— 路径传错、源码被清空与「源码干净」不可区分 | 新增 `scanned` 计数，为 0 时报错并 `exit 1`（fail-closed），与 `a4762a5` 给权限检查加 `checked -eq 0` 守卫同理 |
| `ci.yml` Web 安全门禁步骤 | `bash scripts/check_web_security.sh ...` 后紧跟 `rc=$?`，但 GHA 的 `run` 默认 `bash -e`，脚本非零退出会先被 `-e` 中止，**`rc=2` 的跳过分支永不可达**（已实测：`bash -e -c 'bash t.sh; rc=$?'` 在 `t.sh` exit 2 时不执行后续行）。后果是「无 web 源码」从「跳过」变成「失败」 | 执行移入 `if` 条件上下文（条件失败不触发 `-e`），两种语义同时保留 |
| `ci.yml` validate-docs README 章节检查 | 三处 `grep` 全部只 Warning，**永远不可能让 CI 变红** | 章节存在性（Quick Start / Documentation）改为 `::error::` + `exit 1`；「Installation」那一条**故意保留 Warning**（它是给人的确认提示，不是机器可判定断言） |

只有第 1 项能写回归用例（`tests/test_web_security_gate.sh` 新增 2 例，现 9/9）；后两项是
CI 配置改动，**本环境无法在 GitHub Actions 上执行**，只做了 `yaml.safe_load()` 可解析性与
本地等价复现（README 现满足全部检查，阻断化不会让现有 CI 变红）。

### P0-1　`scripts/*.sh` 丢失可执行位 —— **已修复（`abc6946`）**

**现象**：`test_scripts.sh` 12/19 失败，报「`scripts/rl-xxx.sh` 不存在或不可执行」。`test_snapshot.sh`、`test_remote_cli.sh`、`test_rl_privilege.sh` 各 1 例失败，同源。

**根因**：两个层面。

1. **Git 索引层**：`scripts/` 下 18 个入口中有 16 个在索引里是 `100644`，只有 `check_web_security.sh` 和 `rl-snapshot.sh` 是 `100755`。CHANGELOG 0.2.0 声称已「恢复 CLI 入口的可执行 Git 模式」，但该恢复工作只覆盖了 `tests/*.sh`（工作树中 31 个测试文件确有 100644 → 100755 的待提交变更），**`scripts/` 未被纳入**。
2. **工作树层**：`scripts/rl-hosts.sh`、`scripts/rl-remote-entry.sh`、`scripts/rl-snapshot.sh` 以及 `lib/snapshot_core.sh` 的实际权限是 `600`，比索引还严格。其中 `lib/snapshot_core.sh` 与 `scripts/rl-snapshot.sh` 在本次工作树中发生了 `100755 → 100644` 的回退。

历史背景：根入口 `run.sh`、`user_manager.sh`、`tui_manager.sh` 的执行位早在 2026-03 至 2026-05 间就已被移除（`3dd1c06`、`7d36186`、`3a09519`），属长期遗留。

**影响**：这些脚本**无法被直接执行**，只能 `bash scripts/rl-xxx.sh` 调用。CI 的「Check file permissions」目前只输出 `Warning`，不阻断，因此该问题会长期潜伏。

**修复（已提交 `abc6946`）**：`scripts/` 下 16 个入口恢复 100755，并补回 `lib/snapshot_core.sh`
与 3 个测试文件（它们同时存在内容变更，未随 `74cdbc1` 一并恢复）。P1 由 35/40 提升到 39/40。

**后续加固（`a4762a5`）**：CI「Check file permissions」已由 Warning 收紧为阻断式，
判据直接读 Git 索引 mode 而非 `[[ -x ]]`，并带 `checked -eq 0` 守卫防止门禁静默失效。
为使其转绿，5 个根目录入口（`run.sh` / `user_manager.sh` / `tui_manager.sh` /
`verify_fixes.sh` / `perf_test.sh`）的索引 mode 已补为 100755。

### P0-2　`test_event_spool.sh` 依赖小写首字母的用户名 —— **已修复（`87a74da`）**

**现象**：4 个子测试失败，publisher 一律返回非零。失败签名一致：正向用例因 publisher 返回非零而失败，反向用例因「publisher 恰好拒绝了所有输入」而通过。

**根因**：`lib/user_core.sh:398` 对 owner/group 施加 `^[a-z_][a-zA-Z0-9_-]*$`，要求**首字符小写**。测试以 `$(id -un)` / `$(id -gn)` 作为 owner/group 传入；本机账户为 `T25ronglin`（大写 `T` 开头），因而被判定非法。已用 `set -x` 跟踪确认：函数在 owner 正则校验处直接 `return 1`，从未创建 spool 目录。

**这不是产品缺陷**：生产调用固定传 `root umweb`（见 `lib/user_core.sh:480`），不受影响。测试自身也把 `Alice` 列入非法用户名用例，即**产品与测试都假定用户名小写开头**。

**为何 CI 不暴露**：GitHub Actions 以 `runner` 执行，全小写，故通过。只有本地账户名不满足该假设时才失败。

**修复（已提交 `87a74da`）**：改产品侧。owner/group 是 POSIX 账户名而非本工具创建的
Linux 用户名，POSIX 允许大写与点（`Users`、`staff.svc`），小写首字符约束过严。
校验改为 `^[A-Za-z_][A-Za-z0-9_.-]*$`；真正要挡住的是会被 `chown`/`id`/`getent`
误解析的输入——前导短横线、空白、shell 元字符、路径分隔符与 `..`，首字符限定为
字母或下划线已全部覆盖。已用 28 个恶意输入与 12 个合法账户名逐一验证，无泄漏无误拒。
测试同时新增前置条件断言：若账户名再次不满足规则，立即以明确信息失败，而不是产生
4 个语义不明的 "publisher failed"。

> 未改动 `lib/smb_core.sh` 的 `_smb_valid_username`、`user_core.sh` 的
> `_um_event_spool_username_is_valid` 与 `scripts/rl-chpasswd.sh` —— 它们校验的是
> Linux 用户名，小写约束正确。

### P0-3　`CHANGELOG.md` 把未发布的 v0.3.0 记为已发布 —— **已修复（`2563059`）**

**现象**：`CHANGELOG.md` 顶部是空的 `## Unreleased`，其下直接是 `## 0.3.0 — 2026-09-25`，带完整变更条目与「Validation」段落，格式与已发布版本完全一致。

**实际情况**：

- 远端标签只有 `v0.1.0`、`v0.2.0`，**无 `v0.3.0`**；
- `CHANGELOG.md` 本身是**未跟踪文件**，从未进入 Git 历史；
- 支撑 0.3.0 的全部代码同样处于未提交状态。

README 的表述（「GitHub 当前已发布版本仍为 `v0.2.0`；`v0.3.0` 候选版已准备」）与 Git 事实一致，与 `CHANGELOG.md` 的表述**相互矛盾**。

**修复（本次已应用）**：已将 `CHANGELOG.md` 该节改名为 `## 0.3.0 (unreleased — 未提交/未打 tag/未推送)`，并加注状态说明，指出远端仅有两个 tag、本文件未进入 Git 历史、Validation 段落来自干净克隆环境。

> 另：README 中「全仓 Shell 回归现为 41 个套件通过、0 个失败」一句与本文实测不符，已改为区分「干净克隆的记录」与「当前工作树的实测结果」，并指向本文。

### P1-1　文档时效性

- `task_plan.md` 顶部标注「✅ 完成 | 最后更新: 2026-05-02」，正文却含 2026-05-07 起的进行中条目，状态自相矛盾。
- `progress.md` 最新条目为 2026-07-21，落后于实际进度。
- `.ai-memory/project_memory.md` 最新决策为 2026-08-31（SSH 只读基础），未覆盖 9 月的快照层与 Web 工作。
- `plan.md` 标题与实际技术栈不符（见 3.1 节备注）。

### P1-2　门禁覆盖缺口 —— **已修复（`a4762a5`）**

`tests/test_rl_mail.sh` 与 `tests/test_rl_wecom.sh` **不在** `run_regression.sh` 的 `P1_SCRIPTS` 数组中，只能单独执行。而邮件队列（`lib/rl_mail_queue.sh`，本次改动 +217/−73，含认证加密与旧格式迁移）与企业微信投递正是本轮 v0.3.0 的改动重点。

**修复（已提交 `a4762a5`）**：两个套件已纳入 `P1_SCRIPTS`，P1 由 40 增至 42。两者均使用
stub，不依赖外部网络或额外工具，并行执行下互不干扰（实测污染量为 0）。

### P1-3　设计观察：`DATA_DIR` / `LOG_DIR` 无法通过环境覆盖

`lib/config.sh:17-18` 对 `DATA_DIR`、`LOG_DIR` 是**无条件赋值**：

```bash
DATA_DIR="$SCRIPT_DIR/data"
LOG_DIR="$SCRIPT_DIR/logs"
```

与 `lib/rl_mail_*.sh` 使用的 `${LOG_DIR:=...}` 回退写法不同。这意味着：

- 任何通过环境变量重定向数据/日志目录的尝试都会被 `config.sh` 覆盖；
- 库会把数据写进**源码树**，而不是安装位置或临时目录；
- 逐套件隔离因此必须由测试自己显式覆盖变量，无法在 runner 层统一兜底
  （`run_p1_one` 传的是 `USER_MANAGER_DATA_BASE`，与库读取的 `DATA_DIR` 不是
  同一个变量）。

本轮的 `test_security_hardening.sh` 泄漏正是这一设计放大的结果。**已修复（2026-10-02）**：
见下方勘误。测试层重定向 `EMAIL_LOG_FILE` 的针对性修复保留，作为纵深防御。

#### 勘误（2026-10-02）：本项已解决

契约已改为可被环境覆盖，`lib/config.sh:25-27`：

```bash
DATA_DIR="${USER_MANAGER_DATA_DIR:-$SCRIPT_DIR/data}"
LOG_DIR="${USER_MANAGER_LOG_DIR:-$SCRIPT_DIR/logs}"
REPORT_DIR="$DATA_DIR/report"
```

- **用 `:-` 而非 `:=`**：`source config.sh` 不会把默认值回写进 `USER_MANAGER_DATA_DIR`，
  避免同 shell 内 source 之后再改写 `DATA_DIR` 的调用方读到陈旧值（`test_security_hardening.sh`、
  `test_proc_manager.sh`、`test_audit_integration.sh` 都是这个顺序）。
- **空值视为未设置**并回退默认，避免 `DISABLED_USERS_FILE` 退化为 `/disabled_users.txt`。
- **目录创建责任不变**：`init_directories` 仍是唯一创建者，失败即返回非 0（fail-closed）。
  本轮未新增任何 `mkdir`、未改动权限语义。
- **兼容性**：未设置新变量时行为逐字节不变；`etc/` 下 systemd 单元、tmpfiles.d、sudoers
  均不引用这两个变量，部署行为零变化。
- **实测副作用已消除**：注入生效后，一轮全量回归对 `data/` 与 `logs/` **零写入**
  （前后文件清单与 md5 快照完全一致）。这正是本项的原始诉求。
- **配套**：`run_regression.sh` 在并行与顺序两条路径都注入新变量，P1 套件由此获得真正的
  逐套件隔离；新增 `test_runtime_dir_contract.sh`（10 个用例）覆盖默认值、注入生效、
  空值回退、相对路径边界、目录不存在时的创建、创建失败关闭、与 `USER_MANAGER_DATA_BASE`
  的互不干扰、重复 source 稳定性。

**关于原文中「`USER_MANAGER_DATA_BASE` 与库读取的 `DATA_DIR` 是两套不互通的变量名」这一表述，
需要修正**：库确实读取了 `USER_MANAGER_DATA_BASE`（`lib/config.sh:57`，`DATA_BASE="${USER_MANAGER_DATA_BASE:-/mnt}"`），
但它是**用户家目录挂载点的父目录**（`/mnt/data01`…`/mnt/data07`，见 `lib/quota_core.sh:16,67,82,245,296`、
`lib/controller_user_provisioning_support.sh:17,67`、`lib/report_core.sh:271,1489`、`lib/symlink_core.sh:129`），
与运行时数据目录是两个正交概念。让 `DATA_DIR` 回退到它会在生产上把
`DISABLED_USERS_FILE` 变成 `/mnt/disabled_users.txt`，与家目录挂载点同级。
因此本轮的做法是**新增专用变量**而非复用，并对该不相关用例做了回归护栏。

设计与兼容分析见 `docs/superpowers/specs/2026-10-02-runtime-dir-injection-design.md`。

### P1-4　工作树卫生

- 存在 15 个 `*.bak` 备份文件（含 `README.md.bak`、`tui_manager.sh.bak`、`lib/tui_core.sh.bak` 等）。`.gitignore:36` 已忽略 `*.bak`，均未跟踪，但持续干扰检索。
- `data/` 含运行时产物（`created_users.txt`、`logs/`、`report/`、`secrets/`），已正确排除在版本控制外。

---

### P1-5　`umweb` 无代码层的 root 拒绝启动 —— **接受风险，本轮不修**

**事实**（已逐行复核）：`web/backend/src/main.rs` 去掉文档注释后只有 4 行代码，函数体只有
`umweb::run().await` 一句；全仓 `geteuid` 仅 2 处，都在 `crypto.rs:83/124` 的 master.key
属主比对里。**整个 Rust 侧没有任何 uid 检查**，手工 `sudo ./umweb` 会以 root 全量运行。

**为什么不改**（裁决结论）：

1. 它**不违反**黄金标准「Web 永不获得 root」——生产路径由 `etc/systemd/system/umweb.service:23`
   的 `User=umweb` 强制，Web 不会自己获得 root。实际暴露的是「绕过 systemd 手工启动时提权」。
2. 加 `geteuid() == 0` 拒绝启动有**真实副作用**：CI、开发机 `sudo cargo run`、容器内以 root 跑测试
   都会直接起不来。
3. 审计报告未评估这层副作用，而**本环境无 cargo，无法验证改动的编译结果**。在无法编译验证的前提下
   改 Rust 生产入口，是拿「看起来更安全」换「可能构建失败」。

**建议路径**：目标主机部署验收时用 `systemd-analyze security umweb` + 实机 `id umweb` 先行确认；
若确需代码层兜底，改为**可配置开关**（`UMWEB_ALLOW_ROOT_FOR_DEV=1` 仅开发用）而不是硬拒绝，
并在具备 Rust 工具链的环境里编译 + 跑测试后再合入。

---

## 6. 发布边界与待办

### 6.1 已达成

- 架构与安全边界完整，静态门禁全绿；
- 双控制面 + 只读快照层实现齐备，静态检查无越权痕迹；
- 29 个 Action 与 18 个独立 CLI 入口的功能面在 P1 回归中通过；P1 43 个套件全绿。

### 6.2 阻塞发布

1. ~~**提交工作树**：落地 97 项改动并拆分提交。~~ **已完成**；剩余动作是**推送到 origin 并打 `v0.3.0` tag**。
2. ~~**修复 P0-1**：恢复入口可执行位。~~ **已完成**（`abc6946` + 根目录 5 个入口），CI 权限检查已阻断化（`a4762a5`）。
3. ~~**修正 P0-2**：事件 spool 的 owner/group 校验。~~ **已完成（`87a74da`）**。
4. ~~**修正 P0-3**：`CHANGELOG.md` 的版本状态表述。~~ **已完成（`2563059`）**。
5. **重新执行完整验证**：本机 P1 已 43/43 全绿，前端生产构建已于 2026-10-05 在本环境验证通过（§4.3）；仍缺 Rust 门禁。推送后由 CI 取得可发布证据。
6. ~~**提交本轮未提交改动**：运行时目录注入契约、SMB 共享入参校验、两个失效门禁、独立审计与消融实验产物。~~ **已完成**（`850a807`、`9fe6296`、`807114a`、`cdabb37`、`8d99219`）。**本条为 2026-10-03 订正**：原文写「全部只在工作树」时属实，提交后即失效；现与文首「工作树干净」一致。**推送仍由维护者决定，本文不代为执行。**

**已解除的阻塞**：P0-1/P0-2/P0-3、门禁覆盖缺口、CI 权限门禁、SMB 共享入参校验、Web 安全门禁空转。剩余阻塞集中在环境相关的
验收项（目标主机、真实 webhook、无障碍审计、Rust/前端工具链），见 6.3。

### 6.3 部署前必须完成（既有文档已记录，本次未验证）

1. 在目标 Ubuntu 主机验证 `umweb` 的组成员、sudoers、capability、`systemd` 属性、数据库与密钥属主权限、只读快照权限，以及 `um-snapshot.timer` 运行状态；
2. 真实企业微信 webhook 投递验收；
3. 完整 WCAG / 读屏器审计。

---

## 7. 文档地图

| 文档 | 内容 | 时效 |
| --- | --- | --- |
| [`STATUS.md`](STATUS.md) | 本文：现状、已核实结果、已知缺陷 | 2026-10-03 |
| [`PROGRESS.md`](PROGRESS.md) | 阶段/功能完成度矩阵与未完成项清单 | 2026-10-03 |
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
| [`audit/2026-10-02/README.md`](audit/2026-10-02/README.md) | 独立审计：硬约束 / 404-405 契约 / 文档偏差 / CI 门禁 / 安全性（P0=0、P1=1、P2=12、P3=19） | 2026-10-02 |
| [`ablation/2026-10-02/README.md`](ablation/2026-10-02/README.md) | 消融实验：12 个守卫场景的 GUARD-ACTIVE / INERT 判定与证据 | 2026-10-02 |

> `docs/superpowers/` 被 `.gitignore:56` 整目录忽略，因此运行时目录注入契约的设计文档
> （`superpowers/specs/2026-10-02-runtime-dir-injection-design.md`）**不会自动入库**。
> 该文件已于 `850a807` 用 `git add -f` 显式纳入，链接在 GitHub 上可用；
> 但**同目录下其余 8 份历史设计文档仍不在版本控制内**。

### 相关但已过时的过程文档

`task_plan.md`、`progress.md`、`findings.md`、`.ai-memory/project_memory.md` 记录 2026-05 至 08 的开发过程，**不反映当前状态**，仅作历史参考。
