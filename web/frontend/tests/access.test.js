import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
import { transformWithOxc } from 'vite';
import * as api from '../src/api.js';
import * as model from '../src/access-model.js';

// Execute the real page code with UI/network boundaries stubbed. These are
// component-contract tests, not browser/layout or backend integration tests.
async function harness(filename = 'access.jsx') {
  const calls = [], notices = [], states = [];
  let index = 0, validate = async () => ({ code: '123456' });
  let request = async () => ({ data: { mfa_enabled: false } });
  let endpoint = { data: { items: [], tokens: [], next_cursor: null }, loading: false, refresh() {} };
  const element = (type, props, ...children) => ({ type, props: { ...props, children } });
  const hooks = {
    createElement: element, Fragment: 'Fragment', createContext: () => ({ Provider: 'Provider' }),
    useContext: () => ({}), useEffect() {}, useCallback: (fn) => fn, useMemo: (fn) => fn(),
    useState(initial) {
      const slot = index++;
      if (!(slot in states)) states[slot] = typeof initial === 'function' ? initial() : initial;
      return [states[slot], (value) => { states[slot] = typeof value === 'function' ? value(states[slot]) : value; }];
    },
  };
  const form = { validateFields: () => validate(), resetFields() {}, getFieldValue: () => '123456' };
  const antd = Object.fromEntries(['Alert','Button','Input','InputNumber','Select','Space','Table','Tag','Avatar','ConfigProvider','Drawer','Dropdown','Menu','Spin','Tooltip'].map(name => [name, name]));
  antd.Form = Object.assign(() => {}, { Item: 'Form.Item', useForm: () => [form] });
  antd.Modal = Object.assign(() => {}, { useModal: () => [{ confirm: (options) => calls.push(['confirm', options]) }, 'modal-context'] });
  antd.Typography = { Text: 'Text', Paragraph: 'Paragraph' };
  antd.Layout = Object.assign(() => {}, { Header: 'Header', Sider: 'Sider', Content: 'Content' });
  antd.theme = { useToken: () => ({ token: {} }) };
  antd.message = { useMessage: () => [{ success: (s) => notices.push(['success', s]), error: (s) => notices.push(['error', s]) }, 'toast-context'] };
  const pages = Object.fromEntries(['Dashboard','Users','Resources','Smb','Hosts','System','Logs','Reports','Audit','WeComSettings'].map(name => [name + 'Page', name + 'Page']));
  const ui = Object.fromEntries(['ContentCard','DataState','EmptyState','PageHeader','Icon','LoginPage','SnapshotStatus'].map(name => [name, name]));
  ui.useEndpoint = (url) => { calls.push(['endpoint', url]); return endpoint; };
  const context = vm.createContext({ console, TextEncoder, Date, URLSearchParams,
    localStorage: { getItem: () => null }, window: { location: { hash: '#/mfa' } } });
  const stubs = {
    react: { default: hooks, ...hooks }, antd,
    './api.js': { ...api, apiRequest: async (...args) => { calls.push(['request', ...args]); return request(...args); } },
    './App.jsx': { useLanguage: () => ({ text: (zh) => zh, language: 'zh' }) },
    './access-model.js': model, './ui.jsx': ui, './pages.jsx': pages,
    './access.jsx': { MfaPage: 'MfaPage', ApiTokensPage: 'ApiTokensPage', NotificationsPage: 'NotificationsPage' },
  };
  const source = await readFile(new URL('../src/' + filename, import.meta.url), 'utf8');
  const { code } = await transformWithOxc(source, filename, { jsx: { runtime: 'classic' } });
  const mod = new vm.SourceTextModule(code, { context });
  await mod.link((specifier) => {
    const exports = stubs[specifier];
    assert.ok(exports, 'Unexpected dependency: ' + specifier);
    return new vm.SyntheticModule(Object.keys(exports), function () {
      for (const [key, value] of Object.entries(exports)) this.setExport(key, value);
    }, { context });
  });
  await mod.evaluate();
  return {
    pages: mod.namespace, calls, notices, states,
    render(component, props) { index = 0; return component(props); },
    setValidate(fn) { validate = fn; }, setRequest(fn) { request = fn; },
    setEndpoint(value) { endpoint = value; },
  };
}
function nodes(tree, predicate) {
  const found = [];
  function walk(value) {
    if (Array.isArray(value)) return value.forEach(walk);
    if (!value || typeof value !== 'object') return;
    if (value.type && predicate(value)) found.push(value);
    if (value.props) Object.values(value.props).forEach(walk);
  }
  walk(tree);
  return found;
}
function button(tree, label) {
  return nodes(tree, n => n.type === 'Button' && n.props.children.includes(label))[0];
}

