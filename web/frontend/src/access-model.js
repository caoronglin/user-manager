import { queryString } from './api.js';

export function notificationsUrl(unreadOnly, cursor) {
  return '/api/notifications?' + queryString({
    unread: unreadOnly ? 1 : undefined,
    limit: 100,
    cursor_ts: cursor?.created_at,
    cursor_id: cursor?.id,
  });
}

export function tokenStatus(token, now = Date.now()) {
  if (token.revoked) return 'revoked';
  const expires = Number(token.expires_at);
  if (token.expires_at == null || !Number.isFinite(expires)) return 'unknown';
  return expires * 1000 <= now ? 'expired' : 'active';
}

export function validTokenName(value) {
  const name = typeof value === 'string' ? value.trim() : '';
  return name.length > 0 && new TextEncoder().encode(name).length <= 64;
}
