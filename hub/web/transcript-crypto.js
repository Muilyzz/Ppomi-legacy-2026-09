// Matches SharedTranscriptCrypto.swift. The workspace record key seals turns;
// the server stores the envelope only.
import { RecordError, UUID, base64, unbase64 } from './record-crypto.js';

export const TRANSCRIPT_AAD = 'ppomi-transcript-v1';
export const MAX_TURN_BYTES = 32 * 1024;
const encoder = new TextEncoder();
const decoder = new TextDecoder('utf-8', { fatal: true });

const requireUUID = value => { if (typeof value !== 'string' || !UUID.test(value)) throw new RecordError('invalid'); return value; };

export function base64url(bytes) {
  if (!(bytes instanceof Uint8Array)) throw new RecordError('invalid');
  return base64(bytes).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
}

export function unbase64url(text, maxBytes) {
  if (typeof text !== 'string' || text.length > Math.ceil(maxBytes / 3) * 4 + 4
    || !/^[A-Za-z0-9_-]+$/.test(text)) throw new RecordError('invalid');
  const padded = text.replaceAll('-', '+').replaceAll('_', '/') + '='.repeat((4 - (text.length % 4)) % 4);
  const bytes = unbase64(padded, maxBytes);
  if (base64url(bytes) !== text) throw new RecordError('invalid');
  return bytes;
}

export function transcriptAAD({ workspaceID, keyID, transcriptID, turnID }) {
  return encoder.encode(`${TRANSCRIPT_AAD}|${requireUUID(workspaceID)}|${requireUUID(keyID)}|${requireUUID(transcriptID)}|${requireUUID(turnID)}`);
}

export async function sealTranscriptTurn({ bytes, key, workspaceID, keyID, transcriptID, turnID }, crypto = globalThis.crypto) {
  if (!(bytes instanceof Uint8Array) || bytes.length < 1 || bytes.length > MAX_TURN_BYTES) throw new RecordError('invalid');
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  let sealed;
  try {
    sealed = new Uint8Array(await crypto.subtle.encrypt({
      name: 'AES-GCM', iv: nonce, tagLength: 128,
      additionalData: transcriptAAD({ workspaceID, keyID, transcriptID, turnID }),
    }, key, bytes));
  } catch { throw new RecordError('invalid'); }
  if (sealed.length < 17) throw new RecordError('invalid');
  const ciphertext = sealed.subarray(0, sealed.length - 16);
  const tag = sealed.subarray(sealed.length - 16);
  return Object.freeze({
    version: 1,
    nonce: base64url(nonce),
    ciphertext: base64url(ciphertext),
    tag: base64url(tag),
  });
}

export async function openTranscriptTurn({ envelope, key, workspaceID, keyID, transcriptID, turnID }, crypto = globalThis.crypto) {
  if (!envelope || envelope.version !== 1) throw new RecordError('invalid');
  const nonce = unbase64url(envelope.nonce, 12);
  const tag = unbase64url(envelope.tag, 16);
  const ciphertext = unbase64url(envelope.ciphertext, MAX_TURN_BYTES + 32);
  if (nonce.length !== 12 || tag.length !== 16 || ciphertext.length < 1) throw new RecordError('invalid');
  const combined = new Uint8Array(ciphertext.length + tag.length);
  combined.set(ciphertext);
  combined.set(tag, ciphertext.length);
  try {
    const plain = new Uint8Array(await crypto.subtle.decrypt({
      name: 'AES-GCM', iv: nonce, tagLength: 128,
      additionalData: transcriptAAD({ workspaceID, keyID, transcriptID, turnID }),
    }, key, combined));
    if (plain.length < 1 || plain.length > MAX_TURN_BYTES) throw new RecordError('invalid');
    return plain;
  } catch { throw new RecordError('invalid'); }
  finally { combined.fill(0); }
}

export function encodeTurnPayload(payload) {
  const text = JSON.stringify(payload);
  const bytes = encoder.encode(text);
  if (bytes.length > MAX_TURN_BYTES) throw new RecordError('oversized');
  return bytes;
}

export function decodeTurnPayload(bytes) {
  if (!(bytes instanceof Uint8Array) || bytes.length > MAX_TURN_BYTES) throw new RecordError('invalid');
  try {
    const value = JSON.parse(decoder.decode(bytes));
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new RecordError('invalid');
    return value;
  } catch { throw new RecordError('invalid'); }
}
