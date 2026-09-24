import React, { useEffect, useState } from 'react';
import {
  Alert, Button, Card, Empty, Form, Input, Result, Skeleton, Space, Table, Tag, Typography,
} from 'antd';
import { ApiError, apiRequest, freshnessLabel, formatTime, hasSensitiveKey, unwrap } from './api.js';
import { useFreshness, useLanguage } from './App.jsx';

const { Title, Paragraph, Text } = Typography;

const ICON_PATHS = {
  dashboard: <><rect x="3.5" y="3.5" width="7" height="7" rx="1.5"/><rect x="13.5" y="3.5" width="7" height="7" rx="1.5"/><rect x="3.5" y="13.5" width="7" height="7" rx="1.5"/><rect x="13.5" y="13.5" width="7" height="7" rx="1.5"/></>,
  users: <><circle cx="9" cy="8" r="3.25"/><path d="M3.5 19c.65-3.1 2.43-4.7 5.5-4.7s4.85 1.6 5.5 4.7"/><path d="M15.5 5.2a3 3 0 0 1 0 5.6M17 14.5c2.1.55 3.3 2 3.6 4.5"/></>,
  resources: <><path d="M4 19V8.5a2 2 0 0 1 2-2h3.5a2 2 0 0 1 2 2V19M4 12h7.5M12 19V5a2 2 0 0 1 2-2H18a2 2 0 0 1 2 2v14M12 10h8M12 15h8"/></>,
  share: <><path d="M7.5 12h9M13 8.5l3.5 3.5-3.5 3.5"/><circle cx="5" cy="12" r="2"/><circle cx="19" cy="12" r="2"/><path d="M5 14v3a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-3"/></>,
  hosts: <><rect x="4" y="4" width="16" height="6" rx="1.5"/><rect x="4" y="14" width="16" height="6" rx="1.5"/><path d="M7 7h.01M7 17h.01M11 7h5M11 17h5"/></>,
  system: <><circle cx="12" cy="12" r="3"/><path d="m19.4 15 .1.1 1.15.9-1.1 1.9-1.35-.55a7.7 7.7 0 0 1-1.5.87L16.5 20h-2.2l-.25-1.52a7.7 7.7 0 0 1-1.7 0L12.1 20H9.9l-.2-1.78a7.7 7.7 0 0 1-1.5-.87l-1.4.55-1.1-1.9 1.2-.9a8 8 0 0 1-.2-1.1 8 8 0 0 1 .2-1.1l-1.2-.9 1.1-1.9 1.4.55a7.7 7.7 0 0 1 1.5-.87L9.9 8h2.2l.25 1.52a7.7 7.7 0 0 1 1.7 0L14.3 8h2.2l.2 1.78a7.7 7.7 0 0 1 1.5.87l1.35-.55 1.1 1.9-1.15.9a8 8 0 0 1 .2 1.1 8 8 0 0 1-.3 1Z"/></>,
  logs: <><path d="M5 5h14M5 10h14M5 15h9M5 20h9"/><circle cx="18" cy="17" r="3"/><path d="M18 15.5v1.7l1 0.6"/></>,
  reports: <><path d="M6 3.5h8l4 4V20a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1V4.5a1 1 0 0 1 1-1Z"/><path d="M14 3.5V8h4M8 12h8M8 16h8"/></>,
  audit: <><path d="M12 3 19 6v5c0 4.6-2.8 8-7 10-4.2-2-7-5.4-7-10V6l7-3Z"/><path d="m9 12 2 2 4-4"/></>,
  settings: <><circle cx="12" cy="12" r="3"/><path d="M19 13.5a7.3 7.3 0 0 0 0-3l1.5-1.1-1.5-2.6-1.8.7a7.5 7.5 0 0 0-2.6-1.5L14.3 4h-3l-.3 2a7.5 7.5 0 0 0-2.6 1.5l-1.8-.7-1.5 2.6 1.5 1.1a7.3 7.3 0 0 0 0 3L5.1 14.6l1.5 2.6 1.8-.7a7.5 7.5 0 0 0 2.6 1.5l.3 2h3l.3-2a7.5 7.5 0 0 0 2.6-1.5l1.8.7 1.5-2.6L19 13.5Z"/></>,
  menu: <><path d="M4 7h16M4 12h16M4 17h16"/></>,
  logout: <><path d="M10 5H6a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h4"/><path d="M14 8l4 4-4 4M18 12H9"/></>,
  moon: <path d="M20.4 15.1A8.5 8.5 0 0 1 8.9 3.6 8.5 8.5 0 1 0 20.4 15.1Z"/>,
  sun: <><circle cx="12" cy="12" r="4"/><path d="M12 2.5v2M12 19.5v2M4.6 4.6l1.4 1.4m12 12 1.4 1.4M2.5 12h2m15 0h2M4.6 19.4 6 18m12-12 1.4-1.4"/></>,
  chevron: <path d="m8 10 4 4 4-4"/>,
  clock: <><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></>,
  refresh: <><path d="M20 7v5h-5M4 17v-5h5"/><path d="M5.6 9a7 7 0 0 1 11.6-2L20 12M4 12l2.8 5a7 7 0 0 0 11.6-2"/></>,
};

