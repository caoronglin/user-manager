# WeCom delivery for Web inbox events

The Web service has a separate, non-privileged delivery worker for selected
inbox events created by Web itself. It does not read or write the fixed
root-owned event spool; that spool remains dedicated to `user.created` and
`user.disabled`.

## Event allowlist

The subscription API exposes only event types supported by the corresponding
fixed delivery path. The CLI spool handles user lifecycle events; the Web
worker handles these native inbox events:

| Subscription | Inbox event source | WeCom text |
| --- | --- | --- |
| `security.login_failed` | `security.login_failed` | `[User Manager] Login credential verification failed.` |
| `security.token_revoked` | `security.token_revoked` | `[User Manager] An API token was revoked.` |
| `snapshot.freshness_changed` | `snapshot.stale` or `snapshot.recovered` | `[User Manager] Snapshot freshness changed.` |

Snapshot transitions are normalized to one subscription. The message does not
include whether the manifest became stale or recovered.

## Privacy and delivery behavior

- The inbox insert and native outbox insert share a database transaction. The
  outbox retains only an internal idempotency reference, a random opaque
  delivery id, the allowlisted type, timestamps, and status.
- Outbound text is generated from the event enum only. Notification title,
  summary, target, source, username, IP address, token identifier, password,
  and other event details are not read by the sender or put in the payload.
- The normal WeCom enabled/subscription settings apply. Dry-run writes a local
  delivery-history entry and makes no network request.
- Each event type has a global five-minute send throttle. Login failures are
  also combined into five-minute inbox buckets at their source.
- Live delivery uses the existing encrypted, fixed Tencent webhook setting,
  HTTPS endpoint validation, disabled redirects, an 8-second request timeout,
  a 16 KiB response bound, and at most three attempts. Retries cover network
  errors, timeouts, HTTP 429, and HTTP 5xx only.
- The worker processes at most 32 queued events per 30-second poll. It retains
  up to 2,000 terminal outbox rows for idempotency and the shared delivery
  history keeps its existing 1,000-row bound. A terminal delivery failure
  remains visible in history and is not retried indefinitely.
- The worker assumes one `umweb` process owns a database. It does not claim
  rows with a cross-process lease, so multiple service instances sharing the
  same SQLite database could send the same pending event.
- WeCom does not provide an idempotency key here. If the remote side accepts a
  message but its response is lost, a bounded retry or restart may deliver a
  duplicate.

## Verification status

Focused Rust tests cover the allowlist and snapshot normalization, transactional
outbox insertion, duplicate suppression, metadata minimization, fixed text,
retry classification, dry-run delivery history, and five-minute throttling.
The reqwest HTTP exchange itself has no mock-server test. No target host or live
WeCom credential was available for end-to-end delivery verification; no
external message was sent during development.
