# 第四部分：CI 门禁是否名副其实

核对对象：`.github/workflows/ci.yml`、`.pre-commit-config.yaml`、`tests/run_regression.sh`、`scripts/check_web_security.sh`、`scripts/check_sensitive_files.sh`。

**前置事实（重要，影响下面多条判定）**：GitHub Actions 对未指定 `shell:` 的 `run:` 步骤使用 `bash -e {0}`（**有 `-e`，无 `pipefail`**）。本次用探针实测确认：

```text
$ bash -e -c 'bash scripts/check_web_security.sh /tmp/does-not-exist-xyz; rc=$?; echo REACHED_rc=$rc'
outer_rc=2          # 未打印 REACHED → 脚本返回 2 时 shell 立即中止，rc=$? 不可达

$ bash -e -c '[[ a == b ]] && continue; echo STILL_ALIVE'
STILL_ALIVE        # AND-OR 列表不触发 set -e → 该写法安全
outer_rc=0
```

另：`.pre-commit-config.yaml` 与 CI 是**两套独立门禁**，pre-commit 需开发者手动 `pre-commit install` 才生效（其自身注释第 4-5 行已说明），**不构成 CI 阻断**。

---

## G. ci.yml 逐个步骤判定

### shellcheck job

| 项 | 内容 |
| --- | --- |
| 名称 | ShellCheck（ci.yml:10-33） |
| 阻断性 | **是**。步骤显式 `set -euo pipefail`（:24），循环体 `shellcheck --severity=error "$file"`（:30）非零即中止。job 无 `continue-on-error`。 |
| 失效条件 | **存在一处空转可能**：`checked` 计数器在 `shellcheck` **之后**才自增（:30-31），且**没有 `checked -eq 0` 守卫**。若 `git ls-files -z -- '*.sh'` 返回空（仓库结构剧变 / glob 语义变化），循环体不执行，步骤打印「ShellCheck scanned 0 script(s)」并**通过**。同一仓库的权限门禁（:196-199）恰好有该守卫——**两处不一致**。 |
| 实测 | 本地复现同判据，无输出（通过）。 |
| 判定 | **有效**，但缺零文件守卫（P3） |

### rust-backend job

| 项 | 内容 |
| --- | --- |
| 名称 | Rust Backend（ci.yml:35-61） |
| 阻断性 | **是**。`cargo fmt --all -- --check`（:55）、`cargo clippy --locked --all-targets -- -D warnings`（:58）、`cargo test --locked`（:61）三个独立步骤，任一非零即 job 失败。`-D warnings` 确保 warning 也阻断。 |
| 失效条件 | 未发现。`--locked` 防止依赖被静默升级。 |
| 实测 | **本环境无 `cargo`/`rustc`，无法验证（U6）**。**这意味着「危险 API 404/405 契约由 CI 断言」目前只有静态证据**：断言代码在 `web/backend/tests/api_contract.rs`，其是否真的通过取决于此 job。 |
| 判定 | **有效（设计层面）**，本轮**未复验** |

### web-frontend job

| 项 | 内容 |
| --- | --- |
| 名称 | Web Frontend（ci.yml:63-86） |
| 阻断性 | **是**。`npm ci`（:80）、`npm run build`（:83）、`npm audit --audit-level=high`（:86）三个独立步骤。 |
| 失效条件 | 未发现。 |
| 实测 | **本环境 npm 缓存位于只读文件系统（EROFS），无法验证（U7）**。 |
| 判定 | **有效（设计层面）**，本轮**未复验** |

### test job — Run Regression Suite

| 项 | 内容 |
| --- | --- |
| 名称 | Run Regression Suite（ci.yml:102-105） |
| 阻断性 | **是**。步骤未写 `set -e`，但 GHA 默认 `bash -e`；且 `run_regression.sh:481-485` 显式 `if ((FAIL_COUNT > 0)); then exit 1; fi`。**双重阻断**。 |
| 失效条件 | 未发现。 |
| 注意 | 步骤先跑 `chmod +x tests/*.sh`（:104），会**掩盖**索引 mode 缺陷——但这正是下一 job（权限门禁）用 `git ls-files -s` 判据要解决的问题，两者互补。 |
| 实测 | 本地 `bash tests/run_regression.sh --level all` → 43/0/1，退出码 0。 |
| 判定 | **有效** |

