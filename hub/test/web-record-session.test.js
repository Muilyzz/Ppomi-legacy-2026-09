import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRecordSession } from '../web/record-session.js';

const user = { id: '11111111-1111-4111-8111-111111111111', name: 'Synthetic account' };
const otherUser = { id: '22222222-2222-4222-8222-222222222222', name: 'Other synthetic account' };
const deferred = () => {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
};
const connection = (status = 'ready', recordNames = ['ledger', 'accounting', 'evidence']) => ({
  status,
  workspace: { id: '33333333-3333-4333-8333-333333333333', name: 'Synthetic workspace' },
  device: { id: '44444444-4444-4444-8444-444444444444', label: 'Synthetic browser', platform: 'web' },
  recordNames,
});
const record = (name = 'ledger', version = '7') => ({
  name, version, updatedAt: '2026-09-11T00:00:00Z',
  bytes: new TextEncoder().encode('{"privateValue":"synthetic-private-record"}'),
  text: '{"privateValue":"synthetic-private-record"}',
  json: { privateValue: 'synthetic-private-record' },
});
const failure = code => Object.assign(new Error(`Synthetic ${code}`), { code });

function clock() {
  let nextID = 0;
  const pending = new Map();
  return {
    pending,
    setTimeout(callback, delay) { const id = ++nextID; pending.set(id, { callback, delay }); return id; },
    clearTimeout(id) { pending.delete(id); },
    delays() { return [...pending.values()].map(timer => timer.delay); },
    fire() {
      assert.equal(pending.size, 1);
      const [id, timer] = pending.entries().next().value;
      pending.delete(id);
      return timer.callback();
    },
  };
}

// Timer callbacks may intentionally discard their refresh promise. Only advance
// microtasks here: no network, wall-clock delay, or native/browser runtime.
async function settle(predicate) {
  for (let turn = 0; turn < 40; turn++) {
    if (predicate()) return;
    await Promise.resolve();
  }
  assert.ok(predicate(), 'Expected the asynchronous session operation to finish');
}

function environment(options = {}) {
  const timers = clock(), states = [], clients = [], presentations = [], reads = [], clearedKeys = [];
  let mounted = false, clearCount = 0;
  const session = createRecordSession({
    createClient(owner) {
      const calls = { owner: owner.id, connects: 0, disposals: 0 };
      const client = {
        async connect() {
          calls.connects++;
          return options.connect ? options.connect(calls) : connection();
        },
        read(name, readOptions = {}) {
          reads.push({ name, ...readOptions, owner: owner.id });
          return options.read ? options.read(name, readOptions, calls) : Promise.resolve(record(name));
        },
        dispose() { calls.disposals++; },
      };
      clients.push(calls);
      return client;
    },
    async clearKey(ownerID) {
      clearedKeys.push(ownerID);
      if (options.clearKey) await options.clearKey(ownerID);
    },
    onState(state) { states.push(state); options.onState?.(state); },
    async present(name, value, { signal }) {
      presentations.push({ name, value, signal });
      if (options.present) await options.present(name, value, { signal });
      if (!signal.aborted) mounted = true;
    },
    clearPresentation() { clearCount++; mounted = false; },
    hasPresentation() { return mounted; },
    setTimeout: timers.setTimeout,
    clearTimeout: timers.clearTimeout,
    visible: options.visible ?? true,
    ...(options.initialRecord ? { initialRecord: options.initialRecord } : {}),
  });
  return { session, timers, states, clients, presentations, reads, clearedKeys,
    setMounted(value) { mounted = value; }, clearCount: () => clearCount };
}

test('the record session presents records while emitting only frozen metadata', async () => {
  const e = environment();
  assert.equal(e.session.getState().status, 'idle');
  await e.session.start(user);
  const state = e.session.getState();
  assert.equal(state.status, 'ready');
  assert.equal(state.busy, false);
  assert.equal(state.selected, 'ledger');
  assert.deepEqual(state.record, { name: 'ledger', version: '7', updatedAt: '2026-09-11T00:00:00Z' });
  assert.equal(state.connection.workspace.name, 'Synthetic workspace');
  assert.equal(state.error, null);
  assert.equal(e.presentations.length, 1);
  assert.equal(e.presentations[0].value.json.privateValue, 'synthetic-private-record');
  assert.ok(e.presentations[0].value.bytes.every(byte => byte === 0));
  for (const snapshot of [...e.states, state]) {
    assert.ok(Object.isFrozen(snapshot));
    assert.ok(!JSON.stringify(snapshot).includes('synthetic-private-record'));
    assert.ok(!Object.hasOwn(snapshot, 'bytes'));
    assert.ok(!Object.hasOwn(snapshot, 'json'));
    assert.ok(!Object.hasOwn(snapshot, 'text'));
  }
  await e.session.start({ ...user });
  assert.equal(e.clients.length, 1, 'Restoring the same account keeps its current client');
  assert.equal(e.clients[0].connects, 1);
  e.session.stop();
});

