# 运行时目录 DATA_DIR / LOG_DIR 可被环境覆盖 —— 设计

**日期：** 2026-10-02
**状态：** 已实施（本轮完成评估与落地）
**基线：** `main` @ `62f00fc`
**范围：** 仅 Bash 侧。契约定义在 `lib/config.sh`；新增 1 个测试套件。不改 Rust、前端、systemd 单元、CI 配置。

---

## 1. 目标与非目标

### 1.1 目标

把 `DATA_DIR` / `LOG_DIR` 从「无条件赋值」改为「可被环境覆盖」，并给出单一、明确的注入变量名，使回归运行器能够在**一层**完成逐套件隔离，而不必让每个测试各自覆盖变量。

### 1.2 非目标（本轮明确不做）

- 不重构目录布局，不迁移既有 `data/`、`logs/` 的内部结构。
- 不改 Rust 侧（`web/backend`）任何代码或配置。
- 不改 systemd 单元、tmpfiles.d、sudoers 模板。这些文件当前不引用 `DATA_DIR` / `LOG_DIR`（已 grep 核实，见 §4.2），本轮无需跟随改动。
- 不改 `USER_MANAGER_DATA_BASE` 的既有语义（理由见 §3）。
- 不删除 `tests/test_security_hardening.sh` 中已落地的 `EMAIL_LOG_FILE` 针对性重定向。它是有效的纵深防御，与本轮契约正交。

---

## 2. 契约定义

### 2.1 最终形式

```bash
DATA_DIR="${USER_MANAGER_DATA_DIR:-$SCRIPT_DIR/data}"
LOG_DIR="${USER_MANAGER_LOG_DIR:-$SCRIPT_DIR/logs}"
REPORT_DIR="$DATA_DIR/report"
```

选择 `${VAR:-default}`（而非 `${VAR:=default}`）的理由：

- `:-` 形式**读取**环境变量后赋值给 `DATA_DIR`，不向调用方作用域回写 `USER_MANAGER_DATA_DIR`。
- `:=` 会把 `DATA_DIR` 的值回写进 `USER_MANAGER_DATA_DIR`。当 `DATA_DIR` 是从环境注入时这恰好等价，但当测试在 `source config.sh` **之后**直接改写 `DATA_DIR`（`tests/test_security_hardening.sh:197`、`tests/test_proc_manager.sh:15`、`tests/test_audit_integration.sh:12` 都是这个顺序）时，`:=` 会让 `USER_MANAGER_DATA_DIR` 变成陈旧值，造成「同一 shell 内两个变量互相污染」。`:-` 从根上排除这种反馈。
- 二者在「首次 source」场景下的结果完全一致；差异只在重复 source 时出现，而 `:-` 的语义在重复 source 下更稳定。

### 2.2 默认值语义

未设置 `USER_MANAGER_DATA_DIR` / `USER_MANAGER_LOG_DIR` 时，行为与改动前**逐字节相同**：`$SCRIPT_DIR/data`、`$SCRIPT_DIR/logs`。`SCRIPT_DIR` 在 `config.sh:16` 已通过 `cd ... && pwd` 解析为绝对路径，因此默认值恒为绝对路径。

`REPORT_DIR` 继续从 `DATA_DIR` 派生，不引入独立环境变量——它已有 `USER_MANAGER_USER_REPORT_DIR` 这条独立覆盖通道，再加一条只会制造两个含义重叠的旋钮。

### 2.3 空字符串处理

`${VAR:-default}` 对「未设置」和「设为空串」一视同仁，都回退到默认值。这正是需要的行为：`USER_MANAGER_DATA_DIR=` （运维在 systemd `Environment=` 里写空值、或 shell 里 `export USER_MANAGER_DATA_DIR=` 后误 `unset -v`）若被当作有效路径，会让 `DISABLED_USERS_FILE` 变成 `/disabled_users.txt`——直接写到文件系统根。回退到默认值是失败方向更安全的一侧。

### 2.4 相对路径：允许，但会被规范化前的原样使用（本轮不拒绝）

任务书建议「必须绝对路径」。评估后**本轮不实施**该限制，理由如下：