export function Icon({ name, size = 18 }) {
  return <svg aria-hidden="true" className="ui-icon" width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round">{ICON_PATHS[name] || ICON_PATHS.dashboard}</svg>;
}

export function useEndpoint(url, enabled = true) {
  const { registerFreshness } = useFreshness();
  const [state, setState] = useState({ loading: true, response: null, error: null });
  const [revision, setRevision] = useState(0);
  useEffect(() => {
    if (!enabled || !url) {
      setState({ loading: false, response: null, error: null });
      return undefined;
    }
    const controller = new AbortController();
    let active = true;
    setState((current) => ({ ...current, loading: true, error: null }));
    apiRequest(url, { signal: controller.signal })
      .then((response) => {
        if (!active) return;
        setState({ loading: false, response, error: null });
        registerFreshness(url.split('?')[0], response?.meta?.freshness);
      })
      .catch((error) => {
        if (!active) return;
        setState({ loading: false, response: null, error });
      });
    return () => { active = false; controller.abort(); };
  }, [enabled, url, revision, registerFreshness]);
  return { ...state, data: unwrap(state.response), freshness: state.response?.meta?.freshness, refresh: () => setRevision((n) => n + 1) };
}

export function PageHeader({ title, description, freshness, actions }) {
  const { language } = useLanguage();
  return (
    <div className="page-header">
      <div className="page-heading">
        <Title level={2}>{title}</Title>
        {description && <Paragraph className="page-description">{description}</Paragraph>}
      </div>
      <div className="page-header-side">
        {freshness && <SnapshotStatus freshness={freshness} language={language} />}
        {actions}
      </div>
    </div>
  );
}

export function SnapshotStatus({ freshness, language = 'zh', compact = false }) {
  if (!freshness) return <div className={`snapshot-status snapshot-unknown ${compact ? 'snapshot-compact' : ''}`}><span className="snapshot-dot" />{language === 'zh' ? '等待快照' : 'Awaiting snapshot'}</div>;
  const state = !freshness.present ? 'missing' : freshness.stale ? 'stale' : 'fresh';
  const label = freshnessLabel(freshness, language);
  return (
    <div className={`snapshot-status snapshot-${state} ${compact ? 'snapshot-compact' : ''}`} title={freshness.generated_at ? `${label} · ${formatTime(freshness.generated_at, language)}` : label}>
      <Icon name="clock" size={15} />
      <span>{label}</span>
    </div>
  );
}

export function FreshnessAlert({ freshness }) {
  const { text } = useLanguage();
  if (!freshness) return null;
  if (!freshness.present) return <Alert showIcon type="warning" className="snapshot-alert" message={text('暂无快照', 'No snapshot available')} description={text('采集器尚未生成此类数据，或快照文件暂不可用。', 'The collector has not produced this data yet, or the snapshot is unavailable.')} />;
  if (freshness.stale) return <Alert showIcon type="warning" className="snapshot-alert" message={text('显示的是过期快照', 'Showing a stale snapshot')} description={text('以下内容可能未反映系统当前状态。', 'The values below may not reflect the current system state.')} />;
  return null;
}

export function EmptyState({ title, description, action }) {
  return <div className="empty-state"><Empty image={Empty.PRESENTED_IMAGE_SIMPLE} description={<span><strong>{title}</strong>{description && <small>{description}</small>}</span>} />{action}</div>;
}