test('App supplies MFA identity and refresh callback', async () => {
  const h = await harness('App.jsx');
  const outer = h.render(h.pages.default, {});
  const content = nodes(outer, n => typeof n.type === 'function' && n.type.name === 'AppContent')[0];
  const identity = { username: 'viewer', role: 'viewer', capabilities: [], mfa_enabled: true };
  h.states.splice(0, h.states.length, identity, 'ready', false, 'zh', 'mfa');
  const tree = h.render(content.type, content.props);
  const page = nodes(tree, n => n.type === 'MfaPage')[0];
  assert.equal(page.props.identity, identity);
  assert.equal(typeof page.props.onIdentityChanged, 'function');
});
test('unknown MFA state cannot offer setup or disable', async () => {
  const h = await harness();
  const tree = h.render(h.pages.MfaPage, { identity: {}, onIdentityChanged() {} });
  assert.equal(button(tree, '停用双重验证'), undefined);
  assert.equal(nodes(tree, n => n.type === 'EmptyState').length, 0);
  assert.ok(button(tree, '刷新状态'));
});
test('MFA disable validates before issuing a mutation', async () => {
  const h = await harness();
  h.setValidate(async () => { throw new Error('invalid'); });
  const tree = h.render(h.pages.MfaPage, { identity: { mfa_enabled: true }, onIdentityChanged() {} });
  await button(tree, '停用双重验证').props.onClick();
  assert.equal(h.calls.filter(c => c[0] === 'request').length, 0);
});
test('MFA mutation awaits and catches identity refresh errors', async () => {
  const h = await harness();
  const tree = h.render(h.pages.MfaPage, { identity: { mfa_enabled: true }, async onIdentityChanged() { throw new Error('refresh failed'); } });
  await button(tree, '停用双重验证').props.onClick();
  assert.equal(h.calls[0][1], '/api/auth/mfa/disable');
  assert.equal(h.notices[0][0], 'error');
  assert.equal(h.notices.some(n => n[0] === 'success'), false);
});
test('notification Next and Previous preserve paired cursors, filters reset them', async () => {
  const h = await harness();
  h.setEndpoint({ data: { items: [], next_cursor: { created_at: 123, id: 'a/b' } }, loading: false, refresh() {} });
  const render = () => h.render(h.pages.NotificationsPage, { capabilities: new Set() });
  let tree = render();
  button(tree, '下一页').props.onClick();
  tree = render();
  assert.match(h.calls.at(-1)[1], /cursor_ts=123&cursor_id=a%2Fb/);
  button(tree, '上一页').props.onClick();
  tree = render();
  assert.equal(h.calls.at(-1)[1], '/api/notifications?limit=100');
  button(tree, '下一页').props.onClick();
  tree = render();
  button(tree, '只看未读').props.onClick();
  render();
  assert.equal(h.calls.at(-1)[1], '/api/notifications?unread=1&limit=100');
});
test('revocation failures reject the confirmation promise for retry', async () => {
  const h = await harness();
  h.setRequest(async () => { throw new Error('failed'); });
  const tree = h.render(h.pages.ApiTokensPage, {});
  const table = nodes(tree, n => n.type === 'Table')[0];
  const action = table.props.columns.find(c => c.key === 'actions').render(null, { id: 'test', revoked: false });
  action.props.onClick();
  const options = h.calls.find(c => c[0] === 'confirm')[1];
  await assert.rejects(options.onOk(), /failed/);
});
test('token status distinguishes expiration boundary and revocation', () => {
  assert.equal(model.tokenStatus({ expires_at: 100 }, 99999), 'active');
  assert.equal(model.tokenStatus({ expires_at: 100 }, 100000), 'expired');
  assert.equal(model.tokenStatus({ expires_at: 100, revoked: true }, 1), 'revoked');
  assert.equal(model.tokenStatus({}), 'unknown');
});
test('token name follows trimmed UTF-8 byte limits, not character counts', () => {
  assert.equal(model.validTokenName('  '), false);
  assert.equal(model.validTokenName('x'.repeat(64)), true);
  assert.equal(model.validTokenName('x'.repeat(65)), false);
  assert.equal(model.validTokenName('中'.repeat(21)), true);
  assert.equal(model.validTokenName('中'.repeat(22)), false);
});
