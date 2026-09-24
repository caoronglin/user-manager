import React, { useMemo, useState } from 'react';
import {
  Alert, Button, Checkbox, Descriptions, Drawer, Form, Input, Modal, Progress, Select, Space, Statistic, Switch, Tabs, Tag, Typography, message,
} from 'antd';
import { apiRequest, formatBytes, formatTime, getArray, queryString, safeObject, unwrap } from './api.js';
import { useLanguage } from './App.jsx';
import {
  ContentCard, DataState, DataTable, EmptyState, ExportLink, FreshnessAlert, KeyValueGrid, PageHeader, RecordValue, useEndpoint,
} from './ui.jsx';

const { Text } = Typography;

function valueAt(object, path) {
  return path.split('.').reduce((value, key) => value?.[key], object);
}

function list(value, keys = []) {
  if (Array.isArray(value)) return value;
  for (const key of keys) if (Array.isArray(value?.[key])) return value[key];
  return [];
}

function systemFilesystems(data) {
  const ops = safeObject(data?.ops);
  return list(ops.filesystems, ['mounts']).length
    ? list(ops.filesystems, ['mounts'])
    : list(data?.filesystems, ['mounts']);
}

function sampleColumns(rows, limit = 8) {
  const keys = [...new Set(rows.slice(0, 20).flatMap((row) => row && typeof row === 'object' && !Array.isArray(row) ? Object.keys(row) : ['value']))]
    .filter((key) => !/(password|passwd|secret|token|private.?key|credential|webhook)/i.test(key))
    .slice(0, limit);
  return keys.map((key) => ({
    title: key.replaceAll('_', ' '),
    dataIndex: key,
    key,
    render: (value) => value === null || value === undefined || value === '' ? <Text type="secondary">—</Text> : <RecordValue value={value} name={key} />,
  }));
}

function Metric({ title, value, suffix, note }) {
  return <div className="metric-cell"><Statistic title={title} value={value ?? '—'} suffix={suffix} /><div className="metric-note">{note || '\u00a0'}</div></div>;
}

function LoadError({ error, refresh }) {
  return <DataState error={error} onRetry={refresh} />;
}

