import { createRecordRPC } from './record-rpc.js';
import { createDeviceStore } from './device-store.js';
import { RecordError, UUID, base64, verifyDevice, unwrapRecordKey } from './record-crypto.js';
import { recordContext, keyDelivery } from './record-protocol.js';
import { decodeTurnPayload, encodeTurnPayload, openTranscriptTurn, sealTranscriptTurn } from './transcript-crypto.js';
import { transcriptHead, transcriptList, transcriptPayload, transcriptTurnPage, realtimeTurnRow } from './transcript-protocol.js';
import { createTranscriptRealtime } from './transcript-realtime.js';

/** Encrypts and uploads conversation turns. Ciphertext never becomes host state. */
export function createTranscriptClient({ auth, user, onState = () => {}, fetch: fetcher = globalThis.fetch.bind(globalThis),
  crypto = globalThis.crypto, deviceStore = createDeviceStore({ crypto }),
  realtime: realtimeFactory = createTranscriptRealtime } = {}) {
  if (!user || !UUID.test(user.id) || !auth?.getAccessToken || !auth?.getUser) throw new RecordError('authentication');
  let disposed = false, device = null, context = null, vault = null, connectFlight = null, realtime, transcript = null;
  const lifetime = new AbortController();
  const listeners = new Set();
  const check = () => { if (disposed || auth.getUser()?.id !== user.id) throw new RecordError('cancelled'); };
  const rpc = createRecordRPC({ auth, check, getDeviceID: () => device.deviceID, signal: lifetime.signal, fetch: fetcher });
  function state(status, details = {}) {
    if (!disposed) { try { onState(Object.freeze({ status, ...details })); } catch { /* UI cannot change the trust boundary. */ } }
  }
  function publish(event) {
    for (const listener of listeners) {
      try { listener(event); } catch { /* A view cannot break sync. */ }
    }
  }
  async function fetchKey() {
    const delivery = keyDelivery(await rpc('ppomi_key_get', {}), context.workspace.id);
    if (!delivery) { vault = null; return false; }
    const key = await unwrapRecordKey({
      wrapped: delivery.wrapped, workspaceID: delivery.workspaceID, keyID: delivery.keyID,
      device, usages: ['encrypt', 'decrypt'],
    }, crypto);
    check();
    vault = { key, keyID: delivery.keyID };
    return true;
  }
  function connect() {
    if (connectFlight) return connectFlight;
    const run = (async () => {
      check(); state('connecting');
      device ??= await deviceStore.loadOrCreate(user.id, check);
      check();
      await verifyDevice(device, user.id, crypto);
      check();
      const registered = context ?? recordContext(await rpc('ppomi_register_device', {
        p_device_id: device.deviceID, p_label: '뽀미 웹 브라우저', p_platform: 'web',
        p_public_key: base64(device.publicKey),
      }), device.deviceID);
      const confirmed = recordContext(await rpc('ppomi_context', {}), device.deviceID);
      if (registered.workspace.id !== confirmed.workspace.id) throw new RecordError('invalid');
      context = confirmed;
      await fetchKey();
      check();
      const status = vault ? 'ready' : 'waiting-key';
      state(status, { workspace: context.workspace, device: context.device });
      return Object.freeze({ status, workspace: context.workspace, device: context.device });
    })();
    connectFlight = run;
    run.then(
      () => { if (connectFlight === run) connectFlight = null; },
      error => { if (connectFlight === run) connectFlight = null; state('error', { code: error.code ?? 'invalid' }); },
    ).catch(() => {});
    return run;
  }
  async function decryptRow(row, workspaceID, transcriptID) {
    const bytes = await openTranscriptTurn({
      envelope: row.envelope, key: vault.key, workspaceID, keyID: row.keyID || vault.keyID,
      transcriptID, turnID: row.turnID,
    }, crypto);
    check();
    try { return Object.freeze({ ...transcriptPayload(decodeTurnPayload(bytes)), seq: row.seq, createdAt: row.createdAt }); }
    finally { bytes.fill(0); }
  }
  async function open() {
    check();
    if (!context || !vault) await connect();
    check();
    if (!vault) throw new RecordError('waiting');
    const head = transcriptHead(await rpc('ppomi_transcript_open', {
      p_transcript_id: crypto.randomUUID(), p_key_id: vault.keyID,
    }));
    if (head.workspaceID !== context.workspace.id || head.keyID !== vault.keyID) throw new RecordError('invalid');
    transcript = head;
    return head;
  }
  async function load() {
    check();
    if (!context || !vault) await connect();
    check();
    if (!vault) return Object.freeze({ status: 'waiting-key', transcript: null, turns: Object.freeze([]) });
    const listed = transcriptList(await rpc('ppomi_transcript_list', {}));
    check();
    const selected = listed[0] ?? await open();
    transcript = selected;
    const page = transcriptTurnPage(await rpc('ppomi_transcript_turns', {
      p_transcript_id: selected.id, p_after_seq: 0,
    }), selected.id);
    check();
    if (!page.found) return Object.freeze({ status: 'ready', transcript: selected, turns: Object.freeze([]) });
    const turns = [];
    for (const row of page.turns) turns.push(await decryptRow(row, context.workspace.id, selected.id));
    state('ready', { workspace: context.workspace, device: context.device });
    return Object.freeze({ status: 'ready', transcript: selected, turns: Object.freeze(turns) });
  }
  async function append(payload) {
    check();
    const turn = transcriptPayload(payload);
    if (!context || !vault) await connect();
    check();
    if (!vault) throw new RecordError('waiting');
    if (!transcript) await open();
    check();
    const bytes = encodeTurnPayload(turn);
    let envelope;
    try {
      envelope = await sealTranscriptTurn({
        bytes, key: vault.key, workspaceID: context.workspace.id, keyID: vault.keyID,
        transcriptID: transcript.id, turnID: turn.id,
      }, crypto);
    } finally { bytes.fill(0); }
    check();
    const saved = await rpc('ppomi_transcript_append', {
      p_transcript_id: transcript.id, p_turn_id: turn.id, p_key_id: vault.keyID, p_envelope: envelope,
    });
    check();
    return Object.freeze({ ...turn, seq: String(saved.seq ?? '') });
  }
  async function tombstone() {
    check();
    if (!transcript) return Object.freeze({ deleted: true });
    if (!context || !vault) await connect();
    check();
    await rpc('ppomi_transcript_delete', { p_transcript_id: transcript.id });
    transcript = null;
    return Object.freeze({ deleted: true });
  }
  function subscribe(listener) {
    listeners.add(listener);
    return () => listeners.delete(listener);
  }
  async function startRealtime() {
    if (realtime || disposed) return;
    realtime = realtimeFactory({
      getAccessToken: () => auth.getAccessToken(),
      signal: lifetime.signal,
      onEvent: async event => {
        if (disposed) return;
        try {
          check();
          if (event.type === 'tombstone') {
            if (event.record?.id === transcript?.id || event.record?.id === undefined) {
              transcript = null;
              publish({ type: 'deleted' });
            }
            return;
          }
          if (event.type !== 'turn' || !vault || !context) return;
          const row = realtimeTurnRow(event.record);
          if (transcript && event.record.transcript_id !== transcript.id) return;
          if (!row.envelope || Object.keys(row.envelope).length === 0) return;
          const turn = await decryptRow(row, event.record.workspace_id, event.record.transcript_id);
          publish({ type: 'turn', turn });
        } catch (error) {
          if (error instanceof RecordError && error.code === 'cancelled') return;
        }
      },
    });
    await realtime.start();
  }
  function dispose() {
    if (disposed) return;
    disposed = true;
    lifetime.abort();
    realtime?.stop();
    listeners.clear();
    vault = null; device = null; context = null; transcript = null;
  }
  return Object.freeze({
    connect, load, append, tombstone, subscribe, startRealtime, dispose,
    async clearPrivate() { dispose(); await deviceStore.clear(user.id); },
  });
}
