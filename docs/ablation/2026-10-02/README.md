# 守卫消融实验报告 2026-10-02

基线 `main` @ `62f00fc`。本目录所有报告均由 `.validation/ablation-2026-10-02/harness/` 下的消融脚本产出。

## 0. 生产源码零改动证明

消融全部发生在 `.validation/ablation-2026-10-02/work/` 下的隔离硬链接副本中，基线树只准备一次并被所有场景复用。收尾时刻实测 `git status --short`（HEAD 仍为 `62f00fc`）：

```
 M lib/config.sh
 M tests/run_regression.sh
?? .validation/
?? docs/ablation/
?? docs/audit/
?? tests/test_runtime_dir_contract.sh
```

**本报告系列只写入 `docs/ablation/**` 与 `.validation/ablation/**` 两棵未跟踪目录。** 表中两条 ` M` 与新增的 `tests/test_runtime_dir_contract.sh` 属于并发工作流 W-C（修改 `lib/config.sh` 与测试文件），不是本系列产物；`docs/audit/` 属于 W-B（只读审计）。全程无任何 git 写操作（未执行 add/commit/stash/checkout/reset/clean）。

被本系列消融的全部源文件与 `62f00fc` 逐字节一致——`git diff --name-only 62f00fc` 的输出仅有 `lib/config.sh` 与 `tests/run_regression.sh` 两条，均非本系列触碰：

```
lib/config.sh
tests/run_regression.sh
```

W-C 漂移的时间线已核实：`lib/config.sh` 的 mtime 为 `22:03:46`，晚于 D1 执行时刻（`22:00:54`），因此 D1 是在 `62f00fc` 版 config.sh 上跑出的结果。E1 与 F1 的探针根本不 source `lib/config.sh`（只 source `smb_core.sh` / `common.sh` + `user_core.sh`），不受该漂移影响。

基线回归 `bash tests/run_regression.sh --level all` 收尾实测 **44 passed / 0 failed / 1 skipped**。相对任务书给定的 43 passed 多出的 1 个，来自 W-C 新增的 `tests/test_runtime_dir_contract.sh`；本系列未新增、未修改、未删除任何测试文件。

## 1. 实验环境限制

- 本机无 `cargo` / `rustc`，`web/backend` 侧只能做静态消融与静态判定，不得出具 GUARD-ACTIVE。
- 并发工作流 W-C 会修改 `lib/config.sh` 与个别测试文件；凡读到与 `62f00fc` 不符的内容，一律以 `git show 62f00fc:<path>` 为基线并在对应报告标注。
- 消融一律在 `.validation/ablation-2026-10-02/work/` 下的隔离副本进行，硬链接复制，零生产写入。

## 2. 判定口径

| 判定 | 含义 |
| --- | --- |
| GUARD-ACTIVE | baseline 因该守卫被拒，消融后同一操作真实走通 |
| GUARD-INERT | 消融守卫后行为无变化，守卫未被强制执行 |
| GAP | 守卫存在但覆盖面有缺口（接线缺失、旁路、只写不读） |
| EXPERIMENT-INVALID | 消融侧拿不到成功证据（127/函数缺失等假失败），不作结论 |
| NOT-APPLICABLE | 该文件不存在可消融的守卫 |
| STATIC-ONLY | 静态消融/静态判定，未运行时验证 |

## 3. 有效判据（硬约束）

消融只移除「守卫」，保留「能力」。每个场景必须自带自检：

1. baseline 侧被拒，且拒绝消息明确指向被消融的守卫；
2. ablated 侧操作真实走通（stub 日志执行记录 / 产出文件 / rc=0）；
3. 两侧都不是「命令不存在 / 函数未找到 / rc=127」这类假失败。

第 2 条拿不到成功证据 ⇒ 判 EXPERIMENT-INVALID，不许凑数。

## 4. 场景总表

