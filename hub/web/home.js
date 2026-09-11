import { createAuth } from './auth.js';
import { createRecordClient, createDeviceStore } from './records.js';
import { createRecordSession } from './record-session.js';
import { createTranscriptClient } from './transcript-client.js';
import { createTranscriptSession } from './transcript-session.js';
import { renderRecords, clearRecords } from './record-views.js';
import { timelineProjection } from './timeline-projection.js';
import { AGENT_ENDPOINT } from './config.js';

// The screen is the shared workbench (/web/workbench/app.js, agent/src/web-main.tsx): the same ChatPanel and Workbench the
// Mac and Android apps show. This module only builds the browser-only layers — Supabase login, device key and enrollment,
// the record session, the sandboxed frame renderer — and hands them over as one host object. Tokens, device keys and record
// plaintext never enter that host state; the workbench asks for a token per server request and renders frames into a container.
const VIEWS = Object.freeze([
  Object.freeze({id: 'timeline', label: '타임라인', record: 'ledger'}),
  Object.freeze({id: 'evidence', label: '증빙·전표', record: 'evidence'}),
  Object.freeze({id: 'accounting', label: '분개장', record: 'accounting'}),
  Object.freeze({id: 'playbooks', label: '플레이북', record: 'playbooks'}),
  Object.freeze({id: 'health', label: '건강', record: 'health'}),
  Object.freeze({id: 'spatial', label: '건축물 3D', record: 'spatial'}),
]);
const errors = {
  storage: '브라우저 저장 공간을 사용할 수 없어요. Safari 설정을 확인한 뒤 다시 열어 주세요.',
  connection: '연결을 확인하지 못했어요. 인터넷에 연결한 뒤 다시 시도해 주세요.',
  authentication: '로그인을 다시 확인해 주세요. Google 로그인 버튼으로 시작할 수 있어요.',
  unavailable: '로그인은 ppomi.muilyzz.com에서 시작해 주세요.',
  cleanup: '계정 전환을 마치지 못했어요. 이 창을 닫고 다시 열어 주세요.',
};
const cancelled = () => Object.assign(new Error('cancelled'), {code: 'cancelled'});
const root = document.getElementById('root');
const deviceStore = createDeviceStore();
const listeners = new Set();
let auth, busy = false, restoreQueued = false, container = null, waiters = [];
let hostState = Object.freeze({account: null, deviceID: null, notice: '로그인 상태를 확인하고 있습니다.', noticeIsError: false});
let recordState = Object.freeze({status: 'idle', busy: false, selected: 'ledger', connection: null, record: null, error: null});
let transcriptState = Object.freeze({status: 'idle', transcript: null, turns: Object.freeze([]), error: null});

