# Web Security Boundary（P0 — Snapshot Contract 与 Web 非特权边界）

> 状态：P0 基线。本文件是 Web 控制台的**安全边界权威说明**，与 `plan.md` 的
> 最高级硬约束同级。任何 Web 相关 PR 若与本文件冲突，以**安全边界优先**处理：
> 要么放弃该功能，要么走 `plan.md` 第 14 节的架构冲突流程（停止实现、输出冲突点 /
> 原因 / 风险 / 替代设计 / 需要修改的 ADR-plan 条目），等待架构决定。

---

## 1. 定位：Web 是观察面，不是特权面

Web 服务进程 `umweb` 的定位：

> **非特权观察与应用管理控制面。**

它**不是**“浏览器版 root 运维终端”。整个 Web 化的最终原则：

```text
Web 可以「看」和「管 Web 自己」，但不能「以超级管理员身份改 Linux」。
```

两类控制面严格分离：

| 控制面 | 运行身份 | 能力 |
| --- | --- | --- |
| CLI / TUI 管理面 | 受信任管理员（可 root / sudo） | 用户、配额、资源、SMB 写、备份、防火墙、systemd、sudoers 等**全部**系统变更 |
| Web 非特权控制面 | `umweb`（普通用户） | 只读观测、检索、报表、审计、通知、Web 自身身份与配置 |

当功能需要 root 时，方案永远是：

```text
Web 展示/创建申请（纯数据） → 管理员在 CLI/TUI 执行 → Web 展示结果
```

而不是给 Web 增加特权。

---

## 2. `umweb` 进程硬约束

`umweb` **绝不**拥有、代理、继承或间接获得 root / sudo / Linux capability：

- 不以 root 启动；
- 不加入 `sudo` / `wheel` / `admin` / `useradm` / `docker` / `lxd` 等特权组；
- 不持有任何 `umweb` 相关 sudoers 授权；
- 不执行 `sudo` / `su` / `pkexec` / `doas`；
- 不依赖 setuid/setgid helper；
- 不持有 `CAP_SETUID`/`CAP_SETGID`/`CAP_DAC_OVERRIDE`/`CAP_SYS_ADMIN`/`CAP_SYS_PTRACE`/`CAP_NET_ADMIN` 等 capability；
- 不访问 Docker/containerd/Podman/systemd 私有 socket、D-Bus 特权接口；
- **不实现 `Web → sudo → rl-web-exec → priv_exec` 特权桥**；不新增 `rl-web-exec`。

安全目标：**即使 Web 被完全攻破，攻击者最多获得 `umweb` 普通用户权限，而不是 root。**

systemd 沙箱要求（`umweb.service`，P6 落地时逐项验证，放宽须说明原因）：

```ini
NoNewPrivileges=yes
CapabilityBoundingSet=
AmbientCapabilities=
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
InaccessiblePaths=-/var/run/docker.sock -/run/docker.sock -/run/containerd/containerd.sock -/run/podman/podman.sock -/run/systemd/private -/run/dbus/system_bus_socket
ReadWritePaths=/var/lib/user-manager-web
ReadOnlyPaths=/var/lib/user-manager-web/snapshots
ReadOnlyPaths=/var/lib/user-manager-web/events
```

---

## 3. 数据来源：只读快照层（P0 核心）

Web **不**在 HTTP 请求里实时 fork Bash / 执行系统命令。它读取**可信采集器**预先生成的
结构化、脱敏、版本化、原子落盘的只读快照。

### 3.1 数据流

```text
可信采集器（root，systemd timer / 受信 CLI）
  → 只读 Core 查询（get_managed_usernames / get_user_quota_info / ...）
  → 脱敏信封（snapshot_scrub）
  → schema 校验
  → 原子写入 snapshot store（temp + fsync + rename）
                                 │
                    root:umweb 0640，目录 0750，umweb 只读
                                 │
   (P1+) Rust API 只读 Snapshot ─┘→ Ant Design Pro 前端
```

