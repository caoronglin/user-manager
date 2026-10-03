# 第五部分：安全与健壮性发现

每条：现象 / 证据 / 可利用性判定 / 复现方式 / 建议。**可利用性判定是本节的核心**——文档问题与安全缺陷严格分开（文档类一律在 `doc-vs-code.md，此处只列真实代码/脚本缺陷）。

---

## 1. 严重级分布

| 级别 | 数量 | 编号 |
| --- | --- | --- |
| P0 | **0** | — |
| P1 | 0（本节无；唯一的 P1 在 hard-constraints.md 0.1-a） | — |
| P2 | 4 | F1、F2、F3、F4 |
| P3 | 6 | F5 ~ F10 |

---

## 2. P2 发现

### F1 — 特权门禁在「目录存在但无源码」时空转通过

| 项 | 内容 |
| --- | --- |
| 现象 | `scripts/check_web_security.sh` 对「零个被扫描文件」与「全部通过」返回同一个结果（exit 0 + `OK (no forbidden tokens)`）。这是 plan.md `14.1–14.3 指定的**唯一**提权阻断门禁。 |
| 证据 | `scripts/check_web_security.sh:40-54` 遍历 `find "$SRC_DIR" -type f -name '*.rs'`，**无任何计数器**；`:56-59` 仅判断 violations 数组长度。**对比**：同仓库的权限门禁（`ci.yml:196-199`）有 `checked -eq 0` 守卫，说明作者已识别这一失败模式，只是未推广到此处。 |
| 实测 | `mkdir -p /tmp/audit-empty/src && bash scripts/check_web_security.sh /tmp/audit-empty/src` → 输出 `OK (no forbidden tokens in /tmp/audit-empty/src)`，**rc=0**。 |
| 附带 | `:54` 的 `find ... 2>/dev/null | sort -z` 管道退出码取 `sort` 的 0，**find 中途失败会被静默当作完整扫描**。 |
| 可利用性 | **不可直接利用**（需先修改仓库结构）。属于**门禁失效**：一次目录重命名、文件扩展名变更或 CI 参数笔误，就能让提权门禁长期静默通过而无人察觉。这正是 STATUS.md 记录过的失败模式（P0-1「Warning 不阻断，缺陷长期潜伏」）的重演。 |
| 复现 | 见上方实测命令。 |
| 建议 | 在 `:38` 后加 `checked=0`，循环内自增，`:56` 改为「若 checked==0 则打印 ::error 并 exit 1」；并把 find 的失败显式传播（先 `mapfile -d ''` 收集再判数组长度）。 |

### F2 — 导出/下载路径按字节下标切片，跨字符边界会 panic

| 项 | 内容 |
| --- | --- |
| 现象 | 三处对 `String` 用**字节下标**截断。Rust 的 `String::len()` 返回字节数，而 `s[..N]` / `s.truncate(N)` 在 N 不落在 UTF-8 字符边界上时**直接 panic**（byte index … is not a char boundary）。 |
| 证据 | ① `web/backend/src/http/logs_api.rs:120-122`，`MAX_DOWNLOAD_BYTES = 512 * 1024`（`:22`）；<br>② `web/backend/src/http/audit_api.rs:141-143`（CSV 路径的 `s.truncate(MAX_EXPORT_BYTES)`）；<br>③ `web/backend/src/http/audit_api.rs:149-151`（JSON 路径的 `body[..MAX_EXPORT_BYTES]`），`MAX_EXPORT_BYTES = 512 * 1024`（`:21`）。 |
| 可利用性 | **可由任意已认证的 `logs.read` / `audit.read` 持有者触发**（`viewer` 角色即默认拥有这两项，`config.rs:151,160`）。触发条件：对应快照的拼接文本超过 512 KiB，且第 524288 字节落在某个多字节 UTF-8 字符中间。日志与审计内容含中文是常态（本项目 UI 与日志本身即中文），因此这不是理论边界。<br>**后果**：handler panic → 该请求的连接被中止（axum/tokio 不因单次 handler panic 终止进程），表现为 500/连接重置。属**可用性缺陷**，不是越权、不泄漏数据。 |
| 为什么没被测出来 | 阈值很大，现有测试用的短负载永远走 else 分支。**属测试覆盖缺口**：无一条测试构造过「超限且跨字符边界」的负载。 |
| 复现（需 cargo 或运行中的服务） | 令 logs 快照的拼接文本长度 >524288，且使第 524288 字节处于 3 字节中文序列的第 2 字节，然后请求 `GET /api/logs/download?source=boot`。（本环境无 cargo，**运行时复现记为 U11**。） |
| 建议 | 三处统一改为按字符边界收敛，例如 `text.floor_char_boundary(MAX)`（Rust 1.80+ 稳定），或手工回退到最近的 `is_char_boundary` 位置；并补一条超限跨边界测试。 |

