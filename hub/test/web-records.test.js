import { test } from 'node:test';
import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { createRecordClient, createDeviceStore } from '../web/records.js';
import { RecordError, MAX_RECORD_BYTES, unbase64, sha256 } from '../web/record-crypto.js';

const f = JSON.parse(await readFile(new URL('./fixtures/web-records-native.json', import.meta.url), 'utf8'));
const response = value => new Response(JSON.stringify(value), { headers: { 'Content-Type': 'application/json' } });
const fails = code => error => error instanceof RecordError && error.code === code;
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
// Node has no browser Worker. Exercise the actual checked-in WASM here; the
// production Worker transport/cancellation is separately exercised in-browser.
async function wasmDecode(bytes, { maxOutputBytes, signal }) {
  assert.equal(signal.aborted, false);
  const wasm = await readFile(new URL('../web/vendor/lzfse.wasm', import.meta.url));
  const { instance } = await WebAssembly.instantiate(wasm, {
    env: { emscripten_notify_memory_growth() {} },
    wasi_snapshot_preview1: { fd_close: () => 0, fd_write: () => 52, fd_seek: () => 52 },
  });
  const e = instance.exports; e._initialize?.();
  const source = e.malloc(bytes.length);
  assert.ok(source);
  new Uint8Array(e.memory.buffer, source, bytes.length).set(bytes);
  let capacity = Math.min(maxOutputBytes, 65_536);
  try {
    for (;;) {
      const destination = e.malloc(capacity);
      assert.ok(destination);
      const size = e.ppomi_decode(destination, capacity, source, bytes.length);
      if (size >= 0) return new Uint8Array(e.memory.buffer, destination, size).slice();
      e.free(destination);
      if (size !== -2) throw new RecordError('invalid');
      if (capacity === maxOutputBytes) throw new RecordError('oversized');
      capacity = Math.min(maxOutputBytes, capacity * 2);
    }
  } finally { new Uint8Array(e.memory.buffer).fill(0); }
}
async function environment(options = {}) {
  const pkcs8 = Buffer.concat([Buffer.from('302e020100300506032b656e04220420', 'hex'), Buffer.from(f.privateKey, 'base64')]);
  const privateKey = await webcrypto.subtle.importKey('pkcs8', pkcs8, 'X25519', false, ['deriveBits']);
  const device = { formatVersion: 1, userID: f.userID, deviceID: f.deviceID, privateKey, publicKey: unbase64(f.publicKey, 32) };
  let current = { id: f.userID }, clearCount = 0;
  const calls = [], states = [];
  const context = { workspace: { id: f.workspaceID, name: 'Synthetic workspace' }, device: { id: f.deviceID, label: 'Synthetic browser', platform: 'web' } };
  const defaultResponse = name => {
    if (name === 'ppomi_register_device' || name === 'ppomi_context') return response(context);
    if (name === 'ppomi_key_get') return response({ found: true, workspace_id: f.workspaceID, key_id: f.keyID, records: { accounting: f.recordID }, wrapped: f.wrapped });
    if (name === 'ppomi_record_get') return new Response(JSON.stringify({ found: true, record_id: f.recordID, workspace_id: f.workspaceID,
      key_id: f.keyID, writer_device_id: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee', version: 'VERSION_LITERAL',
      chunk_ids: f.chunks.map(chunk => chunk.hash), updated_at: '2026-09-11T00:00:00Z' }).replace('"VERSION_LITERAL"', f.version));
    if (name === 'ppomi_record_blob_get') return response(f.chunks[0]);
    throw new Error('Unexpected RPC');
  };
  const client = createRecordClient({ auth: { getUser: () => current, getAccessToken: async () => 'synthetic-access-token' },
    user: current, crypto: webcrypto, onState: state => states.push(state),
    deviceStore: { loadOrCreate: async () => structuredClone(device), clear: async () => { clearCount++; } },
    ...(options.decode ? { decode: options.decode } : {}),
    fetch: async (url, request) => {
      const name = url.split('/').at(-1);
      calls.push({ name, url, request });
      return options.handler ? options.handler(name, request, defaultResponse) : defaultResponse(name);
    },
  });
  return { client, calls, states, context, setUser: value => { current = value; }, cleared: () => clearCount };
}

