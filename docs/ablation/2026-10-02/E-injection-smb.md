# E — 注入面与共享配置守卫消融

| 场景 | 守卫名 | 守卫位置 | 判定 | 消融方法 | 复现命令 | 观测差异 | 证据 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| E1 | SMB 共享名字符集校验 | `lib/smb_core.sh:228`（`_smb_valid_share_name`），调用点 `:321` `smb_share_add` / `:361` `smb_share_remove` | GUARD-ACTIVE | `ab_sub` 把 `[[ "$1" =~ ^[A-Za-z0-9_.-]+$ ]]` 换成 `[[ -n "$1" ]]`；函数签名、错误消息、写共享段与 `smb_ensure_include` 全部保留 | `bash .validation/ablation-2026-10-02/harness/E1-smb-share-validate.sh` | 非法共享名 `bad/name`：baseline rc=1 + `SMB error: 共享名只能包含字母/数字/._-` + 配置文件段计数 0；消融 rc=0 + `[bad/name]` 段真实落盘（计数 1） | `harness/E1-smb-share-validate.sh`、`logs/E1-smb-share-validate.txt` |

## 有效判据自检

| 场景 | 自检1 baseline 拒绝理由指向守卫 | 自检2 ablated 真实走通 | 自检3 无 127/函数缺失 |
| --- | --- | --- | --- |
| E1 | 是（消息即来自 `_smb_valid_share_name` 的调用点，唯一拒绝点） | 是（rc=0 且 `[bad/name]` 共享段真实写入文件，grep 计数 0→1） | 是（两侧 rc 1/0） |

## 同一场景下的两条覆盖缺口（非 E1 判定，独立记录）

E1 判 GUARD-ACTIVE 的对象是**字符集守卫**。同一次实验顺带暴露了两处它管不到的地方，两者都不改变 E1 的判定，但必须留档：

### 缺口 1：正则允许纯点号共享名 `..`

`^[A-Za-z0-9_.-]+$` 的字符类包含 `.`，且没有「必须含非点字符」或「排除 `.`/`..`」的补充约束，因此 `..` **合法通过**。实测两侧完全一致：

- baseline：`add name=[..] rc=0`，配置中出现 `[..]` 段（计数 1）
- ablated：同上

这是守卫的**覆盖面缺口**，不是守卫失效。同一函数的 `smb_share_remove`（`:361`）复用同一校验，`..` 在删除路径同样放行。

### 缺口 2：共享路径没有任何穿越校验

`smb_share_add` 对 `path` 只有 `[[ -n "$path" ]]` 非空判断（`:325-328`），没有任何 realpath/前缀/穿越检查。实测两侧完全一致：

- baseline：`add name=[trav] path=[../../etc] rc=0`，配置中原样写入 `path = ../../etc`（计数 1）
- ablated：同上

`../../etc` 会被 Samba 按 drop-in 相对路径解析，写入者可控目录即等于把任意目录暴露成网络共享。这一项按判定口径属 **NOT-APPLICABLE（无守卫可消融）**，不计入 E1 的 12 场景判定表。

## 为什么路径穿越不用「消融」来证明

判据 2 要求 ablated 侧拿到成功证据，而这里 baseline 侧本来就成功——**根本没有可消融的守卫**。把这种情况硬消融成 GUARD-ACTIVE 是伪造结论，因此本报告按 NOT-APPLICABLE 记录，并把证据原文（两侧 rc=0、配置写入穿越路径）留给修复决策使用。

## 备注

- 探针用 `SMB_CONF` / `SMB_SHARES_CONF` 环境变量把落盘位置重定向到 `.validation/.../abenv-E1/`，未触碰 `/etc/samba/` 任何真实文件。
- 输出中的 `无法读取 Samba 主配置` 与 `共享已写入，但主配置 include 未生效` 来自 `smb_ensure_include`，属于 drop-in 落盘后的附带告警，不影响判据：判据取的是 rc 与配置段计数。