### F3 — `UMWEB_ALLOWED_ORIGINS` 为空时 Origin 校验静默失效（fail-open 默认）

| 项 | 内容 |
| --- | --- |
| 现象 | CSRF/Origin 中间件用 `if !allowed_origins.is_empty() { ... }` 包裹整个 Origin 校验。配置默认为空向量（`config.rs:104-111`，`unwrap_or_default()`），于是**默认部署下 Origin 校验完全不执行**。 |
| 证据 | `web/backend/src/http/middleware.rs:104-115` —— 整块逻辑在「非空」时才进入，未命中 allowed_origins 之一即 403。配置默认值见 `config.rs:104-111`。 |
| **注释与实现不符** | `middleware.rs:90-92` 的文档注释写：「登录是预认证引导…豁免 token、**仍受 rate-limit + 统一 401 + Origin 校验保护**」。**但当 allowed_origins 为空时不存在任何 Origin 校验**——注释描述的保护在默认配置下并未生效。 |
| 可利用性 | **低，但非零**。三层缓解使其难以直接利用：① 会话 Cookie 与 CSRF Cookie 均为 `SameSite=Strict`（`routes.rs:183`），跨站请求根本带不上 Cookie；② 未配置任何 CORS 层（Cargo.toml 虽启用了 tower-http 的 cors feature，但 `routes.rs` 未 layer `CorsLayer`），跨源 JS 读响应被浏览器拦截；③ 已认证请求仍有 double-submit CSRF token 校验（`middleware.rs:117-130`）。<br>**残留风险面**是未认证的 `POST /api/auth/login`：它被显式豁免 CSRF token（`middleware.rs:118` 只在存在有效会话时才校验），Origin 校验又默认关闭，理论上可构成 login CSRF。实际利用仍受「JSON content-type 触发预检 + 无 CORS」限制。 |
| 判定 | **P2**（fail-open 默认值 + 注释过度声明保护）。**不是**可利用的越权。 |
| 建议 | 把语义反过来：空配置时**拒绝所有变更请求的异源 Origin**（或至少在 require_tls=true 时强制要求 Origin/Referer 存在），并把 `middleware.rs:90-92` 注释改为与实际行为一致。同时在部署文档中把 `UMWEB_ALLOWED_ORIGINS` 从「可选」升为「生产必填」。 |

### F4 — CI 中 `rc=$?` 分支不可达，「无源码则跳过」的意图从未生效

| 项 | 内容 |
| --- | --- |
| 现象 | `.github/workflows/ci.yml:152-159` 的 Web 安全门禁步骤依赖 `rc=$?` 区分「命中禁止项（1）」与「无源码跳过（2）」。但 GHA 对未指定 `shell:` 的步骤使用 `bash -e {0}`，脚本返回任何非零都会**立即中止步骤**，`rc=$?` 及其后的 if/echo 是死代码。 |
| 证据 | `ci.yml:156-159` 四行；探针实测 `bash -e -c 'bash scripts/check_web_security.sh /tmp/does-not-exist-xyz; rc=$?; echo REACHED_rc=$rc'` → **未打印 REACHED**，外层 rc=2。 |
| 可利用性 | **无直接安全影响——方向是失败关闭的**（缺源码目录会让 job 失败，而不是放行）。但：① 步骤注释（`ci.yml:155`「无 web 源码时视为跳过」）与实际行为相反，会误导排障；② 开发者为「让 CI 变绿」而删除 `web/backend/src` 的可能性虽低，但一旦发生，**提权门禁会连同源码一起消失而无人察觉**（与 F1 同一类风险）。 |
| 判定 | **P2**（门禁意图不可达 + 误导性注释），不是安全绕过。 |
| 建议 | 要么删掉 `rc=$?` 块、把注释改为「缺源码目录即视为门禁失败」（与 set -e 语义一致，推荐）；要么在脚本调用前显式 `set +e` 再取返回码。 |

