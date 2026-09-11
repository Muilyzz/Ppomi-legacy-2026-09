// Matches SharedRecordCrypto.swift / KeyWrap. Keys and plaintext stay on device.
export const MAX_RECORD_BYTES = 128 * 1024 * 1024;
export const MAX_CHUNK_BYTES = 409600;
export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const encoder = new TextEncoder();
const errorMessages = {
  unsupported: '이 브라우저에서는 기록 암호화 키를 안전하게 보관할 수 없습니다. 최신 Safari 또는 Chrome에서 열어 주세요.',
  storage: '브라우저의 기록 키 저장소를 사용할 수 없습니다.',
  authentication: '기록을 보려면 같은 계정으로 다시 로그인해 주세요.',
  connection: '서버 기록에 연결하지 못했습니다. 인터넷 연결을 확인해 주세요.',
  permission: '이 브라우저의 기록 접근 권한을 확인하지 못했습니다.',
  waiting: 'Mac에서 기록 키를 전달하기를 기다리고 있습니다.',
  missing: '아직 공유된 기록이 없습니다.',
  invalid: '기록의 암호화 또는 무결성 검증에 실패했습니다.',
  oversized: '이 기록은 웹에서 열 수 있는 128 MiB 한도를 넘습니다.',
  cancelled: '계정 또는 화면이 변경되어 기록 읽기를 중단했습니다.',
};
export class RecordError extends Error {
  constructor(code) { super(errorMessages[code] ?? errorMessages.invalid); this.name = 'RecordError'; this.code = code; }
}
export function base64(bytes) {
  let binary = '';
  for (let i = 0; i < bytes.length; i += 8192) binary += String.fromCharCode(...bytes.subarray(i, i + 8192));
  return btoa(binary);
}
export function unbase64(text, maxBytes) {
  if (typeof text !== 'string' || text.length > Math.ceil(maxBytes / 3) * 4 || text.length % 4 !== 0
    || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(text)) throw new RecordError('invalid');
  const bytes = Uint8Array.from(atob(text), c => c.charCodeAt(0));
  if (bytes.length > maxBytes || base64(bytes) !== text) throw new RecordError('invalid');
  return bytes;
}
export async function sha256(bytes, crypto = globalThis.crypto) {
  return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)), b => b.toString(16).padStart(2, '0')).join('');
}
const join = (a, b) => { const bytes = new Uint8Array(a.length + b.length); bytes.set(a); bytes.set(b, a.length); return bytes; };
const requireUUID = value => { if (typeof value !== 'string' || !UUID.test(value)) throw new RecordError('invalid'); return value; };

export async function generateDevice(userID, crypto = globalThis.crypto) {
  requireUUID(userID);
  try {
    const pair = await crypto.subtle.generateKey({ name: 'X25519' }, false, ['deriveBits']);
    return { formatVersion: 1, userID, deviceID: crypto.randomUUID(), privateKey: pair.privateKey,
      publicKey: new Uint8Array(await crypto.subtle.exportKey('raw', pair.publicKey)) };
  } catch { throw new RecordError('unsupported'); }
}

// Called after every IndexedDB round trip. Merely seeing a CryptoKey-shaped
// object is insufficient: its restored private key must still derive correctly.
export async function verifyDevice(device, userID, crypto = globalThis.crypto) {
  if (device?.formatVersion !== 1 || device.userID !== userID || !UUID.test(device.deviceID)
    || device.privateKey?.type !== 'private' || device.privateKey.extractable !== false
    || device.privateKey.algorithm?.name !== 'X25519' || !device.privateKey.usages?.includes('deriveBits')
    || !(device.publicKey instanceof Uint8Array) || device.publicKey.byteLength !== 32) throw new RecordError('unsupported');
  let left, right;
  try {
    const publicKey = await crypto.subtle.importKey('raw', device.publicKey, 'X25519', true, []);
    const probe = await crypto.subtle.generateKey('X25519', false, ['deriveBits']);
    left = new Uint8Array(await crypto.subtle.deriveBits({ name: 'X25519', public: probe.publicKey }, device.privateKey, 256));
    right = new Uint8Array(await crypto.subtle.deriveBits({ name: 'X25519', public: publicKey }, probe.privateKey, 256));
    let mismatch = left.length ^ right.length;
    for (let i = 0; i < left.length; i++) mismatch |= left[i] ^ right[i];
    if (mismatch) throw new Error('key mismatch');
    return device;
  } catch { throw new RecordError('unsupported'); }
  finally { left?.fill(0); right?.fill(0); }
}

