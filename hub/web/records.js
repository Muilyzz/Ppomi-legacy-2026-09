import { createRecordRPC } from './record-rpc.js';
import { createDeviceStore } from './device-store.js';
import { decodeLZFSE } from './lzfse.js';
import { validateRecordName, validateKnownVersion, recordContext, keyDelivery, recordHead, recordBlob } from './record-protocol.js';
import { RecordError, UUID, MAX_RECORD_BYTES, MAX_CHUNK_BYTES, base64, unbase64, verifyDevice,
  unwrapRecordKey, decryptRecordChunk, parseExactJSON } from './record-crypto.js';

// Existing callers can keep importing the factory from this module.
export { createDeviceStore } from './device-store.js';

/** Read-only RPC client. No decrypted record or record key is persisted. */
export function createRecordClient({ auth, user, onState = () => {}, fetch: fetcher = globalThis.fetch.bind(globalThis),
  crypto = globalThis.crypto, deviceStore = createDeviceStore({ crypto }), decode = decodeLZFSE } = {}) {
  if (!user || !UUID.test(user.id) || !auth?.getAccessToken || !auth?.getUser) throw new RecordError('authentication');
  let disposed = false, device = null, context = null, vault = null, connectFlight = null;
  const buffers = new Set(), reads = new Map(), verifiedHeads = new Map();
  const lifetime = new AbortController();
  const check = () => { if (disposed || auth.getUser()?.id !== user.id) throw new RecordError('cancelled'); };
  const rpc = createRecordRPC({ auth, check, getDeviceID: () => device.deviceID, signal: lifetime.signal, fetch: fetcher });
  function state(status, details = {}) { if (!disposed) { try { onState(Object.freeze({ status, ...details })); } catch { /* UI cannot change the trust boundary. */ } } }
  async function fetchKey() {
    const delivery = keyDelivery(await rpc('ppomi_key_get', {}), context.workspace.id);
    if (!delivery) { vault = null; return false; }
    const key = await unwrapRecordKey({ wrapped: delivery.wrapped, workspaceID: delivery.workspaceID, keyID: delivery.keyID, device }, crypto);
    check();
    vault = { key, keyID: delivery.keyID, records: delivery.records };
    return true;
  }
  function connectionState() {
    return Object.freeze({ status: vault ? 'ready' : 'waiting-key', ...context, recordNames: Object.freeze(Object.keys(vault?.records ?? {})) });
  }
  function connect() {
    if (connectFlight) return connectFlight;
    const run = (async () => {
      check(); state('connecting');
      device ??= await deviceStore.loadOrCreate(user.id, check);
      check();
      // Validate restored non-extractable keys even with an injected store.
      await verifyDevice(device, user.id, crypto);
      check();
      // A waiting-key refresh is read-only after initial enrollment. Repeating
      // registration would touch/re-enable the server device on every poll.
      const registered = context ?? recordContext(await rpc('ppomi_register_device', { p_device_id: device.deviceID, p_label: '뽀미 웹 브라우저',
        p_platform: 'web', p_public_key: base64(device.publicKey) }), device.deviceID);
      const confirmed = recordContext(await rpc('ppomi_context', {}), device.deviceID);
      if (registered.workspace.id !== confirmed.workspace.id) throw new RecordError('invalid');
      context = confirmed;
      await fetchKey();
      check();
      const result = connectionState(); state(result.status);
      return result;
    })();
    connectFlight = run;
    // Clear the completed flight before awaiting callers can request it again.
    run.then(
      () => { if (connectFlight === run) connectFlight = null; },
      error => { if (connectFlight === run) connectFlight = null; state('error', { code: error.code ?? 'invalid' }); },
    ).catch(() => {});
    return run;
  }
  async function readOnce(name, knownVersion) {
    check();
    validateRecordName(name);
    if (!context || !vault) await connect();
    check();
    if (!vault) throw new RecordError('waiting');
    const recordID = vault.records[name];
    if (!recordID) throw new RecordError('missing');
    state('reading', { name });
    const head = recordHead(await rpc('ppomi_record_get', { p_record_id: recordID }), { workspaceID: context.workspace.id, recordID });
    const { version, identity } = head;
    if (head.keyID !== vault.keyID) {
      if (!await fetchKey() || vault.keyID !== head.keyID || vault.records[name] !== recordID) throw new RecordError('invalid');
    }
    check();
    const previous = verifiedHeads.get(name);
    // A caller's version alone is not proof that this client ever decrypted the
    // record. Bind the optimization to the complete previously verified head.
    if (knownVersion === version && previous && Object.keys(identity).every(key => previous[key] === identity[key])) {
      state('ready');
      return Object.freeze({ name, version, unchanged: true });
    }
    const selected = vault;
    const chunks = [];
    let compressed, bytes, total = 0;
    try {
      for (let part = 0; part < head.chunkIDs.length; part++) {
        check();
        const hash = head.chunkIDs[part], blob = recordBlob(await rpc('ppomi_record_blob_get', { p_hash: hash }), hash);
        const encrypted = unbase64(blob.data, MAX_CHUNK_BYTES);
        if (encrypted.length !== blob.size) throw new RecordError('invalid');
        const plain = await decryptRecordChunk({ bytes: encrypted, hash, key: selected.key, workspaceID: context.workspace.id,
          keyID: selected.keyID, recordID, version, part }, crypto);
        buffers.add(plain); chunks.push(plain); check(); total += plain.length;
        if (total > MAX_RECORD_BYTES) throw new RecordError('oversized');
      }
      compressed = new Uint8Array(total); buffers.add(compressed);
      let offset = 0;
      for (const chunk of chunks) { compressed.set(chunk, offset); offset += chunk.length; chunk.fill(0); buffers.delete(chunk); }
      bytes = await decode(compressed, { maxOutputBytes: MAX_RECORD_BYTES, signal: lifetime.signal });
      check();
      if (!(bytes instanceof Uint8Array) || bytes.length > MAX_RECORD_BYTES) throw new RecordError('oversized');
      const text = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
      const json = name === 'evidence' ? null : parseExactJSON(text);
      check(); verifiedHeads.set(name, identity); state('ready');
      // The caller owns the returned bytes/text/object and must discard its view
      // on logout. Evidence is untrusted HTML: never inject into the app DOM.
      return Object.freeze({ name, bytes, text, json, version, updatedAt: head.updatedAt });
    } catch (error) {
      bytes?.fill(0);
      check();
      if (error instanceof RecordError) throw error;
      if (error?.code === 'size') throw new RecordError('oversized');
      throw new RecordError('invalid');
    } finally {
      for (const chunk of chunks) { if (chunk.byteLength) chunk.fill(0); buffers.delete(chunk); }
      if (compressed?.byteLength) compressed.fill(0);
      buffers.delete(compressed);
    }
  }
  function read(name, { knownVersion } = {}) {
    try { validateKnownVersion(knownVersion); } catch (error) { return Promise.reject(error); }
    // An unconditional reader must never inherit an in-flight unchanged-only
    // result requested by another consumer.
    // Equal pending reads share their result bytes as well as their promise;
    // consumers must coordinate cleanup (record-session owns that lifetime).
    const requestID = JSON.stringify([name, knownVersion ?? null]);
    if (reads.has(requestID)) return reads.get(requestID);
    const run = readOnce(name, knownVersion);
    reads.set(requestID, run);
    run.then(
      () => { if (reads.get(requestID) === run) reads.delete(requestID); },
      error => { if (reads.get(requestID) === run) reads.delete(requestID); state('error', { code: error.code ?? 'invalid' }); },
    ).catch(() => {});
    return run;
  }
  function dispose() {
    if (disposed) return;
    disposed = true;
    lifetime.abort();
    for (const bytes of buffers) { if (bytes.byteLength) bytes.fill(0); }
    buffers.clear(); reads.clear(); verifiedHeads.clear(); vault = null; device = null; context = null;
  }
  return Object.freeze({ connect, read, dispose,
    async clearPrivate() { dispose(); await deviceStore.clear(user.id); },
  });
}