| 场景 | 守卫名 | 守卫位置 | 判定 | 消融方法 | 复现命令 | 观测差异 | 证据 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| A1 | priv_exec 命令白名单 | `lib/privilege.sh:166-171` | GUARD-ACTIVE | 删除 `priv_check_whitelist` 判定整块，保留 `priv_get_required_level`/级别门禁/wrapper | `bash .validation/ablation-2026-10-02/harness/A1-priv-whitelist.sh` | baseline rc=1 + `Command curl is not in the privilege whitelist` + audit PRIV_DENIED + 未执行；消融 rc=0 + stub 实录 `sudo curl http://example.invalid/x` + audit PRIV_EXEC | `.validation/ablation-2026-10-02/harness/A1-priv-whitelist.sh` |
| A5 | priv_exec 权限级别门禁 | `lib/privilege.sh:172-182` | GUARD-ACTIVE | `ab_drop_block` 删级别比较 5 行；**保留** `PRIV_CMD_WHITELIST`、`priv_get_required_level`、全部 wrapper | `bash .validation/ablation-2026-10-02/harness/A5-priv-level.sh` | baseline rc=1 + `Insufficient privileges for 'chmod'. Required level: 1, Current: 2` + audit PRIV_DENIED + 未执行；消融 rc=0 + stub 记录 `sudo chmod 700 .../target` | `.validation/ablation-2026-10-02/harness/A5-priv-level.sh` |
| A3 | run_privileged shell trampoline 拒绝 | `lib/common.sh:93-99` | GUARD-ACTIVE | `ab_drop_block` 删 `case bash\|sh\|sudo\|su` 6 行；**保留** `:89-92` 选项作命令名守卫与 sudo 执行路径 | `bash .validation/ablation-2026-10-02/harness/A3-run-privileged.sh` | baseline rc=1 + `拒绝执行不安全的 shell trampoline: bash` + 未执行；消融 rc=0 + stdout 实见 `TRAMPOLINE-EXECUTED` + stub 记录 `sudo bash -c ...` | `.validation/ablation-2026-10-02/harness/A3-run-privileged.sh` |
| A4 | check_permission 默认拒绝 | `lib/privilege.sh:406` | GUARD-ACTIVE | `ab_sub` 把未知 key 默认级别 ADMIN(1) 改为 GUEST(3)；**保留** `run_with_permission`/`require_permission`/`PERMISSION_MATRIX` | `bash .validation/ablation-2026-10-02/harness/A4-permission-default-deny.sh` | baseline rc=1 + `权限不足: 需要 totally:unknown:unknown 权限` + 未产出文件；消融 rc=0 + `victim.txt` 真实生成 | `.validation/ablation-2026-10-02/harness/A4-permission-default-deny.sh` |
| B1 | action safe/dangerous 分类的执行期强制 | 登记 `lib/action_registry.sh:9,54,72`；唯一展示读取 `:361`（`action_info()`，死函数）与 `scripts/rl-action-list.sh:66,74`；**执行期零判定点** | GUARD-INERT（非安全漏洞） | `ab_sub` 把 risk 形参固化为 `safe` 抹掉 dangerous 登记；handler 注册、`action_run` 分发、requires 检查全部保留 | `bash .validation/ablation-2026-10-02/harness/B1-action-risk.sh` | baseline `registered_risk=dangerous` 但 `action_run probe.dangerous cli` 仍 rc=0、handler 真实执行；消融 `registered_risk=safe` 同样 rc=0 真实执行，两侧零行为差异。防线在 `requires`→`priv_exec`→白名单/ACL 链（A1/A5 已证 ACTIVE） | `.validation/ablation-2026-10-02/harness/B1-action-risk.sh` |
| B2 | registry ↔ handler 接线一致性 | 登记 `lib/action_registry.sh:364-393`；执行期 handler 存在性检查 `:147-150` | NOT-APPLICABLE（审计通过，无缺口） | 非消融，只读静态审计：`lib/*.sh`+`scripts/*.sh` 定义名（1061 个）与 29 条登记 handler 双向比对 | `bash .validation/ablation-2026-10-02/harness/B2-registry-handler-wiring.sh` | `TOTAL=29 MISSING_HANDLER=0`，无 `HANDLER_NOT_REGISTERED`。接线完整，不存在 GAP 候选 | `.validation/ablation-2026-10-02/logs/B2-wiring.txt`、`B2-defined-funcs.txt` |
| C1 | 快照目录逐段符号链接拒绝 | `lib/snapshot_core.sh:181` | GUARD-ACTIVE | `ab_sub` 把逐段 `-L` 拒绝换成 `:`；`snapshot_ensure_dir`、`enter_safe_dir`、原子安装全部保留 | `bash .validation/ablation-2026-10-02/harness/C1-snapshot-symlink.sh` | 守卫本体 baseline `resolve_rc=1`+「快照目录包含符号链接或路径无效」；消融 `resolve_rc=0`+返回被跟随后的路径。纵深侧 `:233` `pwd -P` 比对仍拦（rc=1），属冗余守卫非缺口 | `.validation/ablation-2026-10-02/harness/C1-snapshot-symlink.sh` |
| C2 | 快照写失败关闭（临时文件+原子安装） | `lib/snapshot_core.sh:298-301` | GUARD-ACTIVE | `ab_sub` 把 mktemp 失败中止换成直写目标；写快照能力、`apply_owner`、`sync` 全保留。失败注入：PATH 前置 stub `mktemp` 恒非零 | `bash .validation/ablation-2026-10-02/harness/C2-snapshot-fail-closed.sh` | baseline rc=1+「无法创建临时快照文件」+既有 manifest 完好 `PREVIOUS-GOOD-CONTENT`；消融守卫消失后同一次失败写**摧毁既有快照** `EXISTING_SNAPSHOT=deleted` | `.validation/ablation-2026-10-02/harness/C2-snapshot-fail-closed.sh` |
| D1 | rl_mail_queue HMAC-SHA256 完整性 | `lib/rl_mail_queue.sh:243` | GUARD-ACTIVE | `ab_sub` 把 MAC 比对 `|| exit 1` 换成恒真 `:`；base64 解码、IV 长度校验、hex 正则、openssl 解密、encrypt-then-MAC 顺序全部保留 | `bash .validation/ablation-2026-10-02/harness/D1-mail-hmac.sh` | 未篡改两侧均 rc=0 且还原 `SMTP_PASSWORD_TOP_SECRET`（能力保留）；翻转首块 ciphertext 后 baseline `tamper_rc=1 ACCEPTED_TAMPER=no`，消融 `tamper_rc=0 ACCEPTED_TAMPER=yes` 并把篡改密文当合法明文输出 | `.validation/ablation-2026-10-02/harness/D1-mail-hmac.sh` |
| E1 | SMB 共享名字符集校验 | `lib/smb_core.sh:228`（`_smb_valid_share_name`），调用点 `:321`/`:361` | GUARD-ACTIVE | `ab_sub` 把 `=~ ^[A-Za-z0-9_.-]+$` 换成 `[[ -n "$1" ]]`；函数签名、错误消息、写共享段全部保留 | `bash .validation/ablation-2026-10-02/harness/E1-smb-share-validate.sh` | 非法共享名 `bad/name`：baseline rc=1+`共享名只能包含字母/数字/._-`+配置段计数 0；消融 rc=0+`[bad/name]` 段真实落盘（计数 1）。附带两处覆盖缺口见 E 分册 | `harness/E1-smb-share-validate.sh`、`logs/E1-smb-share-validate.txt` |
| F1 | owner/group POSIX 账户名正则 | `lib/user_core.sh:402` | GUARD-ACTIVE | `ab_sub` 把 owner 与 group 两侧正则同时换成 `=~ ^.*$`；username 校验、符号链接检查、id/getent/chown、原子写全部保留 | `bash .validation/ablation-2026-10-02/harness/F1-user-owner-regex.sh` | owner `-root`：baseline rc=1 且 `id_getent_calls=[]`（未进任何系统命令）；消融 rc=1 但 `id -u -root` 被实录（恶意值抵达 id 参数位）。`root/../root` 同理。合法账户两侧一致 rc=0+落盘 json | `harness/F1-user-owner-regex.sh`、`logs/F1-user-owner-regex.txt` |
| G1 | capability 默认拒绝（未知角色→空集合） | `web/backend/src/auth/rbac.rs:15-17`；消费 `guard.rs:89`→`:100` | STATIC-ONLY | 静态消融：`BTreeSet::new()` → `BTreeSet::from(KNOWN_CAPS…)`，未编译未运行 | `bash .validation/ablation-2026-10-02/harness/G1-web-capability-default-deny.sh` | **无运行时观测**：cargo/rustc/rustup 三者 MISSING。仅静态事实：`http/` 下 36 处 `auth.require()` 均经该链，无绕过 | `harness/G1-web-capability-default-deny.sh`、`logs/G1-web-capability-static.txt` |

## 5. 分册

- `A-privilege.md` — 场景 A1/A5/A3/A4
- `B-action-registry.md` — 场景 B1/B2
- `C-snapshot.md` — 场景 C1/C2
- `D-secret.md` — 场景 D1
- `E-injection-smb.md` — 场景 E1
- `F-identity.md` — 场景 F1
- `G-web-boundary.md` — 场景 G1