export function DashboardPage({ capabilities }) {
  const { text, language } = useLanguage();
  const system = useEndpoint('/api/system-summary', capabilities.has('dashboard.read'));
  const users = useEndpoint('/api/users', capabilities.has('users.read'));
  const resources = useEndpoint('/api/resources/summary', capabilities.has('resource.read'));
  const hosts = useEndpoint('/api/hosts', capabilities.has('hosts.read'));
  const audit = useEndpoint('/api/audit?limit=6', capabilities.has('audit.read'));
  const data = system.data;
  const userRows = getArray(users.data, 'users');
  const mounts = systemFilesystems(data);
  const auditRows = getArray(audit.data, 'items');
  const failures = valueAt(data, 'ops.systemd.failed_service_count');
  const reboot = valueAt(data, 'ops.apt.reboot_required');
  const latest = system.freshness || users.freshness || resources.freshness || hosts.freshness || audit.freshness;
  const accessibleResources = [system, users, resources, hosts, audit].filter((item) => item.response || item.error);
  const loading = accessibleResources.some((item) => item.loading);
  const errorCount = accessibleResources.filter((item) => item.error).length;
  return (
    <>
      <PageHeader title={text('系统概览', 'System overview')} description={text('只读快照 · 系统数据与采集状态', 'Read-only snapshots · system data and collection status')} freshness={latest} />
      {accessibleResources.length === 0 && <Alert showIcon type="warning" title={text('当前账号没有概览读取权限', 'Dashboard access is not enabled for this account')} />}
      {errorCount > 0 && <Alert showIcon type="warning" className="dashboard-error-note" title={text(`${errorCount} 个数据源暂不可用`, `${errorCount} data source(s) unavailable`)} description={text('其他已读取数据仍可查看；请在对应页面重试。', 'Other available data remains visible. Retry from its page.')} />}
      {accessibleResources.some((item) => item.loading) && <div className="dashboard-loading"><div /><div /><div /></div>}
      <div className="dashboard-metrics">
        {capabilities.has('users.read') && !users.loading && !users.error && <Metric title={text('受管用户', 'Managed users')} value={users.data?.count ?? userRows.length} note={users.freshness ? formatTime(users.freshness.generated_at, language) : ''} />}
        {capabilities.has('resource.read') && !resources.loading && !resources.error && <Metric title={text('资源记录', 'Resource records')} value={resources.data?.count ?? getArray(resources.data, 'users').length} note={text('来自资源快照', 'From resource snapshot')} />}
        {capabilities.has('hosts.read') && !hosts.loading && !hosts.error && <Metric title={text('主机探测', 'Host probe')} value={hosts.data?.status || hosts.data?.source || '—'} note={text('只读能力检查', 'Read-only capability probe')} />}
        {data && <Metric title={text('失败服务', 'Failed services')} value={failures ?? '—'} note={reboot === true ? text('系统标记需要重启', 'Reboot is required') : text('系统状态快照', 'System status snapshot')} />}
      </div>

      <section className="dashboard-grid">
        <ContentCard title={text('文件系统用量', 'Filesystem usage')} className="dashboard-filesystems">
          {!system.loading && !system.error && mounts.length === 0 ? <EmptyState title={text('尚无文件系统数据', 'No filesystem data')} description={text('此快照未包含文件系统采集结果。', 'The snapshot does not include filesystem measurements.')} /> : null}
          {mounts.length > 0 && <DataTable
            dataSource={mounts.map((item, index) => ({ ...item, key: item.mountpoint || index }))}
            columns={[
              { title: text('挂载点', 'Mount point'), dataIndex: 'mountpoint', key: 'mountpoint', render: (value) => <Text strong>{value || '—'}</Text> },
              { title: text('总量', 'Total'), dataIndex: 'size_bytes', key: 'size_bytes', render: (value) => formatBytes(value, language) },
              { title: text('已用', 'Used'), dataIndex: 'used_bytes', key: 'used_bytes', render: (value) => formatBytes(value, language) },
              { title: text('可用', 'Available'), dataIndex: 'available_bytes', key: 'available_bytes', render: (value) => formatBytes(value, language) },
              { title: text('使用率', 'Usage'), dataIndex: 'used_percent', key: 'used_percent', render: (value) => value == null ? '—' : <div className="usage-progress"><Progress percent={Number(value)} size="small" showInfo={false} /><span>{value}%</span></div> },
            ]}
          />}
          {system.error && <LoadError error={system.error} refresh={system.refresh} />}
          <div className="card-footnote">{system.freshness ? text(`系统快照 · ${formatTime(system.freshness.generated_at, language)}`, `System snapshot · ${formatTime(system.freshness.generated_at, language)}`) : text('文件系统数据来自只读系统快照', 'Filesystem data comes from read-only system snapshots')}</div>
        </ContentCard>

        <ContentCard title={text('系统状态', 'System health')} className="dashboard-health">
          {system.loading && <div className="panel-skeleton"><span /><span /><span /></div>}
          {system.error && <LoadError error={system.error} refresh={system.refresh} />}
          {data && <div className="health-list">
            <div><span>{text('主机名', 'Hostname')}</span><strong>{data.hostname || '—'}</strong></div>
            <div><span>{text('内核', 'Kernel')}</span><strong>{data.kernel_release || '—'}</strong></div>
            <div><span>{text('系统启动状态', 'Boot state')}</span><Tag color={valueAt(data, 'ops.systemd.boot_state') === 'running' ? 'success' : 'default'}>{valueAt(data, 'ops.systemd.boot_state') || '—'}</Tag></div>
            <div><span>{text('待重启', 'Reboot required')}</span><Tag color={reboot ? 'warning' : 'default'}>{reboot === true ? text('需要', 'Required') : reboot === false ? text('否', 'No') : '—'}</Tag></div>
            <div><span>{text('快照状态', 'Snapshot state')}</span><Tag color={latest?.stale ? 'warning' : latest?.present ? 'success' : 'default'}>{latest?.present ? (latest.stale ? text('已过期', 'Stale') : text('可用', 'Available')) : text('缺失', 'Missing')}</Tag></div>
          </div>}
          <Button type="link" className="card-link" onClick={() => { window.location.hash = '/system'; }}>{text('查看系统详情', 'View system details')} <span aria-hidden="true">→</span></Button>
        </ContentCard>
      </section>

      {capabilities.has('audit.read') && <ContentCard title={text('最近审计记录', 'Recent audit activity')} extra={<Button type="link" onClick={() => { window.location.hash = '/audit'; }}>{text('查看全部', 'View all')} →</Button>}>
        <DataState loading={audit.loading} error={audit.error} onRetry={audit.refresh} empty={!audit.loading && !audit.error && auditRows.length === 0} emptyTitle={text('暂无审计记录', 'No audit records')}>
          <DataTable dataSource={auditRows.map((row, index) => ({ ...row, key: row.id || `${row.timestamp}-${index}` }))} columns={[
            { title: text('时间', 'Time'), dataIndex: 'timestamp', key: 'timestamp', render: (value) => formatTime(value, language) },
            { title: text('用户', 'User'), dataIndex: 'user', key: 'user' },
            { title: text('操作', 'Action'), dataIndex: 'action', key: 'action' },
            { title: text('对象', 'Target'), dataIndex: 'target', key: 'target' },
            { title: text('结果', 'Result'), dataIndex: 'result', key: 'result', render: (value) => <Tag color={value === 'success' ? 'success' : value === 'failure' ? 'error' : 'default'}>{value || '—'}</Tag> },
          ]} size="small" />
        </DataState>
      </ContentCard>}
    </>
  );
}

export function UsersPage({ capabilities }) {
  const { text, language } = useLanguage();
  const users = useEndpoint('/api/users', capabilities.has('users.read'));
  const rows = getArray(users.data, 'users');
  const [selected, setSelected] = useState(null);
  const columns = [
    { title: text('用户名', 'Username'), dataIndex: 'username', key: 'username', render: (value) => <Text strong>{value || '—'}</Text> },
    { title: text('主目录', 'Home directory'), dataIndex: 'home', key: 'home', render: (value) => value || '—' },
    { title: text('挂载点', 'Mount point'), dataIndex: 'mountpoint', key: 'mountpoint', render: (value) => value || '—' },
    { title: text('配额详情', 'Quota details'), key: 'detail', render: (_, record) => capabilities.has('quota.read') ? <Button type="link" onClick={() => setSelected(record)}>{text('查看', 'View')}</Button> : <Text type="secondary">—</Text> },
  ];
  return <>
    <PageHeader title={text('用户与配额', 'Users & quota')} description={text('查看受管 Linux 用户及其存储配额。', 'View managed Linux users and their storage quotas.')} freshness={users.freshness} />
    <FreshnessAlert freshness={users.freshness} />
    <DataState loading={users.loading} error={users.error} onRetry={users.refresh} empty={!users.loading && !users.error && rows.length === 0} emptyTitle={text('没有受管用户', 'No managed users found')}>
      <ContentCard title={text('用户列表', 'Users')} extra={<Text type="secondary">{users.data?.count ?? rows.length} {text('个用户', 'users')}</Text>}>
        <DataTable dataSource={rows.map((row, index) => ({ ...row, key: row.username || index }))} columns={columns} onRow={(record) => ({ onDoubleClick: () => capabilities.has('quota.read') && setSelected(record) })} />
      </ContentCard>
    </DataState>
    <Drawer
      title={selected?.username || text('配额详情', 'Quota details')}
      open={Boolean(selected)}
      onClose={() => setSelected(null)}
      size={560}
      destroyOnHidden
    >
      {selected && <QuotaDetail username={selected.username} allowed={capabilities.has('quota.read')} />}
    </Drawer>
  </>;
}

