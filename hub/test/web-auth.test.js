import { test } from 'node:test';
import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import {
  createAuth, AuthError, SUPABASE_URL, PUBLISHABLE_KEY, REDIRECT_URL,
  SESSION_STORAGE_KEY, PKCE_STORAGE_KEY,
} from '../web/auth.js';

const ALICE = '11111111-1111-4111-8111-111111111111';
const BOB = '22222222-2222-4222-8222-222222222222';
const ACCESS = 'test-only-access-token-0123456789';
const REFRESH = 'test-only-refresh-token-0123456789';
const START = 1_800_000_000_000;
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
const response = (value, status = 200) => new Response(JSON.stringify(value), { status, headers: { 'Content-Type': 'application/json' } });
const user = (id = ALICE) => ({ id, aud: 'authenticated', email: 'test@example.com', user_metadata: { full_name: 'Test user', avatar_url: 'javascript:alert(1)' } });
const grant = (access = ACCESS) => ({ access_token: access, refresh_token: REFRESH, expires_in: 3600, token_type: 'bearer', user: { id: BOB }, provider_token: 'must-not-store-provider-token' });
function memory() {
  const entries = new Map();
  return { getItem: key => entries.get(key) ?? null, setItem: (key, value) => entries.set(key, String(value)), removeItem: key => entries.delete(key) };
}
function fixture({ handler = () => response(user()), clearSecrets, href = REDIRECT_URL, locks } = {}) {
  const storage = memory(), transactions = memory(), calls = [], events = [], cleared = [];
  const handlers = new Map();
  const eventTarget = { addEventListener: (type, fn) => handlers.set(type, fn), removeEventListener: type => handlers.delete(type) };
  const location = { href, assigned: null, assign(url) { this.assigned = url; } };
  let time = START;
  const auth = createAuth({
    storage, transactionStorage: transactions, crypto: webcrypto, location,
    history: { replaceState(_state, _title, url) { location.href = url; } }, eventTarget,
    now: () => time, locks,
    fetch: async (url, options) => { calls.push({ url, options }); return handler(url, options); },
    clearSecrets: async info => { cleared.push(info); if (clearSecrets) await clearSecrets(info); },
    onChange: event => events.push(event),
  });
  return {
    auth, storage, transactions, calls, events, cleared, location,
    advance(ms) { time += ms; },
    seed({ id = ALICE, expiresAt = START + 3600_000, accessToken = ACCESS } = {}) {
      storage.setItem(SESSION_STORAGE_KEY, JSON.stringify({ formatVersion: 1, userId: id, accessToken, refreshToken: REFRESH, expiresAt }));
    },
    transaction(age = 0) { transactions.setItem(PKCE_STORAGE_KEY, JSON.stringify({ formatVersion: 1, verifier: 'a'.repeat(43), createdAt: time - age })); },
    storageEvent(newValue) { handlers.get('storage')?.({ key: SESSION_STORAGE_KEY, newValue, storageArea: storage }); },
  };
}
const authCode = code => error => error instanceof AuthError && error.code === code;

test('Google authorization uses random S256 PKCE and the exact production redirect', async () => {
  const f = fixture({ href: `${REDIRECT_URL}?next=https://evil.example/&code=untrusted#access_token=secret` });
  f.seed();
  await f.auth.signIn();
  const url = new URL(f.location.assigned);
  assert.equal(url.origin, SUPABASE_URL);
  assert.equal(url.pathname, '/auth/v1/authorize');
  assert.equal(url.searchParams.get('provider'), 'google');
  assert.equal(url.searchParams.get('prompt'), 'select_account');
  assert.equal(url.searchParams.get('redirect_to'), REDIRECT_URL);
  assert.equal(url.searchParams.get('code_challenge_method'), 's256');
  const tx = JSON.parse(f.transactions.getItem(PKCE_STORAGE_KEY));
  assert.match(tx.verifier, /^[A-Za-z0-9_-]{43}$/);
  const digest = Buffer.from(await webcrypto.subtle.digest('SHA-256', new TextEncoder().encode(tx.verifier))).toString('base64url');
  assert.equal(url.searchParams.get('code_challenge'), digest);
  assert.equal(f.storage.getItem(SESSION_STORAGE_KEY), null);
  assert.equal(f.calls.length, 0);
  assert.equal(f.cleared[0].reason, 'sign-in');
});

test('sign-in fails closed on preview origins and when storage cannot persist PKCE', async () => {
  const foreign = fixture({ href: 'https://preview.example/?code=anything' });
  await assert.rejects(foreign.auth.signIn(), authCode('unavailable'));
  assert.equal(foreign.location.assigned, null);
  const f = fixture();
  f.transactions.setItem = () => { throw new Error('storage denied'); };
  await assert.rejects(f.auth.signIn(), authCode('storage'));
  assert.equal(f.location.assigned, null);
});