export async function unwrapRecordKey({ wrapped, workspaceID, keyID, device }, crypto = globalThis.crypto) {
  requireUUID(workspaceID); requireUUID(keyID);
  const blob = unbase64(wrapped, 92);
  if (blob.length !== 92) throw new RecordError('invalid');
  let shared, rawKey;
  try {
    const ephemeral = await crypto.subtle.importKey('raw', blob.subarray(0, 32), 'X25519', false, []);
    shared = new Uint8Array(await crypto.subtle.deriveBits({ name: 'X25519', public: ephemeral }, device.privateKey, 256));
    const secret = await crypto.subtle.importKey('raw', shared, 'HKDF', false, ['deriveKey']);
    shared.fill(0);
    const symmetric = await crypto.subtle.deriveKey({ name: 'HKDF', hash: 'SHA-256', salt: encoder.encode(workspaceID),
      info: encoder.encode(`ppomi-wrap-v1|${keyID}`) }, secret, { name: 'AES-GCM', length: 256 }, false, ['decrypt']);
    rawKey = new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: blob.subarray(32, 44), tagLength: 128,
      additionalData: join(encoder.encode(`ppomi-wrap-v1|${workspaceID}|${keyID}|`), device.publicKey) }, symmetric, blob.subarray(44)));
    if (rawKey.length !== 32) throw new RecordError('invalid');
    return await crypto.subtle.importKey('raw', rawKey, 'AES-GCM', false, ['decrypt']);
  } catch { throw new RecordError('invalid'); }
  finally { shared?.fill(0); rawKey?.fill(0); }
}

export function recordVersion(value) {
  if (typeof value === 'number' && !Number.isSafeInteger(value)) throw new RecordError('invalid');
  if (typeof value !== 'number' && typeof value !== 'bigint') throw new RecordError('invalid');
  const integer = BigInt(value);
  if (integer < 1n || integer > 9223372036854775807n) throw new RecordError('invalid');
  return integer.toString();
}
export async function decryptRecordChunk({ bytes, hash, key, workspaceID, keyID, recordID, version, part }, crypto = globalThis.crypto) {
  requireUUID(workspaceID); requireUUID(keyID); requireUUID(recordID);
  if (!(bytes instanceof Uint8Array) || bytes.length < 28 || bytes.length > MAX_CHUNK_BYTES
    || !/^[0-9a-f]{64}$/.test(hash) || !/^[1-9][0-9]{0,18}$/.test(version) || BigInt(version) > 9223372036854775807n
    || !Number.isSafeInteger(part) || part < 0 || part > 1023) throw new RecordError('invalid');
  if (await sha256(bytes, crypto) !== hash) throw new RecordError('invalid');
  try {
    return new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: bytes.subarray(0, 12), tagLength: 128,
      additionalData: encoder.encode(`ppomi-record-v1|${workspaceID}|${keyID}|${recordID}|${version}|${part}`) }, key, bytes.subarray(12)));
  } catch { throw new RecordError('invalid'); }
}

// Recursive JSON parser keeps native Int64 literals exact on browsers without
// JSON.parse reviver source support. No reviver marker keys or eval are used.
// Objects use null prototypes; duplicate keys and excessive nesting are rejected.
export function parseExactJSON(text) {
  if (typeof text !== 'string') throw new RecordError('invalid');
  let cursor = 0;
  const whitespace = () => { while (/[\x20\t\r\n]/.test(text[cursor] ?? '') && cursor < text.length) cursor++; };
  function string() {
    const start = cursor++;
    while (cursor < text.length) {
      const char = text[cursor++];
      if (char === '"') { try { return JSON.parse(text.slice(start, cursor)); } catch { throw new RecordError('invalid'); } }
      if (char === '\\') cursor++;
    }
    throw new RecordError('invalid');
  }
  function value(depth = 0) {
    if (depth > 128) throw new RecordError('invalid');
    whitespace();
    const char = text[cursor];
    if (char === '"') return string();
    if (char === '{' || char === '[') {
      cursor++;
      const array = char === '[', result = array ? [] : Object.create(null), end = array ? ']' : '}';
      whitespace();
      if (text[cursor] === end) { cursor++; return result; }
      while (cursor < text.length) {
        whitespace();
        if (array) result.push(value(depth + 1));
        else {
          if (text[cursor] !== '"') throw new RecordError('invalid');
          const key = string();
          whitespace();
          if (text[cursor++] !== ':' || Object.hasOwn(result, key)) throw new RecordError('invalid');
          result[key] = value(depth + 1);
        }
        whitespace();
        if (text[cursor] === end) { cursor++; return result; }
        if (text[cursor++] !== ',') throw new RecordError('invalid');
      }
      throw new RecordError('invalid');
    }
    for (const [literal, decoded] of [['true', true], ['false', false], ['null', null]]) {
      if (text.startsWith(literal, cursor)) { cursor += literal.length; return decoded; }
    }
    const match = /^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/.exec(text.slice(cursor));
    if (!match) throw new RecordError('invalid');
    const numeric = match[0];
    if (numeric.length > 128) throw new RecordError('invalid');
    cursor += numeric.length;
    if (!/[.eE]/.test(numeric)) {
      const integer = BigInt(numeric);
      if (integer > BigInt(Number.MAX_SAFE_INTEGER) || integer < BigInt(Number.MIN_SAFE_INTEGER)) return integer;
    }
    const number = Number(numeric);
    if (!Number.isFinite(number)) throw new RecordError('invalid');
    return number;
  }
  const result = value();
  whitespace();
  if (cursor !== text.length) throw new RecordError('invalid');
  return result;
}
