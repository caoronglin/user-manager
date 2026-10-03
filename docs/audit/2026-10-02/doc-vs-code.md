# 第三部分：文档与实现的偏差

每一行格式：**文档断言** / **实际情况** / **证据 file:line** / **建议改法**（本次审计不修改任何文档）。

严重级只反映「会误导决策的程度」，不反映安全风险。文档措辞问题一律 ≤P3。

---

## A. 任务点名的四类重点抽查

### A-1 「P0–P7 八个阶段功能代码均已落地，没有半成品模块或未实现的桩」

| 项 | 内容 |
| --- | --- |
| 文档断言 | `docs/PROGRESS.md:16`「代码完成度 | 8 个阶段的**功能代码均已落地**，没有半成品模块或未实现的桩」；`:77`「**没有发现半成品模块、未实现的桩函数或 TODO 占位。**」；`docs/STATUS.md:18`「三部分代码齐备」 |
| 实际情况 | **Rust 侧断言成立，集成侧断言夸大。** ① Rust：`todo!`/`unimplemented!`/`TODO`/`FIXME`/`#[allow(dead_code)]` 全树零命中（`grep -rnE 'todo!\|unimplemented!\|TODO\|FIXME\|XXX\|HACK\|dead_code\|allow\(unused' web/backend/src/` → 无输出）。唯一死函数是 `middleware.rs:136 default_timeout`（3 行、注释自述「P1 仅示范」）。② 集成：**后端 40 条注册路由中有 20 条没有任何前端调用方**（详见 A-1 附表），其中包括 P4 被 PROGRESS.md 亲自列为「代码证据」的 `notifications_api.rs`（4 条）与 `tokens_api.rs`（2 条）。即「通知闭环」与「API Token 管理」在后端存在、经过测试，但**在随包发布的前端里不可达**。 |
| 证据 | 死代码：`web/backend/src/middleware.rs:136-138`。前端不可达端点：`web/frontend/src/*.jsx` 中 `/api/` 字面量共 20 个，`web/backend/src` 注册 40 个。P4 证据声称：`docs/PROGRESS.md:33`（notifications_api.rs / tokens_api.rs 列为 P4 代码证据）、`:57`（「API Token（仅存 SHA-256 hash）」列为「已实现」）。 |
| 严重级 | **P2**（实质性夸大：读者会认为可以在控制台里管理 API Token、查看通知 inbox，实际不能） |
| 建议改法 | 把 PROGRESS.md:16 改为「8 个阶段的**后端**功能代码均已落地；其中通知与 API Token 管理目前**无前端入口**，仅后端 API 可用」；在 §2 的 P4 行「剩余工作」列补一条「补齐 notifications / api-tokens 的前端页面」。

#### A-1 附表：后端已注册但前端从不调用的 20 条路由

| 路由 | 方法 | 所属模块 | PROGRESS.md 是否将其列为某阶段的「代码证据」 |
| --- | --- | --- | --- |
| `/api/notifications` | GET | notifications_api.rs:153 | 是（P4，:33） |
| `/api/notifications/unread-count` | GET | notifications_api.rs:154 | 是（P4，:33） |
| `/api/notifications/read` | POST | notifications_api.rs:159 | 是（P4，:33） |
| `/api/notifications/read-all` | POST | notifications_api.rs:160 | 是（P4，:33） |
| `/api/api-tokens` | GET/POST | tokens_api.rs:160 | 是（P4，:33；:57「API Token 已实现」） |
| `/api/api-tokens/:id` | DELETE | tokens_api.rs:161 | 是（同上） |
| `/api/web-users` | GET/POST | admin_api.rs:261 | 否 |
| `/api/web-users/:id` | PATCH/DELETE | admin_api.rs:262-265 | 否 |
| `/api/sessions` | GET | routes.rs:329 | 否 |
| `/api/sessions/:id` | DELETE | routes.rs:318 | 否 |
| `/api/auth/mfa/setup` | POST | admin_api.rs:253 | 否 |
| `/api/auth/mfa/verify` | POST | admin_api.rs:254 | 否 |
| `/api/auth/mfa/disable` | POST | admin_api.rs:256 | 否 |
| `/api/users/:username` | GET | read_api.rs:207 | 否 |
| `/api/users/:username/resources` | GET | read_api.rs:209 | 否 |
| `/api/smb/users` | GET | read_api.rs:212 | 否 |
| `/api/smb/users/:username` | GET | read_api.rs:213 | 否 |
| `/api/smb/shares` | GET | read_api.rs:214 | 否 |
| `/api/hosts/:id` | GET | read_api.rs:216 | 否 |
| `/api/health` | GET | routes.rs:327 | 否 |