1. 相对路径在 `config.sh` 被 source 的瞬间没有可靠的「基准目录」——`SCRIPT_DIR` 是库的安装位置，而调用方的 CWD 可能是任意目录。接受相对路径等于把语义交给 CWD，而 CWD 在 systemd 单元、cron、sudo 三种入口下各不相同。
2. 但**拒绝**相对路径需要新增校验函数 + 失败分支，这会改变现有 `source config.sh` 的调用契约：`lib/rl_mail_config.sh:5` 等模块用 `: "${DATA_DIR:=$SCRIPT_DIR/data}"`，与 `config.sh` 的 `:-` 语义并不一致，两处校验会分叉。
3. 更关键的是：拒绝意味着**报错退出**，而 `config.sh` 被 `verify_fixes.sh:53` 的 6 个 profile 探测子进程 source。任何一条 profile 因环境里带了一个相对路径而退出，都会把「配置错误」升级为「加载失败」，故障面远大于收益。

因此本轮的处置是：**在文档与测试中把「绝对路径」确立为调用方契约（推荐用法），但不在库内强制**。测试用例 `相对路径被原样接受` 明确记录这一边界，避免后续误以为已强制。若将来要强制，应作为独立一轮，在 `config.sh` 引入统一校验函数并同步 `rl_mail_*.sh` 的 `:=` 写法。

### 2.5 导出与否

`DATA_DIR` / `LOG_DIR` **不 export**，与改动前一致。

理由：这两个变量的消费者分两类——(a) 同进程内 source 的库（`lib/audit_core.sh:12`、`lib/async_core.sh:16`、`lib/email_daemon.sh:16-19`、`lib/proc_manager.sh:15`、`lib/rl_mail_*.sh`、`lib/host_provider.sh:169`、`lib/host_inventory.sh:260`、`lib/logs_core.sh:307`），读的是 shell 变量，export 与否无差别；(b) 子进程，走 `env` / `sudo` 边界。

对 (b)，export 会让 `DATA_DIR` 泄漏进 `sudo` 环境（`sudo` 默认 `env_reset` 会清掉它，但 `env_keep` 可保留），增加一个「库变量渗透到特权进程环境」的面。而 `USER_MANAGER_DATA_DIR` 作为环境变量**天然**会跨 `env` 边界传播——这正是注入点应有的传播方式。两者分工清晰：环境变量负责跨界，shell 变量负责进程内。

**保持不 export 是本轮「改动最小」原则下唯一正确的选择**：加 export 会改变所有子进程的环境，属于契约变更之外的额外风险面。

### 2.6 目录创建责任

**`init_directories()`（`config.sh:105-115`）是唯一的创建者**，已 `mkdir -p` 这 5 个目录：`DATA_DIR`、`REPORT_DIR`、`JOB_STATS_DIR`、`LOG_DIR`、`PASSWORD_POOL_DIR`。本轮**不新增任何 mkdir**。

- 权限：沿用 `mkdir -p` 的默认（受调用方 umask 约束），与现状一致。本轮不引入 `chmod`——给运行时目录强行设权限会改变现有部署的目录 mode，属于未评估的兼容性变更。
- 失败语义：**关闭（fail-closed）**，保持现状——`mkdir` 失败即 `msg_err` + `return 1`，`load_config`（`config.sh:128-131`）随即返回 1，入口 `user_manager.sh:61` / `tui_manager.sh:1355` / `controller_main_menu.sh:45` 全部 `return 1` / `exit 1`。这是正确的：不创建目录就继续跑，会把数据写到意料之外的路径。
- 未被 `init_directories` 覆盖但按需自建的目录，由各模块自己负责，且都已是 `mkdir -p ... || true` 或带错误处理：`lib/audit_core.sh:59-61`、`lib/async_core.sh:50`、`lib/email_daemon.sh:42,79-80`、`lib/proc_manager.sh:246,249`、`lib/rl_mail_audit.sh:27`、`lib/rl_mail_config.sh:20`、`lib/rl_mail_queue.sh:60,342`、`lib/user_core.sh:1644`。全部与 `DATA_DIR` / `LOG_DIR` 的取值无关，改契约不影响它们。