test('waiting for a key retries at 15 seconds and connected records poll at 60 seconds', async () => {
  const e = environment({ connect: calls => connection(calls.connects === 1 ? 'waiting-key' : 'ready') });
  await e.session.start(user);
  assert.equal(e.session.getState().status, 'waiting-key');
  assert.equal(e.session.getState().busy, false);
  assert.equal(e.reads.length, 0);
  assert.deepEqual(e.timers.delays(), [15_000]);
  e.timers.fire();
  await settle(() => e.session.getState().status === 'ready' && !e.session.getState().busy);
  assert.equal(e.clients.length, 1);
  assert.equal(e.clients[0].connects, 2);
  assert.equal(e.reads.length, 1);
  assert.deepEqual(e.timers.delays(), [60_000]);
  e.session.stop();
  assert.equal(e.timers.pending.size, 0);
});

test('hidden sessions have no polling timer and becoming visible refreshes the selected record', async () => {
  const e = environment({ visible: false, initialRecord: 'accounting' });
  await e.session.start(user);
  assert.equal(e.session.getState().selected, 'accounting');
  assert.equal(e.timers.pending.size, 0);
  const readsBefore = e.reads.length;
  e.session.setVisible(true);
  await settle(() => e.reads.length > readsBefore && !e.session.getState().busy);
  assert.equal(e.reads.at(-1).name, 'accounting');
  assert.deepEqual(e.timers.delays(), [60_000]);
  e.session.setVisible(false);
  assert.equal(e.timers.pending.size, 0);
  e.session.stop();
});

test('stopping disposes the client and wipes a record that arrives after logout', async () => {
  const pending = deferred(), began = deferred(), late = record();
  const e = environment({ read: () => { began.resolve(); return pending.promise; } });
  const starting = e.session.start(user);
  await began.promise;
  e.session.stop();
  const stateCount = e.states.length;
  assert.equal(e.clients[0].disposals, 1);
  assert.equal(e.session.getState().status, 'idle');
  assert.equal(e.session.getState().connection, null);
  assert.equal(e.session.getState().record, null);
  pending.resolve(late);
  await starting;
  assert.ok(late.bytes.every(byte => byte === 0));
  assert.equal(e.presentations.length, 0);
  assert.equal(e.states.length, stateCount, 'Late completion cannot repopulate a stopped session');
  assert.equal(e.timers.pending.size, 0);
});

test('a late read from an old selection cannot replace the newly selected record', async () => {
  const pending = deferred(), began = deferred(), stale = record('evidence');
  const e = environment({ read: name => {
    if (name === 'evidence') { began.resolve(); return pending.promise; }
    return record(name);
  } });
  await e.session.start(user);
  const oldRead = e.session.select('evidence');
  await began.promise;
  await e.session.select('accounting');
  pending.resolve(stale);
  await oldRead;
  assert.equal(e.session.getState().selected, 'accounting');
  assert.equal(e.session.getState().record.name, 'accounting');
  assert.deepEqual(e.presentations.map(presentation => presentation.name), ['ledger', 'accounting']);
  assert.ok(stale.bytes.every(byte => byte === 0));
  assert.deepEqual(e.timers.delays(), [60_000]);
  e.session.stop();
});

test('stop aborts a pending presentation before late completion can publish ready metadata', async () => {
  const pending = deferred(), began = deferred();
  const e = environment({ present: () => { began.resolve(); return pending.promise; } });
  const starting = e.session.start(user);
  await began.promise;
  const presentation = e.presentations[0];
  assert.equal(presentation.signal.aborted, false);
  const previousClears = e.clearCount();
  e.session.stop();
  assert.equal(presentation.signal.aborted, true);
  assert.ok(e.clearCount() > previousClears);
  pending.resolve();
  await starting;
  assert.equal(e.session.getState().status, 'idle');
  assert.equal(e.session.getState().record, null);
  assert.ok(presentation.value.bytes.every(byte => byte === 0));
});