推论：`/api/auth/mfa/setup|verify|disable` 不可达意味着**管理员无法在控制台内启用或关闭 TOTP**，只能经 CLI/直连 API。前端只消费了 `mfa/challenge`（`App.jsx:147`）。这与 PROGRESS.md:15「P4 代码完成」存在实质差距。

---

### A-2 「前端调用 15 个 API 端点，均有后端路由对应实现（另有 1 处 /api/users/:username 为模板字符串）」

| 项 | 内容 |
| --- | --- |
| 实际情况 | **子断言「均有后端路由对应实现」完全成立；计数与模板路径描述不准。** 前端实际可达端点为 **20 个**，不是 15+1=16。「15」恰好等于前端源码中**单引号字面量**的路径数，遗漏了 4 个以反引号模板/JSX 属性形式出现的端点：`/api/logs`、`/api/logs/download`、`/api/reports/export`、`/api/audit/export`。另「`/api/users/:username` 为模板字符串」不准确——实际模板是 `/api/users/${encodeURIComponent(username)}/quota`（即 `/api/users/:username/quota`），不是 `/api/users/:username`；后者在前端**根本没有调用方**（见 A-1 附表）。 |
| 证据 | 前端 20 个端点：`App.jsx:83,128,147,160`；`pages.jsx:52-56,128,159,177,199,231,232,254,309,313,353,356,376,383,431,432,481,504`。15 个单引号字面量：`/api/audit?limit=6`、`/api/auth/login`、`/api/auth/logout`、`/api/auth/me`、`/api/auth/mfa/challenge`、`/api/hosts`、`/api/hosts/local/gpu`、`/api/reports`、`/api/resources/summary`、`/api/settings/wecom`、`/api/settings/wecom/deliveries?limit=50`、`/api/settings/wecom/test`、`/api/smb/status`、`/api/system-summary`、`/api/users`。后端 40 条注册路由全量枚举见 `hard-constraints.md` §0.7-a 与 `ci-gates.md`。 |
| 严重级 | **P3**（计数错误；但「均有实现」这一实质结论正确） |
| 建议改法 | 改为「前端调用 20 个 API 端点，均有后端路由对应实现；其中 1 处 `/api/users/:username/quota` 为模板字符串」。

---

### A-3 「29 个 action（safe 18 / dangerous 11）」的分类与实际危险度

| 项 | 内容 |
| --- | --- |
| 实际情况 | **计数与分类完全正确。** 脚本实测（awk 解析 `lib/action_registry.sh` 的 `action_register` 调用）：total 29、safe 18、dangerous 11、modes both 14 / cli 15。逐条复核 11 个 dangerous：`users.create`、`users.quota`、`users.resource`、`backup.run`、`smb.password`、`smb.disable`、`smb.enable`、`smb.remove`、`smb.share.add`、`smb.share.remove`、`smb.include` —— **全部为真实系统变更，无误标**。18 个 safe 中 15 个为纯只读（日志/systemd 列表/审计/SMB 状态/用户列表/host.probe/gpu.summary），1 个为边界项见下。 |
| 证据 | `lib/action_registry.sh:365-393`（29 行注册）。危险度复核：`smb.include`（:393）为「主配置 include 托管配置（status\|ensure）」—— `ensure` 会写 `/etc/samba/smb.conf`，标 dangerous 正确。 |
| 严重级 | **P3**（唯一可讨论项，非错误） |
| 建议改法 | `mail.test`（`lib/action_registry.sh:379`，handler `rl_action_mail_test_cli`，modes=cli，risk=**safe**）会产生真实外部副作用（经 SMTP 发信）。plan.md 0.3 已声明 risk 只是业务标签、不等于 Web-safe，且 `mail.test` **不在** Web capability 集合内，故不构成安全问题。但为免读者误解，建议在 STATUS.md:128 / PROGRESS.md:62 补一句：「`mail.test` 虽标 `safe`，但会发出真实邮件；它不在 Web 能力域内。」 |

