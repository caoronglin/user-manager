# 第一部分：硬约束逐条核对

判定口径：

- **满足** — 找到实现该要求的代码/配置，且该实现本身构成有效约束。
- **部分满足** — 主体成立，但缺少第二道防线或只在某一层生效。
- **违反** — 存在与要求相反的实现。
- **无法验证** — 判定依赖本环境不具备的条件（缺 cargo、缺目标主机、缺凭据），已写明缺失条件，编号对应 `README.md` §4。

核对基线：HEAD = `62f00fc`。

---

## 0.1 Web 进程绝不提权

| # | 要求摘要 | 实现位置 | 判定 | 证据 |
| --- | --- | --- | --- | --- |
| 0.1-a | 不得以 root 身份启动 | `etc/systemd/system/umweb.service:23-24`；`web/backend/src/lib.rs:22` | **部分满足（P1）** | unit 有 `User=umweb` / `Group=umweb`，但 `umweb::run()`（lib.rs:22-78）**没有任何 geteuid()==0 的拒绝启动检查**。若运维手工 sudo ./umweb 启动，进程以 root 全量运行且无代码层拦截。仓库中唯一与 euid 相关的逻辑是 `crypto.rs:83/124` 的属主比对，它会在 root 下**失败关闭**（要求文件属主 == geteuid），因此 root 启动后 master.key 加载会失败——这是副作用而非显式防护。 |
| 0.1-b | 不得加入 sudo/wheel/admin/useradm/docker/lxd 特权组 | — | **无法验证（U1）** | 仓库内无建组/加组脚本。`tests/test_web_deploy_boundary.sh:29-34` 只断言 unit 的 `User=`/`Group=` 文本，不断言实际组成员。需目标主机 `id umweb`。 |
| 0.1-c | 不得存在任何针对 `umweb` 的 sudoers 授权 | `etc/sudoers.d/user-manager.example` | **满足（仓库内）** | `grep -rn 'umweb' etc/` 仅命中 `umweb.service`（自身）与 `tmpfiles.d/user-manager-web.conf`，**无任何 sudoers 条目涉及 umweb**。现有 sudoers 模板只授予 `%useradm` → `rl-chpasswd`（第 9、12 行），未涉及 umweb。目标主机实况见 U2。 |
| 0.1-d | 不得执行 sudo / su / pkexec / doas | `scripts/check_web_security.sh:24-30` | **满足** | token 门禁含 `sudo su pkexec doas`，实测 `bash scripts/check_web_security.sh web/backend/src` → rc=0 无命中；`web/backend/src` 内无 `Command::new`/`std::process::Command`（门禁 line 33-36 亦禁止）。 |
| 0.1-e | 不得依赖 setuid/setgid helper | `umweb.service:56` | **满足** | `RestrictSUIDSGID=yes`；且 `check_web_security.sh:25` 将 `setuid`/`setgid` 列为禁止 token。 |
| 0.1-f | 不得拥有 CAP_SETUID/CAP_SETGID/CAP_DAC_OVERRIDE/CAP_SYS_ADMIN/CAP_SYS_PTRACE/CAP_NET_ADMIN | `umweb.service:42-43` | **满足** | `CapabilityBoundingSet=` 与 `AmbientCapabilities=` 均为空；`tests/test_web_deploy_boundary.sh:37-40` 静态断言这两行为空。门禁 token 覆盖 6 个具名 CAP（check_web_security.sh:26）。 |
| 0.1-g | systemd 必须 `NoNewPrivileges=yes` | `umweb.service:41` | **满足** | 同上，test:37 断言。 |
| 0.1-h | `CapabilityBoundingSet=` 与 `AmbientCapabilities=` 必须为空 | `umweb.service:42-43` | **满足** | 同上。 |
| 0.1-i | 不得经 Docker/containerd/Podman/systemd 私有 socket、D-Bus 特权接口或本地 IPC 间接获得 root | `umweb.service:65` | **满足** | `InaccessiblePaths=-` 显式屏蔽 6 条路径（docker.sock ×2、containerd.sock、podman.sock、systemd/private、dbus/system_bus_socket）；`tests/test_web_deploy_boundary.sh:63-73` 逐条断言 5 类 socket。另 `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX`（service:64）限定地址族。 |