test('native ciphertext → WebCrypto → real LZFSE WASM preserves bytes and Int64 JSON', async () => {
  const e = await environment({ decode: wasmDecode });
  const connected = await e.client.connect();
  assert.equal(connected.status, 'ready');
  assert.deepEqual(connected.recordNames, ['accounting']);
  const record = await e.client.read('accounting');
  assert.equal(record.version, f.version);
  assert.equal(record.bytes.length, f.plainBytes);
  assert.equal(await sha256(record.bytes, webcrypto), f.plainSHA256);
  assert.equal(record.json.amount, 9223372036854775807n);
  assert.equal(record.json.negative, -9223372036854775808n);
  assert.match(record.text, /9223372036854775807/);
  assert.ok(!JSON.stringify(e.states).includes(f.wrapped));
  for (const { name, request } of e.calls) {
    assert.ok(['ppomi_register_device', 'ppomi_context', 'ppomi_key_get', 'ppomi_record_get', 'ppomi_record_blob_get'].includes(name));
    assert.equal(request.headers['X-Ppomi-Device'], f.deviceID);
    assert.equal(request.redirect, 'error');
    assert.equal(request.cache, 'no-store');
    assert.equal(request.credentials, 'omit');
    assert.ok(!request.body.includes(f.privateKey));
    assert.ok(!request.body.includes(f.wrapped));
  }
  const registration = JSON.parse(e.calls[0].request.body);
  assert.equal(registration.p_platform, 'web');
  assert.equal(registration.p_public_key, f.publicKey);
  e.client.dispose();
});

test('concurrent connections share a request while a completed connection can refresh', async () => {
  const e = await environment();
  const first = e.client.connect();
  assert.equal(e.client.connect(), first);
  await first;
  const refreshed = e.client.connect();
  assert.notEqual(refreshed, first);
  assert.equal((await refreshed).status, 'ready');
  assert.equal(e.calls.filter(call => call.name === 'ppomi_register_device').length, 1);
  assert.equal(e.calls.filter(call => call.name === 'ppomi_context').length, 2);
  assert.equal(e.calls.filter(call => call.name === 'ppomi_key_get').length, 2);
  e.client.dispose();
});

test('failed connection and record requests can be retried immediately after awaiting them', async () => {
  let contextAttempts = 0, recordAttempts = 0;
  const e = await environment({
    handler: (name, _request, next) => {
      if (name === 'ppomi_context' && ++contextAttempts === 1) return new Response(null, { status: 503 });
      if (name === 'ppomi_record_get' && ++recordAttempts === 1) return new Response(null, { status: 503 });
      return next(name);
    },
    decode: async () => new TextEncoder().encode('{"amount":1}'),
  });
  await assert.rejects(e.client.connect(), fails('connection'));
  assert.equal((await e.client.connect()).status, 'ready');
  await assert.rejects(e.client.read('accounting'), fails('connection'));
  const retry = e.client.read('accounting');
  assert.equal(e.client.read('accounting'), retry);
  const record = await retry;
  assert.equal(record.json.amount, 1);
  assert.equal(contextAttempts, 2);
  assert.equal(recordAttempts, 2);
  record.bytes.fill(0);
  e.client.dispose();
});

test('key delivery waiting state does not manufacture empty or plaintext records', async () => {
  const e = await environment({ handler: (name, _request, next) => name === 'ppomi_key_get' ? response({ found: false }) : next(name) });
  assert.equal((await e.client.connect()).status, 'waiting-key');
  await assert.rejects(e.client.read('accounting'), fails('waiting'));
  assert.equal(e.calls.filter(call => call.name === 'ppomi_register_device').length, 1);
  assert.ok(!e.calls.some(call => call.name === 'ppomi_record_blob_get'));
});

test('registration/context and head workspace mismatches reject before blob download', async () => {
  for (const stage of ['context', 'head']) {
    const e = await environment({ handler: async (name, _request, next) => {
      const reply = await next(name);
      if (stage === 'context' && name === 'ppomi_context') {
        const value = await reply.json(); value.workspace.id = 'ffffffff-ffff-4fff-8fff-ffffffffffff'; return response(value);
      }
      if (stage === 'head' && name === 'ppomi_record_get') {
        const source = await reply.text(); return new Response(source.replace(f.workspaceID, 'ffffffff-ffff-4fff-8fff-ffffffffffff'));
      }
      return reply;
    } });
    await assert.rejects(stage === 'context' ? e.client.connect() : e.client.read('accounting'), fails('invalid'));
    assert.ok(!e.calls.some(call => call.name === 'ppomi_record_blob_get'));
  }
});

