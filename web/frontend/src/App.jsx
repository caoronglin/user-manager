import React, { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';
import {
  Alert, Avatar, Button, ConfigProvider, Drawer, Dropdown, Layout, Menu, Space, Spin, Tooltip, Typography, theme,
} from 'antd';
import {
  apiRequest, freshnessLabel, unwrap,
} from './api.js';
import {
  AuditPage, DashboardPage, HostsPage, LogsPage, ReportsPage, ResourcesPage, SmbPage, SystemPage, UsersPage, WeComSettingsPage,
} from './pages.jsx';
import { EmptyState, Icon, LoginPage, PageHeader, SnapshotStatus } from './ui.jsx';

const { Header, Sider, Content } = Layout;
const LanguageContext = createContext(null);
const FreshnessContext = createContext(null);
export const useLanguage = () => useContext(LanguageContext);
export const useFreshness = () => useContext(FreshnessContext);

const NAV_ITEMS = [
  { key: 'dashboard', zh: '概览', en: 'Dashboard', capability: 'dashboard.read', icon: 'dashboard' },
  { key: 'users', zh: '用户与配额', en: 'Users & quota', capability: 'users.read', icon: 'users' },
  { key: 'resources', zh: '资源用量', en: 'Resources', capability: 'resource.read', icon: 'resources' },
  { key: 'smb', zh: 'SMB', en: 'SMB', capability: 'smb.read', icon: 'share' },
  { key: 'hosts', zh: '主机与 GPU', en: 'Hosts & GPU', capability: 'hosts.read', icon: 'hosts' },
  { key: 'logs', zh: '运行日志', en: 'Logs', capability: 'logs.read', icon: 'logs' },
  { key: 'reports', zh: '报告', en: 'Reports', capability: 'reports.read', icon: 'reports' },
  { key: 'audit', zh: '审计记录', en: 'Audit', capability: 'audit.read', icon: 'audit' },
  { key: 'system-group', zh: '系统与设置', en: 'System & settings', icon: 'system', children: [
    { key: 'system', zh: '系统状态', en: 'System status', capability: 'dashboard.read', icon: 'system' },
    { key: 'wecom', zh: '企业微信设置', en: 'WeCom settings', capability: 'wecom.manage', icon: 'settings' },
  ] },
];

const PAGE_COMPONENTS = {
  dashboard: DashboardPage,
  users: UsersPage,
  resources: ResourcesPage,
  smb: SmbPage,
  hosts: HostsPage,
  system: SystemPage,
  logs: LogsPage,
  reports: ReportsPage,
  audit: AuditPage,
  wecom: WeComSettingsPage,
};

function readPage() {
  const key = window.location.hash.replace(/^#\/?/, '').split('/')[0];
  return PAGE_COMPONENTS[key] ? key : 'dashboard';
}

function AppContent({ dark, setDark }) {
  const { token } = theme.useToken();
  const [identity, setIdentity] = useState(null);
  const [authState, setAuthState] = useState('checking');
  const [mfaPending, setMfaPending] = useState(false);
  const [language, setLanguage] = useState(localStorage.getItem('um.language') || 'zh');
  const [page, setPage] = useState(readPage);
  const [collapsed, setCollapsed] = useState(false);
  const [mobileOpen, setMobileOpen] = useState(false);
  const [freshnessBySource, setFreshnessBySource] = useState({});
  const [loginNotice, setLoginNotice] = useState('');

  const capabilities = useMemo(() => new Set(identity?.capabilities || []), [identity]);
  const text = (zh, en) => language === 'zh' ? zh : en;
  const availableItems = useMemo(() => NAV_ITEMS.map((item) => item.children
    ? { ...item, children: item.children.filter((child) => capabilities.has(child.capability)) }
    : item).filter((item) => item.children ? item.children.length > 0 : capabilities.has(item.capability)), [capabilities]);
  const availablePages = useMemo(() => availableItems.flatMap((item) => item.children || [item]), [availableItems]);
  const registerFreshness = useCallback((source, freshness) => {
    if (!freshness) return;
    setFreshnessBySource((current) => ({ ...current, [source]: freshness }));
  }, []);
  const freshnessSummary = useMemo(() => {
    const entries = Object.values(freshnessBySource);
    if (!entries.length) return null;
    return entries.find((item) => item?.stale) || entries.find((item) => item?.present) || entries[0];
  }, [freshnessBySource]);

  const loadIdentity = useCallback(async () => {
    try {
      const response = await apiRequest('/api/auth/me');
      const me = unwrap(response);
      if (!me?.username || !Array.isArray(me.capabilities)) throw new Error('identity response is incomplete');
      setIdentity(me);
      setMfaPending(false);
      setAuthState('ready');
      setLoginNotice('');
    } catch (error) {
      if (error.status === 401) {
        setIdentity(null);
        setAuthState('signed-out');
      } else {
        setIdentity(null);
        setAuthState('unavailable');
        setLoginNotice(error.message || text('无法连接到服务。', 'The service is unavailable.'));
      }
    }
  }, []);

  useEffect(() => {
    loadIdentity();
    const onUnauthorized = () => {
      setIdentity(null);
      setMfaPending(false);
      setAuthState('signed-out');
    };
    const onHashChange = () => setPage(readPage());
    window.addEventListener('um:unauthorized', onUnauthorized);
    window.addEventListener('hashchange', onHashChange);
    return () => {
      window.removeEventListener('um:unauthorized', onUnauthorized);
      window.removeEventListener('hashchange', onHashChange);
    };
  }, [loadIdentity]);

  useEffect(() => {
    if (!availablePages.some((item) => item.key === page)) {
      const fallback = availablePages[0]?.key || '';
      if (fallback && page !== fallback) window.location.hash = `/${fallback}`;
    }
  }, [availableItems, availablePages, page]);

  const handleLogin = async (credentials) => {
    setLoginNotice('');
    try {
      const response = await apiRequest('/api/auth/login', {
        method: 'POST', body: credentials, unauthorizedOn401: false,
      });
      const result = unwrap(response);
      if (result?.mfa_required) {
        setMfaPending(true);
        return;
      }
      await loadIdentity();
    } catch (error) {
      setLoginNotice(error.status === 401
        ? text('用户名或密码不正确。', 'The username or password is incorrect.')
        : error.message);
    }
  };

  const handleMfa = async (code) => {
    setLoginNotice('');
    try {
      await apiRequest('/api/auth/mfa/challenge', {
        method: 'POST', body: { code }, unauthorizedOn401: false,
      });
      await loadIdentity();
    } catch (error) {
      setLoginNotice(error.status === 401 || error.status === 400
        ? text('验证码无效，请重试。', 'That code was not accepted. Try again.')
        : error.message);
    }
  };

  const handleLogout = async () => {
    try {
      await apiRequest('/api/auth/logout', { method: 'POST' });
    } finally {
      setIdentity(null);
      setAuthState('signed-out');
      setMfaPending(false);
      setFreshnessBySource({});
      window.location.hash = '';
    }
  };

  const choosePage = (key) => {
    window.location.hash = `/${key}`;
    setPage(key);
    setMobileOpen(false);
  };

  if (authState === 'checking') {
    return <div className="boot-screen"><Spin size="large" /><Typography.Text>{text('正在检查登录状态…', 'Checking session…')}</Typography.Text></div>;
  }
  if (authState !== 'ready') {
    return <LoginPage
      language={language}
      setLanguage={(value) => { localStorage.setItem('um.language', value); setLanguage(value); }}
      onSubmit={mfaPending ? handleMfa : handleLogin}
      mfaPending={mfaPending}
      notice={loginNotice}
      unavailable={authState === 'unavailable'}
      onRetry={loadIdentity}
    />;
  }

  const active = availablePages.find((item) => item.key === page) || availablePages[0];
  const Page = PAGE_COMPONENTS[active?.key];
  const userMenu = [
    { key: 'account', label: <span className="account-summary">{identity.username}<small>{identity.role}</small></span>, disabled: true },
    { type: 'divider' },
    { key: 'logout', label: text('退出登录', 'Sign out'), icon: <Icon name="logout" /> },
  ];
  const navMenu = (
    <Menu
      mode="inline"
      selectedKeys={active ? [active.key] : []}
      defaultOpenKeys={active?.key === 'system' || active?.key === 'wecom' ? ['system-group'] : []}
      items={availableItems.map((item) => ({
        key: item.key,
        icon: <Icon name={item.icon} />,
        label: text(item.zh, item.en),
        ...(item.children ? { children: item.children.map((child) => ({
          key: child.key,
          icon: <Icon name={child.icon} />,
          label: text(child.zh, child.en),
        })) } : {}),
      }))}
      onClick={({ key }) => choosePage(key)}
    />
  );

  return (
    <FreshnessContext.Provider value={{ registerFreshness, freshnessBySource }}>
      <LanguageContext.Provider value={{ language, text }}>
        <Layout className={`app-layout ${dark ? 'app-dark' : ''}`} style={{ background: token.colorBgLayout }}>
          <Sider
            className="desktop-sider"
            width={240}
            collapsedWidth={64}
            collapsed={collapsed}
            breakpoint="lg"
            onCollapse={(value) => setCollapsed(value)}
            theme={dark ? 'dark' : 'light'}
          >
            <div className={`brand ${collapsed ? 'brand-collapsed' : ''}`}>
              <div className="brand-mark" aria-hidden="true"><span>U</span></div>
              {!collapsed && <div className="brand-copy"><strong>User Manager</strong><small>{text('系统观测控制台', 'Operations console')}</small></div>}
            </div>
            <div className="sider-menu">{navMenu}</div>
            {!collapsed && <div className="sider-foot"><span className="sider-foot-mark" />{text('只读系统快照', 'Read-only snapshots')}</div>}
          </Sider>

          <Layout className="main-layout">
            <Header className="app-header">
              <div className="header-left">
                <Button className="mobile-menu-trigger" type="text" icon={<Icon name="menu" />} aria-label={text('打开导航', 'Open navigation')} onClick={() => setMobileOpen(true)} />
                {collapsed && <div className="header-brand"><span className="brand-mark"><span>U</span></span><strong>User Manager</strong></div>}
                <div className="header-current">{active ? text(active.zh, active.en) : text('控制台', 'Console')}</div>
              </div>
              <div className="header-actions">
                <SnapshotStatus freshness={freshnessSummary} language={language} compact />
                <Tooltip title={text('切换语言', 'Switch language')}><Button type="text" className="header-control" onClick={() => { const next = language === 'zh' ? 'en' : 'zh'; localStorage.setItem('um.language', next); setLanguage(next); }} aria-label={text('切换到 English', 'Switch to Chinese')}>{language === 'zh' ? '中' : 'EN'}</Button></Tooltip>
                <Tooltip title={text(dark ? '切换到浅色主题' : '切换到深色主题', dark ? 'Use light theme' : 'Use dark theme')}><Button type="text" className="header-control theme-control" icon={<Icon name={dark ? 'sun' : 'moon'} />} onClick={() => { const next = !dark; localStorage.setItem('um.theme', next ? 'dark' : 'light'); setDark(next); }} aria-label={text('切换主题', 'Toggle theme')} /></Tooltip>
                <Dropdown menu={{ items: userMenu, onClick: ({ key }) => key === 'logout' && handleLogout() }} trigger={['click']} placement="bottomRight">
                  <button className="profile-button" type="button" aria-label={text('打开账户菜单', 'Open account menu')}>
                    <Avatar size={32} className="profile-avatar">{identity.username.slice(0, 1).toUpperCase()}</Avatar>
                    <span className="profile-name">{identity.username}</span>
                    <Icon name="chevron" />
                  </button>
                </Dropdown>
              </div>
            </Header>

            <Content className="content-area">
              {active && Page ? <Page capabilities={capabilities} /> : (
                <EmptyState title={text('暂无可查看的页面', 'No pages available')} description={text('当前账号尚未获得只读查看权限。', 'This account has no read access capabilities.')}/>
              )}
            </Content>
          </Layout>

          <Drawer
            title={<div className="drawer-brand"><span className="brand-mark"><span>U</span></span><strong>User Manager</strong></div>}
            placement="left"
            size={280}
            open={mobileOpen}
            onClose={() => setMobileOpen(false)}
            className="mobile-nav-drawer"
            styles={{ body: { padding: '12px 8px' } }}
          >
            {navMenu}
            <div className="sider-foot"><span className="sider-foot-mark" />{text('只读系统快照', 'Read-only snapshots')}</div>
          </Drawer>
        </Layout>
      </LanguageContext.Provider>
    </FreshnessContext.Provider>
  );
}

export default function App() {
  const [dark, setDark] = useState(localStorage.getItem('um.theme') === 'dark');
  useEffect(() => {
    const onStorage = () => setDark(localStorage.getItem('um.theme') === 'dark');
    window.addEventListener('storage', onStorage);
    return () => window.removeEventListener('storage', onStorage);
  }, []);
  return (
    <ConfigProvider
      theme={{
        algorithm: dark ? theme.darkAlgorithm : theme.defaultAlgorithm,
        token: {
          colorPrimary: '#315ee8',
          colorInfo: '#315ee8',
          borderRadius: 8,
          fontFamily: 'Inter, "PingFang SC", "Microsoft YaHei", system-ui, sans-serif',
          controlHeight: 36,
        },
        components: { Layout: { headerBg: '#ffffff', siderBg: '#ffffff' }, Menu: { itemBorderRadius: 8 } },
      }}
    >
      <AppContent dark={dark} setDark={setDark} />
    </ConfigProvider>
  );
}
