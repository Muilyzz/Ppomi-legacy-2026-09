import { test } from 'node:test';
import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { generateDevice, verifyDevice, unwrapRecordKey, decryptRecordChunk, unbase64, base64,
  RecordError, parseExactJSON, recordVersion } from '../web/record-crypto.js';

const f = JSON.parse(await readFile(new URL('./fixtures/web-records-native.json', import.meta.url), 'utf8'));
const fails = code => error => error instanceof RecordError && error.code === code;
async function fixtureDevice() {
  // RFC 8410 PKCS8 framing around a public TEST-ONLY deterministic private seed.
  const raw = Buffer.from(f.privateKey, 'base64');
  const pkcs8 = Buffer.concat([Buffer.from('302e020100300506032b656e04220420', 'hex'), raw]);
  const privateKey = await webcrypto.subtle.importKey('pkcs8', pkcs8, 'X25519', false, ['deriveBits']);
  return { formatVersion: 1, userID: f.userID, deviceID: f.deviceID, privateKey, publicKey: unbase64(f.publicKey, 32) };
}

test('non-extractable X25519 survives structured cloning and still derives the matching public key', async () => {
  const created = await generateDevice(f.userID, webcrypto);
  const restored = structuredClone(created);
  assert.equal(restored.privateKey.extractable, false);
  assert.equal((await verifyDevice(restored, f.userID, webcrypto)).deviceID, created.deviceID);
  await assert.rejects(webcrypto.subtle.exportKey('pkcs8', restored.privateKey));
  const other = await generateDevice(f.userID, webcrypto);
  await assert.rejects(verifyDevice({ ...restored, publicKey: other.publicKey }, f.userID, webcrypto), fails('unsupported'));
  await assert.rejects(verifyDevice(restored, '22222222-2222-4222-8222-222222222222', webcrypto), fails('unsupported'));
});

test('browsers without X25519 fail explicitly rather than storing an extractable replacement', async () => {
  await assert.rejects(generateDevice(f.userID, { subtle: { generateKey() { throw new DOMException('Unsupported', 'NotSupportedError'); } } }), fails('unsupported'));
});

test('actual Swift KeyWrap fixture unwraps to a non-extractable AES key and decrypts native LZFSE bytes', async () => {
  const device = await fixtureDevice();
  await verifyDevice(device, f.userID, webcrypto);
  const key = await unwrapRecordKey({ ...f, device }, webcrypto);
  assert.equal(key.extractable, false);
  assert.deepEqual(key.usages, ['decrypt']);
  await assert.rejects(webcrypto.subtle.exportKey('raw', key));
  const chunk = f.chunks[0];
  const bytes = await decryptRecordChunk({ ...f, key, part: 0, bytes: unbase64(chunk.data, 409600), hash: chunk.hash }, webcrypto);
  assert.ok(bytes.length > 4);
  assert.equal(new TextDecoder().decode(bytes.subarray(0, 3)), 'bvx');
});

test('wrapped-key tampering and workspace/key binding changes reject the native fixture', async () => {
  const device = await fixtureDevice();
  const modified = unbase64(f.wrapped, 92); modified[91] ^= 1;
  for (const change of [{ wrapped: base64(modified) }, { workspaceID: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee' },
    { keyID: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee' }]) {
    await assert.rejects(unwrapRecordKey({ ...f, ...change, device }, webcrypto), fails('invalid'));
  }
});

test('ciphertext SHA256 and record/part/version AAD prevent substitution', async () => {
  const device = await fixtureDevice(), key = await unwrapRecordKey({ ...f, device }, webcrypto);
  const chunk = f.chunks[0], bytes = unbase64(chunk.data, 409600);
  for (const change of [{ hash: '0'.repeat(64) }, { part: 1 }, { version: '1' },
    { recordID: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee' }]) {
    await assert.rejects(decryptRecordChunk({ ...f, key, bytes, hash: chunk.hash, part: 0, ...change }, webcrypto), fails('invalid'));
  }
});

test('JSON parser preserves native Int64 values and protects structural keys', () => {
  const parsed = parseExactJSON('{"maximum":9223372036854775807,"minimum":-9223372036854775808,"safe":9007199254740991,"fraction":1.25,"__proto__":{"polluted":true},"items":[null,true,"a\\\"b"]}');
  assert.equal(parsed.maximum, 9223372036854775807n);
  assert.equal(parsed.minimum, -9223372036854775808n);
  assert.equal(parsed.safe, 9007199254740991);
  assert.equal(parsed.fraction, 1.25);
  assert.equal(Object.getPrototypeOf(parsed), null);
  assert.equal({}.polluted, undefined);
  assert.deepEqual(parsed.items, [null, true, 'a"b']);
  assert.equal(recordVersion(parsed.maximum), '9223372036854775807');
  assert.throws(() => recordVersion(Number(parsed.maximum)), fails('invalid'));
});

test('malformed, duplicate, trailing and excessive-depth JSON cannot silently alter records', () => {
  for (const source of ['{"a":1,"a":2}', '[1,]', '{"a":01}', '{"a":NaN}', 'true false', '"unterminated',
    '['.repeat(130) + '0' + ']'.repeat(130), '1'.repeat(129)]) {
    assert.throws(() => parseExactJSON(source), fails('invalid'));
  }
});

test('base64 parser rejects noncanonical, malformed and oversized wire values', () => {
  assert.deepEqual(unbase64('AQ==', 1), new Uint8Array([1]));
  for (const value of ['AQ', 'AR==', 'AQ==\n', 'AAAA']) assert.throws(() => unbase64(value, 1), fails('invalid'));
});
