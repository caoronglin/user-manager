import React, { useState } from 'react';
import {
  Alert, Button, Form, Input, InputNumber, Modal, Select, Space, Table, Tag, Typography, message,
} from 'antd';
import {
  apiRequest, formatTime, getArray, safeObject, unwrap,
} from './api.js';
import { useLanguage } from './App.jsx';
import { ContentCard, DataState, EmptyState, PageHeader, useEndpoint } from './ui.jsx';

const { Text, Paragraph } = Typography;

// 服务端 rbac::TOKEN_READ_CAPS 的镜像。API Token 只能携带只读能力，
// 服务端对不在此列的 capability 一律拒绝（tokens_api.rs:117）。
const TOKEN_READ_CAPS = [
  'dashboard.read', 'users.read', 'quota.read', 'resource.read', 'smb.read',
  'hosts.read', 'gpu.read', 'reports.read', 'logs.read', 'audit.read', 'notifications.read',
];

const SEVERITY_TAG = {
  info: { color: 'blue', zh: '信息', en: 'Info' },
  warning: { color: 'gold', zh: '警告', en: 'Warning' },
  error: { color: 'red', zh: '错误', en: 'Error' },
  critical: { color: 'magenta', zh: '严重', en: 'Critical' },
};

export function NotificationsPage({ capabilities }) {
  const { text, language } = useLanguage();
  const canManage = capabilities.has('notifications.manage');
  const [unreadOnly, setUnreadOnly] = useState(false);
  const [busy, setBusy] = useState(false);
  const [toast, toastContext] = message.useMessage();
  const endpoint = unreadOnly ? '/api/notifications?unread=1&limit=100' : '/api/notifications?limit=100';
  const inbox = useEndpoint(endpoint);
  const data = safeObject(inbox.data);
  const items = getArray(inbox.data, 'items');
  const unread = Number(data.unread || 0);

  const act = async (path, body, successText) => {
    setBusy(true);
    try {
      await apiRequest(path, { method: 'POST', body });
      await inbox.refresh();
      toast.success(successText);
    } catch (error) {
      toast.error(error.message || text('操作失败。', 'The request failed.'));
    } finally {
      setBusy(false);
    }
  };

  const columns = [
    {
      title: text('事件', 'Event'),
      dataIndex: 'title',
      render: (value, row) => (
        <Space orientation="vertical" size={0}>
          <Text strong={!row.read}>{value || row.event_type}</Text>
          {row.summary && <Text type="secondary" style={{ fontSize: 12 }}>{row.summary}</Text>}
        </Space>
      ),
    },
    {
      title: text('级别', 'Severity'),
      dataIndex: 'severity',
      width: 96,
      render: (value) => {
        const meta = SEVERITY_TAG[value] || SEVERITY_TAG.info;
        return <Tag color={meta.color}>{language === 'zh' ? meta.zh : meta.en}</Tag>;
      },
    },
    {
      title: text('来源', 'Source'),
      dataIndex: 'source',
      width: 160,
      responsive: ['lg'],
      render: (value, row) => (value || row.target
        ? <Text type="secondary">{value || row.target}</Text>
        : <Text type="secondary">—</Text>),
    },
    {
      title: text('时间', 'Time'),
      dataIndex: 'created_at',
      width: 168,
      render: (value) => <Text type="secondary">{formatTime(value, language)}</Text>,
    },
  ];

  if (canManage) {
    columns.push({
      title: text('操作', 'Actions'),
      key: 'actions',
      width: 104,
      render: (_, row) => (row.read ? <Text type="secondary">—</Text> : (
        <Button size="small" disabled={busy} onClick={() => act('/api/notifications/read', { id: row.id }, text('已标记为已读。', 'Marked as read.'))}>
          {text('标记已读', 'Mark read')}
        </Button>
      )),
    });
  }

  return (
    <>
      <PageHeader
        title={text('通知中心', 'Notifications')}
        description={text('快照与事件产生的只读通知。', 'Read-only notices produced by snapshots and events.')}
        actions={(
          <Space>
            {unread > 0 && <Tag color="processing">{text(`${unread} 条未读`, `${unread} unread`)}</Tag>}
            <Button onClick={() => setUnreadOnly((v) => !v)}>{unreadOnly ? text('显示全部', 'Show all') : text('只看未读', 'Unread only')}</Button>
            {canManage && unread > 0 && (
              <Button type="primary" loading={busy} onClick={() => act('/api/notifications/read-all', {}, text('已全部标记为已读。', 'All marked as read.'))}>
                {text('全部已读', 'Mark all read')}
              </Button>
            )}
          </Space>
        )}
      />
      <ContentCard>
        <DataState
          loading={inbox.loading}
          error={inbox.error}
          onRetry={inbox.refresh}
          empty={!items.length}
          emptyTitle={unreadOnly ? text('没有未读通知', 'No unread notifications') : text('暂无通知', 'No notifications')}
        >
          <Table
            className="data-table"
            columns={columns}
            dataSource={items.map((item) => ({ ...item, key: item.id }))}
            rowKey="key"
            size="middle"
            pagination={false}
            locale={{ emptyText: text('暂无记录', 'No records') }}
          />
        </DataState>
      </ContentCard>
      {toastContext}
    </>
  );
}