**0.1 小结**：8 条中 7 条满足、1 条部分满足（P1）、1 条无法验证（U1/U2）。**未发现任何违反项。**

---

## 0.2 取消 Web 特权执行桥

| # | 要求摘要 | 实现位置 | 判定 | 证据 |
| --- | --- | --- | --- | --- |
| 0.2-a | 不实现 `Web → sudo → rl-web-exec → action_run → priv_exec` 桥，不新增 `rl-web-exec` | 全仓 | **满足** | `grep -rn 'rl-web-exec'` 在 `*.sh`/`*.rs`/`*.js`/`*.jsx` 中**零命中**；仅出现于 `plan.md:68`（被取消的原方案示意）、`docs/WEB_SECURITY_BOUNDARY.md:50`（禁令正文）、`tests/test_snapshot.sh:23`（作为**禁止 token** 扫描采集器）。三处都是「禁止它」而非「实现它」。 |
| 0.2-b | Web 不得调用 action_run / rl_action_run / user_manager.sh / tui_manager.sh / rl-user-create.sh / rl-user-quota.sh --set / rl-user-resource.sh 写子命令 / SMB 写 / rl-backup-run.sh / 任何进入 priv_exec 的写操作 | `web/backend/src/**`、`web/frontend/src/**` | **满足** | 对 10 个禁止标识做全量 grep：`action_run\|rl_action_run\|priv_exec\|user_manager\.sh\|tui_manager\.sh\|rl-user-create\|rl-user-quota\|rl-user-resource\|rl-backup-run\|rl-smb-manage` 在 `web/backend/src` 与 `web/frontend/src` 中**零命中**。 |

---

## 0.3 risk=safe 不等于 Web-safe

| # | 要求摘要 | 实现位置 | 判定 | 证据 |
| --- | --- | --- | --- | --- |
| 0.3-a | Web 维护独立、默认拒绝的 capability allowlist；未显式列出的能力一律拒绝 | `web/backend/src/auth/rbac.rs:10-18`、`web/backend/src/config.rs:133-193` | **满足** | `capabilities_for()` 对未知角色返回空 `BTreeSet`（rbac.rs:15-17），`api_contract.rs:126-130` 断言 `is_allowed(cfg,"owner","users.read") == false`。三角色能力集（config.rs:142-186）逐条核对**全部为 `*.read` 或 Web 自身管理类**（notifications.manage / web_users.manage / sessions.manage / tokens.manage / wecom.manage / settings.manage），**无任何 Linux 系统写能力**。 |
| 0.3-b | 禁止 `if action.risk == "safe" { allow_web() }` 这类映射 | `web/backend/src/**` | **满足** | `web/` 全树不引用 `action_registry`、不引用 `risk` 字段。Web 与 `lib/action_registry.sh` 之间**零耦合**——这是本项目安全模型最关键的解耦点。 |
| 0.3-c | API Token 只能拿到只读能力（防止旧库中已有管理型 token 越权） | `rbac.rs:71-83`、`guard.rs:63-69` | **满足** | `TOKEN_READ_CAPS` 只含 11 个 `*.read`；`authenticate()` 对 Bearer token 的能力集**再次**按此白名单过滤（guard.rs:67-68），即服务端不信任库中已存的 capability 值。 |
| 0.3-d | 附：plan.md 0.3 展示的是 TOML 形式的 allowlist | `config.rs:131-140` | **部分满足（P3）** | 实现改为 Rust 硬编码 `BTreeMap`（注释：「为避免引入 toml 依赖」）。功能上**比 TOML 更严**——能力集不可被环境变量或文件覆盖，无误配置面。仅形式与规划文档不同。 |

---

## 0.4 Web 不提供「审批后提权」