**关键结论：无任何模块假设这两个目录位于源码树下。** 逐个 grep 核实（§4.1），不存在相对路径拼接、`cd` 进目录、或写入前未建目录的写法。

---

## 3. 与 `USER_MANAGER_DATA_BASE` 的关系

### 3.1 事实核查：任务书的前提需要修正

任务书称「runner 已在用 `USER_MANAGER_DATA_BASE` 做逐套件隔离但库不读它」。**前半句成立，后半句不成立**：

`lib/config.sh:57` 明确读取了它——`DATA_BASE="${USER_MANAGER_DATA_BASE:-/mnt}"`。库读得很清楚。

真正的错配是**语义错配**，不是「读不读」的错配。

### 3.2 两个变量的语义完全不同

grep 全仓 `DATA_BASE` 的消费点（`git grep 'DATA_BASE' -- 'lib/*.sh' 'scripts/*.sh' '*.sh' ':!*.bak'`）：

| 出现点 | 用途 |
| --- | --- |
| `lib/quota_core.sh:16,67,82,245,296` | `${DATA_BASE}/data${idx}` —— 用户家目录挂载点 |
| `lib/controller_user_provisioning_support.sh:17,67` | `${DATA_BASE}/data${idx}` —— 建号时确定挂载点 |
| `lib/report_core.sh:271,1489` | `${DATA_BASE}/data${idx}` —— 报表定位挂载点 |
| `lib/symlink_core.sh:129` | `${DATA_BASE}/data${target_idx}` —— 符号链接目标 |
| `lib/access_control.sh:29` | `$DATA_BASE/logs/audit.log` |
| `lib/config.sh:77` | `ALL_DISKS=(1 2 3 4 5 6 7)` —— 7 块盘对应 `data01`..`data07` |

即：**`DATA_BASE` 是「用户家目录挂载点的父目录」，默认值 `/mnt`**。它与「本工具自己的运行时数据目录」是两个正交概念。

### 3.3 方案选择：新增专用变量，不复用 `USER_MANAGER_DATA_BASE`

任务书要求「给出一个方案而不是两个」。本轮的选择是：

> **新增 `USER_MANAGER_DATA_DIR` / `USER_MANAGER_LOG_DIR` 两个专用变量，`USER_MANAGER_DATA_BASE` 保持原样、继续只服务挂载点。runner 在保留 `USER_MANAGER_DATA_BASE` 的同时，额外注入新变量。**

**为什么不能让 `DATA_DIR` 回退到 `USER_MANAGER_DATA_BASE`：**

1. **生产会静默损坏。** 默认 `USER_MANAGER_DATA_BASE=/mnt`。若 `DATA_DIR` 回退到它，`DATA_DIR` 变成 `/mnt`，于是 `DISABLED_USERS_FILE=/mnt/disabled_users.txt`、`USER_CONFIG_FILE=/mnt/user_config.json`、`PASSWORD_POOL_DIR=/mnt/password_pools`——全部落进用户家目录的父目录，与 `/mnt/data01`..`/mnt/data07` 的挂载点同级。备份/家目录遍历会扫到它们。
2. **测试侧会得到假隔离。** `run_p1_one` 传 `USER_MANAGER_DATA_BASE="$tmp"`，若 `DATA_DIR` 也回退到它，则 `DATA_DIR="$tmp"` 而非 `"$tmp/data"`——与 `USER_MANAGER_BACKUP_ROOT="$tmp/backup"` 同级，虽不冲突，但把「运行时数据」和「家目录挂载点根」混进同一个目录，测试失败时的取证会指向错误的目录。
3. **变量名会误导其他调用方。** `USER_MANAGER_DATA_BASE` 已被 20+ 处测试与 `verify_fixes.sh:53` 使用，语义是「挂载点根」。若让它同时决定 `DATA_DIR`，下一个维护者看到 `USER_MANAGER_DATA_BASE=$tmp` 会合理地推断「运行时数据在 $tmp 下」——而实际上它只影响家目录路径。**这是本轮拒绝复用它的决定性理由。**
4. **grep 依据（全仓出现点）**：`USER_MANAGER_DATA_BASE` 在代码中分布于 `verify_fixes.sh:53`、`tests/run_regression.sh:150,158`（并行路径）与 `run_regression.sh:231..397`（顺序路径，30 处）、`tests/test_bootstrap_integration.sh:24,31,46,53,60,67,68,126,133,140,147,154`、`tests/test_{resource,event_spool,lock,user,security_hardening,backup,audit_integration,vm,password_change_smb}_*.sh`、`tests/test_{snapshot,remote_cli}.sh`。文档侧另见 `progress.md:215`、`docs/bats-migration-assessment.md:15` 与若干 `docs/superpowers/plans/*`。全部按「挂载点根」使用，**无一处按「运行时数据根」使用**——这反过来证明当前没有混淆，只是隔离维度不完整。