- 采集器：仓库 `scripts/rl-snapshot.sh`，加载 `lib/bootstrap.sh` 的 `snapshot` profile
  （只加载只读 Core，不加载 `privilege.sh` / 写模块），调用 `lib/snapshot_core.sh`。
- 采集器由 **root** 通过 systemd timer 运行（见 `etc/systemd/system/um-snapshot.{service,timer}` 示例），
  以便读取 `repquota`/`pdbedit` 等需要 root 的只读信息。
- Web 服务 `umweb` **不运行采集器**，只读其产物。

### 3.2 可安全暴露的只读数据盘点

| 快照文件 | kind | Web capability | 数据来源（只读） | fresh 阈值 |
| --- | --- | --- | --- | --- |
| `users.json` | `users` | `users.read` | `get_managed_usernames` + `get_user_home` + `get_user_mountpoint` | 300s |
| `quota.json` | `quota` | `quota.read` | `get_user_quota_info`（used/limit 字节） | 300s |
| `resources.json` | `resources` | `resource.read` | `get_current_resource_limits`（**仅配置值**，只显不改） | 60s |
| `smb.json` | `smb` | `smb.read` | `smb_is_available` + `smb_show_status` + `smb_list_users` + `smb_share_list` + `smb_include_status` | 300s |
| `hosts.json` | `hosts` | `hosts.read` | `host_probe_snapshot_kv`（本机；`source=local`） | 120s |
| `gpu.json` | `gpu` | `gpu.read` | `gpu_snapshot_kv` | 120s |
| `system.json` | `system` | `dashboard.read` | `/proc`、`uname`、`hostname`、`nproc` 只读汇总 | 60s |
| `audit-summary.json` | `audit-summary` | `audit.read` | 审计日志结构化列（**不含 details 原文**） | 30s |
| `manifest.json` | `manifest` | 任意已认证 | 各快照 fresh/absent 元数据 + overall 状态 | 120s |

以上所有数据源均为**只读**。没有任何采集函数执行系统写操作。

### 3.3 Snapshot 信封 Schema（版本化）

每个 `*.json` 都是一个信封：

```json
{
  "schema_version": 1,
  "protocol": "user-manager-snapshot-v1",
  "kind": "users",
  "generator": "user-manager",
  "source": "local",
  "generated_at": "2026-09-21T15:29:30Z",
  "threshold_seconds": 300,
  "data": { }
}
```

- `schema_version`：不兼容字段/语义变更时递增；Web reader 必须拒识未知版本。
- `generated_at`：RFC3339 UTC；freshness 由此计算。
- `source`：`local` 或多主机场景的 `host_id`（进入快照前经 `snapshot_safe_token` 清洗）。
- `threshold_seconds`：该快照的新鲜度阈值，随信封下发，reader 无需另配。

信封由 `snapshot_build_envelope` 生成，落盘前必须通过 `snapshot_validate_json`
（校验字段/类型/版本），不通过则拒绝落盘。

### 3.4 原子生成

`snapshot_atomic_install`：

```text
mktemp 同目录临时文件 → 写入信封 → chmod 0640 → chown root:umweb(仅 root) → fsync 临时文件
→ rename(原子替换) → fsync 目录
```

- 临时文件与目标同目录（同文件系统），`rename` 保证读者永远看到旧或新完整文件，不会读到半写文件。
- 临时文件以 `.` 前缀命名，测试/CI 会用 `find -name '.*.json.*'` 断言无残留。

### 3.5 文件权限与目录

```text
/var/lib/user-manager-web/snapshots    root:umweb  0750   （目录）
/var/lib/user-manager-web/snapshots/*  root:umweb  0640   （快照，umweb 只读）
/var/lib/user-manager-web/events       root:umweb  0750   （不可变 CLI/TUI 事件 spool，umweb 只读）
/var/lib/user-manager-web/events/*.json root:umweb 0640   （单个事件文件，umweb 只读）
```

