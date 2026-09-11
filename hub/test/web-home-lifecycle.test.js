import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
import { createRecordSession } from '../web/record-session.js';
import { webcrypto } from 'node:crypto';
import { createAuth as actualCreateAuth, SESSION_STORAGE_KEY, REDIRECT_URL } from '../web/auth.js';

// Execute the production glue with its real authentication and record-session modules. The shared workbench bundle is
// replaced by a capture of the host object it would receive; record transport, frame rendering, timers and network
// responses are synthetic. No browser profile, live OAuth token, record key, server or private data is used.
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
  constructor(id) { super(); this.id = id; this.children = []; this.textContent = ''; }
  querySelector(selector) { return selector === 'iframe' ? this.children.find(child => child.tagName === 'IFRAME') ?? null : null; }
  replaceChildren(...children) { this.children = children; }
}

async function harness({ recordConnect, recordRead, clearKey, tokenResponse } = {}) {
  assert.match(html, /<main id="root"/, 'The production page mounts the workbench into #root');
  assert.match(html, /<script src="\/web\/workbench\/app\.js" defer><\/script>\s*<script type="module" src="\/web\/home\.js"><\/script>/,
    'The shared bundle is loaded before the glue that mounts it');
  const root = new Element('root'), content = new Element('records');
  const document = new Events();
  document.hidden = false;
  document.getElementById = id => { if (id !== 'root') throw new Error(`Missing production DOM element: ${id}`); return root; };
  const window = new Events(), storage = memory(), transactions = memory();
  const timers = new Map(), clients = [], renders = [], clearedOwners = [], cleanupEvents = [], keys = new Set([ALICE]);
  let clock = START, nextTimer = 0, auth, host, mounted = 0;
  function seed(userID) {
    storage.setItem(SESSION_STORAGE_KEY, JSON.stringify({ formatVersion: 1, userId: userID,
      accessToken: `synthetic-access-${userID}`, refreshToken: `synthetic-refresh-${userID}`, expiresAt: clock + 3600_000 }));
  }
  seed(ALICE);
  const userResponse = id => ({ id, aud: 'authenticated', email: id === ALICE ? 'alice@example.test' : 'bob@example.test',
    user_metadata: { full_name: id === ALICE ? 'Alice fixture' : 'Bob fixture' } });
  const location = { href: REDIRECT_URL, assign() {} };
  function clearRecords(container) {
    assert.equal(container, content, 'Frames are cleared only from the attached records container');
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
    AGENT_ENDPOINT: 'https://agent.example',
    PpomiWebWorkbench: { mountWebWorkbench(target, value) { mounted++; assert.equal(target, root); host = value; } },
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
    createTranscriptSession: () => ({
      start() {}, stop() {}, refresh: async () => {}, append: async () => {},
      clearPrivate: async () => {}, subscribe: () => () => {}, watch: () => () => {},
      getState: () => ({ status: 'idle', transcript: null, turns: [], error: null }),
    }),
    createTranscriptClient: () => ({ dispose() {} }),
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
    renderRecords: async (name, payload, { container, signal }) => {
      assert.equal(container, content, 'Frames render only into the attached records container');
      if (signal.aborted) throw Object.assign(new Error('cancelled'), { code: 'cancelled' });
      clearRecords(container);
      const frame = { tagName: 'IFRAME', name, payload, removed: false };
      content.replaceChildren(frame); renders.push({ frame, signal });
      return { frame, name };
    },
    clearRecords,
    timelineProjection: json => json,
  });
  vm.runInContext(source, context, { filename: 'hub/web/home.js' });
  assert.equal(mounted, 0, 'The workbench waits for the first sign-in check (bounded) so a returning account sees no sign-in flash');
  await settleUntil(() => mounted === 1, 'The glue mounts the shared workbench once the first restore settled');
  assert.equal([...timers.values()].some(timer => timer.delay === 4000), false, 'The mount deadline is cleared once restore settled');
  // The records pane mounts its frame container after React renders; attach it like the pane does.
  let detach = host.records.attach(content);
  return {
    get auth() { return auth; }, host, window, document, clients, renders, timers, clearedOwners, cleanupEvents, keys,
    frame: () => content.querySelector('iframe'),
    detach: () => detach(),
    reattach: () => { detach = host.records.attach(content); },
    account: () => host.source.getState().account,
    records: () => host.records.getState(),
    advance: ms => { clock += ms; },
    async poll() {
      const entry = [...timers.entries()].find(([, timer]) => timer.delay === 60_000);
      assert.ok(entry, 'A visible authenticated view schedules its next poll');
      timers.delete(entry[0]); await entry[1].handler();
    },
    replaceAccount(id) { seed(id); return window.emit('storage', { key: SESSION_STORAGE_KEY, newValue: storage.getItem(SESSION_STORAGE_KEY), storageArea: storage }); },
    close() { detach(); auth?.dispose(); window.emit('pagehide'); timers.clear(); },
  };
}

async function settleUntil(predicate, message) {
  for (let turn = 0; turn < 30; turn++) {
    if (predicate()) return;
    await new Promise(resolve => setImmediate(resolve));
  }
  assert.ok(predicate(), message);
}