---

### A-4 「Shell 回归 43 passed」的口径复核

| 项 | 内容 |
| --- | --- |
| 实际情况 | **完全属实，且 STATUS.md 自己的口径说明是准确的。** 本次实测 `bash tests/run_regression.sh --level all` → `Passed: 43 / Failed: 0 / Skipped: 1`，退出码 0。43 = P0 的 1 个（`verify_fixes`）+ P1 的 42 个（`P1_SCRIPTS` 数组行 16-57，共 42 项）。STATUS.md:151-155 的「计数口径」说明正确。 |
| 证据 | `tests/run_regression.sh:15-58`（P1_SCRIPTS = 42 项）、`:481-485`（`FAIL_COUNT>0 → exit 1`，门禁真实阻断）。 |
| 严重级 | 无（**正面确认**） |
| 建议改法 | 无需修改。

---

## B. STATUS.md / PROGRESS.md 的自相矛盾（同一文档内打架）

| # | 文档断言 | 实际情况 | 证据 | 严重级 | 建议改法 |
| --- | --- | --- | --- | --- | --- |
| B-1 | STATUS.md:19「`main` 领先 `origin/main` **13 个提交**」 vs STATUS.md:36「领先 `origin/main` **7 个提交**」、:43「本地 7 个提交尚未到达」 | 文档内部两个数字互斥；**实测 `git rev-list --count origin/main..main` = 14**，两个数字都不对 | `git rev-list --count origin/main..main` → 14；`origin/main` = 3855ec8（与 :37 记载一致） | P3 | 统一为 14，并只保留一处数字。 |
| B-2 | STATUS.md:127「P1 回归套件（`P1_SCRIPTS`）| **40**」 vs STATUS.md:21「P1 **42** 套件全绿」、:148「P1 套件由 40 增至 **42**」 | 同一文档 §3.2 规模表未随 §4.1 的修复同步；实测 P1_SCRIPTS = **42** | `tests/run_regression.sh:16-57` 逐行计数 = 42 | P3 | 把 §3.2 的 40 改为 42。 |
| B-3 | PROGRESS.md:51-52「邮件通知 / 企业微信 已实现，**无门禁覆盖**；`tests/test_rl_mail.sh` / `test_rl_wecom.sh` **不在 `P1_SCRIPTS`**」 vs PROGRESS.md:115「**已完成、不再占用待办**：邮件/企微门禁覆盖」 | 同一文档 §3 与 §5 直接矛盾。`a4762a5` 已把两个套件纳入 P1_SCRIPTS | `tests/run_regression.sh:37`（test_rl_mail.sh）、`:39`（test_rl_wecom.sh）均在数组内；STATUS.md:275-280 亦记载该修复 | P3 | §3 的两行删去「无门禁覆盖」限定语，改为「已纳入 P1 门禁」。 |
| B-4 | PROGRESS.md:36 P7 阶段「剩余工作」列含「**CI 权限检查升级为阻断**」 vs PROGRESS.md:115「CI 权限阻断…已完成」与 STATUS.md:225-228 | P7 剩余工作列是过期项；`a4762a5` 已完成 | `.github/workflows/ci.yml:161-205`（阻断式实现）；本次复现 `checked=23 missing=0` 且负向对照可捕获 | P3 | 从 P7「剩余工作」列删除该条。 |
| B-5 | STATUS.md:220「CI 的「Check file permissions」**目前只输出 Warning，不阻断**，因此该问题会长期潜伏」 vs STATUS.md:225-226「已由 Warning 收紧为阻断式」 | P0-1 小节内部对同一门禁给出相反的现状描述 | `.github/workflows/ci.yml:190-204`（`exit 1`）；`git log a4762a5 --stat` | P3 | 把 :220 的现状句改为「**曾**只输出 Warning，已在 `a4762a5` 收紧为阻断」。 |
| B-6 | PROGRESS.md:3「核实基线：`main` @ **`1317c44`**」 | HEAD = `62f00fc`，**领先 2 个提交**（`1317c44 → 91706e1 → 62f00fc`）。而 `62f00fc` 本身就修改了 PROGRESS.md 与 STATUS.md，却没更新自己的核实基线 | `git log --oneline 1317c44..HEAD` | P3 | 改为 `@ 62f00fc`。 |
| B-7 | STATUS.md:4「核实基线：`main` @ **`91706e1`**」 | HEAD = `62f00fc`（领先 1 个提交，该提交只改文档，故代码类结论仍成立） | `git show --stat 62f00fc` → 仅 docs/PROGRESS.md、docs/STATUS.md | P3 | 改为 `@ 62f00fc`，或注明「`62f00fc` 仅改本文档」。 |
| B-8 | PROGRESS.md:95 与 :130「`docs/ARCHITECTURE.md` **未覆盖 Web 子系统** / 停留在 2026-08-31」 vs STATUS.md:345 同样记载「2026-08-31，缺 Web」，而 `91706e1` 的提交信息是「修正技术栈表述并**补全 Web 架构**」 | ARCHITECTURE.md 实际 42206 字节、mtime 2026-10-02，已包含 Web 章节（:525 起有 `web/backend/...` 表格行）。STATUS.md:346 也已把 DEEPWIKI 标为「2026-10-02 已刷新」但 ARCHITECTURE 仍标 08-31 | `wc -c docs/ARCHITECTURE.md` = 42206；`grep -n 'web/backend' docs/ARCHITECTURE.md` 命中 | P3 | PROGRESS.md:95/:130、STATUS.md:345 三处时效标注更新为 2026-10-02。 |

