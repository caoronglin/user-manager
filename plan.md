# Web 化实施规划：Rust 后端 + Ant Design Pro 6.0 前端

> 目标：在不重写现有 Bash 业务核心的前提下，为「Linux 多用户运维管理系统」增加一套
> Web 控制台（Rust API + Ant Design Pro 6.0），并以「分层防御」的方式处理好权限问题。
>
> 本文档先固化现状架构与功能基线，再给出 Web 化的目标、架构、权限方案、API 设计、
> 目录结构与分阶段实施路线。

---

## 目录

- [1. 现状架构与功能基线](#1-现状架构与功能基线)
- [2. Web 化目标与非目标](#2-web-化目标与非目标)
- [3. 技术选型](#3-技术选型)
- [4. 总体架构](#4-总体架构)
- [5. 权限方案（核心）](#5-权限方案核心)
- [6. 目录结构](#6-目录结构)
- [7. API 设计](#7-api-设计)
- [8. 前端权限与信息架构](#8-前端权限与信息架构)
- [9. 企业微信机器人入口配置](#9-企业微信机器人入口配置)
- [10. 分阶段实施路线](#10-分阶段实施路线)
- [11. 风险、边界与验收](#11-风险边界与验收)
- [12. 功能全景索引表](#12-功能全景索引表)

---

## 1. 现状架构与功能基线

### 1.1 技术形态

- 纯 Bash/Shell 实现，面向 Ubuntu/Debian 多用户服务器。
- 分层架构：入口层 → 启动加载层（`bootstrap.sh`）→ UI/Controller 层 → Action 分发层
  （`action_registry.sh`）→ Core 业务层 → Privilege/System 基础层 → Linux 系统命令。
- 三类入口：经典 CLI（`user_manager.sh`）、原生 TUI（`tui_manager.sh`）、独立脚本
  （`scripts/rl-*.sh`）。

### 1.2 核心设计思想

> 入口可以多样，业务能力尽量统一。

所有入口最终都通过 `action_registry.sh` 的 `action_run <id> <mode> [args...]` 分发到
统一的 Core 业务函数。这是 Web 化可以「薄封装、不重写」的关键切入点。

### 1.3 Action 注册表（Web 的对接面）

每个 action 有 6 个属性：`id / label / group / handler / requires(能力) / modes / risk`。

| 分组 | 代表 action | risk | 说明 |
| --- | --- | --- | --- |
| users | `users.list` / `users.create` / `users.quota` / `users.resource` | safe/dangerous | 用户生命周期、配额、资源限制 |
| smb | `smb.list` / `smb.status` / `smb.show` / `smb.shares` | safe | SMB 账户与共享只读 |
| smb | `smb.password` / `smb.disable` / `smb.enable` / `smb.remove` / `smb.share.add` / `smb.share.remove` / `smb.include` | dangerous | SMB 写操作 |
| backup | `backup.run` | dangerous | 执行备份 |
| audit | `audit.query` / `audit.view` | safe | 审计查询/查看 |
| logs | `logs.boot` / `logs.failed_services` / `logs.service_recent` / `logs.boot_error_diff` / `logs.system_file_tail` / `logs.auth_failures` | safe | 日志读取 |
| system | `system.timers.list` / `system.timers.logs` | safe | systemd timer |
| hosts | `host.probe` / `gpu.summary` | safe | 主机/GPU 只读探测（仅 cli 模式） |
| mail | `mail.test` | safe | 测试邮件 |

Action CLI 错误码规范：`0` 成功 / `1` 参数错误 / `2` 权限错误 / `3` 运行时错误。

> 通知通道：`lib/rl_wecom_bot_sender.sh` 是企业微信机器人**预留接口**（默认关闭、env 配置、
> 统一频道分发 `rl_notify_send`，尚无调用方），本期为其新增 Web 配置入口（见 §9）。

### 1.4 权限模型（现状，Web 化的地基）

**四级 ACL**（`lib/access_control.sh`）：

| 级别 | 值 | 名称 | 判定依据 |
| --- | --- | --- | --- |
| root | 0 | root | `root` 或 uid=0 |
| admin | 1 | admin | 属于 `sudo`/`wheel`/`admin` 组 |
| user | 2 | user | 普通用户（uid≥1000，非管理组） |
| guest | 3 | guest | 系统用户（uid<1000） |

- `acl_get_current_level` / `acl_check_level` / `acl_is_at_least`，带 300s TTL 缓存。
- `PERMISSION_MATRIX`（`lib/privilege.sh`）把 `resource:action` 映射到所需级别，例如
  `user:create→admin`、`user:read→guest`、`quota:set→admin`、`system:modify→admin`。

**特权执行白名单**（`lib/privilege.sh`）：

- `PRIV_CMD_WHITELIST`：仅白名单命令可提权，多数需 admin，`visudo` 需 root。
- `priv_exec` 是**唯一**提权入口：白名单校验 → 权限级别校验 → 前后状态快照 → 执行
  （root 直跑 / 非 root 走 `sudo`）→ 写审计（`PRIV_EXEC` / `PRIV_DENIED`）。
- 密码经专用 wrapper `rl-chpasswd` 只走 stdin，不落命令行/ps/审计。

**审计**（`lib/access_control.sh` + `lib/audit_core.sh`）：

- `acl_audit_log <action> <target> <result> [details]`：管道分隔 + 字段转义 + `flock`
  并发写 + 10MB 轮转 + 状态快照（user/uid/hostname/pwd/ppid/timestamp）。
- 文件后端 `data/audit/operations.log`，另有 SQLite 索引（`AUDIT_INDEX_FILE`）。

**sudoers 部署模式**（`docs/sudoers-deploy.md`）：

- 服务用户加入 `useradm` 组，sudoers 仅授权白名单命令（`rl-chpasswd`）且 root 目标反向
  防护；文件名无 `.`/`~`、权限 0440 root:root，`visudo -c` 校验。

### 1.5 数据层

| 路径/文件 | 内容 | 敏感度 |
| --- | --- | --- |
| `data/user_config.json` | 托管用户配置 | 高 |
| `data/email_config.json` | SMTP 配置（含 secret） | 高 |
| `data/secrets/.key` | AES-256 主密钥（0600） | 极高 |
| `data/password_pools/` | 密码池（加密落盘 v1:iv:ct:mac） | 极高 |
| `data/audit/operations.log` | 审计日志 | 中 |
| `data/created_users.txt` / `disabled_users.txt` | 用户流水 | 中 |

配置统一支持 `USER_MANAGER_*` 环境变量覆盖；`DATA_BASE=/mnt`、`BACKUP_ROOT=/mnt/backup/...`。

---

## 2. Web 化目标与非目标

### 2.1 目标

1. 提供浏览器控制台，覆盖完整运维能力：用户/配额/资源/SMB/备份/审计/日志、企业微信通知、仪表盘、自助门户、安全加固与集群只读视图（全景见 §12，落地见 §10）。
2. **不重写业务逻辑**：Rust 只做 Web 网关 + 应用层 RBAC，业务仍走 Bash Action/Core。
3. 权限「分层防御」：Web 认证 → 应用层 RBAC → 受控执行入口 → 现有 Bash ACL/白名单 → 全量审计。
4. 与现有 CLI/TUI 并存，不破坏 `run.sh` 与 `scripts/rl-*.sh` 现状。

### 2.2 非目标（本期不做）

- 不把 Bash Core 翻译成 Rust（保持单一业务实现，避免双源真相）。
- 不引入常驻 Agent / 跨主机写操作 / GPU 调度（延续 REMOTE_HOSTS 只读边界）。
- 不做多租户隔离到 OS 用户级别（见 §5 的取舍）。

---

## 3. 技术选型

| 层 | 选型 | 理由 |
| --- | --- | --- |
| 后端框架 | **Rust + axum + tokio** | 异步、类型安全、生态成熟、适合 I/O 密集型封装 shell |
| 进程执行 | `tokio::process` + 受控 argv | 复用 Bash Core；严格白名单，禁止任意命令 |
| 序列化 | `serde` / `serde_json` | 与 Bash JSON 输出对接 |
| 认证 | 自建 Session（HttpOnly Cookie）或 JWT | 视部署复杂度；首期建议 Session Cookie |
| 密码哈希 | `argon2` | 存储 Web 管理员口令 |
| 前端框架 | **Ant Design Pro 6.0**（React 18 + Umi 4 + **antd 6** + TS） | 企业级中后台，内置权限插件与布局 |
| 前端权限 | `@umijs/plugin-access` + `useAccess` + `<Access>` | 路由/按钮级 RBAC，与后端矩阵对齐 |
| 数据请求 | `@umijs/max` + OpenAPI 生成客户端 | 与 Rust 提供的 OpenAPI 对齐 |

> 前端版本说明（已核对 npm registry）：Ant Design Pro 6.0 基于 Umi 4（`umi`/`@umijs/max`
> 4.7.x）+ **antd 6**（最新 6.6.x）+ `@ant-design/pro-components` + TypeScript；具体组合以
> `npm create` 拉取的最新 Pro 6.0 脚手架锁定为准（antd 6 相对 v5 有破坏性变更，勿混用大版本）。
> 权限体系沿用 Umi 的 `plugin-access`（2.4.x）：`access.ts` + `useAccess` + `<Access>` + `initialState`。

---

## 4. 总体架构

```text
浏览器（Ant Design Pro 6.0）
  │  HTTPS / JSON（带 Session Cookie）
  ▼
┌─────────────────────────────────────────────┐
│ Rust Web 服务（axum，非 root 用户 umweb）      │
│  ┌──────────────┐  ┌──────────────────────┐  │
│  │ 认证/会话     │  │ 应用层 RBAC 网关       │  │
│  │ (登录/登出)   │  │ (角色→action 权限矩阵) │  │
│  └──────────────┘  └──────────────────────┘  │
│  ┌──────────────┐  ┌──────────────────────┐  │
│  │ 受控执行入口   │  │ 审计记录（web身份叠加）│  │
│  │ rl-web-exec  │  │                       │  │
│  └──────────────┘  └──────────────────────┘  │
└───────────────────┬─────────────────────────┘
                    │ sudo -n rl-web-exec <action.id> <validated argv>
                    ▼
        scripts/rl-web-exec.sh（受控入口，白名单 action + argv 校验）
                    │
                    ▼
        lib/action_registry.sh → action_run → *_core.sh
                    │
                    ▼
        privilege.sh（PRIV_CMD_WHITELIST + priv_exec + sudo）→ Linux 命令
```

**关键点**：Rust 不直接 `useradd`/`setquota`，而是调用一个**新的受控入口**
`scripts/rl-web-exec.sh`，它只接受已注册的 action ID 与校验过的 argv，内部仍走
`action_run`，从而完整复用现有权限白名单与审计。

---

## 5. 权限方案（核心）

权限问题分两个正交层面，必须**双层都过**才能执行（defense in depth）：

### 5.1 第一层：Web 认证 + 应用层 RBAC（Rust 侧）

- Web 用户独立表（`web_users`：username / argon2 哈希 / role / enabled / mfa 可选），
  与 OS 用户解耦——Web 用户不要求对应真实 Linux 账户。
- 角色映射到现有四级 ACL 语义：

  | Web 角色 | 等价 ACL | 允许的 action |
  | --- | --- | --- |
  | `viewer` | guest | 所有 `risk=safe` 的只读 action（users.list、audit.view、logs.*、smb 只读、host.probe、gpu.summary） |
  | `operator` | user | safe + 部分受控写（backup.run、mail.test、自身相关 user:update） |
  | `admin` | admin | safe + dangerous（users.create/delete、quota、resource、smb 写、firewall、system:modify） |
  | `owner` | root | 全部（含 visudo 级，默认不给 Web 开放） |

- 权限矩阵以「action ID + risk」为粒度在前端与后端各存一份，后端为权威。
- 每个请求：解析 Session → 取角色 → `check(action_id, role)` → 拒绝则记 `DENIED` 并返回 403。

### 5.2 第二层：受控执行入口 + 现有 Bash ACL（Shell 侧）

- 新增 `scripts/rl-web-exec.sh`（仿照 `rl-remote-entry.sh` 的只读白名单思路，但面向
  本地写操作）：
  - **只接受已注册 action ID**（`action_exists` 校验），拒绝任意命令。
  - **argv 白名单校验**：每个 action 定义合法参数模式（用户名正则 `^[a-z_][a-z0-9_-]*$`、
    配额格式、布尔开关等），拒绝注入。
  - 复用 `um_load_profile minimal/full` + `action_run`，因此 `priv_exec` 的命令白名单、
    `requires` 能力检查、`PERMISSION_MATRIX` 全部继续生效。
  - 环境净化：固定 `PATH`/`LC_ALL=C`，清 `LD_PRELOAD`/`BASH_ENV` 等（沿用 rl-chpasswd 做法）。
  - 密码类操作（users 密码、smb.password）密码只走 stdin/临时 secret，绝不进 argv。

### 5.3 服务运行身份与 sudoers

- Rust 服务以**专用非 root 用户 `umweb`** 运行（加入 `useradm` 组）。
- sudoers 仅授权 `umweb` 免密调用受控入口，**不开放任意命令**：

  ```sudoers
  # /etc/sudoers.d/user-manager-web（示例，部署见 docs/web-deploy.md）
  %useradm ALL=(root) NOPASSWD: /usr/local/sbin/rl-web-exec
  %useradm ALL=(root) NOPASSWD: /usr/local/sbin/rl-chpasswd
  # 反向防护：禁止以 root 为目标的高危 action 经 web 入口执行
  %useradm ALL=(root) NOPASSWD: !/usr/local/sbin/rl-web-exec * root *
  ```

- 校验：`visudo -c -f /etc/sudoers.d/user-manager-web` 必须 `parsed OK`。

### 5.4 审计叠加（Web 身份 + OS 身份）

- 每次 Web 调用，Rust 在请求上下文注入 `WEB_USER` / `WEB_ROLE` / `WEB_SESSION_ID` /
  `SOURCE_IP` 环境变量；`rl-web-exec.sh` 与 `acl_audit_log` 读取并写入审计行。
- 审计行同时记录：**谁（Web 用户+角色）**、**以谁（OS 身份）**、**做了什么（action）**、
  **对象（target）**、**结果**、**来源 IP**、时间戳。满足「可追溯到具体浏览器用户」。

### 5.5 传输与存储安全

- 全站 HTTPS；Session Cookie `HttpOnly + Secure + SameSite=Lax`。
- `data/secrets/`、`web_users` 库、`email_config.json`、`wecom_config.json`（含加密 webhook）权限 0600/0640，属主 `umweb`。
- 登录失败限流 + 锁定；敏感 action（dangerous）前端二次确认 + 后端强制 reason 字段。

### 5.6 权限取舍说明

- **不采用**「按 Web 用户 `sudo -u` 到不同 OS 用户」：密码/凭据管理复杂、并发脆弱、
  与现有单服务部署模型冲突。
- **采用**「单服务身份 + 应用层 RBAC + 受控入口」：凭现有 sudoers 白名单模式即可安全落地，
  审计可追溯到 Web 用户，风险集中在服务进程本身，通过网络层（仅内网/反代 HTTPS）收敛。

---

## 6. 目录结构

```text
web/
├── backend/                        # Rust（axum）
│   ├── Cargo.toml
│   └── src/
│       ├── main.rs                 # 启动、路由装配、中间件
│       ├── config.rs               # 配置（绑定地址、DB、仓库根路径）
│       ├── auth/
│       │   ├── mod.rs              # 登录/登出/会话
│       │   ├── users.rs            # web_users 存储（SQLite）
│       │   └── password.rs         # argon2
│       ├── rbac/
│       │   ├── mod.rs              # check(action, role)
│       │   └── matrix.rs           # 角色→action 权限矩阵（权威源）
│       ├── exec/
│       │   ├── mod.rs              # 调 rl-web-exec，注入 WEB_* 环境
│       │   └── argv.rs             # 参数白名单校验（与 shell 侧对齐）
│       ├── audit.rs                # Web 侧审计查询/转发
│       ├── error.rs                # 错误码映射（0/1/2/3 → HTTP）
│       └── routes/
│           ├── mod.rs
│           ├── auth.rs             # POST /api/login /logout /me
│           ├── users.rs            # /api/users/... → users.* actions
│           ├── quota.rs            # /api/quota/... → users.quota
│           ├── smb.rs              # /api/smb/... → smb.* actions
│           ├── backup.rs           # /api/backup/... → backup.run
│           ├── logs.rs             # /api/logs/... → logs.*
│           ├── audit.rs            # /api/audit/... → audit.query
│           └── wecom.rs            # /api/wecom/... → wecom.config.* / wecom.test
│
├── frontend/                       # Ant Design Pro 6.0
│   ├── config/
│   │   ├── routes.ts               # 路由 + access 声明
│   │   └── defaultSettings.ts
│   ├── src/
│   │   ├── access.ts               # 前端权限（与后端矩阵对齐）
│   │   ├── app.tsx                 # initialState（拉 /api/me 权限）
│   │   ├── pages/
│   │   │   ├── Login/              # 登录页
│   │   │   ├── Users/              # 用户管理（列表/创建/配额/资源）
│   │   │   ├── Smb/                # SMB 账户与共享
│   │   │   ├── Backup/             # 备份
│   │   │   ├── Logs/               # 日志查看
│   │   │   ├── Wecom/              # 企业微信机器人配置（开关/webhook/事件/测试）
│   │   │   └── Audit/              # 审计查询
│   │   └── services/               # OpenAPI 生成的请求客户端
│   └── package.json
│
└── docs/
    ├── WEB_ARCHITECTURE.md         # Web 架构说明（本文档可演进）
    └── web-deploy.md               # 部署（umweb 用户 + sudoers + systemd + 反代）

scripts/
└── rl-web-exec.sh                  # 新增：受控执行入口（白名单 action + argv）
```

---

## 7. API 设计

统一响应包络与错误码对齐 Action CLI 规范：

```jsonc
// 成功
{ "ok": true, "data": { } }
// 失败
{ "ok": false, "error": { "code": "PERMISSION|PARAM|RUNTIME|AUTH", "message": "..." } }
```

| 方法 | 路径 | 调用的 action | 需要的 Web 角色 |
| --- | --- | --- | --- |
| POST | `/api/login` | —（校验 web_users） | 匿名 |
| POST | `/api/logout` | — | 任意 |
| GET | `/api/me` | —（返回角色与可访问 action 列表） | 任意 |
| GET | `/api/users` | `users.list` | viewer+ |
| POST | `/api/users` | `users.create` | admin |
| GET | `/api/users/:u/quota` | `users.quota --get` | operator+ |
| PUT | `/api/users/:u/quota` | `users.quota --set` | admin |
| GET | `/api/users/:u/resource` | `users.resource --get` | operator+ |
| PUT | `/api/users/:u/resource` | `users.resource --set` | admin |
| GET | `/api/smb/users` | `smb.list` | viewer+ |
| POST | `/api/smb/password` | `smb.password`（stdin 密码） | admin |
| GET | `/api/smb/shares` | `smb.shares` | viewer+ |
| POST | `/api/backup/:u` | `backup.run` | operator+ |
| GET | `/api/logs/boot` | `logs.boot` | viewer+ |
| GET | `/api/audit` | `audit.query` | viewer+ |
| GET | `/api/wecom/config` | `wecom.config.get`（脱敏） | admin |
| PUT | `/api/wecom/config` | `wecom.config.set`（webhook 加密） | admin |
| POST | `/api/wecom/test` | `wecom.test` | admin |

> 每个 handler 内部固定顺序：`auth → rbac.check → argv 校验 → exec(rl-web-exec) → 解析退出码 → 审计`。

---

## 8. 前端权限与信息架构

- `src/access.ts`：定义 `canUsersCreate / canQuotaSet / canSmbWrite / canBackupRun ...`，
  由 `/api/me` 返回的角色动态计算（与后端 `matrix.rs` 同源，后端为权威）。
- `config/routes.ts`：按角色声明 `access`，未授权路由自动 403 页。
- 菜单与按钮：`<Access accessible={canUsersCreate}>` 包裹「创建用户」等危险操作；
  「企业微信配置」入口与保存按钮用 `canWecomConfig`（admin）包裹，webhook 输入框为密码型且脱敏回显。
- 登录态：`initialState` 拉 `/api/me`，无会话跳登录页；Session 过期静默刷新或重登。
- 危险操作（dangerous）统一二次确认弹窗 + 必填「操作原因」，回传后端入审计 details。

---

## 9. 企业微信机器人入口配置

### 9.1 现状

- `lib/rl_wecom_bot_sender.sh` 是**预留通知接口**，默认关闭，经 `email_core.sh` 加载。
- 现状仅支持环境变量配置（`USER_MANAGER_WECOM_*`），无持久化配置、无 Web 入口，`rl_notify_send` 尚无调用方。
- 已具备能力：webhook 格式校验（`rl_wecom_validate_webhook`）、secret 脱敏
  （`rl_wecom_mask_secret`）、事件白名单（`rl_wecom_event_allowed`）、dry-run、统一频道分发
  `rl_notify_send <channel> <event> <payload>`。
- 回归保障：`tests/test_rl_wecom.sh`（默认关闭 no-op、非法 webhook 拒绝、脱敏、事件过滤等）。

### 9.2 Web 配置入口设计

Web 控制台提供一个「企业微信机器人」配置页，让 admin 在浏览器中完成启用、webhook 绑定、
dry-run 与事件订阅，并发送测试消息。配置持久化到 `data/wecom_config.json`（与 email 配置同级）。

配置 schema（webhook 含 secret key，必须加密存储）：

```json
{
  "enabled": false,
  "dry_run": true,
  "webhook_enc": "v1:<iv>:<ct>:<mac>",
  "events": ["user.created", "user.disabled", "quota.warning", "backup.completed"]
}
```

- 复用邮件 secret 的 **v1 加密方案**（AES-256-CBC + HMAC，encrypt-then-MAC，密钥
  `data/secrets/.key` 0600）；webhook 明文只在发送瞬间存在于内存，落盘即密文。
- 新增/扩展 shell 函数：
  - `wecom_config_load`：读取并解密 webhook。
  - `wecom_config_save`：校验 webhook 格式 → 加密 → 0600 原子落盘。
  - `wecom_config_get_masked`：返回脱敏配置（webhook 仅回显 `...key=***`）供 UI 展示。
  - `rl_wecom_bot_send_text` / `rl_notify_send` 改为优先读持久化配置，env 作为部署期覆盖。

### 9.3 新增 Action 与 API

| Action | 说明 | risk | Web 角色 | API |
| --- | --- | --- | --- | --- |
| `wecom.config.get` | 读取脱敏配置 | safe | admin | `GET /api/wecom/config` |
| `wecom.config.set` | 保存配置（webhook 加密） | dangerous | admin | `PUT /api/wecom/config` |
| `wecom.test` | 发送测试消息 | safe | admin | `POST /api/wecom/test` |

- `wecom.config.set` 的 webhook 与事件列表经 argv 白名单校验；webhook 走 secret 文件/stdin，不进命令行/ps/审计明文。
- `wecom.test` 复用 `rl_wecom_bot_send_text`，尊重 dry-run 开关（dry-run 下不真正外呼，仅记录）。

### 9.4 权限与审计

- 仅 **admin** 可读改配置；`wecom.test` 有外部副作用，同样归 admin。
- webhook 属 secret：UI 脱敏回显、审计调用 `rl_wecom_mask_secret` 脱敏、落盘加密、文件 0600。
- 配置变更写入审计：`WEB_USER + OS 身份 + wecom.config.set + enabled/events + 结果`，webhook 本身脱敏。

### 9.5 通知接线（增量）

- 配置入口为本期重点；业务事件接线（如 `user.created`/`quota.warning`/`backup.completed` 调
  `rl_notify_send wecom ...`）作为增量，在 P3 之后按需接入，与现有 `rl_mail_events` 对齐触发点。

---

## 10. 分阶段实施路线

主线 7 个阶段（P0–P6）已把 §12 全部功能纳入。每阶段独立可验收，且保持「Bash Core 零改动或仅增量新增受控入口」，确保 CLI/TUI 现状不回退。

### P0 — 受控执行入口（地基）

- 新增 `scripts/rl-web-exec.sh`：白名单 action + argv 校验 + 环境净化 + `WEB_*` 审计注入。
- 新增 action `wecom.config.get/set`、`wecom.test`；`data/wecom_config.json` 加密存储；扩展 `rl_wecom_bot_sender.sh`（`wecom_config_load/save/get_masked`）。
- **验收**：只读 action 跑通；注入 argv / 未注册 action / root 目标被拒；wecom 配置加密落盘；`tests/test_web_exec.sh` 与 `tests/test_rl_wecom.sh` 扩展通过。

### P1 — Rust 骨架 + 认证 + 安全底座

- axum 骨架、`config`、错误码映射（0/1/2/3 → HTTP）。
- `web_users`（SQLite + argon2）、登录/登出/me、RBAC 矩阵（权威源）、exec 封装。
- **MFA/TOTP**（`totp_secret` 加密，可强制 admin）、**会话管理**（列出/强制下线）、**登录审计**（成败/IP/UA）、**API Token 管理**（角色 + action 白名单 + 过期）。
- **验收**：登录 + MFA；`/api/me` 返回角色与权限；token 认证；强制下线生效；登录写入审计；`cargo test` + 越权 403 用例。

### P2 — 用户/配额/资源 API + 自助 + 批量

- users/quota/resource 路由 + argv 校验 + dangerous 二次确认字段。
- **用户自助门户**：改自己密码、看自己配额/资源（仅本人，禁越权）。
- **批量操作**：批量建用户、批量设配额（进度 + 部分失败处理，复用 `backup_core` parallel 思路）。
- **验收**：operator 调 admin action 被拒并审计；自助接口无法操作他人；批量部分失败可恢复。

### P3 — SMB/备份/日志/审计 API + 备份恢复 + 审批流

- smb/backup/logs/audit 路由。
- **备份浏览器与一键恢复**：备份索引可视化、校验状态、按批次恢复向导。
- **操作审批流**：dangerous action 需第二人 approve 后才执行（双人控制）。
- **验收**：密码类操作不进 argv（ps 检查）；恢复向导数据正确；审批门禁强制执行。

### P4 — 企业微信 + 通知中心 + 预警自动化

- 企业微信配置页 + 测试（复用 P0 actions 与 `routes/wecom.rs`）。
- **通知中心**：站内收件箱 + WebSocket 实时推送。
- **通知接线**：`user.created`/`quota.warning`/`backup.completed` → `rl_notify_send`（与 `rl_mail_events` 对齐触发点）。
- **配额预警自动化**：超 `DISK_WARNING_THRESHOLD` 自动告警并通知。
- **验收**：webhook 加密 + UI/审计脱敏；事件触发通知落库并推送；超阈自动告警。

### P5 — 前端控制台（全页面 + 门面）

- Ant Design Pro 6.0（Umi 4 + antd 6 + TS）：登录、布局、路由/按钮权限、OpenAPI 客户端。
- **总览仪表盘 Dashboard**（登录首页汇总）+ **资源使用趋势图**（数据来自 `report_core`）。
- 全部页面：Users / Smb / Backup / Logs / Audit / Wecom 配置 / 通知中心 / 安全中心 / 会话 / API Token。
- **实时日志流**（WebSocket tail）、**国际化 + 暗色主题**、**配置中心**（SMTP/阈值/默认值/企微）。
- **验收**：按角色渲染菜单与按钮；Dashboard 渲染；实时日志滚动；i18n/暗色切换；趋势图数据来自 `report_core`。

### P6 — 部署加固 + 集群只读 + 定时报表

- `umweb` 用户、sudoers、systemd、反代 HTTPS、限流、`docs/web-deploy.md`。
- **多主机只读仪表盘**：汇总 `host.probe`/`gpu.summary` 成集群视图（仍只读，不越 REMOTE_HOSTS 边界）。
- **定时报表订阅**：周期生成 HTML/CSV 报告并推送（`report_core` + `systemd_timer_core`）。
- **验收**：`visudo -c` 通过；非授权 action 全链路拒绝；集群视图只读；CLI/TUI 现有回归不回退（`run_regression.sh --level all`）。

> 阶段依赖：P0 是地基；P1 不依赖 P2–P6；P2/P3/P4 的 Rust 路由可并行开发；P5 聚合所有后端能力；P6 部署贯穿全程、最终收口。

---

## 11. 风险、边界与验收

### 11.1 主要风险与缓解

| 风险 | 缓解 |
| --- | --- |
| 服务进程被攻破后滥用提权 | 单服务身份 + sudoers 仅授权受控入口；入口拒绝任意命令与注入；反向规则禁 root 目标 |
| Web 用户与 OS 用户混淆导致越权 | 双层 RBAC；审计同时记录 Web 身份与 OS 身份；矩阵后端权威 |
| 密码/webhook key 泄露到 argv/日志 | 密码仅走 stdin/secret 文件；webhook 加密落盘 + UI/审计脱敏；沿用 rl-chpasswd 与 v1 加密 secret |
| Bash 与 Rust 双重实现导致行为漂移 | Rust 只做网关，业务单源在 Bash；契约用 action ID + 错误码固定 |
| 危险操作误触 | 前端二次确认 + reason；后端强制校验；全量审计 |

### 11.2 边界

- Web 首期覆盖本地动作；跨主机仍只读（`host.probe`/`gpu.summary`），不开放远程写。
- `owner` 角色默认不为 Web 开放 visudo 级操作。

### 11.3 验收清单

**权限与安全**

- [ ] `rl-web-exec.sh` 拒绝未注册 action 与注入 argv（含 root 目标）。
- [ ] 每个 Web action 都经过 `auth → rbac → argv → exec → audit`。
- [ ] 越权请求返回 403 且写入审计 `DENIED`。
- [ ] 密码类操作 `ps` 中不可见明文；企业微信 webhook 落盘加密，UI 与审计均脱敏。
- [ ] MFA 可强制 admin；会话可被强制下线；登录成败/IP/UA 入审计。
- [ ] API Token 绑定角色 + action 白名单 + 过期，越权 token 被拒。
- [ ] dangerous action 审批门禁生效（双人控制），未批准不执行。

**功能与体验**

- [ ] 用户自助门户只能操作本人，无法访问他人配额/资源。
- [ ] 批量操作有进度与部分失败处理；备份可按批次恢复。
- [ ] 通知中心收到业务事件推送；超 `DISK_WARNING_THRESHOLD` 自动告警。
- [ ] 前端按角色渲染菜单与按钮，`/api/me` 与前端 access 一致。
- [ ] Dashboard/趋势图/实时日志流可用；i18n 与暗色主题可切换。

**部署与回归**

- [ ] `visudo -c` 通过；非授权 action 全链路拒绝。
- [ ] 多主机视图只读，不越 REMOTE_HOSTS 边界；定时报表可订阅推送。
- [ ] CLI/TUI 现有回归不回退（`run_regression.sh --level all`）。

---

## 12. 功能全景索引表

§12 已全部纳入 P0–P6 主线。本表作为总清单，标注每项的功能域、落地阶段、所需角色与复用模块，便于跟踪进度与分派。

| # | 功能 | 域 | 阶段 | 角色 | 复用模块 |
| --- | --- | --- | --- | --- | --- |
| 1 | 受控执行入口 `rl-web-exec` | 基础 | P0 | — | action_registry / privilege |
| 2 | 企业微信配置 + 测试 | 通知 | P0/P4 | admin | rl_wecom_bot_sender / secrets |
| 3 | 认证（登录/会话/me）+ RBAC | 基础 | P1 | 任意 | auth / rbac |
| 4 | MFA/TOTP | 安全 | P1 | admin 可强制 | auth / secrets |
| 5 | 会话管理 | 安全 | P1 | admin | auth |
| 6 | 登录审计 | 安全 | P1 | admin | audit_core |
| 7 | API Token 管理 | 安全 | P1 | admin | auth / rbac |
| 8 | 用户/配额/资源 API | 用户 | P2 | viewer+/admin | user_core / quota_core / resource_core |
| 9 | 用户自助门户 | 用户 | P2 | user（本人） | user_core / quota_core / resource_core |
| 10 | 批量操作 | 效率 | P2 | admin | user_core / backup_core |
| 11 | SMB/备份/日志/审计 API | 运维 | P3 | viewer+/admin | smb_core / backup_core / logs_core / audit_core |
| 12 | 备份浏览器与一键恢复 | 运维 | P3 | operator+/admin | backup_core / backup_verify |
| 13 | 操作审批流 | 安全 | P3 | admin 发起/审批 | rbac / audit |
| 14 | 通知中心（站内 + 推送） | 通知 | P4 | viewer+ | audit + WebSocket |
| 15 | 通知接线（业务事件） | 通知 | P4 | 系统自动 | rl_notify_send / rl_mail_events |
| 16 | 配额预警自动化 | 监控 | P4 | 系统自动 | quota_core + rl_notify_send |
| 17 | 前端控制台 + 路由权限 | 前端 | P5 | 按角色 | Ant Design Pro 6.0 |
| 18 | 总览仪表盘 Dashboard | 前端 | P5 | viewer+ | report/system/gpu/quota_core |
| 19 | 实时日志流 | 前端 | P5 | viewer+ | logs_core / journalctl_core + WebSocket |
| 20 | 国际化 + 暗色主题 | 前端 | P5 | 任意 | antd 6 |
| 21 | 配置中心 | 前端 | P5 | admin | config / rl_mail_config / wecom_config |
| 22 | 资源使用趋势图 | 监控 | P5 | viewer+ | report_core |
| 23 | 多主机只读仪表盘 | 监控 | P6 | viewer+ | host_inventory / host_provider / execution_plan |
| 24 | 定时报表订阅 | 监控 | P6 | admin | report_core / systemd_timer_core |

### 12.1 落地原则

- **不重写业务**：所有功能仍走 `rl-web-exec` → Bash Core，Rust 只做编排与展示。
- **权限一致**：新功能默认沿用四级角色 + action risk；dangerous 一律二次确认 + 审计。
- **secret 一致**：任何新增凭据（TOTP、API token、webhook）都走 v1 加密 + 0600 + 脱敏。
- **增量交付**：每项可独立成 PR，不破坏 CLI/TUI 现状。

---

## 附：与现有文档的关系

- 业务架构基线来自 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)。
- 权限/sudoers 细节来自 [`docs/sudoers-deploy.md`](docs/sudoers-deploy.md)。
- 跨主机只读边界来自 [`docs/REMOTE_HOSTS.md`](docs/REMOTE_HOSTS.md)。
- 本文聚焦 Web 化新增部分，后续 Web 架构细节可沉淀到 `docs/WEB_ARCHITECTURE.md`。
