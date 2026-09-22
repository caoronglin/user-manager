# User Manager Web Console (`umweb`)

非特权 Rust Web 控制台。定位：**认证、展示、查询、审计、通知、非特权配置与只读观测**。
它**不是**浏览器版 root 运维终端，也**不**执行任何系统写操作。

技术栈：Rust + axum + tokio + rusqlite + Argon2id + TOTP(P4) + Ant Design Pro 6(P5)。

> ## ✅ 验证状态
> 本目录为 **P1 骨架**，已在 Rust 工具链（1.98）完成编译与全部质量门禁：
> `cargo fmt --check`、`cargo clippy --all-targets -- -D warnings`、`cargo test`、
> `cargo audit`、`cargo deny check` 全部通过。Cargo.lock 与 deny.toml 已入库。
> 后续 P2+ 继续遵循同一门禁。

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

## P1 范围（骨架已含，待工具链验证 + 补齐）

- [x] axum 骨架、config、tracing、request-id、健康检查
- [x] capability RBAC（默认拒绝 + 只读快照 kind 白名单映射）
- [x] CSRF/Origin（仅作用于已注册变更路由）、security headers（CSP/HSTS/nosniff/Referrer-Policy/Permissions-Policy）
- [x] rate limit（IP+username 双维、指数退避）
- [x] Argon2id 密码哈希、服务端会话（hash-only、HttpOnly/Secure/SameSite=Strict Cookie）
- [x] SQLite schema（web_users/sessions/api_tokens/wecom_settings/web_audit）
- [x] 危险路由不存在（契约测试：POST /api/users → 404 等）
- [x] `cargo fmt/clippy/test/audit/deny` 全部通过（Rust 1.98）
- [ ] /login /logout /me 完整接线、MFA/TOTP、Snapshot 读取（P2/P4）

## 本地运行（需 Rust）

```bash
cd web/backend
export UMWEB_DB_PATH=/tmp/umweb.db
export UMWEB_SNAPSHOT_DIR=/var/lib/user-manager-web/snapshots
export UMWEB_REQUIRE_TLS=0
cargo run
curl -s localhost:8080/api/health
```
