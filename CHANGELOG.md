# Changelog

## Unreleased

- Emit a fixed, deduplicated inbox notification in the same database transaction as the first successful API token revocation.
- Emit a fixed `security.login_failed` inbox event only for verified bad passwords, globally deduplicated in five-minute buckets without retaining username, IP or password.
- Observe validated snapshot-manifest freshness transitions and notify only on fresh/stale changes; missing, invalid and indeterminate manifests do not alert.
- Limit WeCom event subscriptions to event types the delivery worker can actually send.
- Replace deprecated Ant Design `Alert.message` and `Card.bordered` props with their current equivalents.
- Fix the execution-plan regression fixture host keys; the full shell regression now passes (41 suites, one optional performance suite skipped).

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
