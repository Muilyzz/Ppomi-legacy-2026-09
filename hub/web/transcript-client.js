import { createRecordRPC } from './record-rpc.js';
import { createDeviceStore } from './device-store.js';
import { RecordError, UUID, base64, verifyDevice } from './record-crypto.js';
import { recordContext } from './record-protocol.js';
import { transcriptHead, transcriptList, transcriptPayload, transcriptTurnPage, realtimeTurnRow } from './transcript-protocol.js';
import { createTranscriptRealtime } from './transcript-realtime.js';

/** Uploads conversation turns as JSON the server can read. No client E2E key. */
export function createTranscriptClient({ auth, user, onState = () => {}, fetch: fetcher = globalThis.fetch.bind(globalThis),
  crypto = globalThis.crypto, deviceStore = createDeviceStore({ crypto }),
  realtime: realtimeFactory = createTranscriptRealtime } = {}) {
  if (!user || !UUID.test(user.id) || !auth?.getAccessToken || !auth?.getUser) throw new RecordError('authentication');
  let disposed = false, device = null, context = null, connectFlight = null, realtime, transcript = null;
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
      check();
      state('ready', { workspace: context.workspace, device: context.device });
      return Object.freeze({ status: 'ready', workspace: context.workspace, device: context.device });
    })();
    connectFlight = run;
    run.then(
      () => { if (connectFlight === run) connectFlight = null; },
      error => { if (connectFlight === run) connectFlight = null; state('error', { code: error.code ?? 'invalid' }); },
    ).catch(() => {});
    return run;
  }
  function turnFromRow(row) {
    return Object.freeze({ ...row.payload, seq: row.seq, createdAt: row.createdAt });
  }
  async function open() {
    check();
    if (!context) await connect();
    check();
    const head = transcriptHead(await rpc('ppomi_transcript_open', {
      p_transcript_id: crypto.randomUUID(),
    }));
    if (head.workspaceID !== context.workspace.id) throw new RecordError('invalid');
    transcript = head;
    return head;
  }
  async function load() {
    check();
    if (!context) await connect();
    check();
    const listed = transcriptList(await rpc('ppomi_transcript_list', {}));
    check();
    const selected = listed[0] ?? await open();
    transcript = selected;
    const page = transcriptTurnPage(await rpc('ppomi_transcript_turns', {
      p_transcript_id: selected.id, p_after_seq: 0,
    }), selected.id);
    check();
    const turns = page.found ? page.turns.map(turnFromRow) : [];
    state('ready', { workspace: context.workspace, device: context.device });
    return Object.freeze({ status: 'ready', transcript: selected, turns: Object.freeze(turns) });
  }
  async function append(payload) {
    check();
    const turn = transcriptPayload(payload);
    if (!context) await connect();
    check();
    if (!transcript) await open();
    check();
    const saved = await rpc('ppomi_transcript_append', {
      p_transcript_id: transcript.id, p_turn_id: turn.id, p_payload: turn,
    });
    check();
    return Object.freeze({ ...turn, seq: String(saved.seq ?? '') });
  }
  async function tombstone() {
    check();
    if (!transcript) return Object.freeze({ deleted: true });
    if (!context) await connect();
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
          if (event.type !== 'turn' || !context) return;
          const row = realtimeTurnRow(event.record);
          if (transcript && event.record.transcript_id !== transcript.id) return;
          if (!row.payload || Object.keys(event.record.payload ?? {}).length === 0) return;
          publish({ type: 'turn', turn: turnFromRow(row) });
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
    device = null; context = null; transcript = null;
  }
  return Object.freeze({
    connect, load, append, tombstone, subscribe, startRealtime, dispose,
    async clearPrivate() { dispose(); await deviceStore.clear(user.id); },
  });
}
