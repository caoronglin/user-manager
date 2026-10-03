# 完成进度与未完成项

> 核实基线：`main` @ `62f00fc`　核实时间：2026-10-03
>
> 本文回答的是**「做完了多少、还剩什么」**。当前工作树状态、实测回归数字与已知缺陷见
> [`STATUS.md`](STATUS.md)，本文不重复。
> 本文所有「已完成」判定均以**可在仓库中指认的代码**为依据；未经本次复验的结论一律标注。

---

## 1. 摘要

| 维度 | 结论 |
| --- | --- |
| 阶段完成度 | P0/P1/P2/P3/P6 共 5 个阶段**代码层面完成**；P4/P5/P7 **代码完成、验收未完成**；P5 另有一处与原规划的技术栈偏离 |
| 代码完成度 | 8 个阶段的**后端功能代码均已落地**，没有半成品模块或未实现的桩；**但前端只消费了后端 40 条注册路由中的 20 条**，其中被本文列为 P4「代码证据」的 `notifications_api.rs`（4 条）与 `tokens_api.rs`（2 条）在控制台里**无入口**——见 §2 的 P4 行与 §3 |
| 未完成的重心 | **主要在验收** —— 目标主机部署、真实 webhook 投递、无障碍审计三项全部未做；另有一处**代码级缺口**：notifications / api-tokens / MFA 管理无前端入口（见 §4 A） |
| 门禁覆盖 | Shell 侧 P1 **43 套件全绿**（本轮补入运行时目录契约 1 个）；Rust 与前端门禁本轮环境缺失、未能复验 |

**核心判断：项目已进入「功能完成、等待验收与发布」阶段。** 剩余工作的性质从「开发」转为「验证」，
这通常意味着风险从「代码不正确」转移到「部署形态未经验证」。

---

## 2. 阶段完成度矩阵（P0–P7）

| 阶段 | 状态 | 代码证据 | 剩余工作 |
| --- | --- | --- | --- |
| **P0** 安全边界与 Snapshot 契约 | 已完成 | `lib/snapshot_core.sh`（失败关闭写、符号链接拒绝、size 限制、freshness 三态）；`scripts/rl-snapshot.sh`（`--out` / `--dry-run` / `--manifest-only`）；`docs/WEB_SECURITY_BOUNDARY.md`；`tests/test_snapshot.sh` 25 例 | 目标机上的属主/组/mode 实机确认 |
| **P1** Rust 非特权骨架 | 已完成 | `web/backend/src/http/routes.rs`（`/api/health`、`/api/auth/login|logout|me`）；`auth/` 下 password(Argon2id)/session/csrf/rate_limit/rbac/guard/mfa；`config.rs` 能力默认拒绝；`web/backend/tests/api_contract.rs` 危险路由 404/405 契约（本文旧版写 `tests/api_contract.rs`，实际路径在 `web/backend/` 下） | 无 |
| **P2** 只读系统 API | 已完成 | `http/read_api.rs` 13 条路由；`store/snapshot.rs` 的 `SNAPSHOT_KINDS` **11 类**白名单（users/quota/resources/smb/hosts/gpu/system/audit-summary/logs/reports/manifest；本文旧版写 8 类，与代码不符）。quota 经 `/api/users/:username/quota` 暴露、gpu 经 `/api/hosts/:id/gpu` 暴露（嵌套而非顶级路径） | 目标机快照数据可用性实机确认 |
| **P3** Logs / Audit / Reports | 已完成 | `http/audit_api.rs`（`/api/audit`、`/api/audit/export`）；`http/logs_api.rs`（`/api/logs`、`/api/logs/download`）；`http/reports_api.rs`（`/api/reports`、`/api/reports/export`） | 无 |
| **P4** Web 身份与通知闭环 | 代码完成，验收未完成，**前端未接线** | `http/wecom_api.rs` + `store/wecom.rs`（加密设置/固定模板/有界历史）；`event_spool.rs` + `store/event_spool.rs`（openat/O_NOFOLLOW 只读消费）；`store/snapshot_observer.rs`（fresh/stale 转换）；`web_event_delivery.rs`（独立 outbox/worker）；`http/notifications_api.rs`；`http/tokens_api.rs` | **补齐 notifications（4 条）与 api-tokens（2 条）的前端页面**——这两组目前只有后端 API，控制台里既看不到通知 inbox，也管不了 API Token；此外真实 webhook 投递验收、原生 HTTP 重试分支无 mock-server 测试、多实例共享 SQLite 无跨进程 outbox lease |
| **P5** 前端 | 代码完成，验收未完成 | `web/frontend` 6 个源文件 1628 行；React 19 + Vite 8 + Ant Design 6；前端调用 **20 个** API 端点（19 个静态路径 + 1 处模板字符串 `/api/users/:username/quota`），均有后端路由对应实现。**本文旧版写「15 个端点 + 1 处 `/api/users/:username`」，两项都不准**：15 是前端源码中单引号字面量的数目，漏掉了以 JSX 属性/反引号出现的 `logs`、`logs/download`、`reports/export`、`audit/export` 4 个；模板路径实为 `/api/users/:username/quota`，而 `/api/users/:username` 在前端**无调用方** | 完整 WCAG / 读屏器审计；**未采用 plan.md 规划的 Umi / ProComponents** |
| **P6** Ubuntu Ops 观测 | 已完成 | `lib/snapshot_ops.sh`：filesystem / systemd / apt / apparmor / cpu / psi 六个采集分节，每节独立报告可用性；`tests/test_snapshot_ops.sh` 7 例 | 目标环境工具可用性实机确认 |
| **P7** 加固与发布 | 代码完成，发布未完成 | CI 7 个 job（shellcheck / rust-backend / web-frontend / test / validate-docs / security / format）；`etc/systemd/system/umweb.service`（UMask、InaccessiblePaths、ReadOnlyPaths）；`etc/tmpfiles.d/user-manager-web.conf`；`tests/test_web_deploy_boundary.sh` | 推送 origin + 打 `v0.3.0` tag；目标机部署验收（CI 权限检查升级为阻断已在 `a4762a5` 完成） |