export function DataState({ loading, error, onRetry, children, empty, emptyTitle, emptyDescription }) {
  const { text } = useLanguage();
  if (loading) return <Card className="content-card"><Skeleton active paragraph={{ rows: 4 }} /></Card>;
  if (error) {
    return <Alert
      type={error.status === 403 ? 'warning' : 'error'}
      showIcon
      className="data-error"
      message={error.status === 403 ? text('没有访问权限', 'Access denied') : text('暂时无法读取数据', 'Data is temporarily unavailable')}
      description={error.message || text('请稍后重试。', 'Please try again later.')}
      action={onRetry ? <Button size="small" onClick={onRetry}>{text('重试', 'Retry')}</Button> : null}
    />;
  }
  if (empty) return <EmptyState title={emptyTitle || text('没有可显示的数据', 'No data to display')} description={emptyDescription} />;
  return children;
}

export function DataTable({ columns, dataSource, rowKey = 'key', emptyText, pagination = false, size = 'middle', scrollX = true, onRow }) {
  const { text } = useLanguage();
  return (
    <Table
      className="data-table"
      columns={columns}
      dataSource={dataSource}
      rowKey={rowKey}
      size={size}
      pagination={pagination}
      locale={{ emptyText: emptyText || <Empty image={Empty.PRESENTED_IMAGE_SIMPLE} description={text('暂无记录', 'No records')} /> }}
      scroll={scrollX ? { x: 'max-content' } : undefined}
      onRow={onRow}
    />
  );
}

export function RecordValue({ value, name, language = 'zh' }) {
  if (hasSensitiveKey(name || '')) return null;
  if (value === null || value === undefined || value === '') return <Text type="secondary">—</Text>;
  if (typeof value === 'boolean') return <Tag color={value ? 'success' : 'default'}>{value ? (language === 'zh' ? '是' : 'Yes') : (language === 'zh' ? '否' : 'No')}</Tag>;
  if (Array.isArray(value)) return <Text>{value.map((entry) => typeof entry === 'object' ? JSON.stringify(sanitizeForDisplay(entry)) : String(entry)).join(', ') || '—'}</Text>;
  if (typeof value === 'object') return <Text code className="inline-object">{Object.entries(value).filter(([key]) => !hasSensitiveKey(key)).map(([key, entry]) => `${key}: ${String(entry ?? '—')}`).join(' · ') || '—'}</Text>;
  return <Text>{String(value)}</Text>;
}

function sanitizeForDisplay(value) {
  if (Array.isArray(value)) return value.map(sanitizeForDisplay);
  if (!value || typeof value !== 'object') return value;
  return Object.fromEntries(Object.entries(value).filter(([key]) => !hasSensitiveKey(key)).map(([key, item]) => [key, sanitizeForDisplay(item)]));
}

export function KeyValueGrid({ value, omit = [] }) {
  const { language } = useLanguage();
  const record = value && typeof value === 'object' && !Array.isArray(value) ? value : {};
  const entries = Object.entries(record).filter(([key]) => !hasSensitiveKey(key) && !omit.includes(key));
  if (!entries.length) return <EmptyState title={language === 'zh' ? '没有可显示的字段' : 'No fields to display'} />;
  return <dl className="key-value-grid">{entries.map(([key, item]) => <div className="key-value-row" key={key}><dt>{key.replaceAll('_', ' ')}</dt><dd><RecordValue name={key} value={item} language={language} /></dd></div>)}</dl>;
}

export function ContentCard({ title, extra, children, className = '' }) {
  return <Card title={title} extra={extra} className={`content-card ${className}`}>{children}</Card>;
}

export function loginErrorMessage(error, language) {
  if (error instanceof ApiError && error.status === 401) return language === 'zh' ? '登录信息无效，请检查后重试。' : 'Those credentials were not accepted.';
  return error?.message || (language === 'zh' ? '登录失败。' : 'Sign in failed.');
}

