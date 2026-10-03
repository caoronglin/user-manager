# user-manager 独立审计报告（2026-10-02）

- 审计基线：分支 `main`，HEAD = `62f00fc`（启动时工作树干净）
- 审计范围：plan.md 第 0 节 / 附录 A、docs/WEB_SECURITY_BOUNDARY.md、docs/REMOTE_HOSTS.md、web/backend、web/frontend、scripts、tests、.github/workflows/ci.yml
- 审计性质：只读。本次仅新建 `docs/audit/2026-10-02/`，未修改任何生产代码、测试、配置或既有文档，无任何 git 写操作。

## 1. 结论摘要

| 审计维度 | 严重级分布 | 一句话结论 |
| --- | --- | --- |
| 一、硬约束逐条核对 | P0 0 / P1 1 / P2 2 / P3 2 | 黄金标准在代码层**成立**（无提权路径、无特权桥、capability 默认拒绝、远端只读、secret 不进 Web 面），未发现违反项；P1 集中在「`umweb` 不以 root 启动」只由 systemd 单点保证、代码层无拒绝启动的兜底。 |
| 二、危险 API 404/405 契约 | P0 0 / P1 0 / P2 1 / P3 2 | 契约在**当前**路由表下结构性成立（40 条注册路由中无一条危险路由，且鉴权在 handler 层而非全局层，未命中路径不会被提前转成 401/403）；但 `api_contract.rs` 只覆盖 WEB_SECURITY_BOUNDARY §6 列举的 18 项中的 12 项，属门禁覆盖缺口而非现存缺陷。 |
| 三、文档与实现偏差 | P0 0 / P1 0 / P2 3 / P3 6 | 「均有后端路由对应实现」「29 action 分类」「43 passed」「1628 行」等核心断言经复核为真；但 STATUS.md / PROGRESS.md 存在 **3 处自相矛盾**（提交数、套件数、邮件门禁覆盖）与 **3 类系统性夸大**（前端端点数少算 4 个、快照 kind 数三个版本、后端半数 API 前端不可达）。 |
| 四、CI 门禁 | P0 0 / P1 0 / P2 2 / P3 3 | 7 个 job 全部真实阻断（无一使用 `continue-on-error` 或 `|| true` 逃逸）；发现 **2 个失效门禁**（README 章节检查只 Warning、check_web_security.sh 空目录空转通过）与 **1 处死代码**（`rc=$?` 在 GHA 默认 `bash -e` 下不可达）。 |
| 五、安全与健壮性（脚本层） | P0 0 / P1 0 / P2 4 / P3 6 | 未发现 `rm -rf` 未加引号、未设权限的 `mktemp` 残留、真实密钥泄漏或 `.bak` 藏密钥；发现 4 个 P2：特权门禁空转、导出/下载路径非字符边界切片 panic、`UMWEB_ALLOWED_ORIGINS` 空值使 Origin 校验静默失效、secret 门禁结构上看不见未跟踪文件。 |

**总计：P0 = 0，P1 = 1，P2 = 12，P3 = 19。**

发布判断：在本次可验证范围内**没有发现阻断发布的安全缺陷**。唯一 P1 是「纵深防御缺口」性质（`umweb` 以 root 手工启动时无代码层拦截），实际暴露面取决于部署形态。真正的风险不在代码，而在**验收缺失**（目标主机部署、真实 webhook 投递、Rust/前端门禁复验）与**文档可信度**——STATUS.md / PROGRESS.md 存在多处自相矛盾，会让读者高估完成度。

## 2. 严重级定义

| 级别 | 定义 |
| --- | --- |
| **P0 阻断发布** | 可被利用的越权 / 提权 / 凭据泄漏；或使「Web 永不获得 root」这一黄金标准在代码层被破坏。 |
| **P1 发布前必修** | 非可直接利用，但违反硬约束且**没有第二道防线**；或门禁失效使同类回归可静默合入。 |
| **P2 应修** | 真实缺陷（panic、fail-open 默认值、门禁空转）或实质性文档夸大，会误导后续决策，但在现有威胁模型下不直接导致越权。 |
| **P3 记录** | 措辞不准、计数错误、死代码、风格不一致、悬空文档引用。**不混报为安全问题。** |

分级原则：文档措辞不准一律 P3；可被利用的安全缺陷一律 ≤P1。两条不混。

## 3. 本次实际执行的验证（可复现）