| # | 要求摘要 | 实现位置 | 判定 | 证据 |
| --- | --- | --- | --- | --- |
| 0.4-a | 审批流不得成为提权后门；Web 后端不得 sudo 执行 | 全仓 | **满足** | Web 侧全部 20 个写路由（`mutating` router，routes.rs:315-324）只写 Web 自有 SQLite / Web 独立 master key：`web-users` CRUD、`api-tokens`、`sessions` 撤销、`notifications/read*`、`settings/wecom`、`auth/mfa/*`。无一触及 Linux 系统。 |
| 0.4-b | 允许「Web 创建申请（纯数据）→ CLI/TUI 执行 → Web 展示结果」 | `web/backend/src/store/notification.rs` | **满足（结构上）** | 通知 inbox 存在且可读（`/api/notifications`），但**没有面向 Linux 系统变更的申请类型**——即该模式尚未被使用。不是违反，是尚未实现。 |

---

## 0.5 远程主机继续保持只读

| # | 要求摘要 | 实现位置 | 判定 | 证据 |
| --- | --- | --- | --- | --- |
| 0.5-a | 只允许 `host.probe` 与 `gpu.summary`；不接受任意 SSH 命令/动态远端参数 | `lib/host_provider.sh:19-20`、`scripts/rl-remote-entry.sh:21-37,44-47` | **满足** | 客户端只从两条**完整常量**中选（provider:19-20 输出固定字面量），**无任何字符串插值**。远端入口 `case` 白名单 + `(($# == 1))` 双重约束，拒绝一切业务参数。 |
| 0.5-b | 不进行远端用户/配额/SMB/防火墙/备份写操作 | 同上 | **满足** | 29 个 Action 中仅 `host.probe`/`gpu.summary` 与远端相关，risk 均为 `safe`；其余 11 个 dangerous 全部与远端无关。 |
| 0.5-c | 不自动分发密钥、不自动修改远端 sudoers | `lib/host_provider.sh:191-198`、`docs/REMOTE_HOSTS.md:52-62` | **满足** | `UserKnownHostsFile` 指向独立文件、`GlobalKnownHostsFile=/dev/null`、`StrictHostKeyChecking=yes`；文档要求管理员带外核验后手工追加公钥。代码中无 known_hosts 写入路径。 |
| 0.5-d | Web 展示远端数据须读本地快照，浏览器请求不得直接触发 SSH | `web/backend/src/http/read_api.rs:157-191` | **满足** | `hosts`/`host_detail`/`host_gpu` 三个 handler 全部只调 `read_with_freshness(&state.snapshots, ...)`。Web 侧唯一的 reqwest 调用点在 WeCom 投递（wecom_api.rs / web_event_delivery.rs / event_spool.rs），与主机探测无关。 |
| 0.5-e | SSH 连接须 BatchMode=yes、禁转发/ProxyCommand/ProxyJump/RemoteCommand/user config | `lib/host_provider.sh:191-198` | **满足** | `-F /dev/null`、`-o BatchMode=yes`、`-o "ProxyCommand=none" -o "ProxyJump=none" -o "RemoteCommand=none" -o RequestTTY=no` 逐条落实 REMOTE_HOSTS.md:107。 |

---

## 0.6 Secret 不进入 Web 可观测面

| # | 要求摘要 | 实现位置 | 判定 | 证据 |
| --- | --- | --- | --- | --- |
| 0.6-a | 快照禁止出现密码/webhook key/TOTP secret/API Token 明文/SSH 私钥 | `lib/snapshot_core.sh:84-101` | **满足** | `snapshot_scrub` 三层：① key 名正则（password/passwd/passphrase/secret/token/webhook/credential/authorization/totp + api_key/private_key/secret_key + session_id）；② value 形态：企微 webhook URL、私钥头、AKIA[0-9A-Z]{16}。 |
| 0.6-b | Web 自身 secret 独立密钥加密存储、只显示脱敏状态、不回显完整值 | `wecom_api.rs:182-183,98-121`、`crypto.rs:115-135` | **满足** | webhook 明文经 `validate_webhook` 后立即 `crypto::encrypt_str`，SQLite 只存 ciphertext；响应固定返回 `webhook_masked`（key=***）+ `webhook_configured` bool。密钥文件侧 `open_existing_private` 强制 `nlink()==1`、属主 == geteuid、mode 强制 0600。 |
| 0.6-c | secret 不进入 URL / argv / 浏览器 localStorage / 错误栈 | `web/frontend/src/App.jsx`、`api.js:107-109` | **满足** | 前端 `localStorage` 只有 `um.language` 与 `um.theme` 两个键（App.jsx:57,182,248,287）；无 `eval`/`new Function`/`dangerouslySetInnerHTML`。Rust 侧 `ApiError::Internal` 经 `telemetry::redact`（error.rs:55-57）。 |
| 0.6-d | 审计记录不含请求值 | `wecom_api.rs:230-239` | **满足** | 注释明示「Only fixed route and result labels enter audit; never include request values」，INSERT 只写固定 route/result 常量与 `auth.user_id`。 |