test('bad ciphertext and decompression output bounds never reach the record view', async () => {
  const altered = await environment({ handler: (name, _request, next) => name === 'ppomi_record_blob_get'
    ? response({ ...f.chunks[0], data: Buffer.alloc(f.chunks[0].size).toString('base64') }) : next(name) });
  await assert.rejects(altered.client.read('accounting'), fails('invalid'));
  const bounded = await environment({ decode: async (_bytes, options) => {
    assert.equal(options.maxOutputBytes, MAX_RECORD_BYTES);
    throw new RecordError('oversized');
  } });
  await assert.rejects(bounded.client.read('accounting'), fails('oversized'));
});

test('account change cancels pending record response and disposal clears only memory', async () => {
  const wait = deferred(), started = deferred();
  const e = await environment({ handler: (name, _request, next) => {
    if (name === 'ppomi_record_get') { started.resolve(); return wait.promise; }
    return next(name);
  } });
  const reading = e.client.read('accounting');
  const rejected = assert.rejects(reading, fails('cancelled'));
  await started.promise;
  e.setUser(null); e.client.dispose();
  wait.resolve(response({ found: false }));
  await rejected;
  assert.equal(e.cleared(), 0);
  await e.client.clearPrivate();
  assert.equal(e.cleared(), 1);
});

test('decompression is cancelled and plaintext is not returned after logout', async () => {
  const wait = deferred(), started = deferred();
  let signal;
  const e = await environment({ decode: async (_bytes, options) => { signal = options.signal; started.resolve(); return wait.promise; } });
  const reading = e.client.read('accounting');
  const rejected = assert.rejects(reading, fails('cancelled'));
  await started.promise;
  e.client.dispose();
  assert.equal(signal.aborted, true);
  const plaintext = new TextEncoder().encode('{"secret":1}');
  wait.resolve(plaintext);
  await rejected;
  assert.ok(plaintext.every(byte => byte === 0));
});

test('a browser without IndexedDB reports unsupported rather than using localStorage keys', async () => {
  const store = createDeviceStore({ indexedDB: null, crypto: webcrypto });
  await assert.rejects(store.loadOrCreate(f.userID), fails('unsupported'));
});

test('device store restores non-extractable keys by account and deletes only the selected account', async () => {
  const rows = new Map();
  // A minimal transaction fake uses the platform structuredClone, not JSON key
  // serialization, and verifies the store's restore/add/delete sequencing.
  const indexedDB = { open() {
    const request = {};
    queueMicrotask(() => {
      request.result = { createObjectStore() {}, transaction() {
        const tx = {};
        tx.objectStore = () => {
          const operation = action => {
            const call = {};
            queueMicrotask(() => {
              try { call.result = action(); call.onsuccess?.(); tx.oncomplete?.(); }
              catch { tx.onerror?.(); }
            });
            return call;
          };
          return {
            get: id => operation(() => structuredClone(rows.get(id))),
            add: value => operation(() => { if (rows.has(value.userID)) throw new Error('duplicate'); rows.set(value.userID, structuredClone(value)); }),
            delete: id => operation(() => rows.delete(id)),
          };
        };
        return tx;
      } };
      request.onupgradeneeded?.(); request.onsuccess?.();
    });
    return request;
  } };
  const a = createDeviceStore({ indexedDB, crypto: webcrypto });
  const first = await a.loadOrCreate(f.userID);
  const b = createDeviceStore({ indexedDB, crypto: webcrypto });
  const restored = await b.loadOrCreate(f.userID);
  assert.equal(restored.deviceID, first.deviceID);
  assert.equal(restored.privateKey.extractable, false);
  const otherID = '22222222-2222-4222-8222-222222222222';
  const other = await b.loadOrCreate(otherID);
  assert.notEqual(other.deviceID, first.deviceID);
  await a.clear(f.userID);
  assert.equal(rows.has(f.userID), false);
  assert.equal(rows.has(otherID), true);
  assert.notEqual((await a.loadOrCreate(f.userID)).deviceID, first.deviceID);
});