test('callback cleans URL and consumes verifier before requests; only /user identity is published', async () => {
  const f = fixture({ href: `${REDIRECT_URL}?code=server-code&next=https://evil.example/`, handler(url, options) {
    assert.equal(f.location.href, REDIRECT_URL);
    assert.equal(f.transactions.getItem(PKCE_STORAGE_KEY), null);
    assert.equal(f.auth.getUser(), null);
    if (url.includes('/token?')) {
      assert.deepEqual(JSON.parse(options.body), { auth_code: 'server-code', code_verifier: 'a'.repeat(43) });
      return response(grant());
    }
    assert.equal(url, `${SUPABASE_URL}/auth/v1/user`);
    return response(user());
  } });
  f.transaction();
  const result = await f.auth.loadSession();
  assert.equal(result.user.id, ALICE);
  assert.equal(result.user.avatarURL, null);
  assert.equal(result.accessToken, undefined);
  const saved = f.storage.getItem(SESSION_STORAGE_KEY);
  assert.ok(!saved.includes('provider-token'));
  assert.ok(!saved.includes(BOB));
  for (const { options } of f.calls) {
    assert.equal(options.headers.apikey, PUBLISHABLE_KEY);
    assert.equal(options.redirect, 'error');
    assert.equal(options.credentials, 'omit');
    assert.equal(options.cache, 'no-store');
    assert.equal(options.referrerPolicy, 'no-referrer');
  }
  assert.ok(!JSON.stringify(f.events).includes(ACCESS));
  assert.equal(await f.auth.getAccessToken(), ACCESS);
});

test('missing, stale, duplicated, implicit and error callbacks never reach token endpoint', async () => {
  for (const item of [
    { search: '?code=x', missing: true },
    { search: '?code=x', age: 600_001 },
    { search: '?code=x&code=y' },
    { search: '#access_token=implicit&refresh_token=unsafe' },
    { search: '?error=denied&error_description=server-secret' },
  ]) {
    const f = fixture({ href: REDIRECT_URL + item.search });
    if (!item.missing) f.transaction(item.age ?? 0);
    await assert.rejects(f.auth.loadSession(), authCode('authentication'));
    assert.equal(f.location.href, REDIRECT_URL);
    assert.equal(f.transactions.getItem(PKCE_STORAGE_KEY), null);
    assert.equal(f.calls.length, 0);
    assert.equal(f.auth.getUser(), null);
  }
});

test('restored local session remains unavailable until server user validation completes', async () => {
  const wait = deferred();
  const f = fixture({ handler: () => wait.promise });
  f.seed();
  const first = f.auth.loadSession(), second = f.auth.loadSession();
  assert.equal(first, second);
  assert.equal(f.auth.getUser(), null);
  wait.resolve(response(user()));
  assert.equal((await first).user.id, ALICE);
  assert.equal(f.calls.length, 1);
});

test('forged stored identity and anonymous user invalidate session and private caches', async () => {
  for (const value of [user(BOB), { ...user(), is_anonymous: true }]) {
    const f = fixture({ handler: () => response(value) });
    f.seed();
    await assert.rejects(f.auth.loadSession(), authCode('authentication'));
    assert.equal(f.storage.getItem(SESSION_STORAGE_KEY), null);
    assert.equal(f.auth.getUser(), null);
    assert.equal(f.cleared.at(-1).reason, 'invalid-session');
  }
});

test('simultaneous expiry consumers rotate once and revalidate the renewed user', async () => {
  const f = fixture({ handler: url => response(url.includes('/token?') ? grant('refreshed-access-0123456789') : user()) });
  f.seed();
  await f.auth.loadSession();
  f.advance(3_550_000);
  const results = await Promise.all(Array.from({ length: 12 }, () => f.auth.getAccessToken()));
  assert.deepEqual(new Set(results), new Set(['refreshed-access-0123456789']));
  assert.equal(f.calls.filter(call => call.url.includes('/token?')).length, 1);
  assert.equal(f.calls.filter(call => call.url.endsWith('/user')).length, 2);
});

test('refresh re-reads rotated storage after acquiring the browser-wide lock', async () => {
  const locked = deferred();
  let f;
  const locks = { async request(name, options, operation) {
    assert.equal(name, SESSION_STORAGE_KEY);
    assert.equal(options.mode, 'exclusive');
    await locked.promise;
    return operation();
  } };
  f = fixture({ locks });
  f.seed({ expiresAt: START - 1 });
  const loading = f.auth.loadSession();
  f.seed({ accessToken: 'rotated-in-another-tab-0123456789' });
  locked.resolve();
  await loading;
  assert.equal(f.calls.length, 1);
  assert.equal(f.calls[0].options.headers.Authorization, 'Bearer rotated-in-another-tab-0123456789');
});