test('conditional reads require the same successfully mounted record presentation', async () => {
  const e = environment({ read: (name, options) => options.knownVersion
    ? { name, version: options.knownVersion, unchanged: true } : record(name) });
  await e.session.start(user);
  assert.equal(e.reads[0].knownVersion, undefined);
  await e.session.refresh();
  assert.equal(e.reads[1].knownVersion, '7');
  assert.equal(e.presentations.length, 1, 'An unchanged record keeps its existing presentation');
  assert.equal(e.session.getState().record.updatedAt, '2026-09-11T00:00:00Z');
  e.setMounted(false);
  await e.session.refresh();
  assert.equal(e.reads[2].knownVersion, undefined, 'A removed view must receive a complete record again');
  assert.equal(e.presentations.length, 2);
  await e.session.select('accounting');
  assert.equal(e.reads.at(-1).knownVersion, undefined, 'The version from another record is never reused');
  e.session.stop();
});

test('unshared records and failed connections report metadata without fabricating records', async () => {
  const missing = environment({ connect: () => connection('ready', ['accounting']) });
  await missing.session.start(user);
  assert.equal(missing.session.getState().status, 'missing');
  assert.equal(missing.session.getState().record, null);
  assert.equal(missing.reads.length, 0);
  assert.equal(missing.presentations.length, 0);
  missing.session.stop();

  const failed = environment({ connect: () => { throw failure('permission'); } });
  await failed.session.start(user);
  assert.equal(failed.session.getState().status, 'error');
  assert.deepEqual(failed.session.getState().error, { code: 'permission', phase: 'connect' });
  assert.equal(failed.session.getState().busy, false);
  assert.equal(failed.presentations.length, 0);
  failed.session.stop();
});

test('read failures expose their phase and can be retried without replacing the account client', async () => {
  let fail = true;
  const e = environment({ read: name => { if (fail) throw failure('connection'); return record(name); } });
  await e.session.start(user);
  assert.equal(e.session.getState().status, 'error');
  assert.deepEqual(e.session.getState().error, { code: 'connection', phase: 'read' });
  assert.equal(e.session.getState().record, null);
  fail = false;
  await e.session.refresh();
  assert.equal(e.session.getState().status, 'ready');
  assert.equal(e.session.getState().error, null);
  assert.equal(e.clients.length, 1);
  e.session.stop();
});

test('private cleanup retains the last key owner across stop and awaits account-specific deletion', async () => {
  const deletion = deferred();
  const e = environment({ clearKey: () => deletion.promise });
  await e.session.start(user);
  e.session.stop();
  let completed = false;
  const clearing = e.session.clearPrivate(null).then(() => { completed = true; });
  await settle(() => e.clearedKeys.length === 1);
  assert.deepEqual(e.clearedKeys, [user.id]);
  assert.equal(completed, false);
  assert.equal(e.session.getState().status, 'idle');
  deletion.resolve();
  await clearing;
  await e.session.start(otherUser);
  assert.equal(e.clients.at(-1).owner, otherUser.id);
  await e.session.clearPrivate(otherUser.id);
  assert.deepEqual(e.clearedKeys, [user.id, otherUser.id]);
  await e.session.clearPrivate(null);
  assert.deepEqual(e.clearedKeys, [user.id, otherUser.id], 'A successfully deleted owner is not retained for a later logout');
});

test('refresh callers share the pending connection and read only the final selected record', async () => {
  const pending = deferred(), began = deferred();
  const e = environment({ connect: () => { began.resolve(); return pending.promise; } });
  const starting = e.session.start(user);
  assert.equal(e.session.refresh(), starting);
  await began.promise;
  assert.equal(e.session.select('accounting'), starting);
  assert.equal(e.session.refresh(), starting);
  assert.equal(e.clients[0].connects, 1);
  assert.equal(e.reads.length, 0);
  assert.equal(e.session.getState().busy, true);
  assert.equal(e.timers.pending.size, 0);
  pending.resolve(connection());
  await starting;
  assert.deepEqual(e.reads.map(read => read.name), ['accounting']);
  assert.equal(e.session.getState().record.name, 'accounting');
  assert.deepEqual(e.timers.delays(), [60_000]);
  e.session.stop();
});