### 3.4 runner 的注入方式

`run_p1_one`（`tests/run_regression.sh:132-174`）在既有 `env` 调用中追加两行：

```bash
USER_MANAGER_DATA_DIR="$tmp/data" \
USER_MANAGER_LOG_DIR="$tmp/logs" \
```

放在 `USER_MANAGER_DATA_BASE="$tmp"` 之后、`UM_INCLUDE_LINT` 之前，与既有 `env` 参数风格一致。并行与顺序两条路径都要加：并行路径是默认（`PARALLEL=1`），顺序路径 `--no-parallel` 虽非默认，但 `run_p1()` 里 30 处 `env` 块若不同步，`--no-parallel` 就退回旧行为，形成一条「只有默认路径隔离」的隐性分叉。

顺序路径的 30 处 `env` 块目前统一传 `USER_MANAGER_DATA_BASE="$PROJECT_ROOT/data"`。新增两行应传 `"$PROJECT_ROOT/data"` 与 `"$PROJECT_ROOT/logs"`——与该路径既有的「指向仓库内目录」语义一致，不引入行为变化；顺序路径的价值是**可复现地观察默认部署形态**，把它也重定向到 `mktemp` 反而破坏了这个用途。

---

## 4. 受影响模块逐一确认

### 4.1 `DATA_DIR` / `LOG_DIR` 全部引用点

```
lib/config.sh:17,18,19,60,61,63,65,68,69,70,71,72,73,74,102,107   契约本体
lib/rl_mail_config.sh:5,6                                        : "${DATA_DIR:=$SCRIPT_DIR/data}"
lib/rl_mail_queue.sh:5,6,7,111                                   : "${DATA_DIR:=$SCRIPT_DIR/data}"
lib/rl_mail_audit.sh:5,6                                          : "${LOG_DIR:=$SCRIPT_DIR/logs}"
lib/audit_core.sh:12                                             ${DATA_DIR:-./data}/audit   + 自行 mkdir
lib/async_core.sh:16                                             ${DATA_DIR:-...}/async_tasks.db + 自行 mkdir
lib/email_daemon.sh:16,19                                        ${DATA_DIR:-./data}, ${LOG_DIR:-./logs} + 自行 mkdir
lib/proc_manager.sh:15                                           ${LOG_DIR:-./logs}/procs + 自行 mkdir
lib/logs_core.sh:307                                             只读候选路径
lib/host_provider.sh:169                                         ${DATA_DIR:-./data}/ssh_known_hosts
lib/host_inventory.sh:260                                        ${DATA_DIR:-./data}/hosts.conf
lib/user_core.sh:1540,1592,1643                                  ${LOG_DIR:-...}/password_rotate.log + mkdir
lib/backup_core.sh:409,414,415                                   生成脚本内的独立 `LOG_DIR=/var/log/user_manager`（heredoc 内字面量，不受本契约影响）
scripts/rl-snapshot.sh:272                                       ${REPORT_DIR:-$DATA_DIR/report}
tests/test_rl_mail.sh:12-14                                      测试自设
tests/test_proc_manager.sh:15                                    测试自设
tests/test_security_hardening.sh:197-207                         测试自设（含注释）
tests/test_audit_integration.sh:12                               测试自设
```

逐类确认结论：

