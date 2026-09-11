import { parseExactJSON } from './record-crypto.js';

// Authenticated records cross into an opaque, network-disabled presentation frame.
// This module never passes an access token, device key, or RPC capability to it.
const NAMES = new Set(['timeline', 'evidence', 'accounting', 'playbooks', 'health', 'spatial']);
const active = new WeakMap();
const title = {timeline: '타임라인', evidence: '증빙·전표', accounting: '분개장', playbooks: '플레이북', health: '건강', spatial: '건축물 3D'};
const target = (container) => container || document.getElementById('main-content');
const failure = (code) => Object.assign(new Error(code), {code});
// The opaque frame follows the system scheme on its own; only an explicit host
// theme (tokens.css's html[data-theme]) has to travel with the URL.
const hostTheme = () => {
  const theme = document.documentElement.dataset.theme;
  return theme === 'light' || theme === 'dark' ? `?theme=${theme}` : '';
};

export function clearRecords(container) {
  container = target(container);
  if (!container) return;
  active.get(container)?.cancel();
  active.delete(container);
  container.replaceChildren();
}

export function showRecordMessage(heading, message, {container, link = false} = {}) {
  container = target(container);
  clearRecords(container);
  const box = document.createElement('div'); box.className = 'record-empty';
  const symbol = document.createElement('span'); symbol.className = 'empty-symbol'; symbol.textContent = '⌁'; symbol.setAttribute('aria-hidden', 'true');
  const h = document.createElement('h3'); h.textContent = heading;
  const p = document.createElement('p'); p.textContent = message;
  box.append(symbol, h, p);
  if (link) { const a = document.createElement('a'); a.href = '/download'; a.className = 'button'; a.textContent = 'Mac 앱 설치 안내'; box.append(a); }
  container.append(box);
}

function payloadFor(name, record) {
  if (record?.data != null) return record.data;
  if (name === 'evidence' && typeof record?.text === 'string') return record.text;
  if (record?.json != null) return record.json;
  if (record?.bytes != null) {
    const text = new TextDecoder('utf-8', {fatal: true}).decode(record.bytes);
    return name === 'evidence' ? text : parseExactJSON(text);
  }
  throw failure('invalid');
}

export async function renderRecords(name, record, {container, signal} = {}) {
  name = name === 'ledger' ? 'timeline' : name;
  if (!NAMES.has(name)) throw failure('unsupported');
  container = target(container);
  if (!container) throw failure('unavailable');
  clearRecords(container);
  if (signal?.aborted) throw failure('cancelled');
  const data = payloadFor(name, record);
  const channel = Array.from(crypto.getRandomValues(new Uint8Array(16)), (x) => x.toString(16).padStart(2, '0')).join('');
  const frame = document.createElement('iframe');
  frame.className = 'record-frame'; frame.title = `${title[name]} 기록`;
  frame.setAttribute('sandbox', 'allow-scripts');
  frame.setAttribute('allow', "camera 'none'; microphone 'none'; geolocation 'none'; clipboard-read 'none'; clipboard-write 'none'");
  frame.referrerPolicy = 'no-referrer';
  frame.src = `/web/${name === 'timeline' ? 'timeline-frame' : 'record-frame'}.html${hostTheme()}#${channel}`;
  return new Promise((resolve, reject) => {
    let settled = false, sent = false;
    const cleanup = () => { clearTimeout(timer); window.removeEventListener('message', receive); signal?.removeEventListener('abort', cancel); };
    const finish = (error) => {
      if (settled) return;
      settled = true; cleanup();
      if (error) { frame.remove(); if (active.get(container)?.frame === frame) active.delete(container); reject(error); }
      else resolve({frame, name});
    };
    const cancel = () => { if (!settled) finish(failure('cancelled')); else { cleanup(); frame.remove(); } };
    const receive = (event) => {
      const m = event.data;
      if (event.source !== frame.contentWindow || event.origin !== 'null' || !m || typeof m !== 'object' || Array.isArray(m)) return;
      if (m.type !== 'ppomi-record-frame' || m.channel !== channel || Object.keys(m).length !== 3) return;
      if (m.stage === 'ready' && !sent) {
        sent = true;
        // '*' is required for an opaque sandbox origin. Only this known WindowProxy receives the message.
        frame.contentWindow.postMessage({type: 'ppomi-record-render', channel, name, data}, '*');
      } else if (m.stage === 'rendered' && sent) finish();
      else if (m.stage === 'error' && sent) finish(failure('render'));
    };
    const timer = setTimeout(() => finish(failure('render')), 20000);
    active.set(container, {cancel, frame});
    signal?.addEventListener('abort', cancel, {once: true});
    window.addEventListener('message', receive);
    container.append(frame);
  });
}