### test job — Validate Shell Syntax

| 项 | 内容 |
| --- | --- |
| 名称 | Validate Shell Syntax（ci.yml:107-114） |
| 阻断性 | **是**。`set -o pipefail` + `bash -n "$file" || exit 1`（:113）。 |
| 失效条件 | **一处需确认，已实测排除**：`[[ "$file" == 'Miniforge.sh' ]] && continue`（:112）在 `set -e` 下是否会误中止整个循环？探针实测 `bash -e -c '[[ a == b ]] && continue; echo STILL_ALIVE'` → 打印 STILL_ALIVE，**不会误中止**。该写法安全。 |
 实测 | 本地复现，无输出（通过）。 |
| 判定 | **有效** |

### validate-docs job — required docs

| 项 | 内容 |
| --- | --- |
| 名称 | Check required documentation exists（ci.yml:122-130） |
| 阻断性 | **是**。`test -f "$doc" || { echo ...; exit 1; }`。 |
| 失效条件 | 覆盖极窄：只检查 `README.md` 与 `docs/DEEPWIKI.md` **两个文件是否存在**。不校验 `docs/STATUS.md`、`plan.md`、`docs/WEB_SECURITY_BOUNDARY.md` 是否存在，也不校验**文档内引用的路径是否有效**（本审计发现的 4 处悬空引用 D-1~D-4 全部能通过此门禁）。 |
| 判定 | **有效但覆盖不足（P3）** |

### validate-docs job — README sections

| 项 | 内容 |
| --- | --- |
| 名称 | Check README sections（ci.yml:132-140） |
| 阻断性 | **否 —— 失效门禁**。三条检查全部是 `grep -Eq ... || echo "Warning: ..."`（:134、:140）与 `if grep -Eiq ...; then echo "Warning"; fi`（:137-139）。grep 无匹配时只打印 Warning，**步骤退出码仍为 0**。 |
| 失效条件 | README 删除「快速开始」/「文档」章节、重新引入「安装/Installation」章节，CI 均**不会失败**。这正是任务点名的「Warning 不阻断」类失效门禁。 |
| 判定 | **失效（P2）**。它给人「文档有门禁」的错觉，实际是提示器。 |
| 建议改法 | 若这两节是硬要求，改为 `|| { echo "::error::..."; exit 1; }`；若只是提示，**把步骤名改成「Warn」并在 job 名/文档中明示其非阻断性质**，避免误导。 |

### security job — check_sensitive_files

| 项 | 内容 |
| --- | --- |
| 名称 | Check for sensitive files（ci.yml:148-150） |
| 阻断性 | **是**。脚本 `set -Eeuo pipefail`（check_sensitive_files.sh:4）+ `exit 1`（:74）。GHA 默认 `bash -e` 亦兜底。 |
| 失效条件 | **结构性覆盖缺口（P2）**：脚本两次遍历都用 `git ls-files`（:32、:55），**只扫描已跟踪文件**。因此本审计关注的 15 个 `*.bak`、`.gitignore.bak`、以及 `data/secrets/.key`、`data/password_pools/*.txt` 等运行时敏感文件**在结构上不可能被此门禁发现**。此外内容匹配只有 5 条正则（私钥头、AKIA、gh*、github_pat、xox*，:35-39），对密码/口令/token 形态无覆盖。文件名黑名单（:28）也只匹配精确 basename，`id_rsa.bak`、`secrets.json.bak` 均不匹配。 |
| 实测 | 本地 `bash scripts/check_sensitive_files.sh .` → `No sensitive tracked files detected`，rc=0。补充：本次**人工**对 15 个 `.bak` 做了含 PASSWORD/SECRET/TOKEN/webhook key/AKIA/gh*/xox* 的扩展扫描，**零命中**（见 findings §5.4）——即当前无泄漏，但这是人工结论，不是门禁保证。 |
| 判定 | **有效（对已跟踪文件）/ 覆盖不足（P2）** |

### security job — Web backend security gate