---

## 3. P3 发现

### F5 — `reports_api.rs` 的导出缺少字节上限与截断标记（与 audit 不一致）

`web/backend/src/http/reports_api.rs:63-104` 的 `reports_export` 只用 `MAX_EXPORT_ROWS` 限行（`:72`），**没有字节上限，也没有 `x-export-truncated` 响应头**；而结构完全平行的 `audit_api.rs` 两者都有（`:20-21`、`:163-166`）。当前 `MAX_EXPORT_ROWS` 较小故影响有限，属一致性问题。检索方式：全量 grep 截断模式后逐条判读，`reports_api.rs` 是唯一无字节上限的导出端点。

### F6 — `/api/hosts/:id/gpu` 忽略路径参数

`web/backend/src/http/read_api.rs:182-191` 的 `host_gpu` 以 `Path(_id)` 接收并丢弃 id，直接返回**本机** gpu 快照。因此 `GET /api/hosts/<任意字符串>/gpu` 返回相同数据。**不构成安全问题**（仍需 `gpu.read`），但路由语义有误导性——路径暗示按主机查询，实际是全局快照。`host_detail`（`:164-180`）则正确地用 `source == "local" && id == "local"` 做了匹配判定。

### F7 — `default_timeout` 为死函数

`web/backend/src/http/middleware.rs:136-138` 定义 `default_timeout()` 但**全仓无调用方**，注释自述「P1 仅示范」。判定死代码。检索方式：对 `web/backend/src/http/*.rs` 中每个 `pub fn` 逐一反查引用数，**全仓仅此一处为 0**。

### F8 — `mail.test` 标 `safe` 但有真实外部副作用

`lib/action_registry.sh:379`：`action_register "mail.test" … "none" "cli" "safe"`，handler `rl_action_mail_test_cli` 会真实发信。**不构成安全问题**（`mail.test` 不在 Web capability 集合内，`rbac.rs:49-67` 的 `KNOWN_CAPS` 中亦无对应项），且 plan.md 0.3 已声明 risk 仅为业务标签。仅建议在文档中显式说明，避免读者按 safe 字面理解。

### F9 — shellcheck / format 两个 job 缺 `checked -eq 0` 守卫（与权限门禁不一致）

`ci.yml:30-33`（shellcheck）与 `ci.yml:230-243`（format）都维护 checked 计数器但**都不检查它是否为 0**；而 `ci.yml:196-199`（权限门禁）有。同一文件内三种写法。此外 `ci.yml:30-31` 的自增位置在 `shellcheck` **之后**，若 shellcheck 失败会先中止，导致计数永远不含失败文件（当前无实际影响，但降低了 summary 的可读性）。

### F10 — format job 的遍历范围与 shellcheck job 不一致

shellcheck job 跳过 `Miniforge.sh` 与 `data/*`、`logs/*`、`templates/*`（`ci.yml:28`），format job 只跳过 `Miniforge.sh`（`ci.yml:231`）。若将来在 data/、logs/、templates/ 下出现 `.sh`，两个 job 行为分叉（format 会额外扫描并可能因运行时脚本不符合 shfmt 而失败）。`.pre-commit-config.yaml:26` 的 exclude 与 shellcheck job 对齐，同样与 format job 不一致。

---

## 4. 明确「未找到」的项目（附检索方式，不写成「没有问题」）

