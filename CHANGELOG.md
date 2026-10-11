# Changelog

## Unreleased

## 0.3.0 (unreleased — 已推送 main，未打 tag)

> 状态说明：本节记录的是**尚未发布**的候选版本。截至 2026-10-11，远端 tag 仍只有 `v0.1.0`、`v0.2.0` 两个，但本文件与其支撑代码**已进入 Git 历史并推送到 `origin/main`**。此前 2026-10-02 记录的「未进入 Git 历史」已随本次推送失效。
>
> 另需注意：`main` 曾于 `0f6bee5` (09-23) 处分叉，远端一条线自行发布了 `release: prepare v0.3.0`（`ef197a6`），另一条线在本地继续开发后合并回主线（`39d7002`）。比对证明远端内容已被本地全部覆盖（67/86 文件逐字节相同，仅远端存在的文件为 0），合并未改变任何文件内容，但远端那条线曾把本节标题写作 `0.3.0 — 2026-09-25`，**该日期从未真正发布**，不应据此认定 0.3.0 已发布。
> 下方 Validation 段落记录的是干净克隆环境下的验证结果，当前工作树的实测差异见 [`docs/STATUS.md`](docs/STATUS.md)。
> 打 tag 并通过 CI 后，请将本节标题改为 `## 0.3.0 — <发布日期>`。

- Add a separate WeCom outbox worker for fixed-template `security.login_failed`, `security.token_revoked`, and `snapshot.freshness_changed` alerts; payloads exclude personal and notification details.
- Improve keyboard access for navigation, account menus, audit/log filters, quota details, and narrow-screen data tables; add skip-to-main and loading/error/empty announcements.
- Add Rust formatting, Clippy, backend test, frontend production build, and high-severity npm audit jobs to GitHub Actions.
- Route locked frontend package downloads through the public npm registry so GitHub runners do not depend on a regional mirror.
- Fix ACL cache lookups with strict shell unset-variable checking and render usage-bar ANSI colors correctly.
- Emit a fixed, deduplicated inbox notification in the same database transaction as the first successful API token revocation.
- Emit a fixed `security.login_failed` inbox event only for verified bad passwords, globally deduplicated in five-minute buckets without retaining username, IP or password.
- Observe validated snapshot-manifest freshness transitions and notify only on fresh/stale changes; missing, invalid and indeterminate manifests do not alert.
- Limit WeCom event subscriptions to event types the delivery worker can actually send.
- Replace deprecated Ant Design `Alert.message` and `Card.bordered` props with their current equivalents.
- Replace deprecated Drawer `width` props and keep the Chinese sign-in button's accessible name aligned with its visible text.
- Fix the execution-plan regression fixture host keys; the full shell regression now passes (41 suites, one optional performance suite skipped).

### Validation

- Rust formatting, Clippy, and all 65 backend tests pass.
- All seven GitHub Actions jobs pass, including ShellCheck, shell regressions, Rust, frontend build and audit, security scanning, documentation, and shfmt.
- Security-hardening shell tests pass (24 passed; one optional SQLite/jq test skipped because those tools are absent locally).
- Temporary browser checks cover password plus TOTP sign-in, key flows, permissions, keyboard navigation, and narrow tables; full WCAG/screen-reader review remains outstanding.
- No target host or live WeCom credential was available, and no external message was sent. Validate host permissions/service behavior and live delivery before deployment.

## 0.2.0 — 2026-09-24

- Add the React/Vite Web console with MFA login, capability-aware pages, system snapshots, audit/log/report views, and WeCom settings/history.
- Add encrypted WeCom configuration, bounded retries and delivery history, plus a read-only root event spool for user creation/disable events with inbox deduplication and five-minute suppression.
- Extend system snapshots with Ubuntu, CPU/memory/pressure, filesystem/inode, systemd, APT/reboot and AppArmor summaries.
- Harden snapshot writes, secret storage, private-file ownership/modes, host inventory validation, and systemd isolation.
- Restore executable Git modes for CLI entrypoints and ignore frontend build artifacts.

### Validation

- Rust: fmt and Clippy pass; 51 tests pass.
- Frontend: offline dependency install and production build pass; npm reports no known dependency vulnerabilities.
- Focused shell security, snapshot, event-spool, and systemd-boundary suites pass.
- Full shell regression: 38 suites pass; three Host/SSH-related suites are blocked by this container's non-root-owned `/tmp`; one optional performance suite is skipped.
- Published on GitHub: https://github.com/caoronglin/user-manager/releases/tag/v0.2.0. Browser visual/accessibility checks and target-host deployment validation remain pending.
