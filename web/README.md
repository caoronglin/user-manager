# User Manager Web Console (`umweb`)

非特权 Rust Web 控制台。定位：**认证、展示、查询、审计、通知、非特权配置与只读观测**。
它**不是**浏览器版 root 运维终端，也**不**执行任何系统写操作。

技术栈：Rust + axum + tokio + rusqlite + Argon2id + TOTP；前端为 React 19 + Vite 8 + Ant Design 6。当前前端尚未迁移到计划中的 Umi / Ant Design ProComponents。

> ## ✅ 验证状态
> **2026-09-24 工作树验证：** Rust fmt、Clippy 通过，后端 65 个测试通过；前端离线依赖安装、生产构建通过，npm 报告 0 个依赖漏洞。Ops 快照 7/7、安全加固 25/25、事件 spool 11/11、systemd 边界 9/9 通过。完整 Shell 回归为 41 个套件通过、0 个失败、1 个可选性能套件跳过。
> 生产构建仍提示 Ant Design `use client` 和约 1.12 MB 主 JS bundle。系统 Chrome/Playwright 已走通临时账号密码登录→TOTP→Dashboard，并验证主要数据页、键盘菜单/筛选、移动抽屉与窄屏表格导航；完整 WCAG/读屏器审计和目标机部署仍待验收。Web 原生 inbox 事件现由独立非特权 worker 按固定模板投递 WeCom；真实 webhook 与多实例共享 SQLite 未验证。版本与阶段状态见根目录 [`plan.md`](../plan.md) 与 [`docs/M1_REPOSITORY_AUDIT.md`](../docs/M1_REPOSITORY_AUDIT.md)。

## 安全边界（最高优先级）

见仓库根 `docs/WEB_SECURITY_BOUNDARY.md`。要点：

- `umweb` 永不提权：无 root/sudo/setuid/capability/特权 socket；
- 不执行系统写操作；不调用 `action_run`/`priv_exec`/写路径；
- 不 fork shell/命令/任意 SSH；
- 系统数据仅经**只读 Snapshot**（root:umweb 0640）观测；Web 只读快照；
- 危险接口（users/smb/hosts/system 写）**根本不存在**，命中即 404/405；
- Web 自身身份/会话/令牌/企业微信走独立 DB + 独立 secret master key。

`scripts/check_web_security.sh`（已接入 CI security job 与 `tests/run_regression.sh`）
对 `web/backend/src` 做**阻断式**扫描，禁止提权/系统管理命令/任意进程派生。

## 目录

```text
web/backend/
  Cargo.toml
  src/
    main.rs        二进制入口（薄封装 → lib::run）
    lib.rs         crate 根，run() 组装 serve
    config.rs      运行配置 + 角色→能力 allowlist（默认拒绝）
    telemetry.rs   结构化日志 + secret redaction
    state.rs       AppState（DB / 会话 / 限流 / 能力）
    error.rs       统一错误 → HTTP（脱敏）
    store/         SQLite schema（仅 Web 自身数据；无明文 secret）
    auth/          password(Argon2id) / session / csrf / rate_limit / rbac
    http/          routes / middleware(request-id, 安全头, CSRF+Origin) / response
  tests/
    api_contract.rs  危险路由必须 404/405 + capability 默认拒绝
web/frontend/        React/Vite/Ant Design 前端
```

## 实现进度

- [x] axum 骨架、config、tracing、request-id、健康检查
- [x] capability RBAC（默认拒绝 + 只读快照 kind 白名单映射）
- [x] CSRF/Origin（仅作用于已认证会话的变更路由；登录为预认证豁免）、security headers
- [x] rate limit（IP+username 双维、指数退避）
- [x] Argon2id 密码哈希、服务端会话（hash-only、HttpOnly/Secure/SameSite=Strict Cookie）
- [x] SQLite schema（web_users/sessions/api_tokens/wecom_settings/web_audit）
- [x] 危险路由不存在（契约测试：写方法 404/405）
- [x] `cargo fmt/clippy/test/audit/deny` 全部通过（Rust 1.98）
- [x] login/logout/me 完整接线；capability 默认拒绝（无会话 401 / 不足 403）
- [x] P2 只读系统 API：users/quota/resources/smb/hosts/gpu/system-summary，全部来自 Snapshot，附 freshness（fresh/stale/缺失显式标识）
- [x] P3 Logs/Audit/Reports 只读 API（audit 过滤+游标+导出上限；logs allowlist 源；reports 元数据索引）
- [x] P4a Web 用户管理（web_users.manage：list/create/patch/delete，绝不触碰 Linux 账户）
- [x] P4a MFA/TOTP：setup/verify/challenge/disable；secret 加密（AES-256-GCM，Web 独立 master key）；登录两步挑战
- [x] P4a Session 管理：列出活跃会话、CSRF 保护的撤销、过期会话清理
- [x] P4b API Tokens：create(一次性明文)/list(无明文无hash)/revoke；DB 仅存 SHA-256 hash；仅允许只读 capability；Bearer 认证可用于只读 API
- [x] P4c 通知 inbox API：读取/未读计数、事件类型过滤、限量游标分页、标记已读/全部已读、event_id 幂等去重；权限由 notifications.read/manage 控制
- [x] P4d WeCom 管理 API：事件目录、加密 Webhook、脱敏设置、版本冲突保护、固定模板测试投递与有界投递历史；重试限定网络/超时/429/5xx 并有上限
- [x] P4e root event spool：安全读取固定 root-owned 目录，`user.created`/`user.disabled` 幂等进入 inbox；按配置投递 WeCom，五分钟按事件类型/用户去重，限制并发和重试
- [x] P4f Web inbox 事件：密码校验失败按五分钟全局桶合并，Token 首次成功撤销与经校验 manifest 的 fresh/stale 转换写固定脱敏通知；未知/缺失状态不误报
- [x] P4g 原生事件投递：`security.login_failed`、`security.token_revoked`、`snapshot.freshness_changed` 使用独立 outbox/worker、固定消息模板和有界重试；不外发个人信息或通知详情
- [ ] P4 后续验收：在目标机验证服务和真实 webhook；当前 worker 假定每个 SQLite 数据库只有一个 `umweb` 实例
- [x] P5 前端页面：登录/MFA、Dashboard、用户/配额/资源、SMB、主机/GPU、系统状态、日志、审计/报表、WeCom 设置/投递历史；能力控制、快照新鲜度提示、主题和中英文切换
- [ ] P5 验收：真实密码+TOTP 登录、主要数据页权限/交互、键盘菜单/筛选、窄屏表格导航已验证；完整 WCAG/读屏器审计仍待完成。当前工程使用 React/Vite/Ant Design，没有采用计划中的 Umi/ProComponents
- [x] P6 Ubuntu Ops 快照：系统与 CPU/内存/PSI、文件系统/inode、systemd、APT/reboot、AppArmor；单节不可用时降级，新增回归 7/7 通过
- [ ] P7 `v0.2.0` 是当前已发布版本；`v0.3.0` 候选版已准备，版本提交 CI 通过后发布；目标机与真实 webhook 验收仍待完成

## 本地运行（需 Rust）

```bash
cd web/backend
export UMWEB_DB_PATH=/tmp/umweb.db
export UMWEB_SNAPSHOT_DIR=/var/lib/user-manager-web/snapshots
export UMWEB_REQUIRE_TLS=0
cargo run
curl -s localhost:8080/api/health
```