---

## C. 数量与口径的系统性偏差

| # | 文档断言 | 实际情况 | 证据 | 严重级 | 建议改法 |
| --- | --- | --- | --- | --- | --- |
| C-1 | PROGRESS.md:31「`store/snapshot.rs` 的 `SNAPSHOT_KINDS` **8 类白名单**」、:58「**8 类**快照 + audit/logs/reports」 | 实际 **11 类**（users/quota/resources/smb/hosts/gpu/system/audit-summary/logs/reports/manifest）。同一份文档对同一个集合给出了两个数 | `web/backend/src/store/snapshot.rs:16-28` | P3 | 统一为 11。 |
| C-2 | `docs/WEB_SECURITY_BOUNDARY.md:104-114` §3.2 快照盘点表列 **9 行**（users/quota/resources/smb/hosts/gpu/system/audit-summary/manifest） | 与代码的 11 类不一致：**表中缺 `logs` 与 `reports`** 两类，而这两类都有独立 capability（`logs.read` / `reports.read`）与独立 handler（`logs_api.rs`、`reports_api.rs`） | `web/backend/src/store/snapshot.rs:16-28`；`auth/rbac.rs:37-38`；`snapshot.rs:265-266`（thresholds logs=60 / reports=300） | P2 | §3.2 表补两行，并标注 `logs`=60s、`reports`=300s，与 `snapshot_kind_threshold`（`lib/snapshot_core.sh:36-37`）对齐。**注：Shell 侧 `snapshot_kind_threshold`（11 项）与 Rust 侧 `default_threshold`（11 项）逐值一致，这是本项目的强项**；只有文档表落后。 |
| C-3 | STATUS.md:22-23「静态门禁…全部通过」 | 属实，本次完整复现 4 项静态门禁全部通过 | 见 `README.md` §3 | — | 无需修改。 |
| C-4 | STATUS.md:128「Action Registry 条目 29（safe 18 / dangerous 11；both 14 / cli 15）」 | **完全正确** | awk 实测 total 29 / safe 18 / dangerous 11 / both 14 / cli 15 | — | 无需修改。 |
| C-5 | STATUS.md:183「CI `security` job（读 Git 索引 mode）：`checked=23, missing=0`」 | **完全正确**（本次逐行复现） | 复刻 `ci.yml:176-205` 判据 → `checked=23 missing=0` | — | 无需修改。 |
| C-6 | PROGRESS.md:34「`web/frontend` 6 个源文件 **1628 行**」 | **完全正确** | `wc -l web/frontend/src/*` = 1628（api.js 109 + App.jsx 310 + main.jsx 11 + pages.jsx 619 + styles.css 295 + ui.jsx 284） | — | 无需修改。 |
| C-7 | PROGRESS.md:31「`http/read_api.rs` **13 条**路由」 | **完全正确** | `read_api.rs:206-218` 共 13 条 `.route()` | — | 无需修改。 |
| C-8 | PROGRESS.md:44「`user_manager.sh` 仅 **89 行**编排」 | **完全正确** | `wc -l user_manager.sh` = 89 | — | 无需修改。 |
| C-9 | STATUS.md:124-127「`lib/*.sh` 67 / `scripts/*.sh` 18 / `tests/*.sh` 44 / Web 后端 Rust 源文件 48 / 前端源文件 6」 | 全部**正确** | 逐项 `ls`/`find` 计数一致 | — | 无需修改。 |
| C-10 | PROGRESS.md:29「`tests/test_snapshot.sh` **25 例**」、:35「`tests/test_snapshot_ops.sh` **7 例**」 | 本次回归两套件均全绿，例数未逐条计数（见 §5 方法说明） | `tests/run_regression.sh` 输出 `[PASS] test_snapshot.sh` / `[PASS] test_snapshot_ops.sh` | — | 未逐条计数，不作判定。 |

