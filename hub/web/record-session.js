/**
 * UI-independent lifetime of one account's selected record.
 * The client owns RPC/crypto; the caller owns rendering and authentication.
 * Await clearPrivate() in auth's cleanup hook before publishing the next user.
 * present() may read the record until its promise settles. Shared result bytes
 * are erased after the last consumer finishes with them.
 */
export function createRecordSession({
  createClient, clearKey, present, clearPresentation, hasPresentation,
  onState = () => {}, initialRecord = 'ledger', visible = true,
  setTimeout: scheduleTask = globalThis.setTimeout,
  clearTimeout: cancelTask = globalThis.clearTimeout,
}) {
  let client = null, userID = null, lastKeyOwnerID = null, connection = null;
  let selected = initialRecord, presentationAbort, timer, connecting = null, reading = null;
  let displayed = null;
  const readResults = new Map();
  let state = Object.freeze({status: 'idle', busy: false, selected, connection: null, record: null, error: null});

  function publish(patch) {
    // Busy belongs to the current operations, never to a completed caller.
    state = Object.freeze({...state, ...patch, busy: Boolean(connecting || reading), selected, connection});
    try { onState(state); } catch { /* A view observer cannot prevent cleanup. */ }
  }
  function clearView() {
    displayed = null;
    clearPresentation();
  }
  function cancelRead() {
    reading = null;
    presentationAbort?.abort(); presentationAbort = null;
  }
  function stop() {
    connecting = null; cancelRead(); cancelTask(timer); client?.dispose();
    client = null; userID = null; connection = null;
    // lastKeyOwnerID survives temporary auth invalidation and page suspension.
    clearView(); publish({status: 'idle', record: null, error: null});
  }
  function schedule() {
    cancelTask(timer);
    if (!client || !visible || connecting || reading) return;
    timer = scheduleTask(() => refresh(), connection?.status === 'waiting-key' ? 15_000 : 60_000);
  }
  function waiting() {
    clearView(); publish({status: 'waiting-key', record: null, error: null});
  }
  function missing(code) {
    clearView(); publish({status: 'missing', record: null, error: Object.freeze({code, phase: 'read'})});
  }
  function failed(error, phase) {
    clearView(); publish({status: 'error', record: null, error: Object.freeze({code: error?.code, phase})});
  }
  function readSelected() {
    if (!client || connection?.status !== 'ready' || connecting) return;
    cancelRead(); cancelTask(timer);
    presentationAbort = new AbortController();
    const signal = presentationAbort.signal;
    const task = {client, name: selected, signal, promise: null};
    reading = task;
    // Install the promise before publishing, so reentrant refreshes share it.
    task.promise = Promise.resolve().then(() => readRecord(task));
    publish({status: 'reading', record: displayed, error: null});
    return task.promise;
  }
  async function readRecord(task) {
    const {name, signal} = task;
    const valid = () => reading === task && client === task.client && !signal.aborted;
    let record, shared;
    try {
      if (!valid()) return;
      if (!connection.recordNames.includes(name)) { missing('unshared'); return; }
      const knownVersion = displayed?.name === name && hasPresentation() ? displayed.version : undefined;
      const pending = task.client.read(name, {knownVersion});
      // A→B→A can join the same client promise twice. Register both consumers
      // before awaiting it; a stale consumer must not erase the active view's bytes.
      shared = readResults.get(pending);
      if (!shared) { shared = {pending, consumers: 0, record: null}; readResults.set(pending, shared); }
      shared.consumers++;
      record = await pending;
      shared.record = record;
      if (!valid()) return;
      if (record.unchanged) { publish({status: 'ready', record: displayed, error: null}); return; }
      await present(name, record, {signal});
      if (!valid()) return;
      displayed = Object.freeze({name, version: record.version, updatedAt: record.updatedAt ?? null});
      publish({status: 'ready', record: displayed, error: null});
    } catch (error) {
      if (!valid() || error?.code === 'cancelled') return;
      if (error?.code === 'missing') missing('missing'); else failed(error, 'read');
    } finally {
      if (shared && --shared.consumers === 0) {
        shared.record?.bytes?.fill(0); shared.record = null;
        readResults.delete(shared.pending);
      }
      record = null;
      if (valid()) { reading = null; publish({}); schedule(); }
    }
  }
  // Copy only the public connection contract. Transport tokens/keys or private
  // payloads must never become observable session state, even with another client.
  function connectionMetadata(value) {
    return Object.freeze({
      status: value.status,
      workspace: Object.freeze({id: value.workspace.id, name: value.workspace.name}),
      device: value.device ? Object.freeze({id: value.device.id, label: value.device.label, platform: value.device.platform}) : null,
      recordNames: Object.freeze([...value.recordNames]),
    });
  }
  function refresh() {
    if (!client) return;
    if (connecting) return connecting.promise;
    if (reading) return reading.promise;
    const task = {client, promise: null};
    connecting = task; cancelTask(timer);
    task.promise = Promise.resolve().then(() => connectRecord(task));
    publish(connection ? {} : {status: 'connecting', error: null});
    return task.promise;
  }
  async function connectRecord(task) {
    const valid = () => connecting === task && client === task.client;
    try {
      if (!valid()) return;
      const connected = await task.client.connect();
      if (!valid()) return;
      connection = connectionMetadata(connected);
      // Transfer ownership to the selected read. This connection's eventual
      // completion must not clear busy or schedule a poll for a newer read.
      connecting = null;
      if (connection.status === 'waiting-key') { waiting(); schedule(); }
      else return await readSelected();
    } catch (error) {
      if (!valid() || error?.code === 'cancelled') return;
      failed(error, 'connect');
    } finally {
      if (valid()) { connecting = null; publish({}); schedule(); }
    }
  }
  function start(user) {
    if (!user || (client && userID === user.id)) return;
    stop(); userID = user.id; lastKeyOwnerID = user.id;
    client = createClient(user);
    return refresh();
  }
  function select(name) {
    if (name === selected) return;
    selected = name; cancelRead(); clearView();
    if (connection?.status === 'ready' && !connecting) return readSelected();
    publish({record: null});
    if (connecting) return connecting.promise;
    if (connection?.status === 'waiting-key') waiting();
  }
  function setVisible(value) {
    visible = Boolean(value);
    if (!visible) cancelTask(timer); else if (client) return refresh();
  }
  async function clearPrivate(previousUserId) {
    const owner = previousUserId ?? lastKeyOwnerID;
    stop();
    if (owner) await clearKey(owner);
    if (lastKeyOwnerID === owner) lastKeyOwnerID = null;
  }
  return Object.freeze({start, stop, select, refresh, setVisible, clearPrivate, getState: () => state});
}
