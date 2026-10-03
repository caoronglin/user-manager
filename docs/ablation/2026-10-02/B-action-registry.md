# B — Action Registry 守卫消融

| 场景 | 守卫名 | 守卫位置 | 判定 | 消融方法 | 复现命令 | 观测差异 | 证据 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| B1 | action safe/dangerous 分类的执行期强制 | 登记 `lib/action_registry.sh:9,54,72`；唯一仓库内读点 `:361`（`action_describe()` 打印）与 `scripts/rl-action-list.sh:66,74`（列表展示）；**执行期零判定点** | GUARD-INERT（**非安全漏洞**，定级已修正） | `ab_sub` 把 risk 形参固化为 `safe`，抹掉 dangerous 分类登记；handler 注册、`action_run` 分发、`action_requirements_met` 全部保留 | `bash .validation/ablation-2026-10-02/harness/B1-action-risk.sh` | baseline `registered_risk=dangerous`，`action_run probe.dangerous cli` 仍 rc=0、handler 真实执行（`proof=HANDLER-EXECUTED`），stderr 空；消融 `registered_risk=safe`，同样 rc=0 真实执行。两侧**零行为差异** | `.validation/ablation-2026-10-02/harness/B1-action-risk.sh` |
| B2 | registry ↔ handler 接线一致性 | 登记 `lib/action_registry.sh:364-393`；执行期 handler 存在性检查 `:147-150` | NOT-APPLICABLE（审计通过，无缺口） | 非消融，只读静态审计：提取 `lib/*.sh`+`scripts/*.sh` 函数定义名（1061 个）与 29 条登记的 handler 比对，再反向扫描未登记的 `rl_action_*_cli` | `bash .validation/ablation-2026-10-02/harness/B2-registry-handler-wiring.sh` | `TOTAL=29 MISSING_HANDLER=0`，无 `HANDLER_NOT_REGISTERED`。接线完整，不存在 GAP 候选 | `.validation/ablation-2026-10-02/logs/B2-wiring.txt`、`B2-defined-funcs.txt` |

## B1 定级修正：这不是漏洞，是「展示元数据被执行层忽略」

初版把 B1 写成 GUARD-INERT 时隐含「危险动作本应被额外把关却没把关」的语义，属于**定级过重**。修正后的结论：

**这不是安全漏洞。真正生效的防线是 `requires` → `priv_exec` → 白名单/ACL 级别链（A1/A5 已实证 GUARD-ACTIVE）；B1 揭示的只是 safe/dangerous 分类是纯展示元数据，执行期对它的读取为零。**

### 一句话消费链结论

`_ACTION_RISK` 从写入到消失只有一条纯展示链——`action_register` 写入 → `action_describe`/`rl-action-list.sh` 打印 → 进程结束，**全程不与任何判定分支相交**；而同一登记里的 `_ACTION_REQUIRES` 走的是 `action_run:146 → action_requirements_met:111 → handler 内部 priv_* wrapper → 白名单 + ACL 级别门禁` 这条真实拦截链。

### 静态证据（4 个读取点，逐一核实）

`_ACTION_RISK` 全仓（排除 `.bak` 与 `.validation`）只有 6 个引用点：

- `lib/action_registry.sh:9` 声明、`:54` 重置、`:72` 写入、`:361` 被 `action_describe()` 打印。
- `scripts/rl-action-list.sh:66,74` 两处**纯列表展示**（plain 模式列、markdown 模式列）。

`action_run()`（`lib/action_registry.sh:127-154`）函数体内的执行前检查序列是：

1. `action_exists`（handler 键非空）— `:135`
2. `action_mode_supported` — `:140`
3. `action_requirements_met`（只看 `requires`，不看 `risk`）— `:146`
4. `declare -F "$handler"` 存在性 — `:149`
5. 直接 `"$handler" "${args[@]}"` — `:153`

**没有第 6 步：没有任何一行读 `_ACTION_RISK[$id]`。** 消融前后行为完全一致，实验证明分类对执行路径零影响。

### 与 `_ACTION_REQUIRES` 的对照（这才是防线）

`_ACTION_REQUIRES` 的读点 `:111` 位于 `action_requirements_met()`，被 `action_run:146` 实际调用。`action_run` 本身只做「requires 非空字符串」的粗检查，真正的权限强制发生在 handler 内部调用的 `priv_*` wrapper 上，最终落到 A1（命令白名单）与 A5（ACL 级别门禁）这两条已证明 GUARD-ACTIVE 的守卫链。

### 对 `action_info()` 死代码说法的修正

初版讨论中出现「`action_info()` 是死函数」的表述，经 `62f00fc` 基线核对**该函数在全仓不存在**（`grep -rln 'action_info' --include='*.sh'` 无命中）。`:361` 实际位于 `action_describe()`（定义 `:350`），该函数并非死代码，但确实**没有任何生产调用者**——全仓 4 个调用点全部在 `tests/test_action_registry.sh:24,38,233,234`，即只有测试在消费它。准确表述是：risk 的查询接口生产侧无消费者，仅测试与列表脚本消费其输出。

### 文档口径

`README.md:54-71` 与 `docs/` 下的动作清单只把 risk 作为表格一列展示，**从未声称 dangerous 动作有额外把关或二次确认**。因此不存在「文档承诺了但代码没实现」的落差，B1 判定维持 GUARD-INERT 但不构成缺陷。

## B2 方法说明

`source` 全部 `lib/*.sh` 会失败：`lib/backup_core.sh` 与 `lib/email_daemon.sh` 在依赖不满足时提前 `return`，污染后续 `declare -F` 判定。因此 B2 改用静态定义名提取，不执行任何模块，结论更保守也更可靠。

`declared` 计数 1061 是 `lib/`+`scripts/` 全部顶层函数定义数，包含大量与 registry 无关的函数；审计只关心「29 条登记 handler 是否都在定义集合内」与「`rl_action_*_cli` 是否都已登记」这两个方向。
