import { SUPABASE_URL, PUBLISHABLE_KEY } from './config.js';
import { RecordError } from './record-crypto.js';

/**
 * Phoenix Realtime client for transcript ciphertext only. The caller decrypts.
 * Tokens are requested per connect and never stored on the returned handle.
 */
export function createTranscriptRealtime({
  getAccessToken, onEvent, signal,
  url = `${SUPABASE_URL.replace(/^https:/, 'wss:')}/realtime/v1/websocket`,
  WebSocket: Socket = globalThis.WebSocket,
  setTimeout: schedule = globalThis.setTimeout,
  clearTimeout: cancel = globalThis.clearTimeout,
} = {}) {
  let socket, closed = false, ref = 0, heartbeat, reconnect;
  const nextRef = () => String(++ref);

  function send(topic, event, payload = {}) {
    if (!socket || socket.readyState !== Socket.OPEN) return;
    socket.send(JSON.stringify({ topic, event, payload, ref: nextRef() }));
  }

  function stopTimers() {
    cancel(heartbeat); cancel(reconnect);
    heartbeat = undefined; reconnect = undefined;
  }

  function dispose() {
    closed = true;
    stopTimers();
    try { socket?.close(); } catch { /* The socket may already be gone. */ }
    socket = undefined;
  }

  async function connect() {
    if (closed || signal?.aborted) return;
    let token;
    try { token = await getAccessToken(); } catch { throw new RecordError('authentication'); }
    if (typeof token !== 'string' || token.length < 16 || token.length > 8192) throw new RecordError('authentication');
    const target = `${url}?apikey=${encodeURIComponent(PUBLISHABLE_KEY)}&vsn=1.0.0`;
    socket = new Socket(target);
    socket.addEventListener('open', () => {
      if (closed) { socket.close(); return; }
      send('realtime:public:ppomi_transcripts', 'phx_join', {
        config: {
          broadcast: { ack: false, self: false },
          presence: { key: '' },
          postgres_changes: [
            { event: 'INSERT', schema: 'public', table: 'ppomi_transcript_turns' },
            { event: 'UPDATE', schema: 'public', table: 'ppomi_transcript_turns' },
            { event: 'UPDATE', schema: 'public', table: 'ppomi_transcripts' },
          ],
        },
        access_token: token,
      });
      heartbeat = schedule(function beat() {
        send('phoenix', 'heartbeat', {});
        heartbeat = schedule(beat, 25_000);
      }, 25_000);
    });
    socket.addEventListener('message', event => {
      if (closed) return;
      let message;
      try { message = JSON.parse(String(event.data)); } catch { return; }
      if (!message || typeof message !== 'object') return;
      const payload = message.payload;
      if (message.event === 'phx_reply' && payload?.status === 'error') {
        try { onEvent({ type: 'error', code: 'connection' }); } catch { /* A view cannot break the socket. */ }
        return;
      }
      if (message.event !== 'postgres_changes' && message.event !== 'INSERT' && message.event !== 'UPDATE') return;
      const change = payload?.data ?? payload;
      const table = change?.table ?? change?.schema_table;
      const record = change?.record ?? change?.new;
      if (!record || typeof record !== 'object') return;
      const kind = change?.type ?? message.event;
      try {
        if (table === 'ppomi_transcripts' || change?.table === 'ppomi_transcripts') {
          onEvent({ type: record.deleted_at ? 'tombstone' : 'transcript', record });
        } else {
          onEvent({ type: kind === 'UPDATE' && record.envelope && Object.keys(record.envelope).length === 0 ? 'wiped' : 'turn', record });
        }
      } catch { /* A view cannot break the socket. */ }
    });
    socket.addEventListener('close', () => {
      stopTimers();
      if (closed || signal?.aborted) return;
      reconnect = schedule(() => { void connect().catch(() => {}); }, 3_000);
    });
    socket.addEventListener('error', () => { try { socket.close(); } catch { /* close is best-effort */ } });
  }

  signal?.addEventListener('abort', dispose, { once: true });
  return Object.freeze({
    start() { closed = false; return connect(); },
    stop: dispose,
  });
}