function QuotaDetail({ username, allowed }) {
  const { text, language } = useLanguage();
  const quota = useEndpoint(`/api/users/${encodeURIComponent(username)}/quota`, allowed);
  const row = getArray(quota.data, 'users')[0];
  return <DataState loading={quota.loading} error={quota.error} onRetry={quota.refresh} empty={!quota.loading && !quota.error && !row} emptyTitle={text('没有配额信息', 'No quota details')}>
    {row && <>
      <FreshnessAlert freshness={quota.freshness} />
      <Descriptions bordered column={1} size="small" items={[
        { key: 'user', label: text('用户', 'User'), children: username },
        { key: 'mountpoint', label: text('挂载点', 'Mount point'), children: row.mountpoint || '—' },
        { key: 'used', label: text('已用', 'Used'), children: formatBytes(row.used_bytes, language) },
        { key: 'limit', label: text('配额上限', 'Quota limit'), children: row.has_quota ? formatBytes(row.limit_bytes, language) : text('未设置', 'Not set') },
        { key: 'percent', label: text('使用率', 'Usage'), children: row.has_quota && Number(row.limit_bytes) > 0 ? <Progress percent={Math.min(100, Math.round(Number(row.used_bytes) * 100 / Number(row.limit_bytes)))} /> : '—' },
      ]} />
    </>}
  </DataState>;
}

export function ResourcesPage() {
  const { text } = useLanguage();
  const resource = useEndpoint('/api/resources/summary');
  const rows = getArray(resource.data, 'users');
  const columns = [
    { title: text('用户名', 'Username'), dataIndex: 'username', key: 'username', render: (value) => <Text strong>{value || '—'}</Text> },
    { title: 'UID', dataIndex: 'uid', key: 'uid' },
    { title: text('CPU 配额', 'CPU quota'), dataIndex: 'cpu_quota', key: 'cpu_quota', render: (value) => value || '—' },
    { title: text('内存限制', 'Memory limit'), dataIndex: 'memory_limit', key: 'memory_limit', render: (value) => value || '—' },
    { title: text('限制状态', 'Limits'), dataIndex: 'has_limits', key: 'has_limits', render: (value) => <Tag color={value ? 'processing' : 'default'}>{value ? text('已配置', 'Configured') : text('未配置', 'Not configured')}</Tag> },
  ];
  return <>
    <PageHeader title={text('资源用量', 'Resource usage')} description={text('用户级 CPU 与内存限制概览。', 'Overview of per-user CPU and memory limits.')} freshness={resource.freshness} />
    <FreshnessAlert freshness={resource.freshness} />
    <DataState loading={resource.loading} error={resource.error} onRetry={resource.refresh} empty={!resource.loading && !resource.error && rows.length === 0} emptyTitle={text('资源快照中没有用户记录', 'No user records in the resource snapshot')}>
      <ContentCard title={text('用户资源限制', 'User resource limits')} extra={<Text type="secondary">{resource.data?.count ?? rows.length} {text('条记录', 'records')}</Text>}>
        <DataTable dataSource={rows.map((row, index) => ({ ...row, key: row.username || index }))} columns={columns} />
      </ContentCard>
    </DataState>
  </>;
}

export function SmbPage() {
  const { text } = useLanguage();
  const smb = useEndpoint('/api/smb/status');
  const data = smb.data;
  const users = getArray(data, 'users');
  const shares = getArray(data, 'shares');
  return <>
    <PageHeader title="SMB" description={text('查看 Samba 服务、账号索引与共享目录快照。', 'View the Samba service, account index and share snapshot.')} freshness={smb.freshness} />
    <FreshnessAlert freshness={smb.freshness} />
    <DataState loading={smb.loading} error={smb.error} onRetry={smb.refresh}>
      {data && <>
        <div className="status-strip">
          <div className="status-item"><span>{text('服务状态', 'Service')}</span><strong><Tag color={data.service_active === 'active' ? 'success' : 'default'}>{data.service_active || '—'}</Tag></strong></div>
          <div className="status-item"><span>{text('Samba 可用', 'Samba available')}</span><strong><Tag color={data.available ? 'success' : 'default'}>{data.available ? text('是', 'Yes') : text('否', 'No')}</Tag></strong></div>
          <div className="status-item"><span>{text('已配置共享', 'Share config')}</span><strong><Tag color={data.include_configured ? 'success' : 'default'}>{data.include_configured ? text('已包含', 'Included') : text('未包含', 'Not included')}</Tag></strong></div>
        </div>
        <div className="dashboard-grid">
          <ContentCard title={text('共享目录', 'Shares')} extra={<Text type="secondary">{shares.length}</Text>}>
            {shares.length ? <DataTable dataSource={shares.map((row, index) => ({ ...row, key: row.name || index }))} columns={[
              { title: text('共享名', 'Name'), dataIndex: 'name', key: 'name', render: (value) => <Text strong>{value || '—'}</Text> },
              { title: text('路径', 'Path'), dataIndex: 'path', key: 'path', render: (value) => value || '—' },
            ]} /> : <EmptyState title={text('没有共享目录记录', 'No share records')} />}
          </ContentCard>
          <ContentCard title={text('SMB 用户', 'SMB users')} extra={<Text type="secondary">{users.length}</Text>}>
            {users.length ? <DataTable dataSource={users.map((user, index) => ({ name: String(user), key: `${user}-${index}` }))} columns={[{ title: text('用户名', 'Username'), dataIndex: 'name', key: 'name' }]} /> : <EmptyState title={text('没有 SMB 用户记录', 'No SMB user records')} />}
          </ContentCard>
        </div>
      </>}
    </DataState>
  </>;
}