| 检查项 | 结论 | 检索/验证方式 |
| --- | --- | --- |
| `rm -rf` 变量未加引号 | **未找到** | 先 `grep -rn 'rm -rf' lib/ scripts/ tests/ *.sh` → 无输出；改用 `git ls-files '*.sh' | xargs grep -nE 'rm[[:space:]]+-[a-zA-Z]*[rR]'` 列出全部 19 处递归删除，逐条判读：**全部为 `rm -rf "$var"` 或 `rm -rf -- "$var"` 形式**（后者还能防选项注入）。`priv_rm` 是封装 wrapper。 |
| `mktemp` 临时文件未清理 / 未设权限 | **未找到** | 对 15 个含 mktemp 的文件统计 mktemp 次数与 `trap … EXIT/RETURN` / `rm -[rf]+` 出现次数：除 `scripts/normalize_echo_output.sh`（开发辅助脚本，mktemp=1 / cleanup=0）外，**每个文件的清理标记数均 ≥ mktemp 次数**。生产入口（`lib/user_core.sh` 5/15、`lib/backup_core.sh` 3/13、`lib/rl_mail_queue.sh` 5/8）均成对。 |
| `.gitignore` 遗漏敏感路径 | **未找到**（对照 WEB_SECURITY_BOUNDARY 列出的 secret 路径） | 文档 `3.5/`4 的 secret 路径分两类：① 仓库内的 data/secrets/、密码池、邮件配置 → `.gitignore:19`、`:4-5`、`:7-8` **均已覆盖**；② `/var/lib/user-manager-web/{snapshots,events}` 等**目标机绝对路径**，本就不在仓库内。另经 `git ls-files data/` 确认 **data/ 下 0 个文件被跟踪**。文档另列的 `data/hosts.conf`、`data/ssh_known_hosts` 也已覆盖（`:82-83`）。 |
| `.bak` 文件含真实密钥或口令 | **未找到** | 对 15 个 .bak（排除 .validation/ 下 4 个并发工作流产物）执行扩展扫描：私钥头 / PASSWORD / PASSWD / SECRET / TOKEN / API_KEY / webhook key / AKIA / gh* / xox* → **全部零命中**。全部 .bak 的 mode 均为 `600`（严于仓库常见的 644）。**注意**：这是本次人工扫描的结论，`check_sensitive_files.sh` 因只扫 `git ls-files` 而**结构上看不见这些文件**。 |
| 用户可控输入拼入 `eval` / `source` / `bash -c` / `systemd-run` / 路径 | **未找到** | ① `git ls-files '*.sh' | xargs grep -nE '[^_[:alnum:]]eval[[:space:]]'` → 仅 2 处：`lib/backup_core.sh:442` 是**注释**、`scripts/rl-chpasswd.sh:71` 是 fd 关闭惯用法，其中 `$rl_fd` 来自 `for rl_fd in {3..63}` **固定整数循环**，非用户输入。② 远端输出解析：`docs/REMOTE_HOSTS.md:91` 明确要求「不要使用 source 或 eval 解析输出」，实现为协议校验 + PROTOCOL_ERROR 标记。③ `systemd-run` 在全仓 `*.sh` 中零出现。④ 快照路径由 kind 派生并经 allowlist（`snapshot.rs:91-96`），无调用方可控路径。 |
| Web 侧任意文件读取 / 任意日志路径 / 任意 URL | **未找到** | ① 文件读取仅 `SnapshotStore::read(kind)`，kind 经 11 项 allowlist + 字符集校验，路径派生不可控（`snapshot.rs:35-39,91-96`）；② 日志源为 3 项定长白名单（`logs_api.rs:20`）；③ 唯一出站 URL 经 `validate_webhook`（`wecom_api.rs:45-83`）严格收敛到固定 https 端点 + 单一 key 参数，且 client 设 `redirect(Policy::none())` + connect 3s / total 8s 超时（`web_event_delivery.rs:216-220`、`event_spool.rs:486-490`）。 |
| sudo / su / setuid / capability 出现在 Web 源码 | **未找到** | `bash scripts/check_web_security.sh web/backend/src` → rc=0 无命中；人工复核 `web/backend/src` 中 `libc::` 的全部 17 处使用，**全部是防御性调用**：`O_NOFOLLOW` / `O_CLOEXEC` / `O_DIRECTORY`、`getegid` 属主校验、`geteuid` 属主校验、fd 生命周期管理（`closedir`/`dup`/`close`/`readdir`/errno）。**无一处用于提权。** |
| `set -e` 缺失导致错误吞掉（生产入口） | **未找到** | ① 全部 `scripts/*.sh` 除 `rl-remote-entry.sh` 外均为 `set -Eeuo pipefail` + ERR trap（逐文件核对，含 5 个特权写入口）。② `rl-remote-entry.sh:3` 为 `set -uo pipefail`（**故意不含 -e**）：它是快照发射器，-e 会导致采集中途中断产出**截断的 key=value 流**，反而制造「看似有效的残缺输出」；正确做法是由客户端协议校验捕获。这是**有意的设计**。③ `lib/*.sh` 全部无 set 行，这是 sourced 库的正确做法——`lib/snapshot_core.sh:13` 有显式说明；set -e 在 sourced 文件中会污染调用方 shell 选项。④ `user_manager.sh`/`tui_manager.sh` 顶层无 set -e，但用显式 || return 1 / || exit 1 + ERR trap，且 `user_manager.sh:50` 有注释明示该交互。**均非疏漏。** |