test('the host exposes only public account and connection state, and the device ID the agent server needs', async t => {
  const h = await harness();
  t.after(() => h.close());
  assert.equal(h.host.source.endpoint, 'https://agent.example');
  // Values come from another vm context: compare structure, not prototypes.
  assert.deepEqual(Array.from(h.host.records.views, view => view.id), ['timeline', 'evidence', 'accounting', 'playbooks', 'health', 'spatial']);
  await settleUntil(() => h.frame(), 'Initial verified account renders records');
  const state = h.host.source.getState();
  assert.deepEqual({ ...state.account }, { id: ALICE, name: 'Alice fixture', email: 'alice@example.test' });
  assert.equal(state.deviceID, ALICE, 'The confirmed browser device becomes the X-Ppomi-Device value');
  assert.equal(state.notice, '');
  assert.deepEqual(Object.keys(state).sort(), ['account', 'deviceID', 'notice', 'noticeIsError']);
  assert.equal(JSON.stringify(state).includes('synthetic-access'), false, 'No token is ever part of host state');
  assert.equal(await h.host.source.getAccessToken(), `synthetic-access-${ALICE}`);
  assert.equal(h.records().connection.workspace.name, 'Alice workspace');
  await settleUntil(() => h.records().record?.version === '1', 'The session publishes the displayed record after the frame rendered');
});

test('same-user token refresh keeps the current record view and does not delete its device key', async t => {
  const token = deferred(), started = deferred();
  const h = await harness({ tokenResponse: () => { started.resolve(); return token.promise; } });
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
  const h = await harness({ tokenResponse: () => { started.resolve(); return token.promise; }, clearKey: () => cleanup.promise });
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
  assert.equal(h.account(), null);
  assert.equal(h.host.source.getState().deviceID, null, 'The old device ID leaves with the old account');
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
  assert.equal(h.account().email, 'bob@example.test');
  assert.equal(h.host.source.getState().deviceID, BOB);
  assert.equal(h.frame().payload.data.fixtureOwner, BOB);
});

test('late connection result from a disposed account cannot replace the current context or view', async t => {
  const oldConnect = deferred(), started = deferred();
  const h = await harness({ recordConnect: (client, connected) => {
    if (client.user.id === ALICE) { started.resolve(); return oldConnect.promise; }
    return connected;
  } });
  t.after(() => h.close());
  await started.promise;
  await h.replaceAccount(BOB);
  await settleUntil(() => h.frame()?.payload.data.fixtureOwner === BOB, 'New account connects and renders');
  oldConnect.resolve({ status: 'waiting-key', workspace: { id: ALICE, name: 'Stale Alice workspace' }, recordNames: [] });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(h.records().connection.workspace.name, 'Bob workspace');
  h.host.records.select('accounting');
  await settleUntil(() => h.frame()?.name === 'accounting', 'Stale waiting context cannot suppress current-account tab reads');
  assert.equal(h.frame().payload.data.fixtureOwner, BOB);
  assert.equal(h.clients[0].disposed, true);
});

test('unchanged visible poll preserves its iframe and tab changes request a full record', async t => {
  const h = await harness();
  t.after(() => h.close());
  await settleUntil(() => h.frame() && h.timers.size, 'Initial rendering completes and schedules polling');
  const frame = h.frame(), client = h.clients[0], count = h.renders.length;
  await h.poll();
  assert.equal(h.frame(), frame);
  assert.equal(h.renders.length, count);
  assert.equal(client.reads.at(-1).knownVersion, '1');
  assert.equal(h.records().record.version, '1');
  h.host.records.select('accounting');
  await settleUntil(() => h.frame()?.name === 'accounting', 'Tab switch renders the selected full record');
  assert.equal(frame.removed, true);
  assert.equal(client.reads.at(-1).knownVersion, undefined);
  h.host.records.select('accounting');
  assert.equal(client.reads.length, 3, 'Reselecting the shown view does not read again');
});

test('logout immediately removes private views and discards a late read including its plaintext buffer', async t => {
  const late = deferred(), started = deferred();
  let block = false;
  const h = await harness({ recordRead: (_client, _name, _options, full) => {
    if (block) { started.resolve(); return late.promise; }
    return full();
  } });
  t.after(() => h.close());
  await settleUntil(() => h.frame() && h.timers.size, 'Initial view is ready');
  const frame = h.frame(), previousRenders = h.renders.length;
  block = true;
  h.host.records.refresh();
  await started.promise;
  const logout = h.host.source.signOut();
  assert.equal(h.account(), null);
  assert.equal(h.frame(), null);
  assert.equal(frame.removed, true);
  assert.equal(h.renders[0].signal.aborted, true);
  await logout;
  assert.equal(h.host.source.getState().notice, '이 브라우저에서 로그아웃했습니다.');
  assert.deepEqual(h.clearedOwners, [ALICE]);
  const bytes = new TextEncoder().encode('{"private":"synthetic late record"}');
  late.resolve({ name: 'ledger', version: '2', bytes, json: { private: 'synthetic late record' } });
  await new Promise(resolve => setImmediate(resolve));
  assert.ok(bytes.every(byte => byte === 0));
  assert.equal(h.renders.length, previousRenders);
  assert.equal(h.frame(), null);
  assert.equal(h.timers.size, 0);
  await assert.rejects(h.host.source.getAccessToken(), 'A signed-out browser has no token for the agent server');
});

test('a record read that arrives before the pane mounted waits for the container instead of failing', async t => {
  const h = await harness();
  t.after(() => h.close());
  await settleUntil(() => h.frame(), 'Initial view is ready');
  const previous = h.frame(), renders = h.renders.length;
  // The pane can unmount and remount around a read (React re-render, sign-in race); the read must wait, not throw.
  h.detach();
  h.host.records.select('accounting');
  for (let turn = 0; turn < 10; turn++) await new Promise(resolve => setImmediate(resolve));
  assert.equal(h.renders.length, renders, 'Nothing renders without a container');
  assert.equal(h.records().status, 'reading', 'The read stays pending rather than reporting an error');
  h.reattach();
  await settleUntil(() => h.frame()?.name === 'accounting', 'The waiting read renders once a container appears');
  assert.equal(previous.removed, true);
  assert.equal(h.records().status, 'ready');
});
