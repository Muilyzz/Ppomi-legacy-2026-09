import { RecordError, UUID, MAX_CHUNK_BYTES, recordVersion } from './record-crypto.js';

const namePattern = /^[A-Za-z][A-Za-z0-9._-]{0,63}$/;

export function validateRecordName(name) {
  if (!namePattern.test(name)) throw new RecordError('invalid');
}

export function validateKnownVersion(version) {
  if (version !== undefined && (typeof version !== 'string' || !/^[1-9][0-9]{0,18}$/.test(version)
    || BigInt(version) > 9223372036854775807n)) throw new RecordError('invalid');
}

/** Normalize server metadata against the device enrolled by this client. */
export function recordContext(value, deviceID) {
  if (!value || !UUID.test(value.workspace?.id) || value.device?.id !== deviceID || value.device?.platform !== 'web'
    || typeof value.workspace.name !== 'string' || value.workspace.name.length > 200
    || typeof value.device.label !== 'string' || value.device.label.length > 120) throw new RecordError('invalid');
  return Object.freeze({ workspace: Object.freeze({ id: value.workspace.id, name: value.workspace.name }),
    device: Object.freeze({ id: value.device.id, label: value.device.label, platform: 'web' }) });
}

/** Only metadata is trusted here; unwrapRecordKey authenticates the wrapped key. */
export function keyDelivery(value, workspaceID) {
  if (value?.found === false) return null;
  if (value?.found !== true || value.workspace_id !== workspaceID || !UUID.test(value.key_id)
    || !value.records || typeof value.records !== 'object' || Array.isArray(value.records)) throw new RecordError('invalid');
  const entries = Object.entries(value.records);
  if (!entries.length || entries.length > 64 || entries.some(([name, id]) => !namePattern.test(name) || !UUID.test(id))) throw new RecordError('invalid');
  return Object.freeze({ workspaceID: value.workspace_id, keyID: value.key_id, wrapped: value.wrapped,
    records: Object.freeze(Object.fromEntries(entries)) });
}

/** A head is metadata, not proof of decryption. Keep the previous-head check in the client. */
export function recordHead(value, { workspaceID, recordID }) {
  if (value?.found === false) throw new RecordError('missing');
  if (value?.found !== true || value.record_id !== recordID || value.workspace_id !== workspaceID || !UUID.test(value.key_id)
    || !UUID.test(value.writer_device_id) || !Array.isArray(value.chunk_ids) || value.chunk_ids.length < 1 || value.chunk_ids.length > 1024
    || value.chunk_ids.some(hash => typeof hash !== 'string' || !/^[0-9a-f]{64}$/.test(hash))) throw new RecordError('invalid');
  const version = recordVersion(value.version);
  return Object.freeze({ version, keyID: value.key_id, chunkIDs: Object.freeze([...value.chunk_ids]),
    updatedAt: typeof value.updated_at === 'string' ? value.updated_at : null,
    identity: Object.freeze({ version, workspaceID, recordID, keyID: value.key_id,
      writerID: value.writer_device_id, chunks: value.chunk_ids.join(',') }) });
}

/** Ciphertext decoding, length, hash and AES-GCM checks remain in the client/crypto layer. */
export function recordBlob(value, hash) {
  if (!value || value.hash !== hash || !Number.isSafeInteger(value.size) || value.size < 28 || value.size > MAX_CHUNK_BYTES) throw new RecordError('invalid');
  return Object.freeze({ size: value.size, data: value.data });
}
