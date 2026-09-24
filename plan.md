# Web 化实施规划：非特权 Rust 控制台 + Ant Design Pro 6.0

> 初始审计基线：`24066159e79514d42686a54eb50d01d35086f212`（2026-09-23）。2026-09-24 状态复核时，`main` 工作树 HEAD 为 `0f6bee5`，并含尚未提交的实现改动；当前改动是否已推送或发布未获验证。
>
> 目标：在不重写现有 Bash 业务核心、不扩大系统特权面的前提下，为「Linux 多用户运维管理系统」增加一套 Web 控制台（Rust API + Ant Design Pro 6.0）。
>
> **最高级硬约束：Web 面板永远不拥有、代理、继承或间接获得 root / sudo / Linux capability 等超级管理员权限。**
> 所有需要超级管理员权限的系统变更，仅允许受信任管理员通过本机 CLI/TUI/受控运维通道执行。
>
> Web 的定位是：**认证、展示、查询、审计、通知、非特权配置与只读观测**；不是“浏览器版 root shell”，也不是现有 CLI/TUI 的无差别远程映射。

---

## 目录

- [0. 不可违反的架构约束](#0-不可违反的架构约束)
- [1. 现状架构与真实能力基线](#1-现状架构与真实能力基线)
- [2. Web 化目标与非目标](#2-web-化目标与非目标)
- [3. 威胁模型与信任边界](#3-威胁模型与信任边界)
- [4. 技术选型](#4-技术选型)
- [5. 总体架构](#5-总体架构)
- [6. 权限模型与能力边界](#6-权限模型与能力边界)
- [7. Web 数据来源：只读快照层](#7-web-数据来源只读快照层)
- [8. API 设计](#8-api-设计)
- [9. 前端信息架构与权限](#9-前端信息架构与权限)
- [10. 企业微信与通知配置](#10-企业微信与通知配置)
- [11. 认证、会话与 CSRF](#11-认证会话与-csrf)
- [12. 部署与 systemd 沙箱](#12-部署与-systemd-沙箱)
- [13. 日志、审计与隐私](#13-日志审计与隐私)
- [14. CI/CD 硬门禁](#14-cicd-硬门禁)
- [15. 分阶段实施路线](#15-分阶段实施路线)
- [16. 风险、边界与验收](#16-风险边界与验收)
- [17. 功能全景索引](#17-功能全景索引)
- [附录 A：Web 明确禁止能力清单](#附录-aweb-明确禁止能力清单)
- [附录 B：与现有模块的关系](#附录-b与现有模块的关系)

---

# 0. 不可违反的架构约束

本节属于工程级**硬约束**。任何 PR、设计、依赖或功能若违反其中任意一条，应直接判定为“不符合架构”，不得以“已经做了 RBAC / 二次确认 / 审批流”为理由放行。

## 0.1 Web 进程绝不提权

Web 后端进程 `umweb`：

- **不得以 root 身份启动**；
- **不得加入 `sudo` / `wheel` / `admin` / `useradm` / `docker` / `lxd` 等特权组**；
- **不得存在任何针对 `umweb` 的 sudoers 授权**；
- **不得执行 `sudo`、`su`、`pkexec`、`doas`**；
- **不得依赖 setuid/setgid helper**；
- **不得拥有 `CAP_SETUID`、`CAP_SETGID`、`CAP_DAC_OVERRIDE`、`CAP_SYS_ADMIN`、`CAP_SYS_PTRACE`、`CAP_NET_ADMIN` 等 Linux capabilities**；
- systemd 必须配置 `NoNewPrivileges=yes`；
- `CapabilityBoundingSet=` 与 `AmbientCapabilities=` 必须为空；
- 不允许通过 Docker/containerd/Podman/systemd 私有 socket、D-Bus 特权接口或其他本地 IPC 间接获得 root 能力。

> **安全目标：即使 Web 服务被完全攻破，攻击者最多获得 `umweb` 普通用户权限，而不是 root。**

## 0.2 取消 Web 特权执行桥

原方案：

```text
Web → sudo -n rl-web-exec → action_run → priv_exec → Linux
```

**取消。不得实现。**

Web 后端不得直接调用：

- `action_run`
- `rl_action_run`
- `user_manager.sh`
- `tui_manager.sh`
- `scripts/rl-user-create.sh`
- `scripts/rl-user-quota.sh --set`
- `scripts/rl-user-resource.sh --set|--runtime-set|--runtime-reset|--remove`
- SMB 写操作
- `scripts/rl-backup-run.sh`
- 任意会进入 `priv_exec` 的写操作

## 0.3 `risk=safe` 不等于 `Web-safe`

`action_registry.sh` 的 `risk=safe` 只表示现有 CLI/TUI Action 的业务风险标签，不能自动转换为 Web 授权。

Web 必须维护独立、默认拒绝的 capability allowlist：

```toml
[capabilities]
dashboard.read = true
users.read = true
quota.read = true
resource.read = true
smb.read = true
audit.read = true
logs.read = true
hosts.read = true
gpu.read = true
reports.read = true
```

**未显式列出的能力一律拒绝。**

禁止：

```rust
if action.risk == "safe" {
    allow_web();
}
```

## 0.4 Web 不提供“审批后提权”

审批流不能成为提权后门。

禁止：

```text
浏览器提交 root 操作
→ 第二人 approve
→ Web 后端 sudo 执行
```

允许：

```text
Web 创建变更申请（纯数据）
→ 管理员在 CLI/TUI 查看申请
→ CLI/TUI 再确认并执行
→ Web 只展示结果
```

即：**审批可以管理意图，但不能让 Web 获得执行特权。**

## 0.5 远程主机继续保持只读

继承 `docs/REMOTE_HOSTS.md` 当前边界：

- 只允许 `host.probe`；
- 只允许 `gpu.summary`；
- 不接受任意 SSH 命令；
- 不接受动态远端命令参数；
- 不进行远端用户/配额/SMB/防火墙/备份写操作；
- 不自动分发密钥；
- 不自动修改远端 sudoers。

Web 展示远端数据时，优先读取**本地快照**，不得由浏览器请求直接触发 SSH。

## 0.6 Secret 不进入 Web 可观测面

Web API、日志、审计、URL、argv、错误栈、浏览器 localStorage 中禁止出现：

- Linux 用户密码；
- SMB 密码；
- SMTP 密码；
- 企业微信 webhook 完整 key；
- TOTP secret；
- API Token 明文；
- SSH 私钥。

任何 secret 必须满足：

1. 仅通过 HTTPS 请求体传入；
2. 服务端不记录请求体；
3. 不回显完整值；
4. 持久化时使用独立密钥加密或单向 hash；
5. UI 只显示脱敏状态；
6. 不进入 shell argv。

## 0.7 默认拒绝

任何新 API、页面、WebSocket/SSE 频道、数据目录、外部网络目标、Action 映射，默认均为**拒绝**，只有显式加入 allowlist 才开放。

---

# 1. 现状架构与真实能力基线

基线来自当前 `main`：

```text
24066159e79514d42686a54eb50d01d35086f212
```

## 1.1 当前技术形态

项目仍以 Bash/Shell 为核心，主要面向 Ubuntu/Debian：

```text
入口层
  ↓
bootstrap.sh
  ↓
UI / Controller
  ↓
action_registry.sh
  ↓
Core
  ↓
access_control / privilege / env
  ↓
Linux 系统命令
```

主要入口：

- `run.sh`
- `user_manager.sh`
- `tui_manager.sh`
- `scripts/rl-*.sh`

## 1.2 当前 Action Registry

当前 `action_registry.sh` 已实际注册：

### 日志与 systemd 只读

- `logs.boot`
- `logs.failed_services`
- `logs.service_recent`
- `logs.boot_error_diff`
- `logs.system_file_tail`
- `logs.auth_failures`
- `system.timers.list`
- `system.timers.logs`

### 主机与 GPU

- `host.probe`
- `gpu.summary`

### 用户

- `users.list`
- `users.create`
- `users.quota`
- `users.resource`

### 邮件、备份与审计

- `mail.test`
- `backup.run`
- `audit.query`
- `audit.view`

### SMB

只读：

- `smb.status`
- `smb.list`
- `smb.show`
- `smb.shares`

写操作：

- `smb.password`
- `smb.disable`
- `smb.enable`
- `smb.remove`
- `smb.share.add`
- `smb.share.remove`
- `smb.include`

## 1.3 当前 `risk` 的语义限制

Registry 保存：

```text
id / label / group / handler / requires / modes / risk
```

但 `action_run()` 当前不会因为 `risk=dangerous` 自动：

- 二次确认；
- 强制审计 reason；
- 阻止非交互执行；
- 阻止 Web 调用。

因此 Web 不得依赖 `risk` 字段作为唯一安全边界。

## 1.4 当前 SSH 只读层

最新代码已提供：

```text
host_inventory
host_provider
execution_plan
host_probe_core
scripts/rl-hosts.sh
scripts/rl-remote-entry.sh
docs/REMOTE_HOSTS.md
```

整体结构：

```text
Inventory
  ↓
Execution Plan
  ↓
Local / SSH Provider
  ↓
固定白名单远端入口
  ↓
host.probe / gpu.summary
```

这一层可作为未来 Web 多主机仪表盘的数据来源，但不能扩展为浏览器任意 SSH。

## 1.5 当前 SMB 管理能力

已具备：

- SMB 用户查询；
- SMB 状态；
- SMB 密码设置；
- enable/disable/remove；
- 共享列举；
- 共享新增/删除；
- Samba include 管理。

Web 仅消费只读视图，不开放 SMB 写操作。

## 1.6 当前企业微信能力

`lib/rl_wecom_bot_sender.sh` 当前提供：

- enabled；
- dry-run；
- webhook 格式校验；
- secret 脱敏；
- event allowlist；
- `rl_wecom_bot_send_text`；
- `rl_notify_send`。

Web 可以管理通知配置，因为其属于**应用级配置**，不需要 Linux 超级管理员权限。

---

# 2. Web 化目标与非目标

## 2.1 目标

首期目标：

1. Web 身份认证；
2. Web 用户与角色管理；
3. Dashboard；
4. 托管用户只读视图；
5. quota/resource 只读视图；
6. SMB 只读视图；
7. 审计只读查询；
8. 安全筛选后的日志视图；
9. 主机/GPU 只读仪表盘；
10. 企业微信通知配置；
11. Web 会话管理；
12. Web API Token 管理；
13. 通知中心；
14. 报表浏览；
15. 主题/i18n。

## 2.2 明确非目标

Web **不实现**：

- Linux 用户创建/删除/重命名；
- Linux 用户密码修改；
- quota 修改；
- CPU/内存限制修改；
- runtime cgroup 修改；
- SMB 密码修改；
- SMB enable/disable/remove；
- SMB share add/remove；
- Samba include 修改；
- 防火墙修改；
- DNS 修改；
- systemd unit/timer 修改；
- 系统软件包维护；
- sudoers 修改；
- root 目标操作；
- 备份恢复；
- 任意命令执行；
- 任意 shell；
- 任意 SSH；
- GPU 调度；
- 远端写操作。

## 2.3 Web 与 CLI/TUI 职责

| 能力 | Web | CLI/TUI |
| --- | --- | --- |
| 用户查看 | ✅ | ✅ |
| 用户创建/删除 | ❌ | ✅ |
| quota 查看 | ✅ | ✅ |
| quota 修改 | ❌ | ✅ |
| resource 查看 | ✅ | ✅ |
| resource 修改 | ❌ | ✅ |
| SMB 查看 | ✅ | ✅ |
| SMB 写操作 | ❌ | ✅ |
| 日志查看 | ✅（受限） | ✅ |
| 审计查看 | ✅ | ✅ |
| 主机/GPU 查看 | ✅ | ✅ |
| 远端写操作 | ❌ | ❌（当前架构） |
| 企业微信配置 | ✅ | ✅/配置文件 |
| root/sudo 操作 | ❌ | ✅（受控） |

---

# 3. 威胁模型与信任边界

## 3.1 主要威胁

假设：

- Web 登录凭据可能被撞库；
- session 可能泄露；
- 前端可能存在 XSS；
- Rust 依赖可能存在漏洞；
- 反向代理可能配置错误；
- Web 进程可能最终被攻击者拿下；
- Web 用户可能恶意尝试横向读取系统数据；
- 日志中可能包含敏感信息；
- 企业微信 webhook 可能形成 SSRF/外联风险；
- 快照数据可能被篡改。

## 3.2 安全目标

即使 Web 服务被完全攻破：

```text
攻击者 ≈ umweb
```

而不是：

```text
攻击者 ≈ root
```

因此必须保证 `umweb`：

```text
无 sudo
无 capability
无 /etc 写权限
无 /root 访问
无其他用户 home 访问
无 Docker/containerd socket
无 systemd 控制 socket
无 SSH 私钥
无特权 Unix socket
```

---

# 4. 技术选型

| 层 | 选型 |
| --- | --- |
| 后端 | Rust + axum + tokio |
| 序列化 | serde / serde_json |
| DB | SQLite（首期） |
| 认证 | 服务端 Session |
| 密码哈希 | Argon2id |
| MFA | TOTP |
| API | REST + OpenAPI |
| 实时通知 | SSE 优先，必要时 WebSocket |
| 前端 | Ant Design Pro 6.0 + Umi 4 + antd 6 + TypeScript |
| 反代 | Nginx / Caddy |
| 服务管理 | systemd |
| 系统数据 | Snapshot Store |
| 多主机数据 | CLI/Timer 采集 → Snapshot |

## 4.1 浏览器会话首期不用无状态 JWT

优先：

```text
随机 Session ID
+
服务端 session store
+
HttpOnly Cookie
```

便于：

- 强制注销；
- 角色即时生效；
- MFA 后轮换；
- 安全事件下全量 revoke。

---

# 5. 总体架构

## 5.1 双控制面

```text
                    ┌──────────────────────────┐
                    │     CLI / TUI 管理面      │
                    │  trusted administrator   │
                    └────────────┬─────────────┘
                                 │
                        privileged operations
                                 │
                                 ▼
                action_registry / *_core / priv_exec
                                 │
                                 ▼
                              Linux
                                 │
                    定时/事件生成只读快照
                                 │
                                 ▼
┌───────────┐ HTTPS  ┌────────────────────────────┐
│ Browser   │───────▶│ Rust Web Service (umweb)   │
└───────────┘        │                            │
                     │ Auth / Session / RBAC      │
                     │ Snapshot Reader            │
                     │ Web-only Config            │
                     │ Notification               │
                     │ Web Audit                  │
                     └─────────────┬──────────────┘
                                   │
                                   ▼
                       Web DB / Snapshot Store

Web Service:
  X sudo
  X root helper
  X privileged action bridge
  X arbitrary shell
  X arbitrary SSH
```

### A. 特权管理面：CLI/TUI

负责：

- OS 用户；
- quota；
- resource；
- SMB 写；
- backup restore；
- firewall；
- systemd；
- sudoers；
- 系统维护。

### B. Web 非特权控制面

负责：

- 查看；
- 检索；
- 统计；
- Dashboard；
- 审计；
- 通知；
- Web 自身身份体系；
- Web 自身配置。

两者不能合并。

---

# 6. 权限模型与能力边界

## 6.1 Web 角色不映射 Linux ACL

删除原方案：

```text
viewer = guest
operator = user
admin = admin
owner = root
```

Web Role 与 Linux ACL 完全解耦。

推荐角色：

```text
viewer
operator
web_admin
```

不提供：

```text
owner
root
superadmin
```

## 6.2 角色能力

### viewer

- Dashboard；
- users/quota/resource read；
- SMB read；
- hosts/GPU read；
- 基础日志 read；
- report read。

### operator

在 viewer 基础上：

- audit query；
- notification inbox；
- report export；
- 标记通知已读。

不增加任何 Linux 写权限。

### web_admin

在 operator 基础上：

- Web 用户管理；
- Web role 管理；
- Session revoke；
- API Token 管理；
- 企业微信配置；
- Web 应用配置；
- Web 安全设置。

**web_admin 仍然只是应用管理员，不是 Linux admin。**

## 6.3 Capability 模型

后端判断 capability，不直接散落判断角色字符串：

```text
dashboard.read
users.read
quota.read
resource.read
smb.read
logs.read
audit.read
hosts.read
gpu.read
reports.read
notifications.read
notifications.manage
web_users.manage
sessions.manage
tokens.manage
wecom.manage
settings.manage
```

角色仅是 capability 集合。

## 6.4 Web 端没有 dangerous action

Web API 定义中不应该存在 Linux 特权 `dangerous` action。

> 如果某 API 必须依赖 root 才能完成，那么这个 API 从设计上就不应该存在于 Web。

---

# 7. Web 数据来源：只读快照层

## 7.1 设计原则

不推荐每个 GET 都：

```text
HTTP → Rust → Bash → system command
```

原因：

- 增加 shell/argv/env 注入面；
- 高并发 fork；
- 超时/僵尸进程；
- 权限边界模糊；
- Web RCE 后更容易枚举系统。

推荐：

```text
可信本地采集器
→ 原子生成脱敏快照
→ Web 只读快照
```

## 7.2 Snapshot Store

建议：

```text
/var/lib/user-manager-web/snapshots/
├── users.json
├── quota.json
├── resources.json
├── smb.json
├── hosts.json
├── gpu.json
├── system.json
├── audit-summary.json
└── reports/
```

权限：

```text
root:umweb 0640
目录 0750
umweb 只读
```

Web 不拥有这些文件。

## 7.3 原子更新

采集端：

```text
write temp
→ validate schema
→ fsync
→ rename
```

禁止 Web 读到半写文件。

## 7.4 Schema

统一：

```json
{
  "schema_version": 1,
  "generated_at": "2026-09-21T13:00:00Z",
  "generator": "user-manager",
  "source": "local",
  "data": {}
}
```

远端快照增加：

```json
{
  "source": "compute-01",
  "status": "ok"
}
```

## 7.5 Freshness

API 明确返回：

```json
{
  "fresh": true,
  "age_seconds": 12,
  "generated_at": "..."
}
```

建议阈值：

```text
system      60s
users       300s
quota       300s
resources   60s
hosts/gpu   120s
audit       30s
```

数据过期必须展示 `stale`，不能伪装成实时。

## 7.6 Web 不触发刷新

首期禁止：

```http
POST /api/snapshots/refresh
```

刷新由：

```text
systemd timer
CLI
可信本地采集器
```

控制。

---

# 8. API 设计

统一成功结构：

```json
{
  "ok": true,
  "data": {},
  "meta": {
    "request_id": "...",
    "generated_at": "..."
  }
}
```

错误：

```json
{
  "ok": false,
  "error": {
    "code": "AUTH_REQUIRED",
    "message": "..."
  },
  "meta": {
    "request_id": "..."
  }
}
```

## 8.1 Auth

```text
POST /api/auth/login
POST /api/auth/logout
GET  /api/auth/me
POST /api/auth/mfa/verify
```

## 8.2 Session

```text
GET    /api/sessions
DELETE /api/sessions/:id
DELETE /api/sessions/others
```

## 8.3 Linux Users

只读：

```text
GET /api/users
GET /api/users/:username
```

不存在：

```text
POST   /api/users
DELETE /api/users/:username
PATCH  /api/users/:username
```

## 8.4 Quota

只读：

```text
GET /api/users/:username/quota
```

不存在：

```text
PUT /api/users/:username/quota
```

## 8.5 Resource

只读：

```text
GET /api/users/:username/resources
GET /api/resources/summary
```

不存在：

```text
PUT  /api/users/:username/resources
POST /api/users/:username/runtime-limit
```

## 8.6 SMB

只读：

```text
GET /api/smb/status
GET /api/smb/users
GET /api/smb/users/:username
GET /api/smb/shares
```

不存在：

```text
POST   /api/smb/password
POST   /api/smb/users/:u/enable
POST   /api/smb/users/:u/disable
DELETE /api/smb/users/:u
POST   /api/smb/shares
DELETE /api/smb/shares/:name
```

## 8.7 Hosts / GPU

```text
GET /api/hosts
GET /api/hosts/:id
GET /api/hosts/:id/gpu
```

读取快照，不直接 SSH。

不存在：

```text
POST /api/hosts/:id/exec
POST /api/hosts/:id/probe
```

## 8.8 Audit

```text
GET /api/audit
GET /api/audit/:id
```

允许过滤：

```text
user
action
result
source
from
to
limit
cursor
```

不接受原始 SQL。

## 8.9 Logs

首期只开放固定集合：

```text
GET /api/logs/boot
GET /api/logs/failed-services
GET /api/logs/auth-failures
```

禁止：

```text
GET /api/logs?path=/any/file
GET /api/logs?unit=<arbitrary>
```

如后续开放 unit 日志，必须后端维护 allowlist。

## 8.10 WeCom

```text
GET  /api/settings/wecom
PUT  /api/settings/wecom
POST /api/settings/wecom/test
```

这是 Web 应用级配置，可由 `web_admin` 管理。

## 8.11 Web Users

```text
GET    /api/web-users
POST   /api/web-users
PATCH  /api/web-users/:id
DELETE /api/web-users/:id
```

这些用户只存在于 Web 身份库，不创建 Linux 用户。

## 8.12 API Token

```text
GET    /api/api-tokens
POST   /api/api-tokens
DELETE /api/api-tokens/:id
```

Token：

- 首次创建只显示一次；
- DB 只存 hash；
- 必须有 `expire_at`；
- 必须有 capability allowlist；
- 支持 revoke。

---

# 9. 前端信息架构、界面设计与交互规范

本节作为 Web 前端的**开发基线**。实现时优先使用 Ant Design Pro / `@umijs/max` 现成布局、权限、请求、国际化能力，避免自行再造一套后台框架。

设计目标：**极简、稳定、信息密度适中、状态优先、只读边界可见**。Web 是观察与协作面板，不是“浏览器版 root 控制台”。

## 9.1 应用壳（App Shell）

采用经典企业后台的 **固定左侧导航 + 顶部工具栏 + 自适应内容区**：

```text
┌──────────────────────────────────────────────────────────────┐
│ Logo / User Manager        全局状态   通知  主题  用户菜单    │ 64
├───────────────┬──────────────────────────────────────────────┤
│ Dashboard     │ PageHeader / Breadcrumb                     │
│ Users         │                                              │
│ SMB           │              Content                         │
│ Hosts & GPU   │                                              │
│ Logs          │                                              │
│ Audit         │                                              │
│ Reports       │                                              │
│ Notifications │                                              │
│ Settings      │                                              │
└───────────────┴──────────────────────────────────────────────┘
```

尺寸约束：

- 设计基准画布：`1440px`；
- Header：`64px`；
- Sider：展开 `240px`，收起 `64px`；
- 页面外边距：桌面端 `24px`；
- 卡片间距：`16px` 或 `24px`；
- 所有尺寸尽量遵循 `8px` 网格；
- `< 1200px` 默认收起 Sider；
- `< 992px` 使用抽屉式导航，页面保持只读可浏览；
- 不为移动端额外增加任何系统写操作能力。

使用 Ant Design/Pro 的语义 token，**不在业务组件中硬编码颜色值**。状态只使用：

```text
normal / success / warning / error / stale / offline / unknown
```

并统一映射到 Ant Design semantic tokens。

## 9.2 一级导航

一级菜单固定为：

```text
Dashboard
Users
SMB
Hosts & GPU
Logs
Audit
Reports
Notifications
Settings
```

不要把 `Quota`、`Resources`、`GPU` 拆成过多一级菜单；它们作为业务域内页签，保持信息架构扁平。

### Users

```text
Users
├─ Overview
├─ Quota
└─ Resources
```

### Settings

```text
Settings
├─ WeCom
├─ Web Users
├─ Sessions
├─ API Tokens
└─ Appearance
```

**明确不出现：**

```text
Create Linux User
Delete Linux User
Set Quota
Set Resource Limit
Reset Linux Password
SMB Password
SMB Enable/Disable
Create/Delete SMB Share
Restore Backup
Firewall
sudoers
System Service Control
Remote Shell
SSH Execute
```

## 9.3 顶部工具栏

从左到右：

1. 当前数据新鲜度状态；
2. 通知入口；
3. 主题切换；
4. 语言切换；
5. 当前 Web 用户菜单。

其中“数据状态”必须长期可见：

```text
● 数据正常 · 18s 前更新
△ 部分快照过期
× 数据源不可用
```

点击后打开 Drawer，列出每个 snapshot 的：

```text
source
generated_at
age
fresh/stale
last_error
```

## 9.4 Dashboard

Dashboard 首屏只展示真正需要快速判断的状态，不堆满图表。

### 第一行：核心指标

使用 `StatisticCard` / `ProCard`：

```text
托管用户        在线用户        存储告警        活跃主机
  42              8               3            6/7
```

每张卡：

- 主数值；
- 次级说明；
- snapshot 更新时间；
- stale 时显示明显标记；
- 点击进入对应详情页。

### 第二行：资源与主机

左侧（约 2/3）：

- 用户磁盘使用 Top N；
- CPU / 内存使用趋势；
- 不做 3D、仪表盘式装饰图。

右侧（约 1/3）：

- Hosts 状态；
- GPU 数量与可见状态；
- offline / unsupported 单独区分。

### 第三行：事件

```text
最近安全事件 / 审计事件       最近通知
```

使用 Timeline/List，不在 Dashboard 提供任何系统修改按钮。

## 9.5 Users 页面

### Overview

使用 `ProTable`：

```text
Username | Home | Mount | Login | Processes | Quota | Resource | Updated
```

功能：

- 搜索用户名；
- 状态过滤；
- 排序；
- 分页；
- CSV 导出；
- 点击用户名进入只读 Drawer/详情页。

详情页建议：

```text
概要
配额
资源
登录历史摘要
相关审计
```

页面顶部固定显示：

> 只读视图。Linux 用户修改请使用受信任 CLI/TUI。

不显示灰掉的“创建/删除/修改”按钮；**直接不渲染这些操作。**

## 9.6 Quota / Resources

Quota：

- 使用率排序；
- 阈值 Tag；
- 使用量/配额文本；
- 线性 Progress；
- stale 标识。

Resources：

- 当前进程数；
- CPU；
- RSS；
- I/O；
- 登录状态；
- 配置限制只显示，不修改。

图表默认最多展示 Top 10，完整数据放表格，避免图表承担全部信息。

## 9.7 SMB 页面

页面用 Tabs：

```text
Status | Users | Shares
```

Status：

- Samba 服务状态；
- 配置快照时间；
- Include 状态只读显示。

Users：

```text
Username | Enabled | Linux User Exists | Status
```

Shares：

```text
Name | Path | Readonly | Valid Users | Updated
```

Web 绝不渲染 Password / Enable / Disable / Remove / Add Share / Remove Share 操作。

## 9.8 Hosts & GPU

合并成一个一级页面，避免主机和 GPU 分散。

左侧主机列表：

```text
host_id
display_name
provider
groups
status
last_seen
```

右侧详情：

```text
Overview | GPU | Capabilities
```

### Overview

- OS / kernel；
- architecture；
- systemd/cgroup；
- provider；
- freshness。

### GPU

使用 `ProTable` + 小型指标卡：

```text
GPU | Model | Memory | Utilization | Backend | Status
```

必须展示：

```text
数据来源：snapshot
最后采集：xx 秒前
```

没有“刷新 SSH”“执行命令”按钮。

## 9.9 Logs 页面

布局：左侧日志源，右侧内容。

日志源只来自后端 allowlist，例如：

```text
Boot
Failed Services
Auth Failures
```

功能：

- 关键词搜索；
- 时间范围；
- severity；
- 自动换行；
- 下载当前查询结果（受大小限制）。

默认暂停实时滚动，避免页面不断跳动；若后续实现 SSE tail，由用户主动开启。

## 9.10 Audit 页面

`ProTable` 字段：

```text
Time | Actor | Source | Action | Target | Result | Request ID
```

点击行打开 Drawer 展示结构化 detail。

过滤条件与 API 一致：

```text
user
action
result
source
from
to
```

禁止把原始审计行直接当 HTML 渲染。

## 9.11 Notifications 页面

分为：

```text
Inbox | Delivery History
```

Inbox：站内事件。

Delivery History：

```text
Time | Channel | Event | Status | Attempts | Error
```

不得显示完整 webhook。

支持：

- 标记已读；
- 批量标记已读；
- 按事件类型过滤；
- 按发送结果过滤。

## 9.12 Settings / WeCom 页面

这是企业微信的主要 Web 配置入口，详见第 10 节。

页面结构：

```text
企业微信机器人
├─ 基本状态
├─ Webhook
├─ 事件订阅
├─ 消息预览
├─ 测试发送
└─ 最近投递状态
```

顶部长期显示安全提示：

> Webhook 等同于向目标群发送消息的凭据。保存后仅显示脱敏值，服务端不会再次返回明文。

## 9.13 统一页面状态

所有数据页必须实现：

```text
loading
empty
error
stale
permission denied
partial failure
```

使用：

- `Skeleton`：首次加载；
- `Spin`：局部短操作；
- `Empty`：无数据；
- `Alert`：stale / partial failure；
- `Result`：403 / 404 / 5xx；
- `App` message/notification：轻量反馈。

不要用 Modal 承载普通详情；详情优先 Drawer。

## 9.14 前端权限

前端 access 仅用于 UX：

```text
canReadUsers
canReadAudit
canReadLogs
canReadHosts
canManageWebUsers
canManageSessions
canManageTokens
canManageWecom
```

真正授权必须在 Rust 后端；前端隐藏按钮不构成安全边界。

`/api/auth/me` 返回：

```json
{
  "user": {
    "id": "...",
    "username": "admin"
  },
  "capabilities": [
    "dashboard.read",
    "users.read",
    "wecom.manage"
  ]
}
```

前端不自行根据角色名推导权限。

## 9.15 组件优先级

优先使用：

```text
ProLayout / PageContainer
ProCard / StatisticCard
ProTable
ProDescriptions
Form / ProForm
Tabs
Drawer
Alert
Tag / Badge
Progress
Timeline
List
Result / Empty / Skeleton
```

避免：

- 自造表格；
- 自造路由权限系统；
- 大量嵌套 Modal；
- 过度动画；
- 低对比度灰字；
- 大面积渐变装饰；
- 非必要玻璃拟态。

## 9.16 可访问性与键盘

最低要求：

- 所有交互控件可 Tab 聚焦；
- 不只靠颜色表达状态；
- 图表提供文本摘要；
- 表单 error 与字段关联；
- Modal/Drawer 正确管理焦点；
- 图标按钮必须有 `aria-label` / Tooltip。

---

# 10. 企业微信与通知系统设计

当前仓库的 `lib/rl_wecom_bot_sender.sh` 已具备：

```text
enabled
dry_run
webhook 格式校验
secret 脱敏
event allowlist
text payload
rl_wecom_bot_send_text
rl_notify_send
```

Web 化后不让 Rust 调 Bash sender；Web 后端使用 Rust HTTP client 独立发送，现有 Bash sender 保留给 CLI/TUI/已有事件链路。两边共享**事件语义**，不共享特权执行链。

## 10.1 集成模式

首期采用企业微信群机器人 Webhook：

```text
User Manager Event
       │
       ▼
Notification Service (Rust)
       │
       ├─ Inbox
       └─ WeCom Sender
               │ HTTPS POST
               ▼
https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=...
```

首期只发送 `text`，减少消息模板和转义复杂度；后续如需要再新增 markdown/template card，并单独定义 schema。

## 10.2 配置归属

企业微信配置属于 **Web 应用配置**，不是 Linux 超级管理员配置。

配置建议保存在 Web DB：

```text
wecom_settings
```

逻辑字段：

```text
enabled
dry_run
webhook_ciphertext
events_json
updated_at
updated_by
version
```

不要把完整 webhook 存在普通 JSON 配置或日志中。

## 10.3 独立密钥

Web 不读取现有 CLI/TUI 特权域通用 key。

使用：

```text
/var/lib/user-manager-web/secrets/master.key
```

权限：

```text
0600 umweb:umweb
```

该 key 只加密 Web 自己管理的 secret：

- WeCom webhook；
- TOTP secret；
- 其他 Web-only credentials。

API Token 不可逆加密，**只保存 hash**。

## 10.4 Webhook 输入与校验

只允许完整形式：

```text
https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=<KEY>
```

Rust 端必须使用 URL parser，而不是纯字符串 contains。

约束：

```text
scheme == https
host == qyapi.weixin.qq.com
port == none || 443
path == /cgi-bin/webhook/send
query 只能有一个 key
key 非空，满足保守字符集/长度上限
username == empty
password == empty
fragment == none
```

HTTP client：

- 禁止 redirect；
- 设置 connect timeout；
- 设置 request timeout；
- 限制 response body 大小；
- 固定 `Content-Type: application/json`；
- 不允许调用者自定义 Host/Header/URL。

## 10.5 保存行为

`PUT /api/settings/wecom` 请求：

```json
{
  "enabled": true,
  "dry_run": false,
  "webhook": "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=...",
  "events": [
    "user.created",
    "user.disabled"
  ]
}
```

规则：

- 如果 `webhook` 缺省：保留旧 secret；
- 如果传入新 webhook：校验成功后立即加密；
- API 响应永远不返回完整 webhook；
- 更新必须记录 `updated_by`；
- 设置采用乐观锁 `version`，防止多人覆盖。

返回：

```json
{
  "enabled": true,
  "dry_run": false,
  "webhook_configured": true,
  "webhook_masked": "https://qyapi.weixin.qq.com/...key=***",
  "events": ["user.created", "user.disabled"],
  "updated_at": "...",
  "version": 4
}
```

## 10.6 事件目录

事件名使用稳定的 namespaced ID，不把中文标题当事件 ID。

计划事件类别（并非都已开放为 WeCom 订阅项）：

```text
security.login_failed
security.account_locked
security.token_revoked
snapshot.stale
snapshot.recovered
host.offline
host.recovered
gpu.unavailable
quota.warning
```

其中：

- `quota.warning` 来源于快照规则判断，不由 Web 修改 quota；
- `host.*` 来源于采集结果；
- `security.*` 来源于 Web 自身认证系统。
- 当前 WeCom API 目录仅开放 `user.created`、`user.disabled`，因为现有 delivery worker 只实现这两种事件；`security.login_failed`、`security.token_revoked`、`snapshot.*` 当前只进入站内 inbox。
- `notification.test` 是固定模板手工测试投递，不是可订阅事件。

CLI/TUI 的 `user.created`、`user.disabled` 等事件如需进入 Web 通知，应通过**只读事件快照/事件 spool**对接，而不是让 Web 调用特权 Action。

## 10.7 系统事件桥接

为了让 CLI/TUI 产生的事件也能进入 Web 通知中心，推荐新增不可变事件 spool：

```text
/var/lib/user-manager-web/events/
```

建议权限：

```text
root:umweb 0750
事件文件 root:umweb 0640
```

特权侧：

```text
产生事件 → 原子写 event JSON
```

Web：

```text
只读 event JSON → 用 event_id 去重 → 写入 Web DB → 发送通知
```

Web **不删除、不覆盖、不修改** root 产生的 event 文件。

事件结构：

```json
{
  "schema_version": 1,
  "event_id": "uuid",
  "event_type": "user.created",
  "created_at": "...",
  "source": "cli",
  "severity": "info",
  "summary": "User created",
  "data": {
    "username": "alice"
  }
}
```

事件数据中不得包含密码、token、webhook、SSH private key。

## 10.8 消息模板

首期统一文本模板：

```text
[User Manager] <事件标题>
状态: <severity/status>
对象: <target>
时间: <timestamp>
主机: <host>
摘要: <safe summary>
```

禁止直接把：

- 原始异常栈；
- HTTP request body；
- shell stderr 全量；
- 审计 raw details；

拼进企业微信消息。

所有模板在发送前经过长度限制和 secret masking。

## 10.9 测试发送

API：

```text
POST /api/settings/wecom/test
```

请求体不允许提供自定义文本，避免 Web 成为任意群消息发送器。

后端发送固定模板：

```text
[User Manager] 企业微信测试
状态: OK
来源: Web Console
时间: <server time>
```

`dry_run=true` 时：

- 不发外网；
- 返回 `DRY_RUN`；
- 仍写 Web audit。

## 10.10 发送结果

WeCom sender 只把 `errcode == 0` 视作业务成功；HTTP 200 但业务错误仍记失败。

记录：

```text
event_id
channel
attempt
started_at
finished_at
http_status
remote_code
success
error_class
```

不记录完整 remote response body，最多保存经白名单提取后的错误码/错误说明。

## 10.11 重试与限流

首期策略：

```text
最大 3 次
指数退避
只对网络错误/明确可重试错误重试
4xx 参数错误不重试
```

增加应用侧速率限制与合并窗口，避免短时间大量事件把机器人打满。

例如同一事件：

```text
host.offline compute-01
```

5 分钟内重复出现时合并为一条状态更新，而不是重复刷屏。

## 10.12 WeCom 配置页交互

页面：`Settings / WeCom`

### 基本卡片

```text
状态             [启用 Switch]
Dry Run          [Switch]
Webhook          [••••••••••••] [替换]
连接状态         已配置 / 未配置
最后测试         2026-... 成功
```

Webhook：

- 已配置时不把真实值填回 Input；
- 显示 `已配置` + 脱敏摘要；
- 点击“替换”后才出现空输入框；
- Cancel 后恢复“已配置”状态。

### 事件订阅

用 `Checkbox.Group` 按域组织：

```text
安全
  登录失败
  账户锁定
  Token 撤销

系统观测
  快照过期/恢复
  主机离线/恢复
  GPU 不可用
  Quota 告警
```

### 保存

保存按钮只修改 Web 应用配置，不涉及任何 root 权限。

保存后：

- 成功 Toast；
- 页面展示更新人/更新时间；
- 写 Web audit；
- 不自动发送测试消息。

### 测试

“发送测试”按钮独立于“保存”。

点击后：

1. 二次确认目标是当前已配置机器人；
2. 固定测试模板；
3. 展示发送中；
4. 返回成功/失败；
5. Delivery History 可查看该次结果。

## 10.13 企业微信验收

- [ ] webhook 明文不进入 DB；
- [ ] GET config 不返回明文；
- [ ] 浏览器 Network 中保存响应无 webhook 明文；
- [ ] request/response 日志无 webhook；
- [ ] URL 只能是企业微信固定 endpoint；
- [ ] redirect 被禁用；
- [ ] `dry_run` 不产生外部请求；
- [ ] test API 不接受自定义 message；
- [ ] `errcode != 0` 记为失败；
- [ ] 重试有上限；
- [ ] 通知风暴有节流/合并；
- [ ] 所有通知都能关联 `event_id`；
- [ ] Web 管理 WeCom 不需要 sudo/root。

---

# 11. 认证、会话与 CSRF

## 11.1 密码

使用 Argon2id。

参数：

- 集中配置；
- 可版本化；
- 支持未来 rehash；
- 登录成功时可按当前 policy 自动升级旧 hash 参数。

## 11.2 Session

Session ID：

- CSPRNG；
- 至少 128 bit；
- 不编码用户信息；
- 推荐 DB 只存 token hash；
- 登录后轮换；
- MFA 后轮换；
- 权限变化后 revoke/轮换。

Cookie：

```text
HttpOnly
Secure
SameSite=Strict
Path=/
```

如确有兼容需求再评估 Lax。

## 11.3 CSRF

所有：

```text
POST
PUT
PATCH
DELETE
```

必须：

- CSRF token；
- Origin validation；
- SameSite 作为额外纵深防护，而不是唯一机制。

## 11.4 登录防护

- IP + username 双维度 rate limit；
- 指数退避；
- 不返回用户枚举差异；
- 登录失败写安全审计；
- `web_admin` 可被强制 MFA。

## 11.5 安全响应头

至少：

```text
Content-Security-Policy
X-Content-Type-Options: nosniff
Referrer-Policy
Permissions-Policy
Strict-Transport-Security
frame-ancestors 'none'
```

---

# 12. 部署与 systemd 沙箱

## 12.1 `umweb` 用户

```text
system user: umweb
shell: /usr/sbin/nologin
home: /var/lib/user-manager-web
```

`groups umweb` 不得包含：

```text
sudo wheel admin useradm docker lxd
```

## 12.2 sudo

部署验收：

```bash
sudo -l -U umweb
```

不得出现授权命令。

仓库不得新增：

```text
umweb NOPASSWD
%umweb
user-manager-web sudoers
```

## 12.3 systemd sandbox

推荐：

```ini
[Service]
User=umweb
Group=umweb

NoNewPrivileges=yes
CapabilityBoundingSet=
AmbientCapabilities=

PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes

RestrictSUIDSGID=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
RestrictNamespaces=yes
RestrictRealtime=yes
SystemCallArchitectures=native

ReadWritePaths=/var/lib/user-manager-web
ReadOnlyPaths=/var/lib/user-manager-web/snapshots
```

具体选项需在目标 Ubuntu/systemd 版本上验证兼容性。

## 12.4 文件权限

```text
/opt/user-manager/web                  root:root    0755
/var/lib/user-manager-web              umweb:umweb  0700
/var/lib/user-manager-web/app.db       umweb:umweb  0600
/var/lib/user-manager-web/secrets      umweb:umweb  0700
/var/lib/user-manager-web/snapshots    root:umweb   0750
snapshots/*.json                       root:umweb   0640
```

## 12.5 禁止 socket

`umweb` 不得访问：

```text
/var/run/docker.sock
/run/containerd/containerd.sock
/run/podman/podman.sock
/run/systemd/private
```

---

# 13. 日志、审计与隐私

## 13.1 Web 审计字段

记录：

```text
request_id
timestamp
web_user_id
session_id_hash
source_ip
method
route_name
capability
target
result
latency
```

禁止记录：

```text
password
Authorization header
Cookie
CSRF token
TOTP
webhook
API token
```

## 13.2 审计分域

现有：

```text
audit_core
acl_audit_log
```

继续服务 CLI/TUI。

Web 维护独立 `web_audit`。

展示层可聚合，但存储权限不应变成“root 和 Web 都能任意写同一审计文件”。

## 13.3 代理来源 IP

只有在反代链受信任时才使用：

```text
X-Forwarded-For
Forwarded
```

应用需显式配置 `trusted_proxies`，否则使用 TCP peer address。

---

# 14. CI/CD 硬门禁

新增 Web 后必须建立阻断式安全 Job。

## 14.1 禁止提权关键词

针对生产代码：

```bash
rg -n '\bsudo\b|\bpkexec\b|\bsu\b|setuid|setgid|CAP_SYS_ADMIN|CAP_SETUID|CAP_SETGID' web/backend/src
```

命中默认 CI fail。

## 14.2 禁止系统管理命令

Web 生产代码中禁止：

```text
useradd
userdel
usermod
chpasswd
setquota
quotaon
systemctl
ufw
iptables
nft
smbpasswd
pdbedit
visudo
mount
umount
reboot
shutdown
```

## 14.3 禁止 shell

Rust Web 生产代码默认不得：

```rust
Command::new("sh")
Command::new("bash")
Command::new("sudo")
```

若未来确需非特权外部工具，必须：

- 独立 ADR；
- 固定 executable；
- 固定 argv；
- 不经 shell；
- 无用户输入拼接；
- 新增安全测试。

## 14.4 API Contract 门禁

测试必须断言以下路由不存在（404/405）：

```text
POST /api/users
PUT /api/users/:u/quota
PUT /api/users/:u/resources
POST /api/smb/password
POST /api/smb/shares
DELETE /api/smb/shares/:name
POST /api/hosts/:id/exec
POST /api/system/*
```

这比“RBAC 返回 403”更强：

> **危险 API 根本不存在。**

## 14.5 部署权限门禁

必须验证：

```text
uid != 0
no sudo group
no useradm
no privileged groups
no capabilities
NoNewPrivileges=yes
```

## 14.6 Rust/前端质量门禁

Rust：

```text
cargo fmt --check
cargo clippy -- -D warnings
cargo test
cargo audit
cargo deny check
```

前端：

```text
lint
typecheck
test
build
dependency audit
```

现有 Bash：

```text
ShellCheck
shfmt
bash -n
run_regression.sh --level all
sensitive file scan
```

---

# 15. 分阶段实施路线

## 当前完成状态（工作树复核，2026-09-24）

| 阶段 | 状态 | 实际情况 |
| --- | --- | --- |
| P0 安全边界与 Snapshot 契约 | [DONE] | 快照采集、版本/类型校验、脱敏、原子安装、失败关闭和只读部署边界均有实现与针对性验证；目标机权限仍需部署验收。 |
| P1 Rust 非特权后端骨架 | [DONE] | Axum、认证、会话、RBAC、CSRF、限流和 SQLite 已实现；Rust 门禁通过。 |
| P2 只读系统 API | [DONE] | users/quota/resources/SMB/hosts/GPU/system-summary 已由快照 API 提供。 |
| P3 Logs / Audit / Reports | [DONE] | 只读日志、审计分页/导出和报告索引 API 已实现。 |
| P4 Web 自身身份与通知 | [PARTIAL] | root event spool 将 `user.created`/`user.disabled` 幂等写入 inbox 并按配置投递 WeCom；真实密码失败按全局 5 分钟桶合并、首次成功撤销 Token 和 manifest freshness 转换也会写入 Web inbox。WeCom 当前只开放实际支持的用户生命周期事件；Web 原生事件的 WeCom 投递和真实目标机验收仍待完成。 |
| P5 Ant Design 前端 | [PARTIAL] | React/Vite/Ant Design 前端页面与 WeCom 设置页已实现，生产构建通过；临时管理员真实密码+TOTP 登录、键盘提交、语言/密码显隐、移动抽屉导航和 1366/1200/992/390px 断点均已验证且无横向溢出。主要数据页权限/交互、菜单与表格键盘操作、无障碍审计仍待验收，工程也未采用计划中的 Umi/ProComponents。 |
| P6 Ubuntu Ops / 多主机观测 | [DONE] | system/filesystem/inode/systemd/APT/reboot/AppArmor 只读采集器已接入快照和回归；不可用能力按状态降级。实际主机采集结果依部署环境而异。 |
| P7 Hardening / 回归 / 发布 | [PARTIAL] | `v0.2.0` 仍是最新发布；P4 通知和本轮前端修正已推送到 `main`，尚未打新版本标签。Rust、前端构建、聚焦安全测试和登录/MFA 浏览器流程均通过。全仓 Shell 回归现为 41 个套件通过、0 个失败、1 个可选性能项跳过；数据页权限/交互、无障碍和目标机权限/服务验证仍待完成。 |

复核记录见 [`docs/M1_REPOSITORY_AUDIT.md`](docs/M1_REPOSITORY_AUDIT.md)。

本轮验证：Rust `cargo fmt --all -- --check`、`cargo clippy --locked --all-targets -- -D warnings`、`cargo test --locked` 通过（59 个后端测试）；前端离线安装与生产构建通过，npm audit 为 0 个漏洞，构建仍有 Ant Design `use client` 与主 bundle 体积提示。使用隔离临时数据库和管理员账号，通过系统 Chrome/Playwright 完成密码登录→TOTP→Dashboard；键盘提交、语言切换、密码显隐、移动抽屉导航均通过；1366/1200/992/390px 页面无横向溢出，未捕获页面异常为 0。聚焦 Shell 回归：安全加固 25/25、快照 25/25、Ops 7/7、事件 spool 11/11、systemd 边界 9/9、独立脚本 19/19、改密权限包装 19/19、远程 CLI 9/9 均通过。全仓 `tests/run_regression.sh --level all` 在一次性 ext4 clone 与私有 TMPDIR 下为 41 个通过、0 个失败、1 个可选性能套件跳过；P0 ShellCheck 使用本机 Mamba 包缓存中的可执行文件。P4 通知更新和本轮前端修正已推送到 GitHub `main`；`v0.2.0` 仍是已发布版本，本轮更新尚未收入 release。数据页权限/交互、无障碍及目标机验收未完成。

## P0 — 安全边界与 Snapshot 契约

目标：先把数据边界做对，不先写“能执行系统命令”的 Web。

任务：

- 固化本 `plan.md`；
- 新增 `docs/WEB_SECURITY_BOUNDARY.md`；
- 定义 snapshot schema；
- 编写 snapshot generator；
- users/quota/resource/smb/host/gpu/system/audit-summary 快照；
- 原子写；
- schema validation；
- freshness 元数据。

验收：

- snapshot 不含 secret；
- `umweb` 对 snapshot 只读；
- REMOTE_HOSTS 仍只允许 `host.probe/gpu.summary`；
- 不新增 Web sudoers。

## P1 — Rust 非特权骨架

任务：

- axum；
- config；
- tracing；
- request ID；
- health；
- SQLite；
- Session；
- Argon2id；
- `/login /logout /me`；
- capability RBAC；
- CSRF；
- rate limit。

硬约束：

```text
无 sudo
无 shell
无 root helper
无 privileged Action bridge
```

验收：

- 服务以普通用户运行；
- 无 capability；
- 登录/MFA/Session 测试；
- CSRF 测试；
- 未授权 401；
- 无 capability 403。

## P2 — 只读系统 API

开放：

```text
users
quota
resources
smb
hosts
gpu
system summary
```

全部来自 snapshot。

验收：

- API 请求不 fork shell；
- snapshot stale 明确标识；
- 无任意文件读取；
- dangerous routes 不存在。

## P3 — Logs / Audit / Reports

实现：

- audit read；
- allowlisted logs；
- reports；
- CSV/JSON export；
- cursor pagination。

验收：

- 不接受任意 path；
- 不接受原始 SQL；
- 导出有大小/行数上限；
- secret 不进入日志。

## P4 — Web 自身管理、企业微信与通知闭环

已实现：

- Web users；
- MFA；
- sessions；
- API tokens；
- `wecom_settings`；
- 独立 Web secret master key；
- 固定模板 WeCom 测试投递、Webhook 加密存储、脱敏读取和投递历史；
- WeCom 固定 endpoint 校验、禁用 redirect、超时和有界重试；
- WeCom 事件目录读取、配置版本冲突检测；
- notification inbox；
- event dedup；

已实现 root→Web 固定 spool 消费，CLI 生产者覆盖用户创建与禁用；Web 幂等写入 inbox，并可依配置投递 WeCom，持久化五分钟同类/同用户抑制状态。账号密码明确校验失败时写固定脱敏 `security.login_failed` 通知，使用全局五分钟桶去重，unknown user、限流与内部错误不产生事件。Token 首次成功撤销会在同一 SQLite 事务中写入固定脱敏的 `security.token_revoked` 通知。后台观察器每 30 秒读取同一份已校验 manifest 与 freshness，仅在 fresh↔stale 转换时原子更新状态并写 inbox；missing/invalid/partial/unavailable 不产生事件。WeCom 目录仅开放实际 dispatcher 支持的 `user.created`、`user.disabled`。仍待实现/验收：

- 为 Web 原生 `security.*` / `snapshot.*` inbox 事件增加独立且受限的 WeCom 投递通路后，再开放对应订阅选项；
- 在目标 Ubuntu 主机验证目录属主/权限、服务启动和故障恢复；
- 配置真实机器人后完成实际外部投递验收（测试环境覆盖逻辑、dry-run 和错误分类，不证明生产机器人已配置）。

验收：

- Web user ≠ Linux user；
- 删除 Web user 不触碰 `/etc/passwd`；
- API Token DB 不存明文；
- webhook 明文只在保存请求和发送瞬间存在；
- GET/日志/审计均不回显 webhook；
- outbound URL 只能命中企业微信固定 endpoint；
- test API 使用固定模板，不接受任意 message；
- `dry_run=true` 时抓包确认无外部请求；
- Delivery History 能关联 `event_id`；
- CLI/TUI 事件进入 Web 时不需要 Web 获得 sudo/root。

## P5 — Ant Design Pro 前端与视觉验收

当前 `web/frontend` 使用 React、Vite 和 Ant Design，已有登录/MFA、只读数据页、系统状态页、通知/WeCom 设置与投递历史、主题和中英文切换。浏览器已走通临时管理员密码登录、TOTP 挑战和 Dashboard，并验证键盘提交、语言/密码交互、移动抽屉和 1366/1200/992/390px 页面无横向溢出。工程目前不是 Umi/Ant Design ProComponents；主要数据页权限与交互、菜单/表格键盘操作及无障碍审计仍须完成。

实现应用壳：

- 64px Header；
- 240px Sider / 64px collapsed；
- 24px desktop content padding；
- 8px spacing system；
- responsive drawer navigation；
- light/dark + i18n；
- snapshot freshness global indicator。

实现页面：

- Login；
- Dashboard；
- Users / Quota / Resources；
- SMB；
- Hosts & GPU；
- Logs；
- Audit；
- Reports；
- Notifications / Delivery History；
- Settings / WeCom；
- Sessions；
- API Tokens；
- Web Users；
- Appearance。

统一组件：

- `PageContainer`；
- `ProCard` / `StatisticCard`；
- `ProTable`；
- `ProDescriptions`；
- `Drawer`；
- `Alert`；
- `Tag` / `Badge`；
- `Progress`；
- `Timeline`；
- `Result` / `Empty` / `Skeleton`。

视觉/交互验收：

- 一级菜单不超过当前规划的 9 个；
- 页面进入 2 次点击内到达主要数据；
- stale/offline/error 不只靠颜色表达；
- Users/SMB/Hosts 页面都能明确看到数据采集时间；
- 所有详情优先 Drawer，不滥用 Modal；
- 所有表格有 loading/empty/error；
- 1440 / 1366 / 1200 / 992 宽度下无关键内容遮挡；
- 键盘可完成菜单、表格过滤和表单操作；
- 不出现 Linux 创建/修改/删除、SMB 写、SSH exec、systemd/firewall 等系统级写按钮。

硬约束：前端不仅“禁用”系统级写操作，而是**不实现相应组件、路由和 API client method**。

## P6 — Ubuntu Ops / 多主机只读观测

首批本机 Ops 只读采集器已落地并接入 `scripts/rl-snapshot.sh`，对应测试 7/7 通过。运行时工具不存在或当前环境不可读时会输出 `degraded` / `unavailable`。部署后的主机数据准确性和 systemd timer 实际运行仍须在目标机核验。

按可用能力逐项降级，不允许单个可选工具缺失导致整份 Snapshot 失败。所有采集固定命令、设置超时和输出上限，单节失败写入 `degraded` / `unavailable` 状态。

首批只读模块：

- 系统摘要：Ubuntu 版本、内核、uptime、boot time、架构、虚拟化和 load；
- CPU/内存：CPU usage、logical CPU、memory、swap 和可用时的 pressure；
- filesystem/inode：逐挂载点采集，单个不可访问或网络挂载失败不得中断其他结果；
- systemd：failed/enabled 状态、关键服务、degraded boot 和 timers；
- APT/security：升级计数、安全更新、apt timer、unattended-upgrades 与 reboot-required；
- AppArmor：启用状态与 profile 汇总，工具不存在时标为 unavailable；
- 多主机沿用现有只读 provider；一台主机失败只标记该主机 unreachable/stale。

不增加 Web 系统写 API，不执行 apt upgrade，不提供 systemd start/stop/restart，不改变 SSH、网络或防火墙配置。

## P7 — 部署加固与发布

当前已完成代码层面的私密文件权限/符号链接校验、Snapshot 严格校验、安全扫描门禁和 systemd `UMask=0077` 加固。全仓回归 41 个套件通过、0 个失败、1 个可选性能套件跳过；执行计划测试 fixture 键已修正，未降低生产路径校验。浏览器完整流程和目标主机的运行属性仍待验收；`v0.2.0` 已推送并发布。

实现：

- systemd sandbox；
- HTTPS；
- trusted proxy；
- CSP；
- Web DB 备份/恢复；
- monitoring；
- dependency scanning；
- release checklist。

最终验收：

```text
sudo -l -U umweb        → 无授权
systemctl show           → NoNewPrivileges=yes
capability               → 空
dangerous API            → 404/405
CLI/TUI regression       → pass
REMOTE_HOSTS boundary    → unchanged
```

---

# 16. 风险、边界与验收

## 16.1 风险矩阵

| 风险 | 新方案缓解 |
| --- | --- |
| Web RCE → root | Web 无 sudo/capability/root helper |
| API 越权 | capability allowlist + 默认拒绝 |
| shell 注入 | Web 不调用 shell |
| SSH 注入 | Web 不直接 SSH |
| 任意文件读 | Snapshot Store + 固定文件集合 |
| 任意日志读 | log source allowlist |
| SSRF | WeCom 固定 host/path |
| secret 泄露 | 独立 secret store + 不记录请求体 |
| Web role 与 OS 权限混淆 | 完全解耦 |
| Web 被攻破后改系统 | OS 权限层直接阻断 |
| Snapshot 篡改 | root 生成、umweb 只读 |
| 旧数据误判实时 | freshness 元数据 |

## 16.2 总验收清单

### 架构

- [ ] Web 无 root/sudo/capability。
- [ ] Web 无 `rl-web-exec`。
- [ ] Web 不调用 `action_run` 执行系统写操作。
- [ ] Web role 不映射 Linux ACL。
- [ ] dangerous API 根本不存在。
- [ ] CLI/TUI 保留完整系统管理能力。

### 进程

- [ ] `umweb` UID != 0。
- [ ] `umweb` 不在 sudo/wheel/admin/useradm/docker/lxd。
- [ ] `sudo -l -U umweb` 无授权。
- [ ] `NoNewPrivileges=yes`。
- [ ] `CapabilityBoundingSet=` 空。
- [ ] `AmbientCapabilities=` 空。

### 数据

- [ ] Snapshot 由可信采集器生成。
- [ ] Snapshot 对 `umweb` 只读。
- [ ] Snapshot schema versioned。
- [ ] Snapshot 有 generated_at/freshness。
- [ ] Snapshot 无 password/token/webhook/SSH private key。

### API

- [ ] POST `/api/users` 不存在。
- [ ] quota PUT 不存在。
- [ ] resource PUT 不存在。
- [ ] SMB write API 不存在。
- [ ] system write API 不存在。
- [ ] SSH exec API 不存在。
- [ ] 任意 file path API 不存在。

### Auth

- [ ] Argon2id。
- [ ] Secure + HttpOnly + SameSite。
- [ ] CSRF token。
- [ ] Origin validation。
- [ ] rate limit。
- [ ] MFA 可强制。
- [ ] Session revoke。
- [ ] 权限变化后 Session 失效。

### Secret

- [ ] API Token 只存 hash。
- [ ] WeCom webhook encrypted。
- [ ] secret 不进日志。
- [ ] secret 不进 URL。
- [ ] secret 不进 argv。
- [ ] secret 不进 localStorage。

### Remote

- [ ] 仍仅 `host.probe` / `gpu.summary`。
- [ ] Web 不直接 SSH。
- [ ] Inventory 不接受任意 SSH 参数。
- [ ] StrictHostKeyChecking 保持开启。
- [ ] known_hosts 不由 Web 修改。

### 回归

- [ ] `bash tests/run_regression.sh --level all`。
- [ ] ShellCheck。
- [ ] shfmt。
- [ ] Rust fmt/clippy/test。
- [ ] cargo audit / cargo deny。
- [ ] 前端 lint/typecheck/test/build。

---

# 17. 功能全景索引

| 功能 | Web | CLI/TUI | 数据源 |
| --- | --- | --- | --- |
| Web 登录 | RW | — | Web DB |
| Web 用户 | RW | — | Web DB |
| Web Session | RW | — | Web DB |
| API Token | RW | — | Web DB |
| Linux 用户列表 | RO | RW | Snapshot / user_core |
| Linux 用户创建删除 | ❌ | RW | user_core |
| quota 查看 | RO | RW | Snapshot / quota_core |
| quota 修改 | ❌ | RW | quota_core |
| resource 查看 | RO | RW | Snapshot / resource_core |
| resource 修改 | ❌ | RW | resource_core |
| SMB 状态/用户/共享 | RO | RW | Snapshot / smb_core |
| SMB 写操作 | ❌ | RW | smb_core |
| Audit | RO | RW | snapshot/index |
| Logs | RO allowlist | RW | snapshot/log provider |
| Hosts | RO | RO | host_inventory/provider |
| GPU | RO | RO | gpu_core |
| 任意 SSH | ❌ | ❌ | — |
| Backup 状态 | RO | RW | snapshot |
| Backup run | ❌ | RW | backup_core |
| Restore | ❌ | RW | backup_core |
| WeCom | RW | 可配置 | Web secret store |
| Notification inbox | RW | — | Web DB |
| Dashboard | RO | — | Snapshot |
| Reports | RO/export | RW | report snapshot |
| Firewall | ❌ | RW | firewall_core |
| DNS | ❌ | RW | dns_core |
| systemd 修改 | ❌ | RW | system_core |
| sudoers | ❌ | root 运维 | OS |

---

# 附录 A：Web 明确禁止能力清单

以下能力未来若有人提出加入 Web，应默认拒绝，除非正式重新评审整个安全边界：

```text
sudo
su
pkexec
doas
setuid helper
setgid helper
Linux capabilities
useradd
userdel
usermod
chpasswd
passwd
setquota
quotaon
quotacheck
systemctl start/stop/restart/enable/disable
mount
umount
iptables
nft
ufw
firewall-cmd
smbpasswd
pdbedit
visudo
apt/dpkg
reboot
shutdown
modprobe
sysctl write
cgroup write
/proc write
/sys write
Docker socket
containerd socket
systemd private socket
arbitrary shell
arbitrary command
arbitrary SSH command
arbitrary file reader
arbitrary log path
arbitrary URL fetch
```

原则：

> 如果某功能必须依赖以上任意能力，那么它默认属于 CLI/TUI 特权管理面，而不是 Web 面。

---

# 附录 B：与现有模块的关系

## B.1 保留并复用

```text
lib/action_registry.sh
lib/user_core.sh
lib/quota_core.sh
lib/resource_core.sh
lib/smb_core.sh
lib/audit_core.sh
lib/logs_core.sh
lib/report_core.sh
lib/host_inventory.sh
lib/host_provider.sh
lib/execution_plan.sh
lib/host_probe_core.sh
lib/gpu_core.sh
lib/rl_wecom_bot_sender.sh
```

复用方式：

```text
CLI/TUI
  → 直接调用 Core / Action

Snapshot Generator
  → 调用只读 Core/Action
  → 输出结构化快照

Web
  → 只读 Snapshot
```

## B.2 不接入 Web 权限域

以下机制继续保留给 CLI/TUI：

```text
access_control.sh 的 Linux ACL
privilege.sh
PRIV_CMD_WHITELIST
priv_exec
sudoers
rl-chpasswd
```

**Web 不通过任何 adapter 接入这些特权机制。**

## B.3 REMOTE_HOSTS

继承 `docs/REMOTE_HOSTS.md` 当前全部边界。

未来增加远程能力时必须：

1. 首先判断是否只读；
2. 新增固定 action ID；
3. 使用固定白名单远端入口；
4. 输出协议版本化；
5. 禁止动态 shell；
6. 独立安全评审；
7. Web 仍优先读 snapshot。

---

# 最终设计原则

整个 Web 化必须始终满足：

> **Web 可以“看”和“管 Web 自己”，但不能“以超级管理员身份改 Linux”。**

当功能需求与该原则冲突时：

```text
安全边界 > 功能便利性
```

解决方式应是：

```text
Web 产生申请 / 展示状态
+
CLI/TUI 执行系统变更
```

而不是：

```text
给 Web 增加 sudo
```
