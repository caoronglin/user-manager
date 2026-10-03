# A — 特权与权限层守卫消融

| 场景 | 守卫名 | 守卫位置 | 判定 | 消融方法 | 复现命令 | 观测差异 | 证据 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| A1 | priv_exec 命令白名单 | `lib/privilege.sh:166-171` | GUARD-ACTIVE | 删除 `if ! priv_check_whitelist "$cmd"` 整块 | `bash .validation/ablation-2026-10-02/harness/A1-priv-whitelist.sh` | baseline rc=1 + `Command curl is not in the privilege whitelist` + audit PRIV_DENIED + 未执行；消融 rc=0 + stub 记录 `sudo curl http://example.invalid/x` + audit PRIV_EXEC | `.validation/ablation-2026-10-02/harness/A1-priv-whitelist.sh` |
| A5 | priv_exec 权限级别门禁 | `lib/privilege.sh:172-182` | GUARD-ACTIVE | `ab_drop_block` 删除 `if [[ "$current_level" -gt "$required_level" ]]` 5 行；**保留** `PRIV_CMD_WHITELIST` 数组、`priv_get_required_level`、全部 wrapper | `bash .validation/ablation-2026-10-02/harness/A5-priv-level.sh` | baseline rc=1 + `Insufficient privileges for 'chmod'. Required level: 1, Current: 2` + audit PRIV_DENIED + 未执行；消融 rc=0 + stub 记录 `sudo chmod 700 .../target` + audit PRIV_EXEC | `.validation/ablation-2026-10-02/harness/A5-priv-level.sh` |
| A3 | run_privileged shell trampoline 拒绝 | `lib/common.sh:93-99` | GUARD-ACTIVE | `ab_drop_block` 删除 `case "$cmd" in bash|sh|sudo|su` 6 行；**保留** `:89-92` 选项作命令名守卫与 sudo 执行路径 | `bash .validation/ablation-2026-10-02/harness/A3-run-privileged.sh` | baseline rc=1 + `拒绝执行不安全的 shell trampoline: bash` + 未执行；消融 rc=0 + stub 记录 `sudo bash -c echo TRAMPOLINE-EXECUTED` + stdout 出现 `TRAMPOLINE-EXECUTED` | `.validation/ablation-2026-10-02/harness/A3-run-privileged.sh` |
| A4 | check_permission 默认拒绝 | `lib/privilege.sh:406` | GUARD-ACTIVE | `ab_sub` 把未知 key 的默认级别 `$ACL_LEVEL_ADMIN`(1) 改为 `$ACL_LEVEL_GUEST`(3)；**保留** `run_with_permission`/`require_permission`/`PERMISSION_MATRIX` | `bash .validation/ablation-2026-10-02/harness/A4-permission-default-deny.sh` | baseline rc=1 + `权限不足: 需要 totally:unknown:unknown 权限` + 未产出文件；消融 rc=0 + `victim.txt` 真实生成 | `.validation/ablation-2026-10-02/harness/A4-permission-default-deny.sh` |

## 有效判据自检

| 场景 | 自检1 baseline 拒绝理由指向守卫 | 自检2 ablated 真实走通 | 自检3 无 127/函数缺失 |
| --- | --- | --- | --- |
| A1 | 是（not in the privilege whitelist） | 是（rc=0 + stub 执行记录） | 是 |
| A5 | 是（Insufficient privileges） | 是（rc=0 + `sudo chmod` 记录） | 是 |
| A3 | 是（拒绝不安全的 shell trampoline） | 是（rc=0 + `TRAMPOLINE-EXECUTED` 实际输出） | 是 |
| A4 | 是（权限不足，指名被消融的矩阵默认项） | 是（rc=0 + 产出文件） | 是 |

## 实验过程中的两次作废（A2 重做原因）

1. **原 A2**（`harness/A2-priv-level.sh`，作废）删除了整个 `PRIV_CMD_WHITELIST` 数组连同 67 行注释，把 `priv_chmod` wrapper 一并拆掉，消融侧 rc=127「未找到命令」。这是能力被拆而非守卫被消融，判 EXPERIMENT-INVALID，不构成任何结论。A5 是它的严格重做版。
2. **首版 A4** 探针只 `source lib/common.sh` 后 `source lib/privilege.sh`，命中 `privilege.sh` 顶部的 `requires access_control.sh to be sourced first` 提前 return，导致 `run_with_permission` 未定义、rc=127。修正为先 source `lib/access_control.sh` 后重跑，得到上表结果。

## 备注

- A5 探针用 `acl_get_current_level() { echo 2; }` 覆盖当前级别为 `ACL_LEVEL_USER`，被测命令选白名单内、要求 `ACL_LEVEL_ADMIN` 的 `chmod`，这样拒绝理由只能来自级别门禁，不会与白名单门禁混淆。
- A1 白名单侧用 `curl`（不在白名单），与 A5 的 `chmod`（在白名单）形成互补，两条门禁互不遮蔽。
