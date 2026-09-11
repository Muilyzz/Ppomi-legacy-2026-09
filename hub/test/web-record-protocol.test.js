import { test } from 'node:test';
import assert from 'node:assert/strict';
import { RecordError, MAX_CHUNK_BYTES, parseExactJSON } from '../web/record-crypto.js';
import { validateRecordName, validateKnownVersion, recordContext, keyDelivery, recordHead, recordBlob } from '../web/record-protocol.js';

const workspaceID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const deviceID = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const recordID = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const keyID = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
const writerID = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
const otherID = 'ffffffff-ffff-4fff-8fff-ffffffffffff';
const hash = 'ab'.repeat(32), nextHash = 'cd'.repeat(32);
const fails = code => error => error instanceof RecordError && error.code === code;
const context = () => ({ workspace: { id: workspaceID, name: 'Family' }, device: { id: deviceID, label: 'Browser', platform: 'web' } });
const delivery = () => ({ found: true, workspace_id: workspaceID, key_id: keyID, records: { ledger: recordID }, wrapped: 'opaque-key-wrap' });
const head = () => ({ found: true, workspace_id: workspaceID, record_id: recordID, key_id: keyID,
  writer_device_id: writerID, version: 1, chunk_ids: [hash, nextHash], updated_at: '2026-09-11T00:00:00Z' });
const binding = { workspaceID, recordID };

test('context exposes frozen display metadata only and binds the enrolled web device', () => {
  const wire = context();
  wire.workspace.secret = 'not-display-state';
  wire.device.public_key = 'not-display-state';
  const result = recordContext(wire, deviceID);
  assert.deepEqual(result, context());
  assert.ok(Object.isFrozen(result) && Object.isFrozen(result.workspace) && Object.isFrozen(result.device));
  wire.workspace.name = 'Changed later';
  assert.equal(result.workspace.name, 'Family');
  for (const value of [null, {}, { ...context(), workspace: { id: 'bad', name: 'Family' } },
    { ...context(), device: { ...context().device, id: otherID } },
    { ...context(), device: { ...context().device, platform: 'macOS' } },
    { ...context(), workspace: { id: workspaceID, name: 'x'.repeat(201) } },
    { ...context(), device: { ...context().device, label: 'x'.repeat(121) } }]) {
    assert.throws(() => recordContext(value, deviceID), fails('invalid'));
  }
});

test('key delivery preserves the waiting sentinel and copies the workspace-bound record map', () => {
  assert.equal(keyDelivery({ found: false }, workspaceID), null);
  const wire = delivery(), result = keyDelivery(wire, workspaceID);
  assert.deepEqual(result, { workspaceID, keyID, records: { ledger: recordID }, wrapped: wire.wrapped });
  assert.ok(Object.isFrozen(result) && Object.isFrozen(result.records));
  wire.records.ledger = otherID;
  assert.equal(result.records.ledger, recordID);
  for (const value of [null, {}, { ...delivery(), found: 'true' }, { ...delivery(), workspace_id: otherID },
    { ...delivery(), key_id: 'bad' }, { ...delivery(), records: [] }, { ...delivery(), records: {} },
    { ...delivery(), records: { ledger: 'bad' } }, { ...delivery(), records: { 'ledger/path': recordID } }]) {
    assert.throws(() => keyDelivery(value, workspaceID), fails('invalid'));
  }
});

test('key delivery enforces the record count and name bounds before key unwrapping', () => {
  const records = Object.fromEntries(Array.from({ length: 64 }, (_, i) => [`record${i}`, recordID]));
  assert.equal(Object.keys(keyDelivery({ ...delivery(), records }, workspaceID).records).length, 64);
  records.extra = recordID;
  assert.throws(() => keyDelivery({ ...delivery(), records }, workspaceID), fails('invalid'));
  assert.doesNotThrow(() => keyDelivery({ ...delivery(), records: { ['a'.repeat(64)]: recordID } }, workspaceID));
  assert.throws(() => keyDelivery({ ...delivery(), records: { ['a'.repeat(65)]: recordID } }, workspaceID), fails('invalid'));
});

