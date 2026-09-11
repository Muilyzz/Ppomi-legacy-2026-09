import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
import { createRecordSession } from '../web/record-session.js';
import { webcrypto } from 'node:crypto';
import { createAuth as actualCreateAuth, SESSION_STORAGE_KEY, REDIRECT_URL } from '../web/auth.js';

// Execute the production controller with its real authentication module. Only
// DOM rendering, timers, record transport and network responses are synthetic.
// No browser profile, live OAuth token, record key, server or private data is used.
const source = (await readFile(new URL('../web/home.js', import.meta.url), 'utf8')).replace(/^import .+;\s*$/gm, '');
const html = await readFile(new URL('../index.html', import.meta.url), 'utf8');
const ALICE = '11111111-1111-4111-8111-111111111111';
const BOB = '22222222-2222-4222-8222-222222222222';
const START = 1_800_000_000_000;
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
const response = value => new Response(JSON.stringify(value));
const memory = () => {
  const values = new Map();
  return { getItem: key => values.get(key) ?? null, setItem: (key, value) => values.set(key, value), removeItem: key => values.delete(key) };
};

class Events {
  listeners = new Map();
  addEventListener(type, listener) {
    if (!this.listeners.has(type)) this.listeners.set(type, new Set());
    this.listeners.get(type).add(listener);
  }
  removeEventListener(type, listener) { this.listeners.get(type)?.delete(listener); }
  emit(type, event = {}) { return Promise.all([...this.listeners.get(type) ?? []].map(listener => listener(event))); }
}
class Element extends Events {
  constructor(id) {
    super(); this.id = id; this.dataset = {}; this.textContent = ''; this.hidden = false; this.disabled = false;
    this.children = []; this.attributes = {};
  }
  setAttribute(name, value) { this.attributes[name] = value; }
  querySelector(selector) { return selector === 'iframe' ? this.children.find(child => child.tagName === 'IFRAME') ?? null : null; }
  replaceChildren(...children) { this.children = children; }
  focus() {}
  click() { return this.disabled ? Promise.resolve() : this.emit('click'); }
}

