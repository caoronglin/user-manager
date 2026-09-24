export class ApiError extends Error {
  constructor(message, status = 0) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
  }
}

export function readCookie(name) {
  const prefix = `${name}=`;
  const item = document.cookie.split(';').map((part) => part.trim()).find((part) => part.startsWith(prefix));
  return item ? decodeURIComponent(item.slice(prefix.length)) : '';
}

export async function apiRequest(path, options = {}) {
  const method = (options.method || 'GET').toUpperCase();
  const { unauthorizedOn401 = true, ...fetchOptions } = options;
  const headers = new Headers(options.headers || {});
  headers.set('Accept', 'application/json');
  if (options.body !== undefined) headers.set('Content-Type', 'application/json');
  if (!['GET', 'HEAD', 'OPTIONS'].includes(method)) {
    const csrf = readCookie('umweb_csrf');
    if (csrf) headers.set('X-CSRF-Token', csrf);
  }

  let response;
  try {
    response = await fetch(path, {
      ...fetchOptions,
      method,
      headers,
      credentials: 'same-origin',
      body: options.body === undefined ? undefined : JSON.stringify(options.body),
    });
  } catch {
    throw new ApiError('无法连接到服务，请检查网络或服务状态。');
  }

  if (response.status === 204) return null;
  const contentType = response.headers.get('content-type') || '';
  const payload = contentType.includes('application/json') ? await response.json().catch(() => null) : null;
  if (!response.ok || payload?.ok === false) {
    if (response.status === 401 && unauthorizedOn401) window.dispatchEvent(new Event('um:unauthorized'));
    const message = response.status === 401
      ? '登录已失效，请重新登录。'
      : response.status === 403
        ? '当前账号没有查看此数据的权限。'
        : payload?.error?.message || payload?.message || `请求失败（${response.status || '网络错误'}）`;
    throw new ApiError(message, response.status);
  }
  return payload;
}

export function unwrap(response) {
  return response?.data ?? null;
}

export function queryString(values) {
  const query = new URLSearchParams();
  Object.entries(values).forEach(([key, value]) => {
    if (value !== undefined && value !== null && String(value).length > 0) query.set(key, String(value));
  });
  return query.toString();
}

export function getArray(value, key) {
  if (Array.isArray(value)) return value;
  const candidate = key ? value?.[key] : null;
  return Array.isArray(candidate) ? candidate : [];
}

export function safeObject(value) {
  return value && typeof value === 'object' && !Array.isArray(value) ? value : {};
}

export function freshnessLabel(freshness, language = 'zh') {
  const age = Number(freshness?.age_seconds);
  if (!freshness?.present) return language === 'zh' ? '尚无快照' : 'No snapshot';
  if (freshness?.stale) return language === 'zh' ? '数据已过期' : 'Snapshot is stale';
  if (Number.isFinite(age)) {
    const value = age < 60 ? `${Math.max(0, age)}s` : `${Math.floor(age / 60)}m`;
    return language === 'zh' ? `采集于 ${value} 前` : `Collected ${value} ago`;
  }
  return language === 'zh' ? '快照可用' : 'Snapshot available';
}

export function formatBytes(value, language = 'zh') {
  const bytes = Number(value);
  if (!Number.isFinite(bytes) || bytes < 0) return '—';
  if (bytes === 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  const power = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1);
  const amount = bytes / 1024 ** power;
  return `${new Intl.NumberFormat(language === 'zh' ? 'zh-CN' : 'en', { maximumFractionDigits: power < 2 ? 0 : 1 }).format(amount)} ${units[power]}`;
}

export function formatTime(value, language = 'zh') {
  if (!value) return '—';
  const date = typeof value === 'number' ? new Date(value < 1e12 ? value * 1000 : value) : new Date(value);
  if (Number.isNaN(date.getTime())) return String(value);
  return new Intl.DateTimeFormat(language === 'zh' ? 'zh-CN' : 'en', {
    dateStyle: 'medium',
    timeStyle: 'short',
  }).format(date);
}

export function hasSensitiveKey(key) {
  return /(password|passwd|secret|token|private.?key|credential|webhook)/i.test(key);
}