---

## 5. 高价值正面发现

以下设计**确实做得对**，且部分**严于文档要求**，建议在后续重构中显式保留（每条都给出「为什么有价值」）。

### 5.1 快照读取层比文档要求更严（`web/backend/src/store/snapshot.rs`）

| 做法 | 位置 | 为什么有价值 |
| --- | --- | --- |
| 打开快照用 `O_NOFOLLOW | O_CLOEXEC` | :246-249 | 终态组件为符号链接时**直接失败**，而不是跟随到攻击者控制的文件。 |
| 逐级检查路径分量、遇 ParentDir 立即 false | :210-240 | 阻断父分量中藏符号链接的穿越（注释明确说明「拒绝 traversal 而不是让路径归一化掩盖父分量里的符号链接」）。这是很多实现会漏掉的一层。 |
| 信封绑定 7 项元数据（schema_version / protocol / kind / generator / source 字符集+长度 / threshold 必须等于代码内默认值 / RFC3339 可解析） | :124-138 | 把「这个文件确实是 kind X 的、由本项目生成、未被替换过」变成**读时校验**而非信任。任一不符返回 None，**不可区分「缺失」与「非法」** → 前端统一呈现 stale，攻击者无法通过伪造文件让界面显示为新鲜。 |
| 未来时间戳判为 stale 而非钳制 | :155-159 | 防止「把 generated_at 设到 2099 年」骗过所有新鲜度检查。注释直接写明了这个威胁。 |
| fresh 与 data 从**同一次读取**派生 | :150-168 | `read_with_freshness` 避免两次 read 跨越一次原子替换，从而算出「旧 data + 新时间」的错配年龄。**这是文档未要求、但确实是正确性的关键细节。** |
| 16 MiB 硬上限 + 二次校验实际读取字节数 | :32、:106、:113-115 | 防超大快照耗尽内存。`file.take(MAX+1).read_to_end` 后再判一次，防止 metadata 撒谎。 |
| 全模块无任何写/创建调用 | 全文 | 「Web 不能写快照」这一约束在类型层面就没有出口，而非靠审查纪律。 |

### 5.2 私钥文件加固超出常规（`web/backend/src/crypto.rs:67-135`）

- 目录用 `O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC` 打开，且**明确拒绝 chmod 任意被配置的父目录**（`:68-70` 注释：可能是用户的 home 目录）——很多实现在这里会顺手 chmod 700 一个不该动的路径。
- 区分「sticky 共享目录（/tmp，测试用）」与「属主匹配的私有目录」两条路径（`:84-99`），前者要求 sticky 位、后者要求 group/other 无任何权限位。
- 要求 `nlink() == 1`（`:124`）——**阻断硬链接攻击**：攻击者无法通过 ln 把自己的文件挂到服务读取路径上。
- 要求 `uid() == geteuid()`（`:124`）——阻断「用别人的文件」。
- 打开后强制 0600 并**回读验证**（`:131-135`）。

### 5.3 SSH 边界按 REMOTE_HOSTS.md 逐条落实（`lib/host_provider.sh`）

两条**完整常量**远端命令、零插值（`:19-20`）；`-F /dev/null` 禁用户 config、`BatchMode=yes`、`StrictHostKeyChecking=yes`、独立 `UserKnownHostsFile`、`GlobalKnownHostsFile=/dev/null`、`HostKeyAlias`、`ProxyCommand=none`、`ProxyJump=none`、`RemoteCommand=none`、`RequestTTY=no`（`:191-198`）。**约束一条不落**，且远端入口 `scripts/rl-remote-entry.sh` 侧还有 `umask 077` + 固定 PATH + `unset CDPATH ENV BASH_ENV GLOBIGNORE` + 严格参数个数检查四重加固。