function harness({ recordConnect, recordRead, clearKey, tokenResponse } = {}) {
  const elements = new Map([...html.matchAll(/\bid="([^"]+)"/g)].map(match => [match[1], new Element(match[1])]));
  const tabs = [...html.matchAll(/<button\b[^>]*data-record-view="([^"]+)"[^>]*>/g)].map(match => {
    const id = /\bid="([^"]+)"/.exec(match[0])?.[1];
    const element = elements.get(id);
    if (!element) throw new Error('Fixture requires real tab IDs');
    element.dataset.recordView = match[1]; return element;
  });
  assert.equal(tabs.length, 6, 'Harness must use all actual record tabs');
  const document = new Events();
  document.hidden = false;
  document.getElementById = id => {
    if (!elements.has(id)) throw new Error(`Missing production DOM element: ${id}`);
    return elements.get(id);
  };
  document.querySelectorAll = selector => selector === '[data-record-view]' ? tabs : [];
  const window = new Events(), storage = memory(), transactions = memory();
  const timers = new Map(), clients = [], renders = [], clearedOwners = [], cleanupEvents = [], keys = new Set([ALICE]);
  let clock = START, nextTimer = 0, auth;
  function seed(userID) {
    storage.setItem(SESSION_STORAGE_KEY, JSON.stringify({ formatVersion: 1, userId: userID,
      accessToken: `synthetic-access-${userID}`, refreshToken: `synthetic-refresh-${userID}`, expiresAt: clock + 3600_000 }));
  }
  seed(ALICE);
  const userResponse = id => ({ id, aud: 'authenticated', email: id === ALICE ? 'alice@example.test' : 'bob@example.test',
    user_metadata: { full_name: id === ALICE ? 'Alice fixture' : 'Bob fixture' } });
  const location = { href: REDIRECT_URL, assign() {} };
  const content = elements.get('main-content');
  function clearRecords() {
    for (const frame of content.children) { frame.removed = true; frame.payload = null; }
    content.replaceChildren();
  }
  function connected(userID) {
    return { status: 'ready', workspace: { id: userID, name: userID === ALICE ? 'Alice workspace' : 'Bob workspace' },
      device: { id: userID, platform: 'web', label: 'Synthetic' }, recordNames: ['ledger', 'accounting', 'evidence', 'playbooks', 'health', 'spatial'] };
  }
  function fullRecord(client, name, version = '1') {
    const json = { fixtureOwner: client.user.id, name, secret: `private-fixture-${client.user.id}` };
    return { name, version, json, text: JSON.stringify(json), bytes: new TextEncoder().encode(JSON.stringify(json)), updatedAt: null };
  }
  const context = vm.createContext({
    document, window, navigator: {}, AbortController, TextDecoder, TextEncoder, Date, console,
    queueMicrotask, setTimeout: (handler, delay) => { const id = ++nextTimer; timers.set(id, { handler, delay }); return id; },
    clearTimeout: id => timers.delete(id),
    createAuth: callbacks => {
      auth = actualCreateAuth({ ...callbacks, storage, transactionStorage: transactions, crypto: webcrypto,
        location, history: { replaceState(_state, _title, url) { location.href = url; } }, eventTarget: window, now: () => clock,
        clearSecrets: async info => { cleanupEvents.push(info); await callbacks.clearSecrets(info); },
        fetch: async (url, request) => {
          if (url.includes('/token?')) {
            const id = JSON.parse(request.body).refresh_token.slice('synthetic-refresh-'.length);
            return tokenResponse ? tokenResponse(id) : response({ access_token: `synthetic-access-${id}`, refresh_token: `synthetic-refresh-${id}`, expires_in: 3600, token_type: 'bearer' });
          }
          if (url.endsWith('/user')) return response(userResponse(request.headers.Authorization.slice('Bearer synthetic-access-'.length)));
          if (url.includes('/logout?')) return new Response(null, { status: 204 });
          throw new Error('Unexpected synthetic auth endpoint');
        },
      });
      return auth;
    },
    createRecordSession,
    createDeviceStore: () => ({ clear: async owner => {
      clearedOwners.push(owner);
      if (clearKey) await clearKey(owner);
      keys.delete(owner);
    } }),
    createRecordClient: ({ user }) => {
      keys.add(user.id);
      const client = { user, disposed: false, reads: [], connectCount: 0,
        async connect() { this.connectCount++; return recordConnect ? recordConnect(this, connected(user.id)) : connected(user.id); },
        async read(name, options = {}) {
          this.reads.push({ name, knownVersion: options.knownVersion });
          if (recordRead) return recordRead(this, name, options, () => fullRecord(this, name));
          return options.knownVersion === '1' ? { name, version: '1', unchanged: true } : fullRecord(this, name);
        },
        dispose() { this.disposed = true; },
      };
      clients.push(client); return client;
    },
    renderRecords: async (name, payload, { signal }) => {
      if (signal.aborted) throw Object.assign(new Error('cancelled'), { code: 'cancelled' });
      clearRecords();
      const frame = { tagName: 'IFRAME', name, payload, removed: false };
      content.replaceChildren(frame); renders.push({ frame, signal });
      // Actual record-views removes its abort listener after a successful render.
      // The retained view is removed by clearRecords, not an already-finished signal.
      return { frame, name };
    },
    clearRecords,
    showRecordMessage: (heading, message) => { clearRecords(); content.replaceChildren({ heading, message }); },
    timelineProjection: json => json,
  });
  vm.runInContext(source, context, { filename: 'hub/web/home.js' });
  return {
    get auth() { return auth; }, elements, window, document, clients, renders, timers, clearedOwners, cleanupEvents, keys,
    frame: () => content.querySelector('iframe'),
    advance: ms => { clock += ms; },
    async poll() {
      const entry = [...timers.entries()].find(([, timer]) => timer.delay === 60_000);
      assert.ok(entry, 'A visible authenticated view schedules its next poll');
      timers.delete(entry[0]); await entry[1].handler();
    },
    replaceAccount(id) { seed(id); return window.emit('storage', { key: SESSION_STORAGE_KEY, newValue: storage.getItem(SESSION_STORAGE_KEY), storageArea: storage }); },
    tab: name => tabs.find(tab => tab.dataset.recordView === name),
    close() { auth?.dispose(); window.emit('pagehide'); timers.clear(); },
  };
}

async function settleUntil(predicate, message) {
  for (let turn = 0; turn < 30; turn++) {
    if (predicate()) return;
    await new Promise(resolve => setImmediate(resolve));
  }
  assert.ok(predicate(), message);
}

test('same-user token refresh keeps the current record view and does not delete its device key', async t => {
  const token = deferred(), started = deferred();
  const h = harness({ tokenResponse: () => { started.resolve(); return token.promise; } });
  t.after(() => h.close());
  await settleUntil(() => h.frame(), 'Initial verified account renders records');
  const frame = h.frame(), client = h.clients[0];
  h.advance(3_550_000);
  const refreshing = h.auth.getAccessToken();
  await started.promise;
  assert.equal(h.auth.getUser(), null, 'Actual auth temporarily withholds the user while refreshing');
  token.resolve(response({ access_token: `synthetic-access-${ALICE}`, refresh_token: `synthetic-refresh-${ALICE}`, expires_in: 3600, token_type: 'bearer' }));
  await refreshing;
  assert.equal(h.auth.getUser().id, ALICE);
  assert.equal(h.frame(), frame);
  assert.equal(client.disposed, false);
  assert.deepEqual(h.clearedOwners, []);
  assert.equal(h.clients.length, 1);
});

