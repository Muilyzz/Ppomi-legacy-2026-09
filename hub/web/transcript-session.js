/**
 * UI-independent lifetime of one account's shared conversation.
 * The client owns RPC/crypto/realtime; the workbench receives decrypted turns only.
 */
export function createTranscriptSession({
  createClient, onTurns = () => {},
} = {}) {
  let client = null, userID = null, loading = null;
  const listeners = new Set();
  const events = new Set();
  let state = Object.freeze({ status: 'idle', transcript: null, turns: Object.freeze([]), error: null });

  function emit(event) {
    for (const listener of events) {
      try { listener(event); } catch { /* A view cannot break sync. */ }
    }
  }

  function publish(patch) {
    state = Object.freeze({ ...state, ...patch });
    try { onTurns(state); } catch { /* A view observer cannot prevent cleanup. */ }
    for (const listener of listeners) {
      try { listener(state); } catch { /* A view cannot break sync. */ }
    }
  }
  function stop() {
    loading = null;
    client?.dispose();
    client = null; userID = null;
    publish({ status: 'idle', transcript: null, turns: Object.freeze([]), error: null });
  }
  async function load(task) {
    const valid = () => loading === task && client === task.client;
    try {
      if (!valid()) return;
      const result = await task.client.load();
      if (!valid()) return;
      publish({
        status: result.status,
        transcript: result.transcript,
        turns: result.turns,
        error: result.status === 'waiting-key' ? Object.freeze({ code: 'waiting' }) : null,
      });
      if (result.status === 'ready') await task.client.startRealtime();
    } catch (error) {
      if (!valid() || error?.code === 'cancelled') return;
      publish({ status: 'error', transcript: null, turns: Object.freeze([]), error: Object.freeze({ code: error?.code ?? 'invalid' }) });
    } finally {
      if (valid()) loading = null;
    }
  }
  function refresh() {
    if (!client) return;
    if (loading) return loading.promise;
    const task = { client, promise: null };
    loading = task;
    task.promise = Promise.resolve().then(() => load(task));
    return task.promise;
  }
  function start(user) {
    if (!user || (client && userID === user.id)) return;
    stop(); userID = user.id;
    client = createClient(user);
    client.subscribe(event => {
      if (event.type === 'deleted') {
        publish({ transcript: null, turns: Object.freeze([]) });
        emit(event);
        return;
      }
      if (event.type !== 'turn' || !event.turn) return;
      if (state.turns.some(turn => turn.id === event.turn.id)) return;
      publish({ turns: Object.freeze([...state.turns, event.turn]) });
      emit(event);
    });
    return refresh();
  }
  async function append(payload) {
    if (!client) return;
    const saved = await client.append(payload);
    if (!state.turns.some(turn => turn.id === saved.id)) {
      publish({ turns: Object.freeze([...state.turns, saved]), status: 'ready', error: null });
      emit({ type: 'turn', turn: saved });
    }
    return saved;
  }
  async function clearPrivate(previousUserId) {
    const owner = previousUserId ?? userID;
    const current = client;
    stop();
    if (current) await current.clearPrivate?.();
    if (userID === owner) userID = null;
  }
  function subscribe(listener) {
    listeners.add(listener);
    return () => listeners.delete(listener);
  }
  function watch(listener) {
    events.add(listener);
    return () => events.delete(listener);
  }
  return Object.freeze({
    start, stop, refresh, append, clearPrivate, subscribe, watch,
    getState: () => state,
  });
}