---

## D. 技术栈漂移的同类问题（plan.md 标题之外还有没有）

任务点名的漂移已知（plan.md 标题写 Ant Design Pro 6.0 / Umi / ProComponents，实际 React + Vite + Ant Design 6；STATUS.md:118 与 PROGRESS.md:72 已记录）。本次做了**系统性排查**：对 9 份文档提取全部反引号包裹的文件路径（`*.sh/*.rs/*.md/*.js/*.jsx/*.json/*.toml/*.conf/*.service/*.timer/*.css`），按 12 个已知前缀逐一解析，剩余无法解析者逐个人工判读。

| # | 文档引用 | 实际情况 | 严重级 | 建议改法 |
| --- | --- | --- | --- | --- |
| D-1 | `docs/ARCHITECTURE.md:525` 表格行「`web/backend/src/store/web_audit.rs` \| Web 侧操作审计」 | **文件不存在**。后端确有 `web_audit` **数据表**（`wecom_api.rs:234` INSERT INTO web_audit），但**没有** `web_audit.rs` 模块——审计写入逻辑散落在各 handler 内联 | P3 | 该行改为 `web/backend/src/http/*_api.rs（各 handler 内联写入 web_audit 表）`，或补建 `store/web_audit.rs` 模块。 |
| D-2 | `docs/DEEPWIKI.md:339` 引用 `lib/ui_menu_fixed.sh` | **文件不存在**（`lib/` 下 67 个 `.sh` 中无此名） | P3 | 删除该行或替换为现存模块。 |
| D-3 | `docs/DEEPWIKI.md:345` 引用 `lib/ui_optimized.sh` | **文件不存在** | P3 | 同上。 |
| D-4 | `docs/DEEPWIKI.md:346` 引用 `optimization_summary.sh` | **文件不存在**（仓库根目录亦无） | P3 | 同上。 |
| D-5 | PROGRESS.md:30 引用 `tests/api_contract.rs` | 文件存在，但实际路径是 `web/backend/tests/api_contract.rs`；同句并列的 `web/backend/src/http/routes.rs` 用了完整路径，此处省略导致指向不明 | P3 | 改为 `web/backend/tests/api_contract.rs`。 |
| D-6 | STATUS.md:182 引用 `check_web_security.sh`（裸名）、:184 引用 `run_regression.sh`（裸名）、:172 引用 `user_core.sh`（裸名）等 | 均为「表格内简写」，按 `scripts/`、`tests/`、`lib/` 前缀解析后全部存在，**非漂移** | — | 无需修改。 |
| D-7 | `docs/REMOTE_HOSTS.md:10` 引用 `/opt/user-manager/scripts/rl-remote-entry.sh` | 是**部署路径**（目标机），仓库对应文件为 `scripts/rl-remote-entry.sh`，**非漂移** | — | 无需修改。 |
| D-8 | `docs/WEB_SECURITY_BOUNDARY.md:106-114` 的 `users.json` 等 9 个 `.json` | 是**运行时快照文件名**（`/var/lib/user-manager-web/snapshots/`），非仓库文件，**非漂移** | — | 无需修改。 |
| D-9 | `docs/REMOTE_HOSTS.md:20` 引用 `data/hosts.conf` | 本机运行时文件，`.gitignore:82` 已正确忽略（不存在属正常），**非漂移** | — | 无需修改。 |

