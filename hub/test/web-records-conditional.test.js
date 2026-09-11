import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { webcrypto } from 'node:crypto';
import { createRecordClient } from '../web/records.js';
import { RecordError, unbase64 } from '../web/record-crypto.js';

const f = JSON.parse(await readFile(new URL('./fixtures/web-records-native.json', import.meta.url), 'utf8'));
const response = value => new Response(JSON.stringify(value));
async function setup() {
  const pkcs8 = Buffer.concat([Buffer.from('302e020100300506032b656e04220420', 'hex'), Buffer.from(f.privateKey, 'base64')]);
  const privateKey = await webcrypto.subtle.importKey('pkcs8', pkcs8, 'X25519', false, ['deriveBits']);
  const device = { formatVersion: 1, userID: f.userID, deviceID: f.deviceID, privateKey, publicKey: unbase64(f.publicKey, 32) };
  const calls = [];
  let decompressions = 0, changedWorkspace = false, changedChunk = false;
  const user = { id: f.userID };
  const client = createRecordClient({ auth: { getUser: () => user, getAccessToken: async () => 'synthetic-access-token' }, user,
    crypto: webcrypto, deviceStore: { loadOrCreate: async () => device, clear: async () => {} },
    // These tests exercise conditional reads after real native AES-GCM checks;
    // decompression itself is covered by the separate native WASM fixture test.
    decode: async () => { decompressions++; return new TextEncoder().encode('{"amount":1}'); },
    fetch: async url => {
      const name = url.split('/').at(-1); calls.push(name);
      if (name === 'ppomi_register_device' || name === 'ppomi_context') return response({ workspace: { id: f.workspaceID, name: 'Synthetic' }, device: { id: f.deviceID, label: 'Browser', platform: 'web' } });
      if (name === 'ppomi_key_get') return response({ found: true, workspace_id: f.workspaceID, key_id: f.keyID, records: { accounting: f.recordID }, wrapped: f.wrapped });
      if (name === 'ppomi_record_get') return new Response(JSON.stringify({ found: true, record_id: f.recordID,
        workspace_id: changedWorkspace ? 'ffffffff-ffff-4fff-8fff-ffffffffffff' : f.workspaceID,
        key_id: f.keyID, writer_device_id: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee', version: 'VERSION_LITERAL',
        chunk_ids: changedChunk ? ['0'.repeat(64)] : f.chunks.map(chunk => chunk.hash) }).replace('"VERSION_LITERAL"', f.version));
      if (name === 'ppomi_record_blob_get') return response(f.chunks[0]);
      throw new Error('Unexpected RPC');
    },
  });
  return { client, calls, count: () => decompressions, changeWorkspace: () => { changedWorkspace = true; }, changeChunk: () => { changedChunk = true; } };
}

test('initial known-version request still decrypts; verified unchanged head skips blobs and decoding', async () => {
  const e = await setup();
  const first = await e.client.read('accounting', { knownVersion: f.version });
  assert.equal(first.unchanged, undefined);
  assert.equal(first.json.amount, 1);
  const before = e.calls.length;
  const next = await e.client.read('accounting', { knownVersion: f.version });
  assert.deepEqual(next, { name: 'accounting', version: f.version, unchanged: true });
  assert.deepEqual(e.calls.slice(before), ['ppomi_record_get']);
  assert.equal(e.count(), 1);
});

test('unconditional and nonmatching-version requests still return full records', async () => {
  const e = await setup();
  await e.client.read('accounting');
  const [conditional, full] = await Promise.all([
    e.client.read('accounting', { knownVersion: f.version }), e.client.read('accounting'),
  ]);
  assert.equal(conditional.unchanged, true);
  assert.equal(full.json.amount, 1);
  const mismatched = await e.client.read('accounting', { knownVersion: '1' });
  assert.equal(mismatched.json.amount, 1);
  assert.equal(e.count(), 3);
});

test('same version cannot hide workspace or chunk changes behind an unchanged response', async () => {
  for (const change of ['changeWorkspace', 'changeChunk']) {
    const e = await setup();
    await e.client.read('accounting');
    e[change]();
    await assert.rejects(e.client.read('accounting', { knownVersion: f.version }), error => error instanceof RecordError && error.code === 'invalid');
    assert.equal(e.count(), 1);
  }
});

test('known version must be a canonical positive Int64 string', async () => {
  const e = await setup();
  for (const value of [1, '01', '-1', '9223372036854775808']) {
    await assert.rejects(e.client.read('accounting', { knownVersion: value }), error => error instanceof RecordError && error.code === 'invalid');
  }
  assert.equal(e.calls.length, 0);
});
