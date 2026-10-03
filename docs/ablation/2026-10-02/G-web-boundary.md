# G — Web 能力边界守卫消融（静态）

| 场景 | 守卫名 | 守卫位置 | 判定 | 消融方法 | 复现命令 | 观测差异 | 证据 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| G1 | capability 默认拒绝（未知角色 → 空集合） | `web/backend/src/auth/rbac.rs:15-17`（`capabilities_for` 的 `.unwrap_or` 分支）；消费点 `web/backend/src/auth/guard.rs:89` → `:100` `Auth::require` | **STATIC-ONLY** | 静态消融：把 `allowed: BTreeSet::new()` 换成 `allowed: BTreeSet::from(KNOWN_CAPS.iter()…)`，只改守卫分支，消费链不动。**未编译、未运行** | `bash .validation/ablation-2026-10-02/harness/G1-web-capability-default-deny.sh` | 无运行时观测可报。本机 `cargo`/`rustc`/`rustup` 三者均 MISSING，消融后代码从未编译，因此**不存在观测差异**。仅可陈述静态事实：分支存在于 `rbac.rs:15-17`，经 `guard.rs:89` 汇入 `Auth.capabilities`，由 `guard.rs:100` 的 `require()` 消费，`web/backend/src/http` 下共 36 处 `auth.require(...)` 调用点 | `harness/G1-web-capability-default-deny.sh`、`logs/G1-web-capability-static.txt` |

## 有效判据自检

| 场景 | 自检1 baseline 拒绝理由指向守卫 | 自检2 ablated 真实走通 | 自检3 无 127/函数缺失 |
| --- | --- | --- | --- |
| G1 | 不适用（无运行时） | **不满足**（无 cargo/rustc，消融侧从未编译或执行） | 不适用 |

自检 2 不满足 ⇒ 依判定口径不得出具 GUARD-ACTIVE，只能记 STATIC-ONLY。

## 静态可断言的事实（有源码行号为证）

1. `capabilities_for(config, role)`（`rbac.rs:10-19`）对未在 `config.capabilities` 中出现的角色返回 `Capabilities { allowed: 空集合 }`，`is_allowed`（`:21-23`）随之返回 false。
2. 该集合唯一的生产消费点是 `guard.rs:89` `rbac::capabilities_for(&state.config, &session.role)`，写入 `AuthContext.capabilities`；`Auth::require`（`guard.rs:100`）在 `allows(cap)` 为假时返回 403 语义错误。
3. `http/` 下 36 处 `auth.require(<cap>)` 全部走这条链，无 handler 绕过。
4. 快照 kind 侧另有独立白名单：`CAP_TO_SNAPSHOT`（`rbac.rs:27`）与 `capability_for_snapshot`（`:41`），未映射即 `None`（拒绝）。
5. API Token 侧 `KNOWN_CAPS` / `TOKEN_READ_CAPS`（`rbac.rs` 尾部）同样只做交集收窄，不做放行。

## 静态消融做了什么、没做什么

改动只有一处：把「未知角色 → 空集合」替换为「未知角色 → `KNOWN_CAPS` 全集」。若该分支真被执行，未知/伪造角色将获得全部已声明能力。

**但本次没有验证这件事发生**：没有 `cargo check`、没有 `cargo test`、没有启动后端、发过任何 HTTP 请求。消融后的表达式是否通过借用检查、`BTreeSet::from` 是否匹配 `Capabilities.allowed` 的类型，均未验证。按任务硬约束，此处严禁写成 GUARD-ACTIVE。

## 复现该结论所需的最小后续动作（不在本轮范围）

在有 Rust 工具链的环境执行：

- `cargo check -p user-manager-backend`（确认静态消融可编译）；
- 对 `capabilities_for` 补一条断言测试：`is_allowed(&cfg, "nonexistent-role", "users.read") == false`，消融后该断言必须失败——这才是把 G1 从 STATIC-ONLY 升级为 GUARD-ACTIVE 的唯一合法路径。

## 备注

`rbac.rs` 文件头注释（`:1-5`）明确写着铁律：绝不把 `action_registry.sh` 的 `risk=safe` 当作 Web-safe。这与 B1 的结论互为印证——B1 侧 risk 是纯展示元数据，Web 侧另有一套独立的、默认拒绝的能力模型，两套不共享信任。