| 验证 | 命令 | 结果 |
| --- | --- | --- |
| Shell 分级回归 | `bash tests/run_regression.sh --level all` | **43 passed / 0 failed / 1 skipped**，退出码 0（约 16 s）。与 STATUS.md §4.1 完全一致。 |
| Shell 语法 | `bash -n`（全部 Git 跟踪 `*.sh`，跳过 Miniforge.sh） | 通过，无输出 |
| ShellCheck | `shellcheck --severity=error`（同 CI 遍历与跳过规则） | 通过，无输出 |
| Web 安全门禁 | `bash scripts/check_web_security.sh web/backend/src` | `OK (no forbidden tokens)`，rc=0 |
| 敏感文件扫描 | `bash scripts/check_sensitive_files.sh .` | `No sensitive tracked files detected`，rc=0 |
| CI 权限门禁复现 | 复刻 `ci.yml` 的 `git ls-files -s` 判据 | `checked=23 missing=0`，与 STATUS.md:183 一致 |
| 权限门禁负向对照 | 临时仓库构造 `100644 bad.sh` | 被捕获（`CAUGHT: 100644 bad.sh`）→ 门禁非空转 |
| `set -e` 语义探针 | `bash -e -c 'bash check_web_security.sh <不存在目录>; rc=$?; echo REACHED'` | 未打印 REACHED，外层 rc=2 → `rc=$?` 分支不可达 |
| `&& continue` 探针 | `bash -e -c '[[ a == b ]] && continue; echo STILL_ALIVE'` | 打印 STILL_ALIVE → CI 语法检查步骤不会被误中止 |

计数复核（均为脚本实测，非引用文档）：`lib/*.sh`=67、`scripts/*.sh`=18、`tests/*.sh`=44、后端 `*.rs`（含 tests/）=48、前端源文件=6、前端总行数=1628、`P1_SCRIPTS`=42、Action Registry=29（safe 18 / dangerous 11 / both 14 / cli 15）、`user_manager.sh`=89 行、`SNAPSHOT_KINDS`=11、后端注册路由=40 条、前端可达端点=20 个、后端不可达端点=20 个、`.bak`=15（另有 4 个在 `.validation/`，属并发工作流产物，不在本次基线内）。

## 4. 「无法验证」条目清单（含缺失条件）

| # | 条目 | 缺失条件 |
| --- | --- | --- |
| U1 | `umweb` 不加入 `sudo`/`wheel`/`admin`/`useradm`/`docker`/`lxd` 等特权组（plan.md 0.1） | 仓库内不存在建组/加组脚本，判定完全依赖目标主机实机 `id umweb` / `getent group`。`tests/test_web_deploy_boundary.sh` 只断言 unit 文件文本，不断言实际组成员。 |
| U2 | `sudo -l -U umweb` 必须为空（WEB_SECURITY_BOUNDARY §9） | 需要目标主机的 root 权限执行 `sudo -l`。 |
| U3 | `NoNewPrivileges` / `CapabilityBoundingSet` / `InaccessiblePaths` 在目标机真实生效 | 需要 `systemd-analyze security umweb` 或实机行为观察；仓库只提供 unit 文本与静态断言。 |
| U4 | 快照/DB/master.key 在目标机的属主、组、mode（root:umweb 0640 / 0750） | 需要目标主机实机 `stat`。 |
| U5 | `um-snapshot.timer` 实际运行并产出快照 | 需要目标主机 `systemctl status` + 快照目录实况。 |
| U6 | Rust `fmt` / `clippy -D warnings` / 65 项后端测试 | 本环境无 `cargo` / `rustc`。**这一项同时决定了「§6 契约由 CI 断言」目前只有静态证据。** |
| U7 | 前端 `npm ci` + 生产构建 | npm 缓存位于只读文件系统（`EROFS`），无法安装依赖。 |
| U8 | 真实企业微信 webhook 投递 | 无凭据，未发送任何外部消息。 |
| U9 | 完整 WCAG / 读屏器审计 | 需人工审计或辅助技术环境。 |
| U10 | API 契约测试 `api_contract.rs` 实际断言 404/405 | 同 U6。本报告对该契约的判定基于**静态路由表全量枚举**（40 条 `.route()`），而非运行时观测。 |
| U11 | 导出/下载路径 panic（findings F2）是否可实际触发 | 需 `cargo test` 或运行中的服务 + 构造 >512 KB 且跨字符边界的 UTF-8 负载。 |
| U12 | `plan.md` 自身 2802 行内版本号/模块名/路径引用的完整核对 | 本次对 9 份文档做了全量反引号路径解析（见 `doc-vs-code.md` §5），发现 4 处悬空引用；`plan.md` 逐条引用未做全量枚举。 |
| U13 | 15 个 `.bak` 是否掩盖「功能已删但文档仍引用」 | 已对 15 个 `.bak` 逐个与现网文件 `diff`：全部为「现网净增」，删除量最大的是 `lib/tui_core.sh`（-32 行，经核为终端检测代码内联重构，非功能删除）。**未发现功能被删。** 但 `.bak` 不参与任何门禁，长期存在仍是检索噪声源。 |

## 5. 报告索引

| 文件 | 内容 |
| --- | --- |
| [`hard-constraints.md`](hard-constraints.md) | 第一部分：硬约束逐条核对表（30 个检查项） |
| [`doc-vs-code.md`](doc-vs-code.md) | 第三部分：文档与实现偏差逐条 |
| [`ci-gates.md`](ci-gates.md) | 第四部分：CI 门禁逐个判定 |
| [`findings.md`](findings.md) | 第五部分：安全与健壮性发现 + 高价值正面发现 |