export function LoginPage({ language, setLanguage, onSubmit, mfaPending, notice, unavailable, onRetry }) {
  const [busy, setBusy] = useState(false);
  const [form] = Form.useForm();
  const zh = language === 'zh';
  const submit = async (values) => {
    setBusy(true);
    try { await onSubmit(mfaPending ? values.code : values); }
    finally { setBusy(false); }
  };
  return (
    <main className="login-screen">
      <div className="login-topline">
        <div className="login-brand"><div className="brand-mark"><span>U</span></div><strong>User Manager</strong></div>
        <Button type="text" onClick={() => setLanguage(zh ? 'en' : 'zh')}>{zh ? 'EN' : '中文'}</Button>
      </div>
      <div className="login-main">
        <section className="login-copy">
          <div className="login-wordmark">User Manager</div>
          <Title>{zh ? '系统状态，一目了然。' : 'Your systems, in clear view.'}</Title>
          <Paragraph>{zh ? '安全查看用户、资源与主机快照。' : 'A secure view of user, resource and host snapshots.'}</Paragraph>
          <div className="login-boundary"><span className="boundary-icon"><Icon name="audit" size={20} /></span><span>{zh ? '只读观测 · 权限由服务端校验' : 'Read-only observation · access enforced by the server'}</span></div>
        </section>
        <Card className="login-card" bordered={false}>
          <Title level={3}>{mfaPending ? (zh ? '双重验证' : 'Two-factor verification') : (zh ? '登录控制台' : 'Sign in')}</Title>
          <Paragraph className="login-form-hint">{mfaPending ? (zh ? '输入身份验证器中的 6 位验证码。' : 'Enter the 6-digit code from your authenticator.') : (zh ? '使用你的 Web 控制台账号继续。' : 'Continue with your web console account.')}</Paragraph>
          {notice && <Alert showIcon type="error" message={notice} className="login-alert" />}
          {unavailable && <Alert showIcon type="warning" message={zh ? '服务暂不可用' : 'Service unavailable'} description={zh ? '确认后端服务已启动后重试。' : 'Confirm the backend service is running, then retry.'} className="login-alert" action={<Button size="small" onClick={onRetry}>{zh ? '重试' : 'Retry'}</Button>} />}
          <Form form={form} layout="vertical" onFinish={submit} requiredMark={false}>
            {mfaPending ? (
              <Form.Item name="code" label={zh ? '验证码' : 'Verification code'} rules={[{ required: true, message: zh ? '请输入验证码' : 'Enter the verification code' }, { pattern: /^\d{6}$/, message: zh ? '验证码为 6 位数字' : 'Use the 6-digit code' }]}>
                <Input size="large" inputMode="numeric" autoComplete="one-time-code" maxLength={6} autoFocus placeholder="000000" />
              </Form.Item>
            ) : (
              <>
                <Form.Item name="username" label={zh ? '用户名' : 'Username'} rules={[{ required: true, message: zh ? '请输入用户名' : 'Enter your username' }]}>
                  <Input size="large" autoComplete="username" autoFocus placeholder={zh ? '输入用户名' : 'Enter username'} />
                </Form.Item>
                <Form.Item name="password" label={zh ? '密码' : 'Password'} rules={[{ required: true, message: zh ? '请输入密码' : 'Enter your password' }]}>
                  <Input.Password size="large" autoComplete="current-password" placeholder={zh ? '输入密码' : 'Enter password'} />
                </Form.Item>
              </>
            )}
            <Button type="primary" size="large" htmlType="submit" loading={busy} block>{mfaPending ? (zh ? '验证并登录' : 'Verify and sign in') : (zh ? '登录' : 'Sign in')}</Button>
            {mfaPending && <Button type="link" block onClick={() => window.dispatchEvent(new Event('um:unauthorized'))}>{zh ? '返回账号登录' : 'Back to sign in'}</Button>}
          </Form>
          <div className="login-footnote">{zh ? '系统数据来自受控快照，不执行主机操作。' : 'Data is read from controlled snapshots. Host actions are not available.'}</div>
        </Card>
      </div>
      <footer className="login-footer">User Manager <span>·</span> {zh ? '系统运维观测' : 'Operations visibility'}</footer>
    </main>
  );
}

export function ExportLink({ endpoint, filename, label, format = 'csv' }) {
  const { text } = useLanguage();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const download = async () => {
    setBusy(true);
    setError('');
    try {
      const response = await fetch(endpoint, { credentials: 'same-origin', headers: { Accept: '*/*' } });
      if (!response.ok) throw new Error(response.status === 401 ? text('登录已失效。', 'Session expired.') : text('导出失败，请稍后重试。', 'Export failed. Try again later.'));
      const blob = await response.blob();
      const url = URL.createObjectURL(blob);
      const anchor = document.createElement('a');
      anchor.href = url;
      anchor.download = filename;
      document.body.appendChild(anchor);
      anchor.click();
      anchor.remove();
      window.setTimeout(() => URL.revokeObjectURL(url), 1000);
    } catch (cause) {
      setError(cause.message);
    } finally {
      setBusy(false);
    }
  };
  return <Space direction="vertical" size={8} align="end"><Button loading={busy} onClick={download}>{label || text(`导出 ${format.toUpperCase()}`, `Export ${format.toUpperCase()}`)}</Button>{error && <Text type="danger">{error}</Text>}</Space>;
}