---

## 0.7 默认拒绝

| # | 要求摘要 | 实现位置 | 判定 | 证据 |
| --- | --- | --- | --- | --- |
| 0.7-a | 新 API 默认拒绝 | `web/backend/src/http/routes.rs:303-349` | **满足** | 路由表为**白名单枚举**：40 条 `.route()` 全部显式列出，未注册路径由 axum 默认 fallback 返回 404。新增 API 必须改代码才能生效。 |
| 0.7-b | 新数据目录默认拒绝 | `store/snapshot.rs:16-28,35-39` | **满足** | `SNAPSHOT_KINDS` 11 项白名单 + `is_allowed_kind()` 双重校验（字符集 + 成员资格）。路径由 `{kind}.json` 派生（snapshot.rs:95），**不接受任何调用方提供的路径**。 |
| 0.7-c | 新日志源默认拒绝 | `http/logs_api.rs:20` | **满足** | `ALLOWED_SOURCES = ["boot","failed-services","auth-failures"]`；不在列的 source 返回 400（logs_api.rs:49-51, 99-101）。 |
| 0.7-d | 新外部网络目标默认拒绝 | `http/wecom_api.rs:45-83` | **满足** | `validate_webhook` 严格校验 scheme/host/port/path/userinfo/fragment/query-key 形态。**但见 `ci-gates.md` G-10：CI 门禁不覆盖出站网络，缺的是门禁不是实现。** |

---

## 附录 A：Web 明确禁止能力清单

实现侧结论：`check_web_security.sh` 的禁止 token 覆盖 33 个词（line 24-30），另加 2 个进程派生模式（line 33-36）。逐项核对**门禁未覆盖**的条目：

| 附录 A 条目 | 是否有其他防线 | 说明 |
| --- | --- | --- |
| `passwd` | 无 | 门禁含 `chpasswd` 但**不含 `passwd`**。当前代码无调用，但回归无门禁。 |
| `apt` / `dpkg` | 无 | 门禁完全未收录。 |
| sysctl write / cgroup write / /proc write / /sys write | 部分 | 依赖 `ProtectSystem=strict` + `ProtectKernelTunables` + `ProtectKernelModules` + `ProtectControlGroups`（service:47-52）；但门禁无 token 约束。 |
| Docker / containerd / systemd 私有 socket | 有 | `umweb.service:65` `InaccessiblePaths` + test:63-73 断言。 |
 arbitrary URL fetch | 部分 | `reqwest` 是正式依赖（Cargo.toml:61）。实现侧由 `validate_webhook` 严格收敛到唯一 host，**但门禁无任何出站网络约束**——若有人新增对用户输入的 reqwest 调用，CI 不会拦。 |
| arbitrary file reader | 有 | 快照读取经 kind 白名单 + `O_NOFOLLOW` + 符号链接分量逐级检查（snapshot.rs:210-250）。 |
| arbitrary log path | 有 | `ALLOWED_SOURCES` 三项定长白名单。 |
| arbitrary shell / command | 有 | `Command::new` / `std::process::Command` 全量禁止。 |
| arbitrary SSH command | 有 | 两条完整常量远端命令。 |

**附录 A 小结：无「违反」项**（当前代码不触碰任何禁止能力）。缺的是 **CI 门禁对 6 类条目的覆盖**（passwd、apt/dpkg、sysctl、/proc 与 /sys 写、出站网络），判为 **P2**（见 `ci-gates.md` G-10）。

---

## docs/WEB_SECURITY_BOUNDARY.md 专项