- **假设目录在源码树下**：无。所有引用都是 `"$VAR/..."` 形式的绝对路径拼接，无相对路径二次拼接。
- **写入前未建目录**：无。5 处写入型模块各自 `mkdir -p`（§2.6 已列）。
- **权限假设**：`init_directories` 不设 mode，其余模块的 `chmod 750`（`audit_core.sh:67`、`email_daemon.sh:80`）作用于**自己创建的子目录**，与父目录被重定向到何处无关。
- **`lib/backup_core.sh:409` 是特例且安全**：那处 `LOG_DIR="/var/log/user_manager"` 在 `GENEOF` heredoc 内，是**生成给用户家目录运行的备份脚本**的字面量，与本进程的 `LOG_DIR` 无关。契约变更不触及。
- **`lib/user_core.sh:1450` 同理**：`DATA_BASE="\${DATA_BASE:-/mnt}"` 在生成给 cron 的脚本内。

### 4.2 生产部署路径

- `etc/systemd/system/um-snapshot.service`、`umweb.service`、`um-snapshot.timer`：`grep -rn 'DATA_DIR|LOG_DIR|Environment' etc/` 仅命中 `umweb.service:27` 的 `Environment=RUST_LOG=info`。**无任何单元引用本契约的变量**，因此部署行为零变化。
- `etc/tmpfiles.d/user-manager-web.conf`：只声明 `d /var/lib/user-manager-web/events`，与 `DATA_DIR` 无关。
- `etc/sudoers.d/user-manager`：只授权 `/usr/local/sbin/rl-chpasswd`，不涉及目录变量。
- `.gitignore`：`logs/` 是**整目录**忽略（实测 `git check-ignore -v logs/` 命中）；`data/` **不是**整目录忽略，而是逐条列举（`data/password_pools/`、`data/report/`、`data/audit/`、`data/job_stats/`、`data/*.db`、`data/secrets/`、`data/created_users.txt` 等）。**这一点纠正了任务书「`data/` 已在 .gitignore 里」的表述。** 对新默认值的含义：默认值仍是 `$SCRIPT_DIR/data`，与今天完全一致，所以 `.gitignore` 现状继续有效；但也意味着**若将来把 `DATA_DIR` 指向仓库内的新位置，新文件不会被自动忽略**。本轮不新增运行时文件，故无需改 `.gitignore`；`.gitignore` 不在允许修改的文件清单内，此处仅作记录。

---

## 5. 迁移与风险

### 5.1 行为变化清单

| 变化 | 影响面 |
| --- | --- |
| 未设置新变量 | **无**。逐字节等价于改动前。 |
| 设置了 `USER_MANAGER_DATA_DIR` / `USER_MANAGER_LOG_DIR` | 数据与日志改写入该路径。这是新增能力，无既有调用方会命中。 |
| runner 默认路径 | 每个套件的 `DATA_DIR`/`LOG_DIR` 指向 `mktemp -d` 下的独立目录，套件间不再共享 `<repo>/data`、`<repo>/logs`。**这是本轮唯一影响既有套件的改动。** |

### 5.2 风险与缓解

| 风险 | 评估 | 缓解 |
| --- | --- | --- |
| 某个套件隐式依赖 `<repo>/data` 中已有文件 | 低。`git grep 'PROJECT_ROOT/data' -- 'tests/*.sh'` 显示测试代码中**无**任何读 `$PROJECT_ROOT/data` 的位置（命中全部来自 `run_regression.sh` 自身的 `env` 块与各套件的 `USER_MANAGER_DATA_BASE` 默认值，二者都是「挂载点根」语义，不受影响）。 | 新套件 + 两轮全量回归实测 |
| 目录重定向后某套件写入失败 | 低。§4.1 已确认无「假设在源码树下」的写法，且各写入方自建目录。 | 两轮全量回归 |
| 4 路并行抖动掩盖真实失败 | 已知（`docs/PROGRESS.md:94`）。单次全绿不足以下结论。 | 连续跑两轮全量回归，均须 0 failed |
| `.gitignore` 未覆盖新位置产生残留 | 本轮不触发（不新增运行时文件）。 | §4.2 已记录；`git status --untracked-files=all` 验证 |
| 顺序路径与并行路径分叉 | 已消除：两条路径都注入新变量 | 顺序路径传仓库内路径，与该路径既有语义一致 |

### 5.3 回滚方式