test('record head keeps native Int64 versions exact without accepting rounded numbers or strings', () => {
  const wire = parseExactJSON(JSON.stringify(head()).replace('"version":1,', '"version":9223372036854775807,'));
  const result = recordHead(wire, binding);
  assert.equal(result.version, '9223372036854775807');
  assert.equal(result.identity.version, result.version);
  for (const version of ['1', 0, -1, 1.5, Number.MAX_SAFE_INTEGER + 1, 9223372036854775808n]) {
    assert.throws(() => recordHead({ ...head(), version }, binding), fails('invalid'));
  }
});

test('record head rejects another workspace or record and preserves the missing response', () => {
  assert.throws(() => recordHead({ found: false }, binding), fails('missing'));
  for (const value of [null, {}, { ...head(), found: 1 }, { ...head(), workspace_id: otherID },
    { ...head(), record_id: otherID }, { ...head(), key_id: 'bad' }, { ...head(), writer_device_id: 'bad' }]) {
    assert.throws(() => recordHead(value, binding), fails('invalid'));
  }
});

test('head identity binds version, workspace, record, key, writer and ordered chunks', () => {
  const wire = head(), result = recordHead(wire, binding);
  assert.deepEqual(result.identity, { version: '1', workspaceID, recordID, keyID, writerID, chunks: `${hash},${nextHash}` });
  assert.ok(Object.isFrozen(result) && Object.isFrozen(result.identity) && Object.isFrozen(result.chunkIDs));
  wire.chunk_ids.reverse();
  assert.deepEqual(result.chunkIDs, [hash, nextHash]);
  for (const changed of [{ version: 2 }, { key_id: otherID }, { writer_device_id: otherID },
    { chunk_ids: [nextHash, hash] }, { chunk_ids: [hash] }]) {
    assert.notDeepEqual(recordHead({ ...head(), ...changed }, binding).identity, result.identity);
  }
  assert.notDeepEqual(recordHead({ ...head(), workspace_id: otherID }, { ...binding, workspaceID: otherID }).identity, result.identity);
  assert.notDeepEqual(recordHead({ ...head(), record_id: otherID }, { ...binding, recordID: otherID }).identity, result.identity);
  assert.equal(recordHead({ ...head(), updated_at: null }, binding).updatedAt, null);
});

test('head chunk metadata rejects malformed hashes and over-limit manifests', () => {
  for (const chunk_ids of [null, {}, [], [hash.toUpperCase()], ['a'.repeat(63)], [1], Array(1025).fill(hash)]) {
    assert.throws(() => recordHead({ ...head(), chunk_ids }, binding), fails('invalid'));
  }
  assert.equal(recordHead({ ...head(), chunk_ids: Array(1024).fill(hash) }, binding).chunkIDs.length, 1024);
});

test('blob metadata binds the requested hash and exact ciphertext size bounds', () => {
  const wire = { hash, size: 28, data: 'opaque-ciphertext', extra: 'ignored' };
  assert.deepEqual(recordBlob(wire, hash), { size: 28, data: 'opaque-ciphertext' });
  assert.ok(Object.isFrozen(recordBlob(wire, hash)));
  assert.doesNotThrow(() => recordBlob({ ...wire, size: MAX_CHUNK_BYTES }, hash));
  assert.throws(() => recordBlob({ ...wire, hash: nextHash }, hash), fails('invalid'));
  for (const size of [27, MAX_CHUNK_BYTES + 1, 28.5, '28', 28n, Number.MAX_SAFE_INTEGER + 1]) {
    assert.throws(() => recordBlob({ ...wire, size }, hash), fails('invalid'));
  }
});

test('known versions accept only canonical positive Int64 strings or an absent condition', () => {
  for (const version of [undefined, '1', '9223372036854775807']) assert.doesNotThrow(() => validateKnownVersion(version));
  for (const version of [null, 1, 1n, '', '0', '01', '-1', '+1', ' 1', '1.0', '1e3', '9223372036854775808']) {
    assert.throws(() => validateKnownVersion(version), fails('invalid'));
  }
});

test('record names preserve the shared ASCII name grammar', () => {
  for (const name of ['ledger', 'Ledger.v1_2-3', 'a'.repeat(64)]) assert.doesNotThrow(() => validateRecordName(name));
  for (const name of ['', '_ledger', '1ledger', 'ledger/path', 'ledger name', '장부', 'a'.repeat(65)]) {
    assert.throws(() => validateRecordName(name), fails('invalid'));
  }
});
