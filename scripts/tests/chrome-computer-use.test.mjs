import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const listeners = {};
const event = name => ({addListener: fn => { listeners[name] = fn; }});
const tabs = new Map([[1, {id: 1, windowId: 7, active: true, url: 'https://user.example', status: 'complete'}]]);
let nextID = 2;
const calls = [];
globalThis.chrome = {
  tabs: {
    async create(options) { calls.push(['create', options]); const tab = {id: nextID++, status: 'complete', ...options}; tabs.set(tab.id, tab); return tab; },
    async get(id) { if (!tabs.has(id)) throw new Error('Tab closed'); return tabs.get(id); },
    async update(id, options) { calls.push(['update', id, options]); Object.assign(tabs.get(id), options); return tabs.get(id); },
    async remove(id) { calls.push(['remove', id]); tabs.delete(id); },
    onActivated: event('activated'), onRemoved: event('removed')
  },
  windows: {async getLastFocused() { return {id: 7, incognito: false}; }},
  scripting: {async executeScript(options) { calls.push(['script', options.target.tabId]); return [{result: {title: 'fixture'}}]; }},
  action: {onClicked: event('clicked'), setBadgeText() {}, setTitle() {}},
  runtime: {onInstalled: event('installed'), onStartup: event('startup')}
};
const source = await readFile(new URL('../../Sources/CoreModel/Resources/ChromeComputerUse/background.js', import.meta.url), 'utf8');
const {handleRequest, pageOperation} = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
const first = '11111111-1111-1111-1111-111111111111';
const second = '22222222-2222-2222-2222-222222222222';
const request = (operation, session = first, args = {}) => handleRequest({operation, session, arguments: args});

test('profile tabs stay inactive, muted and separate; takeover never edits or closes a user tab', async () => {
  await request('browser_open', first, {url: 'https://one.example'});
  await request('browser_open', second, {url: 'https://two.example'});
  assert.equal(tabs.get(1).active, true);
  assert.equal(tabs.get(1).url, 'https://user.example');
  assert.equal(tabs.get(2).active, false);
  assert.equal(tabs.get(2).muted, true);
  assert.equal(tabs.get(3).active, false);
  assert.deepEqual(calls.filter(([name]) => name === 'update').map(call => call[2]),
    [{muted: true}, {url: 'https://one.example/'}, {muted: true}, {url: 'https://two.example/'}]);
  await request('browser_snapshot');
  assert.deepEqual(calls.at(-1), ['script', 2]);
  tabs.get(2).active = true;
  listeners.activated({tabId: 2});
  tabs.get(2).active = false; // Ownership stays with the user after switching away.
  const before = calls.length;
  await assert.rejects(request('browser_act', first, {action: 'click', ref: 'old'}), /human_activity/);
  await assert.rejects(request('browser_open', first, {url: 'https://replacement.example'}), /human_activity/);
  assert.equal(calls.length, before);
  assert.equal((await request('browser_close')).closed, false);
  assert.equal(tabs.has(2), true);
  assert.equal((await request('browser_close', second)).closed, true);
  assert.equal(tabs.has(3), false);
  assert.equal(tabs.has(1), true);
  await assert.rejects(request('browser_open', first, {url: 'file:///etc/passwd'}), /Only HTTP/);
});

test('page action rechecks visibility at execution and rejects stale references', () => {
  globalThis.document = {visibilityState: 'visible'};
  assert.throws(() => pageOperation('browser_act', {action: 'click', ref: 'old'}), /human_activity/);
  document.visibilityState = 'hidden';
  globalThis.__remoteCodeSnapshot = new Map();
  assert.throws(() => pageOperation('browser_act', {action: 'click', ref: 'old'}), /stale_reference/);
});

test('toolbar disconnect releases the native host even when Chrome does not echo onDisconnect', async () => {
  let disconnected = false;
  chrome.runtime.connectNative = () => ({onMessage: event('message'), onDisconnect: event('disconnect'), disconnect() { disconnected = true; }});
  listeners.clicked();
  listeners.clicked();
  assert.equal(disconnected, true);
  disconnected = false;
  listeners.clicked();
  listeners.clicked();
  assert.equal(disconnected, true);
});