### 5.4 密码不经 argv（`scripts/rl-chpasswd.sh`）

密码经**无名管道**注入 fd 0（`:66`），不落盘、不进 ps、不进审计日志；`env -i` 清空 LD_PRELOAD / BASH_ENV / ENV / SHELLOPTS 等注入面（`:77`）；`exec` 前显式关闭 fd 3..63（`:70-72`，注释指出「env -i 不清理 fd」这一常被忽略的注入面）；最终 exec 的命令行**只含用户名**。这是把「密码不进入可观测面」做到了进程参数层面，而非仅靠「不给变量取名 password」。

### 5.5 双层能力过滤，服务端不信任库中已存值（`auth/guard.rs:63-69` + `auth/rbac.rs:71-83`）

Bearer token 认证时，数据库中存储的 capability 值**被再次**按 `TOKEN_READ_CAPS` 过滤。注释写明这是为了「旧数据库中已有的管理型 token 也无法调用变更接口」。**向后兼容不引入权限提升**——这是很容易做错（直接信任存储值）而这里做对了的点。

### 5.6 systemd 沙箱严于文档清单（`etc/systemd/system/umweb.service`）

WEB_SECURITY_BOUNDARY `2 要求的 17 项，unit **全部落实**（User / Group / UMask=0077 / NoNewPrivileges / 两个空 CapabilitySet / PrivateTmp / PrivateDevices / ProtectSystem=strict / ProtectHome / ProtectKernelTunables / ProtectKernelModules / ProtectControlGroups / RestrictSUIDSGID / RestrictAddressFamilies / 6 条 InaccessiblePaths / ReadWritePaths / 2 条 ReadOnlyPaths）。**此外额外加了 8 项文档未要求的**：`ProtectKernelLogs`、`ProtectClock`、`ProtectHostname`、`RestrictNamespaces`、`RestrictRealtime`、`LockPersonality`、`MemoryDenyWriteExecute`、`SystemCallArchitectures=native`。超出基线而非低于基线，值得肯定。

### 5.7 门禁的反空转设计（`ci.yml:196-199`）

权限门禁带 `checked -eq 0` 守卫，直接封堵「glob 失配 → 零文件 → 静默通过」。这正是空转门禁反模式，作者在本仓库最关键的门禁上已经识别并修复。本次审计还用**负向对照实测**确认它真的能捕获（构造 100644 → 如期报错）。**建议把这个守卫模式推广到 shellcheck / format / check_web_security 三个 job**（见 F1、F9）。

### 5.8 采集器与 Web 的阈值/协议定义跨语言一致

`lib/snapshot_core.sh:30-42`（Shell，11 项）与 `web/backend/src/store/snapshot.rs:260-270`（Rust，11 项）**逐值一致**（system/resources 60、users/quota/smb 300、hosts/gpu/manifest 120、logs 60、reports 300、audit-summary 30）。且 Rust 侧在读时强制 `env.threshold_seconds == default_threshold(kind)`（`:134`）——**不接受快照自称的阈值，一律以代码为准**。跨语言契约漂移是这类项目最常见的隐性缺陷来源，这里从设计上堵住了。

### 5.9 secret 响应只给布尔与掩码（`http/wecom_api.rs:98-121`）

`webhook_configured: bool` + 固定的 `webhook_masked` 字符串，**不提供任何可反推的元数据**（无长度、无前缀、无哈希）。审计写入（`:230-239`）同样只记固定标签。

### 5.10 15 个 `.bak` 全部 mode 600，且不含密钥

`find` 实测 15 个 .bak 的权限均为 600（严于仓库常见的 644），扩展密钥扫描零命中（见 `4`）。**「存在 .bak」是卫生问题，「.bak 泄露密钥」不是——两者不应混为一谈。**

### 5.11 capability allowlist 不可被环境覆盖

`config.rs:133-193` 的角色→能力映射是 Rust 硬编码，**没有对应的环境变量或配置文件开关**。运维无法通过设置一个环境变量就放宽权限。虽然与 plan.md 0.3 展示的 TOML 形式不同，但在这个方向上**比 TOML 更安全**（无环境变量注入面）。
