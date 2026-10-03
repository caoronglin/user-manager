# C — 快照层守卫消融

| 场景 | 守卫名 | 守卫位置 | 判定 | 消融方法 | 复现命令 | 观测差异 | 证据 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| C1 | 快照目录逐段符号链接拒绝 | `lib/snapshot_core.sh:181` | GUARD-ACTIVE | `ab_sub` 把 `[[ -L "$current" ]] && return 1` 换成 `:`；`snapshot_ensure_dir`、`enter_safe_dir`、原子安装全部保留 | `bash .validation/ablation-2026-10-02/harness/C1-snapshot-symlink.sh` | 守卫本体：baseline `resolve_rc=1`、输出空、报「快照目录包含符号链接或路径无效」；消融 `resolve_rc=0`、返回被跟随后的路径。纵深侧：完整写路径消融后仍被 `:233` `enter_safe_dir` 的 `pwd -P` 比对拦下（rc=1） | `.validation/ablation-2026-10-02/harness/C1-snapshot-symlink.sh` |
| C2 | 快照写失败关闭（临时文件 + 原子安装） | `lib/snapshot_core.sh:298-301` | GUARD-ACTIVE | `ab_sub` 把 `tmp="$(mktemp ...)" || {` 换成 `tmp="$file" || {`，即 mktemp 失败不再中止而是直写目标；写快照能力、`apply_owner`、`sync` 全部保留。失败注入：PATH 前置 stub `mktemp` 恒返回非零 | `bash .validation/ablation-2026-10-02/harness/C2-snapshot-fail-closed.sh` | baseline：rc=1，报「无法创建临时快照文件」，**既有 manifest.json 完好**（`intact content=PREVIOUS-GOOD-CONTENT`）；消融：mktemp 失败被吞，直写目标后 `mv` 同文件失败，**既有快照被删除**（`EXISTING_SNAPSHOT=deleted`） | `.validation/ablation-2026-10-02/harness/C2-snapshot-fail-closed.sh` |

## C1 纵深防御说明

消融掉 `:181` 后，`snapshot_ensure_dir`（`:216`）仍会调 `snapshot_enter_safe_dir`（`:232-236`），它 `cd -P` 后用 `pwd -P` 与期望值比对——`cd -P` 解析符号链接后实得 `.../real` 而非 `.../link`，比对失败，`:233` 打印「快照目录不是安全目录」并返回 1。

这是**冗余守卫**，不是缺口：同一威胁有两道独立实现，消融任意一道都不足以放行写入。报告把 C1 判为 GUARD-ACTIVE，依据是守卫本体 `:181` 的行为差异（`resolve_rc` 1 → 0），而非写路径的最终成败。

## C2 消融侧为何也是 rc=1

消融侧的 rc=1 **不是假失败**，它来自消融自身引入的 `mv: 'manifest.json' 与 'manifest.json' 为同一文件`，与「命令不存在 / 函数未定义 / 127」无关。判据第 2 条取的不是退出码，而是**既有快照的存活状态**：

- baseline：写失败中止，旧快照内容完好（原子安装契约生效）。
- 消融：守卫消失后同一次失败的写操作**摧毁了既有快照**（先被直写覆盖、再被 EXIT trap 的 `rm -f "$tmp"` 删除，因为此时 `tmp == file`）。

这正是「失败关闭」这条守卫的实际价值：它保证任何一次不成功的写都不会损坏已有快照。

## 补充观察（非本场景判定）

`snapshot_core.sh:290-293` 与 `:321-324` 各有一处目标文件的 `-L` 拒绝，位置在「打开临时文件之前」和「原子安装之前」两处，二次检查以覆盖写入期间被替换的 TOCTOU 窗口。C1 未单独消融这两处，代码审阅显示它们与 `:181` 同构。