| 项 | 内容 |
| --- | --- |
| 名称 | Web backend security gate（ci.yml:152-159） |
| 阻断性 | **实际是**（因 `bash -e`），但**代码与意图不符**。原文：<br>`bash scripts/check_web_security.sh web/backend/src`<br>`rc=$?`<br>`if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then exit "$rc"; fi`<br>`echo "web security gate rc=$rc"` |
| 失效条件 | **两处**：<br>① **`rc=$?` 是死代码**。步骤未写 `set -e`，但 GHA 默认 `bash -e {0}` 已启用。脚本返回 1 或 2 时 shell **立即中止**，`rc=$?` 与其后的 `if`/`echo` 全部不可达（探针已实测）。<br>② 后果与注释相反：注释说「无 web 源码时视为跳过，退出码 2」，实际 **rc=2 会让 job 硬失败**。这是**失败关闭**（安全方向正确），但「跳过」语义从未生效，运维若真的删除 `web/backend/src` 会看到一条令人困惑的失败而非提示。 |
| 判据空转 | **存在空转**（P2，见 findings F1）：`check_web_security.sh` **没有「扫了几个文件」守卫**。目录存在但无 `.rs` 文件时，`violations` 为空 → `exit 0` 打印「OK (no forbidden tokens)」。实测：<br>`mkdir -p /tmp/audit-empty/src && bash scripts/check_web_security.sh /tmp/audit-empty/src` → `rc=0`，**扫描 0 个文件却判定通过**。<br>另有部分失败静默：`:54` 的 `find ... 2>/dev/null \| sort -z`，find 中途出错时管道退出码取 `sort` 的 0，部分扫描失败会被当作全通过。 |
| 其他覆盖缺口 | 门禁只扫 `web/backend/src`（不含 `web/backend/tests/`）；token 列表（:24-30）**缺 `passwd`、`apt`、`dpkg`、`sysctl`**；**完全不覆盖出站网络**（`reqwest` 是正式依赖，Cargo.toml:61）。对照 `plan.md` 附录 A，**6 类禁止能力无门禁**。 |
| 实测 | `bash scripts/check_web_security.sh web/backend/src` → `OK (no forbidden tokens)`，rc=0（真阳性通过）。空目录场景 → rc=0（假阳性通过，见上）。 |
| 判定 | **对当前代码有效；存在 1 个空转缺口（P2）+ 1 处死代码（P3）+ 6 类覆盖缺口（P2）** |

### security job — Check file permissions

| 项 | 内容 |
| --- | --- |
| 名称 | Check file permissions（ci.yml:161-205） |
| 阻断性 | **是**。`missing > 0 → exit 1`（:200-204）。这是 `a4762a5` 从 Warning 收紧后的版本。 |
| 判据是否可能空转 | **不会**。三重保障：<br>① 判据读 **Git 索引 mode**（`git ls-files -s`，:194）而非 `[[ -x ]]`——索引才是 checkout 后权限的唯一来源，且不受 umask/ACL/`core.fileMode` 影响（:173-175 注释所述，本次核对属实）；<br>② 逐路径分类（:182-187）：`scripts/*.sh` 或根目录 `*.sh`，`lib/*.sh` 按设计为 644 被显式排除；<br>③ **有 `checked -eq 0` 守卫**（:196-199），「未匹配到任何入口脚本」直接 `exit 1`——**这是本仓库唯一带此守卫的门禁**，也正因如此，shellcheck/format 两个 job 的缺失才显得不一致。 |
| 实测 | 正向：复刻判据 → `checked=23 missing=0`，与 STATUS.md:183 记载一致。<br>**负向对照**（关键，证明非空转）：临时 git 仓库中构造 `bad.sh`=100644、`good.sh`=100755 → 门禁输出 `CAUGHT: 100644 bad.sh`，`missing=1`。 |
| 判定 | **有效，非空转。这是全仓库设计最扎实的一个门禁。** |

### format job — shfmt

| 项 | 内容 |
| --- | --- |
| 名称 | Format Check (shfmt)（ci.yml:209-243） |
| 阻断性 | **是**。`unclean > 0 → exit 1`（:239-242）。注释明示「已从提示模式收紧为阻断模式」（:207-208），且仓库中**无** `continue-on-error`。 |
| 失效条件 | **一处空转可能**：`checked` 计数器（:232）**没有 `checked -eq 0` 守卫**。glob 返回空时会打印 `checked=0, needs-format=0` 并通过。<br>另：遍历范围（:237 `git ls-files -z -- '*.sh'`）**不跳过** `data/*`、`logs/*`、`templates/*`，与 shellcheck job（:28）不一致——若将来在 `data/` 下放 `.sh`，两 job 行为分叉。 |
| 判定 | **有效**，缺零文件守卫（P3） |

