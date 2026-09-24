# M1 仓库审计与实现状态

初始审计日期：2026-09-23；工作树复核：2026-09-24
初始基线：`24066159e79514d42686a54eb50d01d35086f212`。复核时分支为 `main`，HEAD 为 `0f6bee5`，工作树包含尚未提交的功能与加固改动。

本文记录代码和针对性验证状态。它不构成目标主机部署、GitHub 推送或版本发布证明。

## 架构与安全边界

```text
CLI/TUI/scripts
    ↓
trusted root snapshot collector
    ↓ versioned, scrubbed, atomic snapshots
non-root umweb (Rust/Axum, read-only snapshot access)
    ├── capability-gated read APIs
    ├── Web-owned SQLite state: users, MFA, sessions, tokens, notifications
    └── encrypted WeCom settings and bounded delivery history
React/Vite/Ant Design frontend
```

- CLI/TUI 继续负责 Linux 用户、配额、SMB 和备份等系统管理；Web 不调用这些写路径。
- `scripts/rl-snapshot.sh` 组装基础系统快照和 `lib/snapshot_ops.sh` 采集的 Ubuntu/Ops 摘要。不可用的工具或分节以降级状态表达。
- Rust 系统观测 API 从固定快照种类读取；Web 自身用户、会话、MFA、token、通知和企业微信状态存于 Web 数据库。
- 前端已存在于 `web/frontend`。当前包使用 React、Vite 和 Ant Design；没有使用原规划中的 Umi/Ant Design ProComponents。
- `umweb.service` 的仓库配置包含普通用户运行、能力清空、`NoNewPrivileges`、只读快照访问和 `UMask=0077` 等约束。静态文件不能证明目标主机实际安装和运行状态。

Web 仍不得获得 root/sudo/capability、特权 socket 或任意命令执行能力。系统写操作继续由本机受信任 CLI/TUI 执行。

## 阶段完成度

| 阶段 | 状态 | 当前判断 |
| --- | --- | --- |
| P0 安全边界与 Snapshot | [DONE] | 有版本/类型/时间校验、只读快照 API、脱敏和失败关闭的原子写实现；目标机属主、组和 mode 尚待部署验证。 |
| P1 Rust 后端基础 | [DONE] | Axum、服务端认证与会话、能力默认拒绝、CSRF、限流和 SQLite 已实现。 |
| P2 只读系统 API | [DONE] | users/quota/resources/SMB/hosts/GPU/system summary 均从固定快照读取。 |
| P3 Logs/Audit/Reports | [DONE] | 固定来源日志、审计过滤/分页/导出上限及报表索引已实现。 |
| P4 Web 身份与通知 | [PARTIAL] | root event spool 消费 CLI 的 `user.created`/`user.disabled`，幂等写入 inbox 并按配置投递 WeCom，同类同用户五分钟抑制；真实密码失败通知按全局时间桶合并，Token 首次成功撤销和 manifest fresh/stale 状态转换也会写入 inbox。WeCom 只开放 dispatcher 支持的用户生命周期事件；Web 原生通知的 WeCom 通路和真实 webhook 仍待完成。 |
| P5 前端 | [PARTIAL] | 生产构建通过；已在浏览器检查桌面登录页、语言切换和密码显隐。因未运行后端，认证/MFA 端到端、响应式与键盘/无障碍验收仍未完成；当前栈与 Umi/ProComponents 规划不同。 |
| P6 Ubuntu Ops/多主机只读观测 | [DONE] | 本机 Ops 采集器覆盖系统、CPU/内存/压力、文件系统/inode、systemd、APT/reboot、AppArmor，并有分节降级处理和测试。目标环境的数据可用性仍需实机确认。 |
| P7 Hardening/回归/发布 | [PARTIAL] | `v0.2.0` 已推送并发布；全仓 Shell 回归现为 41 个套件通过、0 个失败、1 个可选性能项跳过。浏览器完整流程和目标机验收仍未完成。 |

## 本轮修复与新增实现