export function HostsPage({ capabilities }) {
  const { text } = useLanguage();
  const hosts = useEndpoint('/api/hosts', capabilities.has('hosts.read'));
  const gpu = useEndpoint('/api/hosts/local/gpu', capabilities.has('gpu.read'));
  const data = safeObject(hosts.data);
  const hostEntries = Object.entries(data).filter(([key]) => !['protocol', 'action', 'end'].includes(key));
  const gpuEntries = Object.entries(safeObject(gpu.data)).filter(([key]) => !['protocol', 'action', 'end'].includes(key));
  const hostRows = hostEntries.map(([name, value]) => ({ key: name, name, value }));
  const gpuRows = gpuEntries.map(([name, value]) => ({ key: name, name, value }));
  const columns = [
    { title: text('字段', 'Field'), dataIndex: 'name', key: 'name', render: (value) => <Text strong>{value.replaceAll('_', ' ')}</Text> },
    { title: text('观测结果', 'Observed value'), dataIndex: 'value', key: 'value', render: (value, row) => <RecordValue name={row.name} value={value} /> },
  ];
  return <>
    <PageHeader title={text('主机与 GPU', 'Hosts & GPU')} description={text('本机能力探测与 GPU 状态。', 'Local host capability probe and GPU status.')} freshness={hosts.freshness || gpu.freshness} />
    <FreshnessAlert freshness={hosts.freshness || gpu.freshness} />
    <Tabs items={[
      { key: 'host', label: text('主机探测', 'Host probe'), children: <DataState loading={hosts.loading} error={hosts.error} onRetry={hosts.refresh} empty={!hosts.loading && !hosts.error && hostRows.length === 0} emptyTitle={text('主机快照为空', 'Host snapshot is empty')}><ContentCard title={text('本机主机信息', 'Local host information')}><DataTable dataSource={hostRows} columns={columns} /></ContentCard></DataState> },
      ...(capabilities.has('gpu.read') ? [{ key: 'gpu', label: 'GPU', children: <DataState loading={gpu.loading} error={gpu.error} onRetry={gpu.refresh} empty={!gpu.loading && !gpu.error && gpuRows.length === 0} emptyTitle={text('GPU 快照为空', 'GPU snapshot is empty')} emptyDescription={text('没有可用设备信息，或当前系统未提供 GPU 探测工具。', 'No device details were collected, or GPU probe tools are unavailable.')}><ContentCard title={text('GPU 探测结果', 'GPU probe results')}><DataTable dataSource={gpuRows} columns={columns} /></ContentCard></DataState> }] : []),
    ]} />
  </>;
}

export function SystemPage() {
  const { text, language } = useLanguage();
  const system = useEndpoint('/api/system-summary');
  const data = safeObject(system.data);
  const ops = safeObject(data.ops);
  const opsSections = [
    ['filesystems', text('文件系统与 inode', 'Filesystems & inodes')],
    ['systemd', text('systemd 服务', 'systemd services')],
    ['apt', text('软件包与重启状态', 'Packages & reboot status')],
    ['apparmor', 'AppArmor'],
  ];
  const uptime = Number(data.uptime_seconds);
  const uptimeLabel = Number.isFinite(uptime) ? `${Math.floor(uptime / 86400)}d ${Math.floor((uptime % 86400) / 3600)}h ${Math.floor((uptime % 3600) / 60)}m` : '—';
  return <>
    <PageHeader title={text('系统状态', 'System status')} description={text('只读主机指标、文件系统与运维状态。', 'Read-only host metrics, filesystems and operations status.')} freshness={system.freshness} />
    <FreshnessAlert freshness={system.freshness} />
    <DataState loading={system.loading} error={system.error} onRetry={system.refresh} empty={!system.loading && !system.error && Object.keys(data).length === 0} emptyTitle={text('系统快照中没有数据', 'The system snapshot is empty')}>
      {Object.keys(data).length > 0 && <>
        <div className="system-metric-grid">
          <Metric title={text('主机名', 'Hostname')} value={data.hostname || '—'} note={`${data.arch || '—'} · ${data.kernel_release || '—'}`} />
          <Metric title={text('CPU 核心', 'CPU cores')} value={data.cpu_count ?? '—'} note={text('系统识别的逻辑 CPU', 'Logical CPUs reported by the system')} />
          <Metric title={text('运行时间', 'Uptime')} value={uptimeLabel} note={data.project_version ? `User Manager ${data.project_version}` : ''} />
          <Metric title={text('可用内存', 'Available memory')} value={formatBytes(data.mem_available_bytes, language)} note={data.mem_total_bytes ? text(`共 ${formatBytes(data.mem_total_bytes, language)}`, `${formatBytes(data.mem_total_bytes, language)} total`) : ''} />
        </div>
        <div className="dashboard-grid">
          <ContentCard title={text('系统负载', 'System load')}>
            <div className="loadavg-row">{[['1 min', 'load1'], ['5 min', 'load5'], ['15 min', 'load15']].map(([label, key]) => <div key={key}><span>{label}</span><strong>{data.loadavg?.[key] ?? '—'}</strong></div>)}</div>
          </ContentCard>
          <ContentCard title={text('系统信息', 'System details')}>
            <Descriptions size="small" column={1} items={[
              { key: 'host', label: text('主机名', 'Hostname'), children: data.hostname || '—' },
              { key: 'kernel', label: text('内核版本', 'Kernel'), children: data.kernel_release || '—' },
              { key: 'arch', label: text('架构', 'Architecture'), children: data.arch || '—' },
              { key: 'version', label: text('采集器版本', 'Collector version'), children: data.project_version || '—' },
            ]} />
          </ContentCard>
        </div>
        {opsSections.map(([key, title]) => {
          const section = safeObject(ops[key]);
          const arrays = Object.entries(section).filter(([, value]) => Array.isArray(value));
          const scalars = Object.fromEntries(Object.entries(section).filter(([, value]) => !Array.isArray(value)));
          return <ContentCard key={key} title={title} extra={section.status && <Tag color={section.status === 'ok' ? 'success' : section.status === 'degraded' ? 'warning' : 'default'}>{section.status}</Tag>} className="system-section">
            <KeyValueGrid value={scalars} />
            {arrays.map(([arrayName, rows]) => <div className="system-subtable" key={arrayName}><div className="subtable-title">{arrayName.replaceAll('_', ' ')}</div>{rows.length && typeof rows[0] === 'object' ? <DataTable dataSource={rows.map((row, index) => ({ ...row, key: row.name || row.mountpoint || index }))} columns={sampleColumns(rows)} size="small" /> : <Text type="secondary">{rows.length ? rows.join(', ') : text('暂无记录', 'No records')}</Text>}</div>)}
          </ContentCard>;
        })}
      </>}
    </DataState>
  </>;
}