改动集中在 `lib/config.sh:17-18` 两行、`tests/run_regression.sh` 的 `env` 块、1 个新测试文件、2 个文档。回滚优先级：

1. **只回滚 runner 注入**（删 `run_p1_one` 与 `run_p1()` 中的 4 行 `env` 参数）：库契约保留，套件恢复共享 `<repo>/data`、`<repo>/logs`。这是最小回滚，且不损失新能力。
2. **回滚库契约**（`lib/config.sh:17-18` 恢复无条件赋值）：同时必须移除新套件（它断言的正是新契约，留着必然失败），并从 `P1_SCRIPTS` 中摘除。
3. 文档改动可独立回滚，不影响运行时。

无需数据迁移：目录内容不因变量取值改变而移动，切换变量只是改变「下一次写入落在哪里」，既有数据留在原处。

---

## 6. 测试设计

新增 `tests/test_runtime_dir_contract.sh`，遵循 `tests/test_framework.sh` 的 `test_suite_start` / `test_start` / `test_pass` / `test_fail` 风格，并遵守并发安全约束：

- 用 `setup_test_env` 拿到 `$TEST_TMPDIR`（`mktemp -d`，EXIT trap 清理），全部断言只碰 `$TEST_TMPDIR`。
- 契约断言一律在 `env -i` 风格的**子进程**里做（`bash -c 'source "$1/lib/config.sh"; printf ...'`），不污染父 shell 的 `DATA_DIR`。这样 4 路并行下互不干扰，也不受 `run_p1_one` 注入的变量影响——每个用例都显式 `env` 传入或 `env -u` 清除。
- **不断言任何写入 `<repo>/data`、`<repo>/logs` 的行为**，只断言变量取值与 `init_directories` 的返回值，避免与「跑测试不应污染工作树」的门禁冲突。

用例覆盖（对应任务书要求的四类）：

| # | 用例 | 覆盖点 |
| --- | --- | --- |
| 1 | 默认值 | 未注入时 `DATA_DIR=$SCRIPT_DIR/data`、`LOG_DIR=$SCRIPT_DIR/logs`，且为绝对路径 |
| 2 | 环境变量生效 | 注入绝对路径后 `DATA_DIR`/`LOG_DIR` 跟随，且派生的 `DISABLED_USERS_FILE`、`SYMLINK_LOG` 等一并跟随 |
| 3 | 空值回退 | `USER_MANAGER_DATA_DIR=` 视为未设置，回退默认 |
| 4 | 相对路径边界 | 相对路径被原样接受（记录 §2.4 的「不强制」决策） |
| 5 | 目录不存在时创建 | `init_directories` 对不存在的注入路径返回 0 并创建之 |
| 6 | 创建失败即关闭 | 注入不可创建路径时 `init_directories` 返回非 0 |
| 7 | `USER_MANAGER_DATA_BASE` 互不干扰 | 设置 `USER_MANAGER_DATA_BASE` **不**改变 `DATA_DIR`（§3.3 的回归护栏） |
| 8 | 重复 source 稳定 | 两次 `source config.sh` 结果一致（`:-` 的幂等性） |

用例 6 需要一个「必定创建失败」的路径：以普通用户在只读父目录下 `mkdir`。测试用 `chmod 0555` 的临时目录构造；当前环境 uid=1001 非 root，可复现。若以 root 运行则该构造不成立——用 `test_skip` 显式跳过并说明原因，不静默通过。

---

## 7. 验证

1. 新套件单跑全绿。
2. `bash tests/run_regression.sh --level all` 连续两轮，均 0 failed。
3. `bash -n`（Git 跟踪 `*.sh`，跳过 `Miniforge.sh`）、`shellcheck --severity=error`、`shfmt -d`（v3.12.0）、`scripts/check_web_security.sh`、`scripts/check_sensitive_files.sh` 全部通过。
4. `git status --short --untracked-files=all` 无新增运行时产物。

计数口径提醒（`docs/STATUS.md:153`）：`P1_SCRIPTS` 增加 1 个套件后，P1 为 43；运行器末尾汇总把 P0 也计入 `PASS_COUNT`，故「全轮次通过数」为 44，不是 43。