**D 小结**：除已知的 plan.md 标题漂移外，**同类漂移确实还有 5 处**（D-1 ~ D-4 悬空文件引用 + D-5 路径不完整），全部为 P3。**未发现「版本号漂移」**——`v0.1.0`/`v0.2.0`/无 `v0.3.0` 的记载与 `git tag` 现状一致。

---

## E. 15 个未跟踪的 `*.bak` 是否掩盖「功能已删但文档仍引用」

| 项 | 内容 |
| --- | --- |
| 实际情况 | **未发现功能被删。** 15 个 `.bak`（`docs/ARCHITECTURE.md.bak`、`docs/DEEPWIKI.md.bak`、`.gitignore.bak`、`lib/action_registry.sh.bak`、`lib/bootstrap.sh.bak`、`lib/gpu_core.sh.bak`、`lib/tui_core.sh.bak`、`README.md.bak`、`run.sh.bak`、`tests/run_regression.sh.bak`、`tests/test_gpu_core.sh.bak`、`tests/test_scripts.sh.bak`、`tests/test_tui_core.sh.bak`、`tests/test_tui_mainline.sh.bak`、`tui_manager.sh.bak`）逐个与现网文件 `diff`：**全部为「现网净增」**。删除量最大的 `lib/tui_core.sh`（-32 行）经人工判读为终端检测代码（`[[ -t 1 ]]`/`stty -g`/`tput cnorm`）的内联重构，**非功能删除**。另 4 个 `.bak` 位于 `.validation/ablation-2026-10-02/`，属并发工作流（W-A）产物，不在 `62f00fc` 基线内。 |
| 证据 | 逐文件 diff 增删统计见 `findings.md` §5.4；`.gitignore:36` 已忽略 `*.bak`。 |
| 严重级 | P3（长期检索噪声；STATUS.md:305 与 PROGRESS.md:93/:97 已自认） |
| 建议改法 | 已有的「删除 15 个 `.bak`」建议成立。补一条门禁建议：把 `*.bak` 加入 `scripts/check_sensitive_files.sh` 的扫描范围（当前它只扫 `git ls-files` 跟踪文件，`.bak` 结构上不可见，见 `ci-gates.md` G-9）。

---

## F. 本节判定方法说明（避免「看起来没问题」）

- 「未发现」的表述均已写明检索方式；本报告未在任何位置把「我没找到问题」写成「没有问题」。
- C-10（test_snapshot.sh 25 例 / test_snapshot_ops.sh 7 例）**未逐条计数**，只确认套件通过，故明确标注「不作判定」而非默认判为满足。
- U12（plan.md 自身 2802 行的逐条引用核对）**未做全量枚举**，只对 9 份文档做了反引号路径解析；这一限制已写入 `README.md` §4。
- 本节所有计数均来自本次实测命令输出，未引用任何文档数字。