export function LogsPage() {
  const { text, language } = useLanguage();
  const [source, setSource] = useState('boot');
  const [input, setInput] = useState('');
  const [search, setSearch] = useState('');
  const query = queryString({ source, q: search });
  const logs = useEndpoint(`/api/logs?${query}`);
  const lines = getArray(logs.data, 'lines');
  const exportQuery = queryString({ source, q: search });
  return <>
    <PageHeader title={text('运行日志', 'Runtime logs')} description={text('仅显示采集器允许的日志源；内容来自日志快照。', 'Only allowlisted log sources are shown. Content comes from snapshots.')} freshness={logs.freshness} actions={<ExportLink endpoint={`/api/logs/download?${exportQuery}`} filename={`${source}.log`} label={text('下载日志', 'Download log')} />} />
    <FreshnessAlert freshness={logs.freshness} />
    <ContentCard title={text('日志查询', 'Log query')} className="log-card">
      <div className="filter-row log-filters">
        <Select
          value={source}
          onChange={setSource}
          options={[
            { value: 'boot', label: text('系统启动', 'Boot') },
            { value: 'failed-services', label: text('失败服务', 'Failed services') },
            { value: 'auth-failures', label: text('认证失败', 'Authentication failures') },
          ]}
          aria-label={text('日志来源', 'Log source')}
        />
        <Input.Search value={input} onChange={(event) => setInput(event.target.value)} onSearch={setSearch} allowClear placeholder={text('按关键词过滤', 'Filter by keyword')} enterButton={text('搜索', 'Search')} />
      </div>
      <DataState loading={logs.loading} error={logs.error} onRetry={logs.refresh} empty={!logs.loading && !logs.error && lines.length === 0} emptyTitle={text('此来源暂无日志', 'No log lines for this source')}>
        {logs.data?.truncated && <Alert showIcon type="info" title={text('显示最近的 500 行。', 'Showing the most recent 500 lines.')} className="log-truncated" />}
        <pre className="log-output">{lines.map((line, index) => <span className="log-line" key={`${index}-${line}`}><span className="log-index">{String(index + 1).padStart(3, '0')}</span>{line}</span>)}</pre>
      </DataState>
    </ContentCard>
  </>;
}

export function ReportsPage() {
  const { text, language } = useLanguage();
  const reports = useEndpoint('/api/reports');
  const rows = getArray(reports.data, 'reports');
  return <>
    <PageHeader title={text('报告', 'Reports')} description={text('报告文件索引仅包含元数据，不提供文件内容读取。', 'The report index contains metadata only; report contents are not exposed.')} freshness={reports.freshness} actions={<ExportLink endpoint="/api/reports/export?format=csv" filename="reports.csv" />} />
    <FreshnessAlert freshness={reports.freshness} />
    <DataState loading={reports.loading} error={reports.error} onRetry={reports.refresh} empty={!reports.loading && !reports.error && rows.length === 0} emptyTitle={text('没有报告索引', 'No reports in the index')}>
      <ContentCard title={text('报告索引', 'Report index')} extra={<Text type="secondary">{reports.data?.count ?? rows.length} {text('份报告', 'reports')}</Text>}>
        <DataTable dataSource={rows.map((row, index) => ({ ...row, key: `${row.name || 'report'}-${index}` }))} columns={[
          { title: text('文件名', 'Name'), dataIndex: 'name', key: 'name', render: (value) => <Text strong>{value || '—'}</Text> },
          { title: text('大小', 'Size'), dataIndex: 'size_bytes', key: 'size_bytes', render: (value) => formatBytes(value, language) },
          { title: text('修改时间', 'Modified'), dataIndex: 'modified_at', key: 'modified_at', render: (value) => formatTime(value, language) },
        ]} />
      </ContentCard>
    </DataState>
  </>;
}