- 采集器（root）写入并 `chown root:umweb`；`umweb` 只读，**不能写**快照。
- `etc/tmpfiles.d/user-manager-web.conf` 在 Web 服务启动前创建 root-owned event spool；CLI/TUI 只追加原子 UUID JSON 文件，Web 校验并去重后写入自己的 SQLite，不删除或修改 spool 文件。
- 服务单元显式屏蔽 Docker、containerd、Podman、systemd private 和 D-Bus 控制 socket。`AF_UNIX` 仍用于日志通道，但不能连接这些特权路径。
- `SNAPSHOT_DIR` 默认 `/var/lib/user-manager-web/snapshots`，可用
  `USER_MANAGER_SNAPSHOT_DIR` 覆盖（开发/测试）。只需**文件名安全**的 kind
  （`^[a-z][a-z-]*$`），路径穿越 kind 直接被 `snapshot_atomic_install` 拒绝。

### 3.6 Freshness

- 年龄在**读取时**计算：`age_seconds = now - generated_at`，不在生成时固化，避免旧数据被伪装成实时。
- `fresh := age_seconds <= threshold_seconds`。缺失/过期必须对前端体现为 `stale`/`unavailable`，不能伪装实时。
- `manifest.json` 用 `overall ∈ {fresh, partial, stale, unavailable}` 支撑前端全局“数据状态”指示器。
- Web **不**在首期提供 `POST /api/snapshots/refresh`；刷新由 systemd timer / CLI / 采集器控制。

---

## 4. Secret 脱敏（scrub）

所有进入快照的字符串落盘前经 `snapshot_scrub`（jq 递归）：

- **按 key 名**：命中 `password|passwd|passphrase|secret|token|webhook|credential|
  authorization|totp|api_key|private_key|session_id` 等的字段值一律替换为 `***REDACTED***`。
- **按 value 形态**：
  - 企业微信 webhook URL（`https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=...`）→ `***REDACTED_WEBHOOK***`；
  - 私钥头（`-----BEGIN ... PRIVATE KEY-----`）→ `***REDACTED_KEY***`；
  - AWS key 形态（`AKIA[0-9A-Z]{16}`）→ `***REDACTED_KEY***`。

审计快照只抽取结构化列（`timestamp|user|action|target|result`），**不包含** details 原文
（其含 CWD/TTY/source_ip 等上下文，且用户提供的 details 可能含敏感信息）。CLI/TUI 事件
如需进入 Web，走不可变 event spool（见 `plan.md` 10.7），Web 只读、不去重写。

快照**禁止**出现：Linux/SMB/SMTP 密码、企业微信 webhook 完整 key、TOTP secret、
API Token 明文、SSH 私钥。

---

## 5. Web Capability Allowlist（默认拒绝）

Web 权限**不等于** `action_registry.sh` 的 `risk=safe`，也不映射 Linux ACL。Web 维护
**独立的、默认拒绝**的 capability allowlist。未显式列出的一律拒绝。

读能力：`dashboard.read` `users.read` `quota.read` `resource.read` `smb.read`
`logs.read`(allowlist) `audit.read` `hosts.read` `gpu.read` `reports.read` `notifications.read`

应用管理能力：`notifications.manage` `web_users.manage` `sessions.manage`
`tokens.manage` `wecom.manage` `settings.manage`

角色（`viewer` / `operator` / `web_admin`）只是上述 capability 的集合；不存在
`owner`/`root`/`superadmin`。前端 access 仅用于 UX，真正授权一律在后端。

---

## 6. 危险 API 必须“不存在”（而非 403）

以下接口在设计上**根本不存在**，CI 用契约测试断言返回 `404/405`，而不是依赖 RBAC 返回 403：

```text
POST   /api/users
DELETE /api/users/:username
PATCH  /api/users/:username
PUT    /api/users/:username/quota
PUT    /api/users/:username/resources
POST   /api/users/:username/runtime-limit
POST   /api/smb/password
POST   /api/smb/users/:u/enable
POST   /api/smb/users/:u/disable
DELETE /api/smb/users/:u
POST   /api/smb/shares
DELETE /api/smb/shares/:name
POST   /api/hosts/:id/exec
POST   /api/hosts/:id/probe
POST   /api/system/*
POST   /api/snapshots/refresh
任意 shell / command / SSH / file path / log path / URL fetch
```