test('a superseded refresh cannot clear a new selection loading state or schedule its poll', async () => {
  const oldRead = deferred(), oldBegan = deferred(), newRead = deferred(), newBegan = deferred();
  const e = environment({ read: name => {
    if (name === 'ledger') { oldBegan.resolve(); return oldRead.promise; }
    newBegan.resolve(); return newRead.promise;
  } });
  const starting = e.session.start(user);
  await oldBegan.promise;
  const selecting = e.session.select('accounting');
  await newBegan.promise;
  const stale = record('ledger');
  oldRead.resolve(stale);
  await starting;
  assert.equal(e.session.getState().status, 'reading');
  assert.equal(e.session.getState().selected, 'accounting');
  assert.equal(e.session.getState().busy, true);
  assert.equal(e.session.getState().record, null);
  assert.equal(e.timers.pending.size, 0);
  assert.ok(stale.bytes.every(byte => byte === 0));
  assert.equal(e.session.refresh(), selecting, 'A refresh during a read joins its current result');
  assert.equal(e.reads.length, 2);
  newRead.resolve(record('accounting'));
  await selecting;
  assert.equal(e.session.getState().busy, false);
  assert.equal(e.session.getState().record.name, 'accounting');
  assert.deepEqual(e.presentations.map(item => item.name), ['accounting']);
  assert.deepEqual(e.timers.delays(), [60_000]);
  e.session.stop();
});

test('changing tabs during a background reconnect waits for the new context before reading', async () => {
  const reconnect = deferred(), began = deferred();
  const e = environment({ connect: calls => {
    if (calls.connects === 2) { began.resolve(); return reconnect.promise; }
    return connection();
  } });
  await e.session.start(user);
  const refreshing = e.session.refresh();
  await began.promise;
  assert.equal(e.session.select('evidence'), refreshing);
  assert.equal(e.session.select('accounting'), refreshing);
  assert.equal(e.reads.length, 1, 'No read starts against the previous context while reconnecting');
  assert.equal(e.timers.pending.size, 0);
  reconnect.resolve(connection('ready', ['accounting']));
  await refreshing;
  assert.deepEqual(e.reads.map(read => read.name), ['ledger', 'accounting']);
  assert.equal(e.reads[1].knownVersion, undefined);
  assert.equal(e.session.getState().record.name, 'accounting');
  e.session.stop();
});

test('a stopped session never starts a queued connection or lets it affect the next account', async () => {
  const e = environment();
  const starting = e.session.start(user);
  e.session.stop();
  const next = e.session.start(otherUser);
  await Promise.all([starting, next]);
  assert.equal(e.clients[0].connects, 0);
  assert.equal(e.clients[0].disposals, 1);
  assert.deepEqual(e.reads.map(read => read.owner), [otherUser.id]);
  assert.equal(e.session.getState().busy, false);
  assert.deepEqual(e.timers.delays(), [60_000]);
  e.session.stop();
});

test('a failing state observer cannot prevent connection completion or private cleanup', async () => {
  const e = environment({ onState: () => { throw new Error('Synthetic view observer failure'); } });
  await e.session.start(user);
  assert.equal(e.session.getState().status, 'ready');
  assert.equal(e.session.getState().busy, false);
  assert.ok(e.presentations[0].value.bytes.every(byte => byte === 0));
  await e.session.clearPrivate(user.id);
  assert.deepEqual(e.clearedKeys, [user.id]);
  assert.equal(e.clients[0].disposals, 1);
  assert.equal(e.session.getState().status, 'idle');
  assert.equal(e.timers.pending.size, 0);
});

test('returning to a pending record retains shared bytes until its active presentation finishes', async () => {
  const ledger = deferred(), accounting = deferred(), presentationBegan = deferred(), presentationDone = deferred();
  let renderedBytes;
  const e = environment({
    read: name => name === 'ledger' ? ledger.promise : accounting.promise,
    present: async (_name, value) => {
      presentationBegan.resolve();
      await presentationDone.promise;
      renderedBytes = [...value.bytes];
    },
  });
  const first = e.session.start(user);
  await settle(() => e.reads.length === 1);
  const middle = e.session.select('accounting');
  await settle(() => e.reads.length === 2);
  const latest = e.session.select('ledger');
  await settle(() => e.reads.length === 3);
  const value = record('ledger'), expectedBytes = [...value.bytes];
  ledger.resolve(value);
  await presentationBegan.promise;
  await first;
  assert.deepEqual([...value.bytes], expectedBytes, 'The stale consumer cannot erase shared result bytes');
  assert.equal(e.session.getState().busy, true);
  presentationDone.resolve();
  await latest;
  assert.deepEqual(renderedBytes, expectedBytes, 'Presentation can read bytes until its promise settles');
  assert.ok(value.bytes.every(byte => byte === 0));
  const stale = record('accounting');
  accounting.resolve(stale);
  await middle;
  assert.ok(stale.bytes.every(byte => byte === 0));
  assert.deepEqual(e.presentations.map(item => item.name), ['ledger']);
  assert.equal(e.session.getState().record.name, 'ledger');
  assert.deepEqual(e.timers.delays(), [60_000]);
  e.session.stop();
});