export function AuditPage() {
  const { text, language } = useLanguage();
  const [formValues, setFormValues] = useState({ user: '', action: '', result: '' });
  const [applied, setApplied] = useState({ user: '', action: '', result: '' });
  const [cursor, setCursor] = useState(0);
  const query = queryString({ ...applied, limit: 50, cursor });
  const audit = useEndpoint(`/api/audit?${query}`);
  const rows = getArray(audit.data, 'items');
  const total = audit.data?.total_matched || 0;
  const nextCursor = audit.data?.next_cursor;
  const exportQuery = queryString({ ...applied, format: 'csv' });
  const applyFilters = () => { setApplied(formValues); setCursor(0); };
  return <>
    <PageHeader title={text('审计记录', 'Audit')} description={text('查询只读审计摘要；详情文本不会在此展示。', 'Search the read-only audit summary. Detail text is not exposed here.')} freshness={audit.freshness} actions={<ExportLink endpoint={`/api/audit/export?${exportQuery}`} filename="audit.csv" />} />
    <FreshnessAlert freshness={audit.freshness} />
    <ContentCard title={text('筛选条件', 'Filters')} className="audit-filters-card">
      <div className="filter-row">
        <Input value={formValues.user} onChange={(event) => setFormValues((current) => ({ ...current, user: event.target.value }))} placeholder={text('用户', 'User')} aria-label={text('按用户筛选', 'Filter by user')} />
        <Input value={formValues.action} onChange={(event) => setFormValues((current) => ({ ...current, action: event.target.value }))} placeholder={text('操作', 'Action')} aria-label={text('按操作筛选', 'Filter by action')} />
        <Select value={formValues.result || undefined} onChange={(value) => setFormValues((current) => ({ ...current, result: value || '' }))} allowClear placeholder={text('全部结果', 'Any result')} options={[{ value: 'success', label: text('成功', 'Success') }, { value: 'failure', label: text('失败', 'Failure') }]} />
        <Button type="primary" onClick={applyFilters}>{text('应用筛选', 'Apply filters')}</Button>
      </div>
    </ContentCard>
    <ContentCard title={text('审计事件', 'Audit events')} extra={<Text type="secondary">{text(`匹配 ${total} 条`, `${total} matched`)}</Text>}>
      <DataState loading={audit.loading} error={audit.error} onRetry={audit.refresh} empty={!audit.loading && !audit.error && rows.length === 0} emptyTitle={text('没有匹配的审计事件', 'No matching audit events')}>
        <DataTable dataSource={rows.map((row, index) => ({ ...row, key: row.id || `${row.timestamp}-${index}` }))} columns={[
          { title: text('时间', 'Time'), dataIndex: 'timestamp', key: 'timestamp', render: (value) => formatTime(value, language) },
          { title: text('用户', 'User'), dataIndex: 'user', key: 'user' },
          { title: text('操作', 'Action'), dataIndex: 'action', key: 'action' },
          { title: text('对象', 'Target'), dataIndex: 'target', key: 'target' },
          { title: text('结果', 'Result'), dataIndex: 'result', key: 'result', render: (value) => <Tag color={value === 'success' ? 'success' : value === 'failure' ? 'error' : 'default'}>{value || '—'}</Tag> },
        ]} />
      </DataState>
      <div className="table-pager"><Button disabled={cursor <= 0 || audit.loading} onClick={() => setCursor(Math.max(0, cursor - 50))}>{text('上一页', 'Previous')}</Button><Text type="secondary">{total ? `${cursor + 1}–${Math.min(cursor + rows.length, total)} / ${total}` : '0'}</Text><Button disabled={nextCursor == null || audit.loading} onClick={() => setCursor(nextCursor || 0)}>{text('下一页', 'Next')}</Button></div>
    </ContentCard>
  </>;
}

const EVENT_LABELS = {
  'security.login_failed': ['登录失败', 'Login failed'],
  'security.account_locked': ['账户锁定', 'Account locked'],
  'security.token_revoked': ['Token 撤销', 'Token revoked'],
  'snapshot.stale': ['快照过期', 'Snapshot stale'],
  'snapshot.recovered': ['快照恢复', 'Snapshot recovered'],
  'host.offline': ['主机离线', 'Host offline'],
  'host.recovered': ['主机恢复', 'Host recovered'],
  'gpu.unavailable': ['GPU 不可用', 'GPU unavailable'],
  'quota.warning': ['Quota 告警', 'Quota warning'],
  'notification.test': ['固定模板测试', 'Fixed-template test'],
};

function eventGroup(event) {
  const prefix = event.split('.')[0];
  if (prefix === 'security') return 'security';
  if (prefix === 'snapshot' || prefix === 'host' || prefix === 'gpu' || prefix === 'quota') return 'system';
  return 'other';
}