---

## 3. 功能域完成度

| 功能域 | 状态 | 依据 |
| --- | --- | --- |
| 用户生命周期 | 已实现 | `lib/user_core.sh`；`user_manager.sh` 仅 89 行编排，业务已下沉 |
| 磁盘配额 | 已实现 | `lib/quota_core.sh`；`scripts/rl-user-quota.sh`；快照 kind `quota` |
| 资源限制 | 已实现 | `lib/resource_core.sh`；`scripts/rl-user-resource.sh`；快照 kind `resources` |
| 备份与恢复 | 已实现 | `lib/backup_core.sh`、`backup_verify.sh`、`backup_excludes.sh` |
| 防火墙 / DNS | 已实现 | `lib/firewall_core.sh`、`lib/dns_core.sh`、`lib/network_stack_core.sh` |
| 安全基线 | 已实现 | `lib/security_baseline_core.sh` |
| 审计与日志 | 已实现 | `lib/audit_core.sh`、`logs_core.sh`、`logs_presenter.sh`、`journalctl_core.sh` |
| 邮件通知 | 已实现，**已纳入门禁**（`a4762a5`） | `lib/rl_mail_*.sh`；`tests/test_rl_mail.sh` 已在 `P1_SCRIPTS` 内 |
| 企业微信 | 已实现，**已纳入门禁**（`a4762a5`） | `lib/rl_wecom_bot_sender.sh`；`tests/test_rl_wecom.sh` 已在 `P1_SCRIPTS` 内 |
| SMB 管理 | 已实现 | `lib/smb_core.sh`；`scripts/rl-smb-manage.sh`；快照 kind `smb` |
| 跨主机只读探测 | 已实现 | `lib/host_inventory.sh`、`host_provider.sh`、`execution_plan.sh`、`scripts/rl-hosts.sh`、`rl-remote-entry.sh`。仅 `host.probe` / `gpu.summary` |
| 基础快照采集 | 已实现 | `scripts/rl-snapshot.sh` + `lib/snapshot_core.sh` |
| Ubuntu Ops 采集 | 已实现 | `lib/snapshot_ops.sh` 六个分节 |
| Web 认证与身份 | 已实现 | Argon2id 密码、TOTP MFA 两步挑战、服务端会话、API Token（仅存 SHA-256 hash） |
| Web 只读 API | 已实现 | 11 类快照（已含 `audit-summary`/`logs`/`reports`，**旧版写「8 类 + audit/logs/reports」是重复计数**）+ audit/logs/reports 路由，全部 capability 门控并附 freshness |
| Web 前端 | 已实现 | 登录/MFA、只读信息页、能力过滤、新鲜度提示、主题与中英文切换、键盘可达 |
| systemd 定时与部署 | 已实现 | `etc/systemd/system/um-snapshot.{service,timer}`、`umweb.service`；`etc/tmpfiles.d/`；`etc/sudoers.d/` |