---

## H. 非 CI 门禁

| 名称 | 阻断性 | 失效条件 | 判定 |
| --- | --- | --- | --- |
| `tests/run_regression.sh`（本地/CI 通用） | **是**（:481-485） | 无 | **有效**。本地实测 43/0/1，退出码 0。 |
| `scripts/check_web_security.sh`（本地） | 退出码 0/1/2，语义在文件头 :11 有文档 | 见 G 节「判据空转」 | **有效但可空转（P2）** |
| `scripts/check_sensitive_files.sh`（本地） | 退出码 0/1/2 | 只扫已跟踪文件（P2） | **有效但覆盖不足（P2）** |
| `.pre-commit-config.yaml`（shellcheck + shfmt） | **不阻断 CI**。需开发者手动 `pre-commit install`（配置注释 :4-5 自述） | 未安装即完全不生效；且不覆盖 `validate-docs`/`security` 任何检查 | **定位为开发者本地加速器，非门禁**。不应被计入 CI 保障。（正面：其 `args: ["-d"]` 刻意替换了 shfmt 上游默认的 `[-w, -s]`，与 CI 裸 `shfmt -d` 对齐，两端判定一致。） |

---

## I. 汇总

| 类别 | 数量 | 明细 |
| --- | --- | --- |
| 门禁总数（CI 步骤） | 13 | shellcheck×1、rust×3、frontend×3、test×2、validate-docs×2、security×4、format×1 —— 按 job 归并为 7 个 job |
| 使用 `continue-on-error` | **0** | 全文件无该关键字 |
| 使用 `\|\| true` 逃逸 | **0** | 全文件无该模式 |
| 缺 `set -e` 但仍阻断 | 4 | 依赖 GHA 默认 `bash -e`（test job ×2、security job ×2），已确认阻断有效 |
| **失效门禁（不阻断）** | **1** | G-7 validate-docs / Check README sections（三处 grep 全部只 Warning） |
| **空转门禁（无文件/无匹配即通过）** | **3** | G-1 shellcheck（缺 checked==0 守卫）、G-9 check_web_security.sh（**实测**空目录 rc=0）、G-11 format（缺 checked==0 守卫） |
| 死代码（意图不可达） | **1** | G-9 的 `rc=$?` 分支（**实测**） |
| 判定有效且经实测或负向对照证明 | 5 | G-1*、G-5、G-6、G-10、G-12 —— 其中 G-10 做了负向对照 |
| 本轮无法验证 | 2 | rust-backend（无 cargo，U6）、web-frontend（EROFS，U7） |

**门禁失效条数（按任务口径「不会在失败时阻断」+「空转即通过」合并计）：4 条** —— 1 条纯失效（G-7）+ 3 条存在空转可能（G-1、G-9、G-11），其中 **G-9 已用实测证明可空转**。

**严重级**：G-7 = P2（失效门禁）、G-9 空转 = P2（已实测）、G-1/G-11 缺守卫 = P3（低概率）、G-9 死代码 = P3（方向安全）、G-10 的 6 类附录 A 覆盖缺口 = P2。

---

## J. 对 `a4762a5` 权限门禁收紧的专项复核（任务点名）

问题：「它读 Git 索引 mode，判据是否可能空转？」

**结论：不可能空转，且判据选型正确。** 三点依据：

1. **判据来源正确**。用 `git ls-files -s` 的 mode 字段（ci.yml:194）而非 `[[ -x ]]`：前者是 checkout 后权限的唯一真实来源，且不受本地 umask、ACL、`core.fileMode=false` 影响。后者在本仓库正是失效原因（STATUS.md:216 记载 worktree 实际 mode 与索引不一致）。
2. **有零文件守卫**（:196-199）。`checked -eq 0` → `exit 1`，直接封堵「模式写错/仓库结构变化导致 glob 失配」这一最常见的空转路径。
3. **负向对照实测通过**。本次在临时仓库构造 100644 文件，门禁如期捕获（`CAUGHT: 100644 bad.sh`）。这不是「理论上会阻断」，是**实测会阻断**。

同时该门禁的范围设计也正确：`lib/*.sh` 被显式排除（:172 注释「是被 source 的库，设计上就是 644」），避免了误报。