| # | 要求 | 实现位置 | 判定 | 证据 |
| --- | --- | --- | --- | --- |
| B-1 | 快照落盘 root:umweb 0640、目录 0750 | `lib/snapshot_core.sh:22-24`、`umweb.service:34-36` | **无法验证（U4）** | `SNAPSHOT_OWNER=root` / `SNAPSHOT_GROUP=umweb` 且注释明示「仅 EUID=0 时生效」；unit 有 `ReadOnlyPaths`。实际 mode 需目标机 `stat`。 |
| B-2 | Web 不能写快照 | `store/snapshot.rs` 全文 | **满足** | 读取层只使用 `OpenOptions::new().read(true)`（snapshot.rs:246-249），**全模块无任何 write/create/File::create 调用**。 |
| B-3 | 原子写（temp + fsync + rename）+ `.` 前缀命名 | `lib/snapshot_core.sh` `snapshot_atomic_install` | **满足（测试覆盖）** | `tests/test_snapshot.sh` 25 例覆盖 [7][11]（原子写、0640、无残留临时文件）。本次回归中该套件全绿。 |
| B-4 | 路径穿越 kind 被拒 | `snapshot.rs:35-39,95,225` | **满足（测试覆盖）** | `is_allowed_kind` + `path_has_no_symlink_components` 对 `Component::ParentDir` 直接 return false。 |
| B-5 | 未知 `schema_version` 必须拒识 | `snapshot.rs:124-138` | **满足** | 信封绑定 6 项元数据（schema_version/protocol/kind/generator/source 字符集/threshold/RFC3339），任一不符即返回 None（不可区分「缺失」与「非法」，前端统一呈现 stale）。 |
| B-6 | Web 不提供 `POST /api/snapshots/refresh` | 路由表 | **满足** | 40 条注册路由中无此路径；`api_contract.rs:70` 显式断言 404/405。 |
| B-7 | 审计快照不含 details 原文 | `docs/WEB_SECURITY_BOUNDARY.md:191-193`、`audit_api.rs:30-41,129` | **满足** | `read_audit_items` 只取 `data.recent`；CSV 导出字段固定为 timestamp,user,action,target,result。 |
| B-8 | 采集器由 root 经 systemd timer 运行 | `etc/systemd/system/um-snapshot.service`/`.timer` | **无法验证（U5）** | 配置文件齐备；实际运行状态需目标主机。 |

---

## docs/REMOTE_HOSTS.md 专项

见 0.5-a ~ 0.5-e，五项全部**满足**。补充核对：

| # | 要求 | 实现位置 | 判定 | 证据 |
| --- | --- | --- | --- | --- |
| R-1 | `data/hosts.conf` 必须是普通文件、非符号链接、组/其他不可写 | `lib/host_inventory.sh` | **满足** | 运行时检查大小、ACL 与父目录链（REMOTE_HOSTS.md:38）。另 `.gitignore:82` 已忽略 `data/hosts.conf`。 |
| R-2 | `address` 不接受 SSH alias、`@`、空白、前导 `-` 或选项形态 | `lib/host_inventory.sh` | **满足** | 地址字符集校验（前导 `-` 拒绝是防 `-oProxyCommand` 类注入的关键）。 |
| R-3 | 远端 stdout 须经协议校验，异常标记 PROTOCOL_ERROR，**不作为 shell 代码执行** | `lib/host_provider.sh` | **满足** | 校验版本、字段、重复键、控制字符、行数与总字节；REMOTE_HOSTS.md:91 显式要求「不要使用 source 或 eval 解析输出」。 |
| R-4 | 远端入口以 umask 077、固定 PATH、unset CDPATH ENV BASH_ENV GLOBIGNORE 启动 | `scripts/rl-remote-entry.sh:5-8` | **满足** | 逐条落实（LC_ALL=C + 固定 PATH + 4 个环境注入面 unset）。 |

---

## 汇总

| 判定 | 数量 |
| --- | --- |
| 满足 | 27 |
| 部分满足 | 2（0.1-a = P1，0.3-d = P3） |
| **违反** | **0** |
| 无法验证 | 5（U1、U2、U3、U4、U5） |

**黄金标准（Web 永不获得 root / sudo / capability）在代码层与配置层未发现任何违反项。** 唯一的 P1 是纵深防御缺口：`umweb` 的非特权性完全依赖 systemd unit，代码层没有 geteuid()==0 拒绝启动的兜底。