**Action Registry**：29 个 action（`safe` 18 / `dangerous` 11），CLI/TUI 完整接线。

---

## 4. 未完成项清单

### A. 代码层面的未完成

| 项 | 说明 |
| --- | --- |
| **前端未使用规划的 Umi / ProComponents** | `plan.md` 标题与 P5 章节写的是 Ant Design Pro 6.0 + Umi，实际工程是 React 19 + Vite 8 + Ant Design 6。**这是主动的技术栈降级，不是未完成**，但规划文档未同步，构成认知偏差。 |
| **WeCom 原生 HTTP 重试分支无测试** | 重试分类逻辑（网络/超时/429/5xx）没有 mock-server 测试覆盖，无法证明分类正确。 |
| **多实例缺少跨进程 outbox lease** | `web_event_delivery` 假定每个 SQLite 数据库只有一个 `umweb` 实例。若将来多副本部署，事件可能重复投递。 |
| **前端未接入 OpenAPI / SSE / WebSocket / 反代配置** | `plan.md` §4 原列 `REST + OpenAPI`、`SSE 优先，必要时 WebSocket`、`反代理 Nginx / Caddy`，实际均未实现（已在选型表中标注）。当前按需拉取、事件经 outbox 轮询；反代形态由目标主机决定。 |
| **notifications / api-tokens 无前端入口** | 后端 40 条注册路由中前端只调 20 条。`/api/notifications`（4 条）与 `/api/api-tokens`（2 条）只有后端实现与测试，控制台里看不到通知 inbox、也无法签发/吊销 API Token。`/api/auth/mfa/setup\|verify\|disable` 同理不可达，意味着**管理员无法在控制台内启用/关闭 TOTP**。 |

**没有发现半成品模块、未实现的桩函数或 TODO 占位。**

### B. 验收层面的未完成（风险最高）

| 项 | 为什么重要 | 阻塞条件 |
| --- | --- | --- |
| **目标 Ubuntu 主机部署验收** | 仓库中的 `umweb.service`、sudoers、tmpfiles 只是**配置文件**，不能证明目标机上 `umweb` 真的非特权运行。需实测：组成员（不得含 sudo/wheel/admin/docker/lxd）、无任何 sudoers 授权、capability 为空、`NoNewPrivileges`/`UMask`/路径权限生效、DB 与密钥属主、只读快照权限、快照 timer 运行状态 | 需要目标主机访问权限 |
| **真实企业微信 webhook 投递** | 整个通知链路（spool → inbox → outbox → worker → webhook）**从未发送过一条真实消息**。固定模板、签名、频率限制均未在真实端点验证 | 需要真实机器人凭据 |
| **完整 WCAG / 读屏器审计** | 仅做过临时浏览器 mock 验证（键盘导航、窄屏表格、skip-to-main）。真实读屏器（NVDA/VoiceOver）行为未验证 | 需要人工审计或辅助技术环境 |
| **Rust 门禁与前端构建本轮未复验** | 本次核实环境无 `cargo`/`rustc`；npm 缓存位于只读文件系统。65 项后端测试、严格 Clippy、fmt、前端生产构建的记录来自 2026-09-24 | 需要具备工具链的环境或等待 CI |

### C. 工程债

