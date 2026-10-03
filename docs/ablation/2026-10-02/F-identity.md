# F — 身份与账户名校验守卫消融

| 场景 | 守卫名 | 守卫位置 | 判定 | 消融方法 | 复现命令 | 观测差异 | 证据 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| F1 | owner/group POSIX 账户名正则 | `lib/user_core.sh:402`（`_um_publish_cli_user_event_spool_at` 内，对 owner 与 group 各判一次） | GUARD-ACTIVE | `ab_sub` 把该行两个 `=~ ^[A-Za-z_][A-Za-z0-9_.-]*$` 同时换成 `=~ ^.*$`；`_um_event_spool_username_is_valid`、spool 目录符号链接检查、`id`/`getent`/`chown`、原子写全部保留 | `bash .validation/ablation-2026-10-02/harness/F1-user-owner-regex.sh` | 恶意 owner `-root`：baseline rc=1 且 `id_getent_calls=[]`（从未调用系统命令）；消融 rc=1 但 `id_getent_calls=[id -u -root;]`，恶意值已越过 `:402` 抵达 `id` 参数位。恶意 owner `root/../root` 同理（baseline 无调用 / 消融 `id -u root/../root`）。合法 owner `T25ronglin`/`T` 两侧完全一致：rc=0、`id -u T25ronglin; getent group T`、json_written=1 | `harness/F1-user-owner-regex.sh`、`logs/F1-user-owner-regex.txt` |

## 有效判据自检

| 场景 | 自检1 baseline 拒绝理由指向守卫 | 自检2 ablated 真实走通 | 自检3 无 127/函数缺失 |
| --- | --- | --- | --- |
| F1 | 是（baseline 侧 `id`/`getent` 调用数为 0，说明在 `:402` 就 `return 1`，未进入任何系统命令） | 是（恶意值在消融侧**确实抵达了 `id -u` 的参数位**，由记录型 stub 实录） | 是（两侧 rc 均为 1，非 127；rc 来源是 `id` 本身拒绝 `-root`，不是命令缺失） |

## 为什么 ablated 侧 rc 仍是 1

消融后 rc 未变 0，但**这不构成假失败**：失败来自 `id` 这个独立的下游校验，而不是「函数未定义 / 命令不存在 / 127」。判据 2 在本场景取的不是退出码，而是**系统调用边界的穿越**——

- baseline：恶意 owner 到不了 `id`，一次系统查找都没发生；
- 消融：恶意 owner 被当成「合法账户名」放行，实际拼进了 `id -u` 的参数。

这与 C2 的处理方式一致：rc 相同不代表守卫无作用，差异出现在更细的观测层。

## 该守卫的真实定位：前置拦截，不是唯一防线

`lib/user_core.sh:399-401` 的注释写明设计意图——真正要挡的是「会被 chown/id/getent 误解析的输入：前导短横线（选项注入）、空白与 shell 元字符」。实测确认这是一道**冗余层**：

- `id -u "$owner"`（`:405`）对 `-root`、`root/../root` 本身就返回非零，函数在此 `return 1`；
- `getent group "$group"`（`:406-407`）要求 gid 为纯数字；
- `chown -- "$owner:$group"`（`:416`）已用 `--` 终止选项解析。

因此 F1 的价值判断是：`:402` 把非法输入挡在**系统命令之前**，减少了一层无谓的失败与副作用；即便消融，最坏也只是把恶意字符串递交给本就拒绝它的 `id`/`getent`，不会造成 chown 选项注入。三层中任一层单独存在即可拒绝该输入。

## 与 87a74da 的关系（高价值回归点）

`87a74da` 把本行从 `^[a-z_][a-zA-Z0-9_-]*$` 放宽为 `^[A-Za-z_][A-Za-z0-9_.-]*$`，修的是**误杀**（POSIX 账户名允许大写与点，如 `Users`、`staff.svc`），不是放松防线。本次消融复跑确认两件事：

1. 放宽后的正则仍挡住前导短横线与路径分隔符（`^[A-Za-z_]` 首字符约束 + 字符类不含 `/`）；
2. 放宽没有顺带引入新的可穿越字符——字符类中的 `.` 只出现在非首位，单独的首字符 `.`/`-` 仍被拒。

case3 用当前真实账户 `T25ronglin`/`T` 做正向对照，两侧均 rc=0 并落盘 json，确认消融只改守卫、不拆能力。

## 观测方法说明

探针用 PATH 前置的**记录型 stub** 包装 `id` 与 `getent`：stub 先把参数追加到日志，再 `exec /usr/bin/...` 原样转发，**不改变任何返回码或输出**。这与 `strace` 同属纯观测插桩，不是「让实验通过」的桩。stub 位置在 `.validation/.../abenv-F1/stub/`，未改动系统 `/usr/bin`。
