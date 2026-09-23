# User Manager Web Console (`umweb`)

非特权 Rust Web 控制台。定位：**认证、展示、查询、审计、通知、非特权配置与只读观测**。
它**不是**浏览器版 root 运维终端，也**不**执行任何系统写操作。

技术栈：Rust + axum + tokio + rusqlite + Argon2id + TOTP(P4) + Ant Design Pro 6(P5)。

> ## ✅ 验证状态
> P1 基线已在 Rust 工具链（1.98）完成编译与全部质量门禁：
> `cargo fmt --check`、`cargo clippy --all-targets -- -D warnings`、`cargo test`、
> `cargo audit`、`cargo deny check` 全部通过。Cargo.lock 与 deny.toml 已入库。
> 后续 API 阶段沿用同一质量门禁；P4c 通知 inbox 的当前改动尚待本地回归验证。

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
- [ ] P4 后续：WeCom 配置与发送、投递记录、事件目录与节流合并、root 事件 spool 消费

## 本地运行（需 Rust）

```bash
cd web/backend
export UMWEB_DB_PATH=/tmp/umweb.db
export UMWEB_SNAPSHOT_DIR=/var/lib/user-manager-web/snapshots
export UMWEB_REQUIRE_TLS=0
cargo run
curl -s localhost:8080/api/health
```