export function WeComSettingsPage() {
  const { text, language } = useLanguage();
  const [form] = Form.useForm();
  const settings = useEndpoint('/api/settings/wecom');
  const deliveries = useEndpoint('/api/settings/wecom/deliveries?limit=50');
  const [replaceWebhook, setReplaceWebhook] = useState(false);
  const [saving, setSaving] = useState(false);
  const [testing, setTesting] = useState(false);
  const [conflict, setConflict] = useState(false);
  const [notice, setNotice] = useState(null);
  const [toast, toastContext] = message.useMessage();
  const data = safeObject(settings.data);
  const deliveryRows = getArray(deliveries.data, 'deliveries');
  const eventCatalog = getArray(data, 'event_catalog');
  const configured = Boolean(data.webhook_configured);

  React.useEffect(() => {
    if (!settings.data) return;
    form.setFieldsValue({
      enabled: Boolean(data.enabled),
      dry_run: Boolean(data.dry_run),
      events: getArray(data, 'events'),
      webhook: '',
    });
    setReplaceWebhook(false);
    setConflict(false);
  }, [settings.data, form]);

  const reloadAll = () => {
    settings.refresh();
    deliveries.refresh();
    setConflict(false);
    setNotice(null);
  };

  const save = async () => {
    setSaving(true);
    setConflict(false);
    setNotice(null);
    try {
      const values = await form.validateFields();
      const replacement = String(values.webhook || '').trim();
      if (values.enabled && !values.dry_run && !configured && !replacement) {
        setNotice({ type: 'error', text: text('启用实时投递前，请先填写 Webhook。', 'A webhook is required for live delivery.') });
        return;
      }
      const body = {
        enabled: Boolean(values.enabled),
        dry_run: Boolean(values.dry_run),
        events: Array.isArray(values.events) ? values.events : [],
        version: Number(data.version || 0),
        webhook: replacement || null,
      };
      await apiRequest('/api/settings/wecom', { method: 'PUT', body });
      setReplaceWebhook(false);
      form.setFieldValue('webhook', '');
      await settings.refresh();
      setNotice({ type: 'success', text: text('设置已保存。不会自动发送测试消息。', 'Settings saved. No test message was sent.') });
      toast.success(text('WeCom 设置已保存', 'WeCom settings saved'));
    } catch (error) {
      if (error?.errorFields) return;
      if (error.status === 409) {
        setConflict(true);
        setNotice({ type: 'warning', text: text('配置已在其他位置更新。请重新载入后再保存。', 'Settings changed elsewhere. Reload before saving again.') });
      } else {
        setNotice({ type: 'error', text: error.message || text('保存失败。', 'Save failed.') });
      }
    } finally {
      setSaving(false);
    }
  };

  const sendTest = async () => {
    setTesting(true);
    setNotice(null);
    try {
      const result = unwrap(await apiRequest('/api/settings/wecom/test', { method: 'POST', body: {} }));
      setNotice({
        type: result?.status === 'SUCCESS' ? 'success' : result?.status === 'DRY_RUN' ? 'info' : 'warning',
        text: result?.status === 'SUCCESS'
          ? text('固定测试消息已发送。', 'Fixed test message sent.')
          : result?.status === 'DRY_RUN'
            ? text('Dry Run 已记录；没有发出外部请求。', 'Dry Run recorded; no external request was sent.')
            : text('测试发送未成功，可在投递历史查看结果。', 'The test did not succeed. See delivery history for details.'),
      });
      toast[result?.status === 'SUCCESS' ? 'success' : 'info'](result?.status || text('测试已记录', 'Test recorded'));
      deliveries.refresh();
    } catch (error) {
      setNotice({ type: error.status === 400 ? 'warning' : 'error', text: error.message || text('发送测试失败。', 'Test send failed.') });
      deliveries.refresh();
    } finally {
      setTesting(false);
    }
  };

  const confirmTest = () => {
    Modal.confirm({
      title: text('发送固定模板测试消息？', 'Send a fixed-template test message?'),
      content: data.dry_run
        ? text('当前为 Dry Run，只会记录测试结果，不会发送外部请求。', 'Dry Run is enabled. The result will be recorded without an external request.')
        : text('这会向已配置的企业微信机器人发送固定测试模板。', 'This sends the fixed test template to the configured WeCom bot.'),
      okText: text('确认测试', 'Send test'),
      cancelText: text('取消', 'Cancel'),
      onOk: sendTest,
    });
  };

  const lastDelivery = deliveryRows[0];
  const groups = [
    ['security', text('安全事件', 'Security')],
    ['system', text('系统观测', 'System observation')],
    ['other', text('其他', 'Other')],
  ].map(([key, title]) => ({ key, title, events: eventCatalog.filter((event) => eventGroup(String(event)) === key) })).filter((group) => group.events.length);

  return <>
    {toastContext}
    <PageHeader title={text('企业微信设置', 'WeCom settings')} description={text('配置告警投递与事件订阅。Webhook 仅写入密文，读取时只返回脱敏状态。', 'Configure alert delivery and event subscriptions. The webhook is encrypted at rest and masked on read.')} />
    <DataState loading={settings.loading} error={settings.error} onRetry={reloadAll} empty={!settings.loading && !settings.error && !settings.data} emptyTitle={text('无法读取 WeCom 设置', 'WeCom settings unavailable')}>
      {settings.data && <>
        {notice && <Alert showIcon className="settings-notice" type={notice.type} title={notice.text} action={conflict ? <Button size="small" onClick={reloadAll}>{text('重新载入', 'Reload')}</Button> : undefined} />}
        <div className="dashboard-grid settings-grid">
          <ContentCard title={text('投递配置', 'Delivery configuration')} className="settings-main-card">
            <Form form={form} layout="vertical" initialValues={{ enabled: Boolean(data.enabled), dry_run: Boolean(data.dry_run), events: getArray(data, 'events'), webhook: '' }}>
              <div className="wecom-status-row">
                <div><span className="wecom-status-label">{text('企业微信机器人', 'WeCom bot')}</span><strong>{configured ? <Tag color="success">{text('已配置', 'Configured')}</Tag> : <Tag>{text('未配置', 'Not configured')}</Tag>}</strong></div>
                <div><span className="wecom-status-label">{text('最后测试', 'Last test')}</span><strong>{lastDelivery ? <span>{lastDelivery.success ? text('成功', 'Success') : lastDelivery.error_class === 'dry_run' ? 'Dry Run' : text('失败', 'Failed')} · {formatTime(lastDelivery.finished_at || lastDelivery.started_at, language)}</span> : text('尚未测试', 'Not tested')}</strong></div>
              </div>

              <Form.Item name="enabled" label={text('启用通知投递', 'Enable notifications')} valuePropName="checked" extra={text('关闭后不会发出通知。', 'When disabled, notifications are not delivered.')}>
                <Switch checkedChildren={text('已启用', 'On')} unCheckedChildren={text('已停用', 'Off')} />
              </Form.Item>
              <Form.Item name="dry_run" label="Dry Run" valuePropName="checked" extra={text('开启时只记录固定测试结果，不向外部发送请求。', 'When enabled, the fixed test is recorded without an external request.')}>
                <Switch checkedChildren="Dry Run" unCheckedChildren={text('实时投递', 'Live')} />
              </Form.Item>

              <Form.Item label={text('Webhook', 'Webhook')}>
                {configured && !replaceWebhook ? <div className="webhook-masked">
                  <div><Tag color="success">{text('已配置', 'Configured')}</Tag><span className="masked-value">{data.webhook_masked || '••••••••••••'}</span></div>
                  <Button onClick={() => setReplaceWebhook(true)}>{text('替换', 'Replace')}</Button>
                </div> : <>
                  <Form.Item name="webhook" noStyle>
                    <Input.Password autoComplete="new-password" placeholder={text('粘贴新的机器人 Webhook', 'Paste a new bot webhook')} visibilityToggle={false} />
                  </Form.Item>
                  <div className="field-extra">{configured ? text('留空会保留现有密钥；提交非空值才会替换。', 'Leave blank to keep the current secret; a non-empty value replaces it.') : text('Webhook 不会被回显；仅提交非空值后才保存。', 'The webhook is never returned. It is saved only when a non-empty value is submitted.')}</div>
                  {configured && <Button type="link" className="cancel-replace" onClick={() => { setReplaceWebhook(false); form.setFieldValue('webhook', ''); }}>{text('取消替换', 'Cancel replacement')}</Button>}
                </>}
              </Form.Item>

              <Form.Item name="events" label={text('事件订阅', 'Event subscriptions')}>
                <Checkbox.Group className="event-groups">
                  {groups.map((group) => <section className="event-group" key={group.key}>
                    <div className="event-group-title">{group.title}</div>
                    <div className="event-options">{group.events.map((event) => <Checkbox value={event} key={event}>{EVENT_LABELS[event]?.[language === 'zh' ? 0 : 1] || event}<small className="event-code">{event}</small></Checkbox>)}</div>
                  </section>)}
                </Checkbox.Group>
              </Form.Item>

              <div className="save-row">
                <div className="updated-meta">{data.updated_at ? text(`更新于 ${formatTime(data.updated_at, language)}${data.updated_by ? ` · ${data.updated_by}` : ''}`, `Updated ${formatTime(data.updated_at, language)}${data.updated_by ? ` · ${data.updated_by}` : ''}`) : text('尚未保存配置', 'Settings have not been saved')}</div>
                <Space>
                  <Button disabled={!data.enabled || (!configured && !data.dry_run)} loading={testing} onClick={confirmTest}>{text('发送固定测试', 'Send fixed test')}</Button>
                  <Button type="primary" loading={saving} onClick={save}>{text('保存设置', 'Save settings')}</Button>
                </Space>
              </div>
            </Form>
          </ContentCard>

          <ContentCard title={text('安全说明', 'Security notes')} className="settings-aside-card">
            <div className="security-note"><span className="security-note-icon">✓</span><div><strong>{text('密钥仅读写', 'Write-only secret')}</strong><p>{text('读取设置只返回是否已配置和脱敏摘要，不会返回真实 Webhook。', 'Reads return only configured state and a masked summary, never the original webhook.')}</p></div></div>
            <div className="security-note"><span className="security-note-icon">✓</span><div><strong>{text('固定测试模板', 'Fixed test template')}</strong><p>{text('测试内容由服务端生成，页面不接受自定义消息或目标地址。', 'The server provides the test content. This page accepts no custom message or destination.')}</p></div></div>
            <div className="security-note"><span className="security-note-icon">✓</span><div><strong>{text('版本冲突保护', 'Version conflict protection')}</strong><p>{text('保存使用版本号校验；并发更新时需先重新载入。', 'Optimistic version checks require a reload after concurrent updates.')}</p></div></div>
          </ContentCard>
        </div>

        <ContentCard title={text('投递历史', 'Delivery history')} extra={<Button type="text" onClick={deliveries.refresh}>{text('刷新', 'Refresh')}</Button>}>
          <DataState loading={deliveries.loading} error={deliveries.error} onRetry={deliveries.refresh} empty={!deliveries.loading && !deliveries.error && deliveryRows.length === 0} emptyTitle={text('暂无投递记录', 'No delivery history')}>
            <DataTable dataSource={deliveryRows.map((row, index) => ({ ...row, key: row.id || index }))} columns={[
              { title: text('开始时间', 'Started'), dataIndex: 'started_at', key: 'started_at', render: (value) => formatTime(value, language) },
              { title: 'event_id', dataIndex: 'event_id', key: 'event_id', render: (value) => <Text code>{value || '—'}</Text> },
              { title: text('尝试', 'Attempt'), dataIndex: 'attempt', key: 'attempt' },
              { title: text('结果', 'Result'), dataIndex: 'success', key: 'success', render: (value, row) => <Tag color={value ? 'success' : row.error_class === 'dry_run' ? 'processing' : 'warning'}>{value ? text('成功', 'Success') : row.error_class === 'dry_run' ? 'Dry Run' : text('失败', 'Failed')}</Tag> },
              { title: 'HTTP', dataIndex: 'http_status', key: 'http_status', render: (value) => value ?? '—' },
              { title: text('远端代码', 'Remote code'), dataIndex: 'remote_code', key: 'remote_code', render: (value) => value ?? '—' },
              { title: text('错误分类', 'Error class'), dataIndex: 'error_class', key: 'error_class', render: (value) => value || '—' },
              { title: text('完成时间', 'Finished'), dataIndex: 'finished_at', key: 'finished_at', render: (value) => formatTime(value, language) },
            ]} size="small" />
          </DataState>
        </ContentCard>
      </>}
    </DataState>
  </>;
}
