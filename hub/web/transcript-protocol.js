import { RecordError, UUID, recordVersion } from './record-crypto.js';

const rolePattern = /^(user|assistant)$/;
const partTypes = new Set(['text', 'reasoning', 'tool']);

function optionalUUID(value) {
  if (value == null) return null;
  if (!UUID.test(value)) throw new RecordError('invalid');
  return value;
}

export function transcriptHead(value) {
  if (!value || !UUID.test(value.id) || !UUID.test(value.workspace_id)) throw new RecordError('invalid');
  return Object.freeze({
    id: value.id,
    workspaceID: value.workspace_id,
    createdByUserID: optionalUUID(value.created_by_user_id),
    createdByDeviceID: optionalUUID(value.created_by_device_id),
    createdAt: typeof value.created_at === 'string' ? value.created_at : null,
    updatedAt: typeof value.updated_at === 'string' ? value.updated_at : null,
  });
}

export function transcriptList(value) {
  const rows = Array.isArray(value) ? value : value?.transcripts;
  if (!Array.isArray(rows) || rows.length > 50) throw new RecordError('invalid');
  return Object.freeze(rows.map(item => {
    const head = transcriptHead(item);
    const seq = item.last_seq === 0 || item.last_seq === 0n || item.last_seq === '0' ? '0' : recordVersion(item.last_seq);
    return Object.freeze({ ...head, lastSeq: seq });
  }));
}

export function transcriptPayload(value) {
  if (!value || !UUID.test(value.id) || !rolePattern.test(value.role) || !Array.isArray(value.parts)
    || value.parts.length > 32) throw new RecordError('invalid');
  const parts = value.parts.map(part => {
    if (!part || !partTypes.has(part.type)) throw new RecordError('invalid');
    if (part.type === 'tool') {
      if (typeof part.name !== 'string' || part.name.length < 1 || part.name.length > 80) throw new RecordError('invalid');
      return Object.freeze({ type: 'tool', name: part.name, state: typeof part.state === 'string' ? part.state : 'done' });
    }
    if (typeof part.text !== 'string' || part.text.length > 16_000) throw new RecordError('invalid');
    return Object.freeze({ type: part.type, text: part.text });
  });
  return Object.freeze({ id: value.id, role: value.role, parts });
}

export function transcriptTurnRow(value, { workspaceID, transcriptID } = {}) {
  if (!value || !UUID.test(value.turn_id) || !value.payload || typeof value.payload !== 'object') {
    throw new RecordError('invalid');
  }
  const seq = recordVersion(value.seq);
  if (workspaceID && value.workspace_id && value.workspace_id !== workspaceID) throw new RecordError('invalid');
  if (transcriptID && value.transcript_id && value.transcript_id !== transcriptID) throw new RecordError('invalid');
  return Object.freeze({
    turnID: value.turn_id,
    seq,
    writerUserID: optionalUUID(value.writer_user_id),
    writerDeviceID: optionalUUID(value.writer_device_id),
    payload: transcriptPayload(value.payload),
    createdAt: typeof value.created_at === 'string' ? value.created_at : null,
  });
}

export function transcriptTurnPage(value, transcriptID) {
  if (value?.found === false) return Object.freeze({ found: false, turns: Object.freeze([]) });
  if (value?.found !== true || value.transcript_id !== transcriptID || !Array.isArray(value.turns)
    || value.turns.length > 200) throw new RecordError('invalid');
  return Object.freeze({
    found: true,
    transcriptID: value.transcript_id,
    workspaceID: UUID.test(value.workspace_id) ? value.workspace_id : null,
    turns: Object.freeze(value.turns.map(row => transcriptTurnRow(row, { transcriptID }))),
  });
}

/** Realtime rows are ciphertext. Only identity/seq are trusted as a refetch signal. */
export function realtimeTurnSignal(value) {
  if (!value || !UUID.test(value.workspace_id) || !UUID.test(value.transcript_id) || !UUID.test(value.turn_id)) {
    throw new RecordError('invalid');
  }
  const envelope = value.envelope;
  return Object.freeze({
    workspaceID: value.workspace_id,
    transcriptID: value.transcript_id,
    turnID: value.turn_id,
    seq: value.seq == null ? null : recordVersion(value.seq),
    wiped: !!envelope && typeof envelope === 'object' && Object.keys(envelope).length === 0,
  });
}