test('external account replacement during auth refresh clears the last key owner before showing the next account', async t => {
  const token = deferred(), started = deferred(), cleanup = deferred();
  const h = harness({ tokenResponse: () => { started.resolve(); return token.promise; }, clearKey: () => cleanup.promise });
  t.after(() => h.close());
  await settleUntil(() => h.frame(), 'Initial account renders records');
  const oldFrame = h.frame();
  h.advance(3_550_000);
  const refreshing = h.auth.getAccessToken();
  const cancelled = assert.rejects(refreshing, error => error.code === 'cancelled');
  await started.promise;
  assert.equal(h.auth.getUser(), null);
  await h.replaceAccount(BOB);
  await settleUntil(() => h.clearedOwners.length === 1, 'Cleanup finds the last key owner despite null auth.current');
  assert.equal(h.cleanupEvents.at(-1).previousUserId, null);
  assert.deepEqual(h.clearedOwners, [ALICE]);
  assert.equal(h.elements.get('user-email').textContent, '');
  assert.equal(h.frame(), null);
  assert.equal(oldFrame.removed, true);
  assert.equal(h.clients.length, 1, 'Next account must wait for private cleanup');
  cleanup.resolve();
  // A browser-wide auth lock may still be held by the old request. Release that
  // response after cleanup, and ensure it cannot publish the old account.
  token.resolve(response({ access_token: `synthetic-access-${ALICE}`, refresh_token: `synthetic-refresh-${ALICE}`, expires_in: 3600 }));
  await cancelled;
  await settleUntil(() => h.frame()?.payload.data.fixtureOwner === BOB, 'Next verified account renders only after cleanup');
  assert.equal(h.keys.has(ALICE), false);
  assert.equal(h.keys.has(BOB), true);
  assert.equal(h.elements.get('user-email').textContent, 'bob@example.test');
  assert.equal(h.frame().payload.data.fixtureOwner, BOB);
});

test('late connection result from a disposed account cannot replace the current context or view', async t => {
  const oldConnect = deferred(), started = deferred();
  const h = harness({ recordConnect: (client, connected) => {
    if (client.user.id === ALICE) { started.resolve(); return oldConnect.promise; }
    return connected;
  } });
  t.after(() => h.close());
  await started.promise;
  await h.replaceAccount(BOB);
  await settleUntil(() => h.frame()?.payload.data.fixtureOwner === BOB, 'New account connects and renders');
  oldConnect.resolve({ status: 'waiting-key', workspace: { id: ALICE, name: 'Stale Alice workspace' }, recordNames: [] });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(h.elements.get('workspace-status').textContent, 'Bob workspace');
  await h.tab('accounting').click();
  await settleUntil(() => h.frame()?.name === 'accounting', 'Stale waiting context cannot suppress current-account tab reads');
  assert.equal(h.frame().payload.data.fixtureOwner, BOB);
  assert.equal(h.clients[0].disposed, true);
});

test('unchanged visible poll preserves its iframe and tab changes request a full record', async t => {
  const h = harness();
  t.after(() => h.close());
  await settleUntil(() => h.frame() && h.timers.size, 'Initial rendering completes and schedules polling');
  const frame = h.frame(), client = h.clients[0], count = h.renders.length;
  await h.poll();
  assert.equal(h.frame(), frame);
  assert.equal(h.renders.length, count);
  assert.equal(client.reads.at(-1).knownVersion, '1');
  assert.equal(h.elements.get('record-version').textContent, '버전 1');
  await h.tab('accounting').click();
  await settleUntil(() => h.frame()?.name === 'accounting', 'Tab switch renders the selected full record');
  assert.equal(frame.removed, true);
  assert.equal(client.reads.at(-1).knownVersion, undefined);
});

test('logout immediately removes private views and discards a late read including its plaintext buffer', async t => {
  const late = deferred(), started = deferred();
  let block = false;
  const h = harness({ recordRead: (_client, _name, _options, full) => {
    if (block) { started.resolve(); return late.promise; }
    return full();
  } });
  t.after(() => h.close());
  await settleUntil(() => h.frame() && h.timers.size, 'Initial view is ready');
  const frame = h.frame(), previousRenders = h.renders.length;
  block = true;
  const refresh = h.elements.get('refresh-records').click();
  await started.promise;
  const logout = h.elements.get('sign-out').click();
  assert.equal(h.elements.get('user-email').textContent, '');
  assert.equal(h.frame(), null);
  assert.equal(frame.removed, true);
  assert.equal(h.renders[0].signal.aborted, true);
  await logout;
  assert.deepEqual(h.clearedOwners, [ALICE]);
  const bytes = new TextEncoder().encode('{"private":"synthetic late record"}');
  late.resolve({ name: 'ledger', version: '2', bytes, json: { private: 'synthetic late record' } });
  await refresh;
  assert.ok(bytes.every(byte => byte === 0));
  assert.equal(h.renders.length, previousRenders);
  assert.equal(h.frame(), null);
  assert.equal(h.timers.size, 0);
});
