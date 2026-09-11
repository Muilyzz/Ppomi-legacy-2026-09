import {parseExactJSON} from './record-crypto.js';
import display from './vendor/ledger-display.js';
const fail = () => { throw Object.assign(new Error('timeline-format'), {code: 'invalid'}); };
const text = value => typeof value === 'string' && value.length <= 4000 && !['__proto__','prototype','constructor'].includes(value);
const date = value => typeof value === 'string' && Number.isFinite(Date.parse(value));
const MAX = BigInt(Number.MAX_SAFE_INTEGER);

// Presentation only. Native archives carry the common engine's exact output.
// Older archives can show observed snapshots; they cannot create journal flows.
export function timelineProjection(archive) {
  if (!archive || archive.formatVersion !== 1 || !Array.isArray(archive.snapshots) || !Array.isArray(archive.transactions)) fail();
  let projection, observedOnly = false;
  if (typeof archive.timelinePresentation === 'string') {
    const bytes = Uint8Array.from(atob(archive.timelinePresentation), c => c.charCodeAt(0));
    projection = parseExactJSON(new TextDecoder('utf-8', {fatal: true}).decode(bytes));
    bytes.fill(0);
  } else {
    observedOnly = true;
    const accounts = [], series = Object.create(null);
    const kst = new Intl.DateTimeFormat('sv-SE', {timeZone: 'Asia/Seoul', year:'numeric', month:'2-digit', day:'2-digit', hour:'2-digit', minute:'2-digit', hourCycle:'h23'});
    for (const snapshot of archive.snapshots) {
      if (!text(snapshot.account) || !text(snapshot.app) || !date(snapshot.ts)) fail();
      const id = snapshot.account.replace(new RegExp(display.leadingDigits,'u'),'').replace(new RegExp(display.maskedNumber,'gu'),'').trim().replace(/\s+/gu,' ');
      if (!text(id)) fail();
      if (!series[id]) { accounts.push({id, app: display.titles[snapshot.app] || snapshot.app}); series[id] = []; }
      series[id].push([kst.format(new Date(snapshot.ts)), snapshot.balance, '스냅샷']);
    }
    for (const points of Object.values(series)) points.sort((a,b) => a[0].localeCompare(b[0]));
    projection = {accounts, series, inside: accounts.map(a => a.id), lines: [], defaultLens:display.defaultLens, home:'가계부', lenses: archive.lenses || [], nodes:archive.nodes || {}, lens:display.defaultLens};
  }
  if (!projection || !Array.isArray(projection.accounts) || !Array.isArray(projection.lines) || !Array.isArray(projection.inside)
    || !Array.isArray(projection.lenses) || !projection.series || !text(projection.defaultLens)) fail();
  // The canonical renderer uses Number. Prove all sums/differences stay exact;
  // otherwise show original source values rather than silently round them.
  let bound = 0n, count = 0;
  const amount = n => {
    if (typeof n === 'bigint') { bound += n < 0n ? -n : n; return; }
    if (!Number.isSafeInteger(n)) fail();
    bound += BigInt(Math.abs(n));
  };
  for (const a of projection.accounts) {
    if (!text(a.id) || !text(a.app)) fail();
    for (const p of projection.series[a.id] || []) {
      if (!Array.isArray(p) || !date(p[0]) || typeof p[2] !== 'string') fail();
      amount(p[1]); count++;
    }
  }
  for (const line of projection.lines) {
    if (!date(line.ts) || !text(line.dr) || !text(line.cr) || typeof line.memo !== 'string') fail();
    amount(line.amount);
  }
  for (const lens of projection.lenses) if (!text(lens.name) || !Array.isArray(lens.inside) || !lens.inside.every(text)) fail();
  if (!projection.inside.every(text)) fail();
  const preciseSourceOnly = bound * 4n > MAX || count > 50_000;
  return {projection: preciseSourceOnly ? null : projection, observedOnly, preciseSourceOnly,
    snapshots: observedOnly || preciseSourceOnly ? archive.snapshots : [],
    transactions: observedOnly || preciseSourceOnly ? archive.transactions : []};
}