export function ApiTokensPage() {
  const { text, language } = useLanguage();
  const [form] = Form.useForm();
  const [open, setOpen] = useState(false);
  const [saving, setSaving] = useState(false);
  const [issued, setIssued] = useState(null);
  const [toast, toastContext] = message.useMessage();
  const tokens = useEndpoint('/api/api-tokens');
  const rows = getArray(tokens.data, 'tokens');

  const create = async () => {
    setSaving(true);
    try {
      const values = await form.validateFields();
      const response = await apiRequest('/api/api-tokens', { method: 'POST', body: values });
      setIssued(safeObject(unwrap(response)));
      setOpen(false);
      form.resetFields();
      await tokens.refresh();
    } catch (error) {
      if (error?.errorFields) return;
      toast.error(error.message || text('创建失败。', 'Could not create the token.'));
    } finally {
      setSaving(false);
    }
  };

  const revoke = (row) => {
    Modal.confirm({
      title: text('吊销这个 API Token？', 'Revoke this API token?'),
      content: text('吊销后使用该 Token 的客户端将立即收到 401，操作不可撤销。', 'Clients using it will get 401 immediately. This cannot be undone.'),
      okText: text('吊销', 'Revoke'),
      okButtonProps: { danger: true },
      cancelText: text('取消', 'Cancel'),
      onOk: async () => {
        try {
          await apiRequest(`/api/api-tokens/${row.id}`, { method: 'DELETE' });
          await tokens.refresh();
          toast.success(text('已吊销。', 'Revoked.'));
        } catch (error) {
          toast.error(error.message || text('吊销失败。', 'Could not revoke.'));
        }
      },
    });
  };

  const columns = [
    { title: text('名称', 'Name'), dataIndex: 'name', render: (v) => <Text strong>{v}</Text> },
    {
      title: text('能力', 'Capabilities'),
      dataIndex: 'capabilities',
      render: (value) => <Space size={[0, 4]} wrap>{(Array.isArray(value) ? value : []).map((cap) => <Tag key={cap}>{cap}</Tag>)}</Space>,
    },
    { title: text('创建时间', 'Created'), dataIndex: 'created_at', width: 168, render: (v) => <Text type="secondary">{formatTime(v, language)}</Text> },
    {
      title: text('过期时间', 'Expires'),
      dataIndex: 'expires_at',
      width: 168,
      render: (v) => <Text type="secondary">{formatTime(v, language)}</Text>,
    },
    {
      title: text('状态', 'Status'),
      dataIndex: 'revoked',
      width: 96,
      render: (v) => (v ? <Tag color="red">{text('已吊销', 'Revoked')}</Tag> : <Tag color="success">{text('有效', 'Active')}</Tag>),
    },
    {
      title: text('操作', 'Actions'),
      key: 'actions',
      width: 88,
      render: (_, row) => (row.revoked
        ? <Text type="secondary">—</Text>
        : <Button size="small" danger onClick={() => revoke(row)}>{text('吊销', 'Revoke')}</Button>),
    },
  ];

  return (
    <>
      <PageHeader
        title={text('API Token', 'API tokens')}
        description={text('签发只读访问令牌。令牌明文只在创建时显示一次。', 'Issue read-only access tokens. The plaintext is shown once, at creation.')}
        actions={<Button type="primary" onClick={() => setOpen(true)}>{text('签发 Token', 'Issue token')}</Button>}
      />
      {issued?.token && (
        <Alert
          className="snapshot-alert"
          type="warning"
          showIcon
          closable
          onClose={() => setIssued(null)}
          title={text('令牌已签发，请立即复制', 'Token issued — copy it now')}
          description={(
            <Space orientation="vertical" size={4} style={{ width: '100%' }}>
              <Text copyable={{ text: issued.token }} code style={{ wordBreak: 'break-all' }}>{issued.token}</Text>
              <Text type="secondary">{text('关闭后无法再次查看。服务端只保存哈希。', 'It cannot be retrieved again. The server keeps only a hash.')}</Text>
            </Space>
          )}
        />
      )}
      <ContentCard>
        <DataState
          loading={tokens.loading}
          error={tokens.error}
          onRetry={tokens.refresh}
          empty={!rows.length}
          emptyTitle={text('尚未签发任何 Token', 'No tokens issued yet')}
        >
          <Table className="data-table" columns={columns} dataSource={rows.map((r) => ({ ...r, key: r.id }))} rowKey="key" size="middle" pagination={false} />
        </DataState>
      </ContentCard>
      <Modal
        title={text('签发 API Token', 'Issue API token')}
        open={open}
        onCancel={() => setOpen(false)}
        onOk={create}
        okText={text('签发', 'Issue')}
        cancelText={text('取消', 'Cancel')}
        confirmLoading={saving}
        destroyOnHidden
      >
        <Form form={form} layout="vertical" requiredMark={false} initialValues={{ expire_days: 90 }}>
          <Form.Item name="name" label={text('名称', 'Name')} rules={[{ required: true, message: text('请输入名称', 'Enter a name') }, { max: 64, message: text('不超过 64 个字符', 'At most 64 characters') }]}>
            <Input maxLength={64} placeholder={text('例如：grafana-readonly', 'e.g. grafana-readonly')} />
          </Form.Item>
          <Form.Item name="expire_days" label={text('有效天数', 'Valid for (days)')} rules={[{ required: true, message: text('请输入有效天数', 'Enter a validity in days') }]}>
            <InputNumber min={1} max={3650} style={{ width: '100%' }} />
          </Form.Item>
          <Form.Item name="capabilities" label={text('只读能力', 'Read capabilities')} rules={[{ required: true, message: text('至少选择一项只读能力', 'Pick at least one read capability') }]}>
            <Select mode="multiple" options={TOKEN_READ_CAPS.map((cap) => ({ value: cap, label: cap }))} placeholder={text('选择该令牌可访问的只读端点', 'Choose which read endpoints this token may reach')} />
          </Form.Item>
          <Paragraph type="secondary" style={{ marginBottom: 0, fontSize: 12 }}>
            {text('服务端只接受只读能力；写入与管理能力无法通过 Token 授予。', 'The server only accepts read capabilities; write and admin capabilities cannot be granted to a token.')}
          </Paragraph>
        </Form>
      </Modal>
      {toastContext}
    </>
  );
}