function notify() { for (const listener of listeners) { try { listener(); } catch { /* A view cannot break the browser layers. */ } } }
function setHost(patch) { hostState = Object.freeze({...hostState, ...patch}); notify(); }
function showUser(user) { setHost({account: user ? Object.freeze({id: user.id, name: user.name ?? null, email: user.email ?? null}) : null}); }
function showStatus(notice = '', error = false) { setHost({notice, noticeIsError: error}); }
function subscribe(listener) { listeners.add(listener); return () => listeners.delete(listener); }
// present() may run before the records pane mounted its container; wait for it, but never past the read's own cancellation.
function attached(signal) {
  if (container) return Promise.resolve(container);
  if (signal?.aborted) return Promise.reject(cancelled());
  return new Promise((resolve, reject) => {
    const waiter = {resolve, reject};
    waiters.push(waiter);
    signal?.addEventListener('abort', () => { waiters = waiters.filter(item => item !== waiter); reject(cancelled()); }, {once: true});
  });
}
const recordSession = createRecordSession({
  createClient: user => createRecordClient({auth, user, deviceStore}),
  clearKey: owner => deviceStore.clear(owner),
  clearPresentation: () => { if (container) clearRecords(container); },
  hasPresentation: () => Boolean(container?.querySelector('iframe')),
  present: async (recordName, record, {signal}) => {
    const view = VIEWS.find(item => item.record === recordName)?.id ?? recordName;
    const payload = view === 'timeline' ? {data: timelineProjection(record.json)} : {data: record.json ?? record.text};
    const target = await attached(signal);
    return renderRecords(view, payload, {container: target, signal});
  },
  onState: state => {
    recordState = state;
    // The agent server needs this browser's confirmed device ID with every request; the conversation is configured only then.
    const deviceID = state.connection?.device?.id ?? null;
    if (deviceID !== hostState.deviceID) hostState = Object.freeze({...hostState, deviceID});
    notify();
  },
  visible: !document.hidden,
  setTimeout, clearTimeout,
});
const transcriptSession = createTranscriptSession({
  createClient: user => createTranscriptClient({auth, user, deviceStore}),
  onTurns: state => { transcriptState = state; notify(); },
});
async function restore() {
  if (busy) return;
  busy = true; recordSession.stop(); transcriptSession.stop(); showUser(null); showStatus('로그인 상태를 확인하고 있습니다.');
  try {
    const session = await auth.loadSession(); showUser(session?.user ?? null); showStatus();
    if (session) { recordSession.start(session.user); transcriptSession.start(session.user); }
  }
  catch (error) { recordSession.stop(); transcriptSession.stop(); showUser(null); if (error?.code !== 'cancelled') showStatus(errors[error?.code] || errors.authentication, true); }
  finally { busy = false; if (restoreQueued) { restoreQueued = false; queueMicrotask(restore); } }
}
const host = Object.freeze({
  source: Object.freeze({
    endpoint: AGENT_ENDPOINT,
    getState: () => hostState,
    subscribe,
    getAccessToken: () => auth.getAccessToken(),
    async signIn() {
      if (busy) return;
      busy = true; showStatus('Google 로그인으로 이동합니다.');
      try { await auth.signIn(); }
      catch (error) { showStatus(errors[error?.code] || errors.authentication, true); busy = false; }
    },
    async signOut() {
      try { await auth.signOut(); showStatus('이 브라우저에서 로그아웃했습니다.'); }
      catch (error) { showStatus(errors[error?.code] || errors.cleanup, true); }
    },
  }),
  records: Object.freeze({
    views: Object.freeze(VIEWS.map(({id, label}) => Object.freeze({id, label}))),
    getState: () => recordState,
    subscribe,
    select(view) {
      const record = VIEWS.find(item => item.id === view)?.record;
      if (record) recordSession.select(record);
    },
    refresh() { recordSession.refresh(); },
    attach(element) {
      container = element;
      for (const waiter of waiters.splice(0)) waiter.resolve(element);
      return () => { if (container === element) container = null; };
    },
  }),
  transcripts: Object.freeze({
    async load() {
      await transcriptSession.refresh();
      const state = transcriptSession.getState();
      return state.status === 'ready' ? { turns: state.turns } : null;
    },
    append: turn => transcriptSession.append(turn),
    subscribe: listener => transcriptSession.watch(listener),
  }),
});
document.addEventListener('visibilitychange', () => recordSession.setVisible(!document.hidden));
window.addEventListener('pagehide', () => { recordSession.stop(); transcriptSession.stop(); showUser(null); });
let firstRestore = Promise.resolve();
try {
  auth = createAuth({
    clearSecrets: async ({previousUserId}) => {
      showUser(null);
      await Promise.all([recordSession.clearPrivate(previousUserId), transcriptSession.clearPrivate(previousUserId)]);
    },
    onChange: event => {
      if (event.type === 'signed-out') { recordSession.stop(); transcriptSession.stop(); showUser(null); showStatus(); }
      else if (event.type === 'session-changed') { if (busy) restoreQueued = true; else queueMicrotask(restore); }
    },
  });
  window.addEventListener('pageshow', event => { if (event.persisted) { busy = false; restore(); } });
  window.addEventListener('online', restore);
  firstRestore = restore();
} catch { recordSession.stop(); transcriptSession.stop(); showUser(null); showStatus(errors.storage, true); }
// The first sign-in check is usually one request; mounting after it spares a returning account the sign-in banner flash.
// A slow network never holds the screen for long, and the pending restore simply refreshes the mounted workbench later.
function mount() {
  const workbench = globalThis.PpomiWebWorkbench;
  if (typeof workbench?.mountWebWorkbench === 'function') workbench.mountWebWorkbench(root, host);
  else root.textContent = '화면을 불러오지 못했어요. 새로고침한 뒤 다시 열어 주세요.';
}
let mountTimer;
Promise.race([firstRestore, new Promise(resolve => { mountTimer = setTimeout(resolve, 4000); })]).then(() => { clearTimeout(mountTimer); mount(); });
if ('serviceWorker' in navigator && window.isSecureContext) navigator.serviceWorker.register('/service-worker.js', {scope: '/', updateViaCache: 'none'}).catch(() => {});