| 项 | 影响 |
| --- | --- |
| **`.bak` 备份文件仍留在工作树** | 已被 `.gitignore` 忽略且未跟踪，但持续干扰检索 |
| **P1 并行执行存在抖动** | 4 路并行下偶发失败（本次观察到 2 例，单跑全绿、重跑不复现）。单次回归结果不足以判定 |
| **`docs/ARCHITECTURE.md` 未覆盖 Web 子系统** | 停留在 2026-08-31，读者据此无法了解 Web 架构 |
| **`plan.md` 标题与实际技术栈不符** | 见 A 节第一项 |
| **15 个 `*.bak` 备份文件** | 已被 `.gitignore` 忽略，但持续干扰检索 |
| **`task_plan.md` / `progress.md` 状态自相矛盾** | 前者标注「✅ 完成 / 最后更新 2026-05-02」却含进行中条目；后者最新条目为 2026-07-21 |

---

## 5. 建议优先级

若只做三件事：

**1. 目标主机部署验收**
风险最高、阻塞最多。前面所有安全约束（`umweb` 非特权、无 sudoers、只读快照）目前都只是**仓库里的声明**，一次真实部署才能证明成立。在此之前发布 v0.3.0 等于把未验证的安全姿态交给使用者。

**2. 推送 origin，取得真实的 Rust 与前端门禁证据**
代码已提交到本地 `main` 但未推送，远端仍停在 `3855ec8`。本机没有 Rust 工具链，npm 缓存又在只读文件系统上，65 项后端测试、严格 Clippy、fmt 与前端生产构建**本轮全部未能复验**。推送后由 CI 取得可发布证据。**但不建议在目标机验收前打正式 tag。**

**已完成、不再占用待办**：邮件/企微门禁覆盖、CI 权限阻断、owner/group 校验缺陷、
事件 spool 日志泄漏、plan.md 与 ARCHITECTURE.md 的技术栈偏差、
`DATA_DIR` / `LOG_DIR` 运行时目录注入（2026-10-02，契约见 `superpowers/specs/2026-10-02-runtime-dir-injection-design.md`）、
SMB 共享名/路径入参校验与 Web 安全门禁空转修复（2026-10-03，见 `STATUS.md` P2-1/P2-2）。

**新增可做项（2026-10-03）**：补齐 notifications / api-tokens / MFA 管理的前端页面（见 §4 A）。
它是**唯一一个在本机可完整验证**（仅需前端工具链）、且能直接消除「后端做完但用户看不到」的待办。

**暂缓**：WCAG/读屏器审计、真实 webhook 投递、OpenAPI/SSE/反代。

---

## 6. 文档索引

| 文档 | 用途 |
| --- | --- |
| [`STATUS.md`](STATUS.md) | 当前工作树状态、实测回归结果、已知缺陷 |
| [`superpowers/specs/2026-10-02-runtime-dir-injection-design.md`](superpowers/specs/2026-10-02-runtime-dir-injection-design.md) | 运行时目录 `DATA_DIR` / `LOG_DIR` 注入契约设计与兼容分析（**注意：`.gitignore:56` 忽略整个 `docs/superpowers/`；本文件已在 `850a807` 中用 `git add -f` 显式入库，同目录其余 8 份历史文档仍未入库**） |
| [`../plan.md`](../plan.md) | Web 化实施规划与不可违反的架构约束 |
| [`M1_REPOSITORY_AUDIT.md`](M1_REPOSITORY_AUDIT.md) | 仓库审计与阶段复核记录 |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | 架构设计与功能说明（**未覆盖 Web**） |
| [`WEB_SECURITY_BOUNDARY.md`](WEB_SECURITY_BOUNDARY.md) | Web 非特权边界与快照契约 |
| [`wecom-native-events.md`](wecom-native-events.md) | WeCom 原生事件投递与隐私边界 |
| [`REMOTE_HOSTS.md`](REMOTE_HOSTS.md) | SSH 主机与 GPU 只读探测边界 |
| [`../CHANGELOG.md`](../CHANGELOG.md) | 版本变更记录 |
| [`../web/README.md`](../web/README.md) | Web 控制台实现进度 |
| [`audit/2026-10-02/README.md`](audit/2026-10-02/README.md) | 独立审计报告（含本文多处数字订正的原始证据） |
| [`ablation/2026-10-02/README.md`](ablation/2026-10-02/README.md) | 守卫消融实验：哪些安全护栏真的在生效 |