- 数值环境变量和备份保留参数在进入算术运算/`find` 参数前进行十进制格式与范围校验；host provider 的文件描述符检查使用实际 Bash 子进程 PID。
- Snapshot writer 对路径符号链接、权限设置、属主设置、同步和安装失败采取失败关闭处理，并清理临时文件；Snapshot reader 限制大小、拒绝符号链接、检查协议/kind/元数据并将异常未来时间标记为 stale。
- Web 私密文件和数据库路径强化了符号链接、文件类型、属主、硬链接数和权限检查；服务配置增加 `UMask=0077`。
- 邮件队列 secret 使用认证加密格式并验证完整性，兼容读取旧格式并迁移；篡改数据失败关闭。
- 新增只读 Ubuntu Ops 采集，包括文件系统/inode、systemd、APT/reboot-required、AppArmor、Ubuntu/启动时间/虚拟化、CPU/内存/swap/PSI。
- WeCom 管理 API 支持脱敏配置读取、加密持久化、事件目录、版本冲突检测、固定测试消息、有界投递历史及限定条件和次数的重试。
- `web/frontend` 增加登录/MFA、只读信息页、WeCom 管理、投递记录、能力过滤、快照新鲜度提示、主题和中英文切换。页面代码不能代替浏览器实测。

## 验证记录

| 验证 | 结果 | 范围/限制 |
| --- | --- | --- |
| `cargo fmt --all -- --check` | 通过 | Web backend。 |
| `cargo clippy --locked --all-targets -- -D warnings` | 通过 | Web backend。 |
| `cargo test --locked` | 通过，59 个测试 | 当前 backend 单元与集成测试；包含登录失败去重、Token 撤销通知、快照 freshness observer 和 WeCom 目录一致性；不覆盖目标机部署。 |
| `npm ci --offline` + `npm run build` | 通过 | 前端生产构建；npm audit 报告 0 个漏洞。构建有 Ant Design `use client` 提示和约 1.12 MB 主 JS bundle 提示。浏览器已检查桌面登录页渲染、语言切换和密码显隐；由于后端未启动，API 显示 404，认证/MFA 流程未验证；响应式和无障碍仍未验收。 |
| `tests/test_snapshot_ops.sh` | 通过，7/7 | Ops collector 测试；当前容器/主机工具缺失时会验证降级状态。 |
| `tests/test_backup_core.sh` | 通过，16/16 | 备份保留与参数校验。 |
| `tests/test_security_hardening.sh` | 通过，25/25 | 在临时 Mamba/SQLite 环境中运行；测试环境与缓存已删除。 |
| Snapshot 专项测试 | 通过，25/25 | 在 ext4 Git 副本中恢复索引保存的执行位后通过。 |
| Ops / CLI event spool / Web 边界测试 | 通过，7/7、11/11、9/9 | Ubuntu Ops collector、事件发布器和 systemd 安全边界。 |
| 脚本入口 / 改密包装 / Remote CLI | 通过，19/19、19/19、9/9 | 在 ext4 Git 副本中验证入口执行位和只读协议。 |
| 全仓 `tests/run_regression.sh --level all` | 41 个通过、0 个失败、1 个跳过 | 在一次性 ext4 clone 与私有临时目录中运行；Host/SSH 用例通过，执行计划测试 fixture 键修正后通过。可选性能套件按默认规则跳过，生产安全校验未放宽。 |

此前审计记录的 shell 数值注入、子 shell FD 路径、Snapshot 错误处理、WeCom 缺失和 P5/P6 缺失已在当前工作树有对应实现。P4 当前有 CLI 用户生命周期、Web 密码失败/Token 撤销与快照 fresh/stale 转换 inbox 事件；WeCom 仅投递 CLI 用户生命周期事件。

## 未完成项与发布边界

1. Web 原生 `security.*` / `snapshot.*` inbox 事件尚未接入 WeCom dispatcher，保持不可订阅；目标 Ubuntu 主机与真实机器人验收仍待完成。
2. 继续使用浏览器验证登录/MFA、权限隐藏、WeCom 保存/测试、主要页面数据状态、响应式与键盘/无障碍；当前仅完成登录页桌面渲染、语言和密码显隐检查，且 Vite/Ant Design 栈尚未迁移到 Umi/ProComponents。
3. 在目标 Ubuntu 主机验证 `umweb` 的组成员、sudoers、capability、systemd 属性、数据库/密钥属主权限、只读快照权限和 timer 运行状态。
4. 已完成：在一次性 ext4 clone 和私有临时目录重跑完整回归；修复执行计划测试 fixture 中带空格的主机键，41 个套件通过、0 个失败，生产代码的安全父路径校验保持不变。
5. `v0.2.0` 已推送到 `main`，标签与 GitHub Release 均已验证；GitHub 发布页为 https://github.com/caoronglin/user-manager/releases/tag/v0.2.0。旧版 `v0.1.0` 不包含本轮更改。