test('logout invalidates pending refresh immediately and cannot be resurrected by its response', async () => {
  const wait = deferred(), started = deferred();
  const f = fixture({ handler(url) {
    if (url.includes('/token?')) { started.resolve(); return wait.promise; }
    if (url.includes('/logout?')) return new Response(null, { status: 204 });
    return response(user());
  } });
  f.seed();
  await f.auth.loadSession();
  f.advance(3_550_000);
  const token = f.auth.getAccessToken();
  const rejected = assert.rejects(token, authCode('cancelled'));
  await started.promise;
  await f.auth.signOut();
  assert.equal(f.auth.getUser(), null);
  assert.equal(f.storage.getItem(SESSION_STORAGE_KEY), null);
  wait.resolve(response(grant()));
  await rejected;
  assert.equal(f.storage.getItem(SESSION_STORAGE_KEY), null);
  assert.ok(f.calls.some(call => call.url.endsWith('logout?scope=local')));
});

test('account callback waits for private cache cleanup before exchange or publication', async () => {
  const wait = deferred(), started = deferred();
  const f = fixture({ href: `${REDIRECT_URL}?code=new-account`, clearSecrets() { started.resolve(); return wait.promise; },
    handler: url => response(url.includes('/token?') ? grant() : user(BOB)),
  });
  f.seed();
  f.transaction();
  const loading = f.auth.loadSession();
  await started.promise;
  assert.equal(f.auth.getUser(), null);
  assert.equal(f.calls.length, 0);
  wait.resolve();
  assert.equal((await loading).user.id, BOB);
  assert.equal(f.cleared[0].previousUserId, ALICE);
});

test('failed private cleanup prevents account publication and authorization redirect', async () => {
  const f = fixture({ clearSecrets: () => { throw new Error('private details must not escape'); } });
  await assert.rejects(f.auth.signIn(), authCode('cleanup'));
  assert.equal(f.location.assigned, null);
  assert.equal(f.auth.getUser(), null);
  await assert.rejects(f.auth.loadSession(), authCode('cleanup'));
  assert.equal(f.calls.length, 0);
});

test('failed account exchange cannot restore the previous account on retry', async () => {
  const f = fixture({ href: `${REDIRECT_URL}?code=new-account`, handler: () => { throw new TypeError('offline'); } });
  f.seed();
  f.transaction();
  await assert.rejects(f.auth.loadSession(), authCode('connection'));
  assert.equal(f.storage.getItem(SESSION_STORAGE_KEY), null);
  assert.equal(await f.auth.loadSession(), null);
  assert.equal(f.auth.getUser(), null);
});

test('external account replacement invalidates in-flight verification and clears old private state', async () => {
  const wait = deferred(), started = deferred();
  const f = fixture({ handler: () => { started.resolve(); return wait.promise; } });
  f.seed();
  const loading = f.auth.loadSession();
  const rejected = assert.rejects(loading, authCode('cancelled'));
  await started.promise;
  f.seed({ id: BOB });
  f.storageEvent(f.storage.getItem(SESSION_STORAGE_KEY));
  wait.resolve(response(user()));
  await rejected;
  assert.equal(f.auth.getUser(), null);
  assert.equal(JSON.parse(f.storage.getItem(SESSION_STORAGE_KEY)).userId, BOB);
  assert.equal(f.cleared.at(-1).reason, 'external-session');
});

test('cached token access detects a storage logout even before the storage event arrives', async () => {
  const f = fixture();
  f.seed();
  await f.auth.loadSession();
  f.storage.removeItem(SESSION_STORAGE_KEY);
  await assert.rejects(f.auth.getAccessToken(), authCode('authentication'));
  assert.equal(f.auth.getUser(), null);
  assert.equal(f.cleared[0].previousUserId, ALICE);
});

test('offline validation exposes no cached user but preserves refresh material for retry', async () => {
  const f = fixture({ handler: () => { throw new TypeError('network failed'); } });
  f.seed();
  await assert.rejects(f.auth.loadSession(), authCode('connection'));
  assert.equal(f.auth.getUser(), null);
  assert.ok(f.storage.getItem(SESSION_STORAGE_KEY));
  await f.auth.signOut();
  assert.equal(f.storage.getItem(SESSION_STORAGE_KEY), null);
});

test('invalid and oversized server responses fail without trusting token claims', async () => {
  for (const result of [response({ error: 'not a user' }), response({ ...user(), padding: 'x'.repeat(65_536) })]) {
    const f = fixture({ handler: () => result });
    f.seed();
    await assert.rejects(f.auth.loadSession(), authCode('authentication'));
    assert.equal(f.auth.getUser(), null);
    assert.equal(f.storage.getItem(SESSION_STORAGE_KEY), null);
  }
});

test('disposed authentication cannot publish an outstanding verified response', async () => {
  const wait = deferred(), started = deferred();
  const f = fixture({ handler: () => { started.resolve(); return wait.promise; } });
  f.seed();
  const loading = f.auth.loadSession();
  const rejected = assert.rejects(loading, authCode('cancelled'));
  await started.promise;
  f.auth.dispose();
  wait.resolve(response(user()));
  await rejected;
  assert.equal(f.auth.getUser(), null);
});