export function MfaPage({ identity, onIdentityChanged }) {
  const { text } = useLanguage();
  const [form] = Form.useForm();
  const [busy, setBusy] = useState(false);
  const [pending, setPending] = useState(null);
  const [toast, toastContext] = message.useMessage();
  const enabled = Boolean(identity?.mfa_enabled);

  const run = async (path, body, onDone) => {
    setBusy(true);
    try {
      const response = await apiRequest(path, { method: 'POST', body });
      onDone(unwrap(response));
    } catch (error) {
      toast.error(error.message || text('操作失败。', 'The request failed.'));
    } finally {
      setBusy(false);
    }
  };

  const beginSetup = () => run('/api/auth/mfa/setup', undefined, (result) => setPending(safeObject(result)));

  const confirmSetup = async () => {
    let values;
    try {
      values = await form.validateFields();
    } catch { return; }
    await run('/api/auth/mfa/verify', { code: String(values.code || '').trim() }, () => {
      setPending(null);
      form.resetFields();
      onIdentityChanged(true);
      toast.success(text('双重验证已启用。', 'Two-factor verification is now on.'));
    });
  };

  const disable = () => run('/api/auth/mfa/disable', { code: String(form.getFieldValue('code') || '').trim() }, () => {
    form.resetFields();
    onIdentityChanged(false);
    toast.success(text('双重验证已停用。', 'Two-factor verification is off.'));
  });

  return (
    <>
      <PageHeader
        title={text('双重验证', 'Two-factor verification')}
        description={text('用 TOTP 身份验证器为登录追加一层保护。', 'Add a TOTP authenticator as a second step at sign-in.')}
        actions={<Tag color={enabled ? 'green' : 'default'}>{enabled ? text('已启用', 'Enabled') : text('未启用', 'Not enabled')}</Tag>}
      />
      <ContentCard>
        {pending ? (
          <Space orientation="vertical" size="middle" style={{ width: '100%' }}>
            <Alert
              type="info"
              showIcon
              title={text('第 1 步：用身份验证器扫描', 'Step 1: scan with your authenticator')}
              description={(
                <Space orientation="vertical" size={4} style={{ width: '100%' }}>
                  <Text type="secondary">{text('把下面链接导入 Google Authenticator、1Password 或其他 TOTP 应用：', 'Import the link below into Google Authenticator, 1Password or any TOTP app:')}</Text>
                  <Text copyable={{ text: pending.otpauth_url }} code style={{ wordBreak: 'break-all' }}>{pending.otpauth_url}</Text>
                </Space>
              )}
            />
            <Form form={form} layout="vertical" requiredMark={false} style={{ maxWidth: 320 }}>
              <Form.Item name="code" label={text('第 2 步：输入应用显示的 6 位验证码', 'Step 2: enter the 6-digit code')} rules={[{ required: true, message: text('请输入验证码', 'Enter the code') }, { pattern: /^\d{6}$/, message: text('验证码为 6 位数字', 'Use the 6-digit code') }]}>
                <Input inputMode="numeric" maxLength={6} placeholder="000000" autoComplete="one-time-code" />
              </Form.Item>
            </Form>
            <Space>
              <Button type="primary" loading={busy} onClick={confirmSetup}>{text('验证并启用', 'Verify and enable')}</Button>
              <Button disabled={busy} onClick={() => { setPending(null); form.resetFields(); }}>{text('取消', 'Cancel')}</Button>
            </Space>
            <Alert type="warning" showIcon title={text('未完成验证前不要退出本页', 'Do not leave this page before verifying')} />
          </Space>
        ) : enabled ? (
          <Space orientation="vertical" size="middle" style={{ width: '100%', maxWidth: 420 }}>
            <Alert type="success" showIcon title={text('双重验证正在生效。', 'Two-factor verification is active.')} description={text('每次登录都需要身份验证器上的 6 位验证码。', 'Every sign-in asks for the 6-digit code from your authenticator.')} />
            <Form form={form} layout="vertical" requiredMark={false}>
              <Form.Item name="code" label={text('输入当前验证码以停用', 'Enter a current code to disable')} rules={[{ required: true, message: text('请输入验证码', 'Enter the code') }, { pattern: /^\d{6}$/, message: text('验证码为 6 位数字', 'Use the 6-digit code') }]}>
                <Input inputMode="numeric" maxLength={6} placeholder="000000" autoComplete="one-time-code" />
              </Form.Item>
            </Form>
            <Button danger loading={busy} onClick={disable} style={{ alignSelf: 'flex-start' }}>{text('停用双重验证', 'Disable')}</Button>
          </Space>
        ) : (
          <EmptyState
            title={text('尚未启用双重验证', 'Two-factor verification is off')}
            description={text('启用后，即使密码泄露也无法直接登录。', 'Once enabled, a leaked password alone cannot sign in.')}
            action={<Button type="primary" loading={busy} onClick={beginSetup}>{text('开始启用', 'Set up now')}</Button>}
          />
        )}
      </ContentCard>
      {toastContext}
    </>
  );
}