Web 只保留只读 GET（users/quota/resource/smb/hosts/gpu/system/audit/logs-allowlist/reports）
与 Web 自身管理（auth/sessions/web-users/api-tokens/settings-wecom/notifications）。

---

## 7. REMOTE_HOSTS 边界（不变）

继承 `docs/REMOTE_HOSTS.md`：仍只允许 `host.probe` / `gpu.summary`，不扩展为任意 SSH。
Web 不直接 SSH、不因页面刷新触发 SSH；远端数据由采集器 / timer 生成快照后，Web 只读。
`test_snapshot.sh` 断言远端入口仍拒绝写 action 与注入形态，锁定该边界不回退。

---

## 8. 企业微信（P4 落地的边界预声明）

企业微信是 Web **应用级配置**，可由 `web_admin` 管理，不需要 root。边界预声明（实现见 P4）：

- 仅允许 `https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=<KEY>`（URL parser 校验，
  非字符串 contains）；
- 禁用 redirect；设置连接/请求 timeout；响应体大小上限；
- webhook 用 Web 独立 secret key 加密存储，**永不完整回显**，不进日志/审计/URL/argv；
- `errcode == 0` 才算业务成功；test API 用固定模板，不接受自定义 message；
- Web 不读 CLI 权限域主密钥。

---

## 9. 部署与 sudoers

- 采集器 `um-snapshot.service`（root）→ 写快照（root:umweb 0640）。
- Web `umweb.service`（umweb）→ 只读快照 + 只写自己的 DB/secrets（`/var/lib/user-manager-web`）。
- **不得**为 `umweb` 新增任何 sudoers 授权；`sudo -l -U umweb` 必须为空。
- 本仓库不得新增 `umweb NOPASSWD` / `%umweb` / `user-manager-web` sudoers 文件。

---

## 10. 验收与测试映射

| 验收项 | 验证 |
| --- | --- |
| 快照不含 secret | `test_snapshot.sh` [5][12]：scrub 断言、输出无私钥/明文 |
| schema 版本化 + 校验 | `test_snapshot.sh` [3][4][6] |
| 原子写、0640、无残留临时文件 | `test_snapshot.sh` [7][11] |
| 路径穿越 kind 被拒 | `test_snapshot.sh` [8] |
| freshness fresh/stale/absent | `test_snapshot.sh` [9] |
| manifest + overall | `test_snapshot.sh` [10] |
| 采集器无特权写/提权命令 | `test_snapshot.sh` [2]（去注释扫描） |
| `umweb` 只读快照 | 权限模型（root:umweb 0640）+ P6 部署门禁断言 |
| REMOTE_HOSTS 仅 host.probe/gpu.summary | `test_snapshot.sh` [16] + `test_remote_cli.sh` |
| 不新增 Web sudoers | 部署门禁（P6）+ 人工核对 `etc/sudoers.d/` |

> `scripts/check_sensitive_files.sh` 与 CI security job 继续在提交面阻断私钥/密钥入库。

---

## 11. 新增快照类型的流程（防回归）

1. 判断数据是否只读、是否需要 root；需要写操作的一律不回 Web。
2. 在采集器新增 `collect_<kind>`（只读 Core，输出 JSON 对象）。
3. 在 `snapshot_kind_threshold` 增加 kind 与阈值；按需加入 `snapshot_all_kinds`。
4. 在 `test_snapshot.sh` 增补：schema 校验、scrub、fresh、无 secret 断言。
5. 涉及不兼容字段变更时递增 `SNAPSHOT_SCHEMA_VERSION`，并在本节记录。
6. 若需暴露新能力，先加 Web capability allowlist（默认拒绝），再开 API，再上前端；
   危险接口仍坚持“不存在”。
