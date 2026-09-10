// Web/journal.js — 분개 하나를 모든 스코프로 본다. 사건 하나도, 하루·주·달·분기·반기·해·전체도 같은 표(차변 | 대변)다.
// 축 둘: 스코프 = 발생 시각 창(사건은 eventID), 깊이 = 계정 계층을 어디까지 펴서 보이는지(0 = 유형 다섯).
// 층: 원본만(recorded) | 유효한 평가 조정까지 상계(effective). 선택·상계 규칙은 AccountingEngine.entries / netPostings 와 같다.
// CSS 없음: 시맨틱 마크업에 theme.css 의 훅(.sec .nav .on .n .meta .key .card)만 단다. 꾸밈은 밖에서 <style>로 주입한다.
// 앱은 journal.html <script>에 끼워 넣고 Storybook은 import 한다 — 둘 다 globalThis.Journal.
(function (root) {
'use strict';
var UNITS = ['event', 'day', 'week', 'month', 'quarter', 'half', 'year', 'all'];
var UNIT_LABEL = {event: '사건', day: '일', week: '주', month: '월', quarter: '분기', half: '반기', year: '년', all: '전체'};
var KIND_ORDER = ['asset', 'liability', 'equity', 'income', 'expense'];
var KIND_LABEL = {asset: '자산', liability: '부채', equity: '자본', income: '수익', expense: '비용'};
var WEEKDAY = '일월화수목금토', LIST_LIMIT = 300;   // ponytail: 목록은 300행까지. 넘으면 '외 n건' — 긴 스코프의 목록은 하위 스코프 표가 맞다

function esc(s) { return String(s).replace(/[&<>"']/g, function (c) { return {'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#x27;'}[c]; }); }
function pad(n) { return String(n).padStart(2, '0'); }
function ymd(d) { return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()); }
function hm(d) { return pad(d.getHours()) + ':' + pad(d.getMinutes()); }
// 'YYYY-MM-DD' is a local calendar day (Date('YYYY-MM-DD') would be UTC midnight); anything else is what Date makes of it.
function toDate(at) { var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(at); return at instanceof Date ? at : m ? new Date(+m[1], m[2] - 1, +m[3]) : new Date(at); }

// ---- 스코프 창: [start, end) 로컬 시각. event·all 은 창이 없다(null).
function span(unit, at) {
  var d = toDate(at), y = d.getFullYear(), m = d.getMonth(), day = d.getDate();
  switch (unit) {
    case 'day': return [new Date(y, m, day), new Date(y, m, day + 1)];
    case 'week': { var s = new Date(y, m, day - (d.getDay() + 6) % 7); return [s, new Date(s.getFullYear(), s.getMonth(), s.getDate() + 7)]; }   // 월요일 시작
    case 'month': return [new Date(y, m, 1), new Date(y, m + 1, 1)];
    case 'quarter': { var q = m - m % 3; return [new Date(y, q, 1), new Date(y, q + 3, 1)]; }
    case 'half': { var h = m < 6 ? 0 : 6; return [new Date(y, h, 1), new Date(y, h + 6, 1)]; }
    case 'year': return [new Date(y, 0, 1), new Date(y + 1, 0, 1)];
    default: return null;
  }
}
function shift(unit, at, n) {
  var w = span(unit, at); if (!w) return at;
  var s = w[0], months = {month: 1, quarter: 3, half: 6, year: 12}[unit];
  return months ? new Date(s.getFullYear(), s.getMonth() + months * n, 1) : new Date(s.getFullYear(), s.getMonth(), s.getDate() + (unit === 'week' ? 7 : 1) * n);
}
function title(unit, at) {
  var w = span(unit, at); if (!w) return UNIT_LABEL[unit];
  var s = w[0], y = s.getFullYear(), m = s.getMonth();
  switch (unit) {
    case 'day': return ymd(s) + ' (' + WEEKDAY[s.getDay()] + ')';
    case 'week': { var e = new Date(w[1] - 1); return ymd(s) + ' ~ ' + pad(e.getMonth() + 1) + '-' + pad(e.getDate()); }
    case 'month': return y + '년 ' + (m + 1) + '월';
    case 'quarter': return y + '년 ' + (m / 3 + 1) + '분기';
    case 'half': return y + '년 ' + (m < 6 ? '상반기' : '하반기');
    default: return y + '년';
  }
}

// ---- 선택: 원본 + (effective) 평가 체인마다 마지막 조정 하나. 발생·기록 시각·ID 순.
function activeEntries(archive, bookID, layer) {
  var superseded = {};
  archive.entries.forEach(function (e) { if (e.assessment && e.assessment.replacesEntryID) superseded[e.assessment.replacesEntryID] = 1; });
  return archive.entries.filter(function (e) {
    return e.bookID === bookID && (e.layer === 'recorded' || (layer === 'effective' && e.layer === 'adjustment' && !superseded[e.id]));
  }).sort(function (a, b) {
    return Date.parse(a.occurredAt) - Date.parse(b.occurredAt) || Date.parse(a.recordedAt) - Date.parse(b.recordedAt) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
  });
}
function inScope(entries, unit, at) {
  if (unit === 'event') return entries.filter(function (e) { return e.eventID === at; });
  var w = span(unit, at); if (!w) return entries;
  var s = +w[0], e = +w[1];
  return entries.filter(function (x) { var t = Date.parse(x.occurredAt); return t >= s && t < e; });
}
function eventIDs(entries) { var seen = {}, out = []; entries.forEach(function (e) { if (e.layer === 'recorded' && !seen[e.eventID]) { seen[e.eventID] = 1; out.push(e.eventID); } }); return out; }

// ---- 깊이: 계정을 조상 계층의 depth 번째로 접는다. 0 = 유형, 계층보다 깊으면 그 계정 자신. 모르는 ID는 ID 그대로(추측하지 않는다).
function chain(byID, id) { var out = [], seen = {}; for (var a = byID[id]; a && !seen[a.id]; a = byID[a.parentID]) { seen[a.id] = 1; out.unshift(a); } return out; }
function rollup(accounts, depth) {
  var byID = {}; accounts.forEach(function (a) { byID[a.id] = a; });
  return function (id) {
    var c = chain(byID, id);
    if (!c.length) return {id: id, name: id, kind: '', path: []};
    if (depth === 0) { var k = c[0].kind; return {id: 'kind:' + k, name: KIND_LABEL[k] || k, kind: k, path: []}; }
    var n = Math.min(depth, c.length), t = c[n - 1];
    return {id: t.id, name: t.name, kind: t.kind, path: c.slice(0, n - 1).map(function (a) { return a.name; })};
  };
}
function maxDepth(accounts, bookID) {
  var byID = {}, n = 0; accounts.forEach(function (a) { byID[a.id] = a; });
  accounts.forEach(function (a) { if (a.bookID === bookID) n = Math.max(n, chain(byID, a.id).length); });
  return n;
}

// ---- 집계 = 스코프 전체를 분개 하나로: 접은 계정마다 차변 양수로 상계하고 부호로 나눈다. 분개마다 차대가 맞으니 합도 맞는다.
// ponytail: Number 합 — 최소단위 2^53(원화 9천조)까지 정확. 그 위는 BigInt.
function aggregate(entries, accounts, depth) {
  var to = rollup(accounts, depth), net = {}, meta = {};
  entries.forEach(function (e) { e.postings.forEach(function (p) { var t = to(p.accountID); meta[t.id] = t; net[t.id] = (net[t.id] || 0) + (p.side === 'debit' ? p.amount : -p.amount); }); });
  var debit = [], credit = [];
  Object.keys(net).forEach(function (id) { var v = net[id]; if (v) (v > 0 ? debit : credit).push({account: meta[id], amount: Math.abs(v)}); });
  var by = function (a, b) { return KIND_ORDER.indexOf(a.account.kind) - KIND_ORDER.indexOf(b.account.kind) || b.amount - a.amount || (a.account.name < b.account.name ? -1 : 1); };
  var sum = function (rows) { return rows.reduce(function (s, r) { return s + r.amount; }, 0); };
  debit.sort(by); credit.sort(by);
  return {debit: debit, credit: credit, debitTotal: sum(debit), creditTotal: sum(credit), count: entries.length};
}
// 최소단위 정수 → 단위 표기. 소수 자리는 문자열로 자른다(부동소수 없음).
function amount(n, unit) {
  var s = unit.scale || 0, a = String(Math.abs(n)).padStart(s + 1, '0'), i = a.slice(0, a.length - s), f = a.slice(a.length - s);
  return (n < 0 ? '−' : '') + BigInt(i).toLocaleString('ko-KR') + (s ? '.' + f : '') + ' ' + unit.symbol;
}

// ---- 마크업
function btn(key, value, label, on) { return '<button type="button" data-' + key + '="' + esc(value) + '"' + (on ? ' class="on" aria-pressed="true"' : ' aria-pressed="false"') + '>' + esc(label) + '</button>'; }
function cell(row, unit) {
  if (!row) return '<td></td><td></td>';
  var path = row.account.path.length ? '<small class="meta">' + esc(row.account.path.join(' / ')) + ' / </small>' : '';
  return '<td>' + path + esc(row.account.name) + '</td><td class="n">' + amount(row.amount, unit) + '</td>';
}
function journalTable(agg, unit) {
  var n = Math.max(agg.debit.length, agg.credit.length), rows = '';
  for (var i = 0; i < n; i++) rows += '<tr>' + cell(agg.debit[i], unit) + cell(agg.credit[i], unit) + '</tr>';
  return '<table class="journal" aria-label="분개"><thead><tr><th scope="col">차변</th><th scope="col" class="n">금액</th><th scope="col">대변</th><th scope="col" class="n">금액</th></tr></thead>' +
    '<tbody>' + rows + '</tbody><tfoot><tr><th>합계</th><th class="n">' + amount(agg.debitTotal, unit) + '</th><th></th><th class="n">' + amount(agg.creditTotal, unit) + '</th></tr></tfoot></table>';
}
function entryList(entries, accounts, unit, scopeUnit) {
  if (!entries.length) return '';
  var leaf = rollup(accounts, Infinity), shown = entries.slice(0, LIST_LIMIT);
  var rows = shown.map(function (e) {
    var d = new Date(e.occurredAt), when = scopeUnit === 'day' ? hm(d) : scopeUnit === 'week' || scopeUnit === 'month' ? (d.getMonth() + 1) + '/' + d.getDate() + ' ' + hm(d) : ymd(d);
    var names = function (side) { return e.postings.filter(function (p) { return p.side === side; }).map(function (p) { return leaf(p.accountID).name; }).join(' + '); };
    var total = e.postings.reduce(function (s, p) { return s + (p.side === 'debit' ? p.amount : 0); }, 0);
    return '<tr data-event="' + esc(e.eventID) + '"><td><small class="meta">' + esc(when) + '</small></td><td><button class="entry" type="button">' + esc(e.memo || '분개') + '</button></td>' +
      '<td><small class="meta">' + esc(names('credit')) + ' → ' + esc(names('debit')) + '</small></td><td class="n">' + amount(total, unit) + '</td></tr>';
  }).join('');
  if (entries.length > shown.length) rows += '<tr><td colspan="4"><small class="meta">… 외 ' + (entries.length - shown.length) + '건</small></td></tr>';
  return '<div class="sec">분개 ' + entries.length + '건</div><table class="entries" aria-label="분개 목록"><tbody>' + rows + '</tbody></table>';
}
function eventMeta(entries) {
  return entries.filter(function (e) { return e.layer === 'recorded'; }).map(function (e) {
    return '<div><small class="meta">' + esc(new Date(e.occurredAt).toLocaleString('ko-KR')) + ' · 활동 ' + esc(e.eventID) + ' · 출처 ' + esc(e.source) + (e.sourceRecordID ? ' · 기록 ' + esc(e.sourceRecordID) : '') + '</small></div>';
  }).join('');
}
function assessments(entries) {
  return entries.filter(function (e) { return e.layer === 'adjustment'; }).map(function (e) {
    var a = e.assessment || {};
    return '<div class="card"><div class="lbl">평가 조정 · 신뢰도 ' + (a.confidenceBasisPoints / 100) + '% · ' + esc(a.model || '모델 미기재') + (a.replacesEntryID ? ' · 이전 평가 ' + esc(a.replacesEntryID) + ' 대체' : '') + '</div>' +
      '<div>' + esc(a.rationale || '') + '</div>' + (e.postings.length ? '' : '<small class="meta">추가 차변·대변 없음 · 이전 평가 철회</small>') + '</div>';
  }).join('');
}
function html(st) {
  var book = st.archive.books.find(function (b) { return b.id === st.bookID; });
  if (!book) return '<p class="meta">장부를 찾을 수 없습니다: ' + esc(st.bookID) + '</p>';
  var accounts = st.archive.accounts, deepest = maxDepth(accounts, st.bookID), depth = Math.min(st.depth, deepest);
  var active = activeEntries(st.archive, st.bookID, st.layer), scoped = inScope(active, st.unit, st.at), agg = aggregate(scoped, accounts, depth);
  var isEvent = st.unit === 'event', first = scoped.find(function (e) { return e.layer === 'recorded'; });
  var heading = isEvent ? (first ? first.memo || '분개' : '사건 없음') : title(st.unit, st.at);
  var depths = ''; for (var d = 0; d <= deepest; d++) depths += btn('depth', d, d ? String(d) : '유형', depth === d);
  return '<div class="jtitle"><h2 class="key">' + esc(heading) + '</h2>' + (isEvent ? '' : ' <small class="meta">' + agg.count + '건</small>') + '</div>' +
    (isEvent ? eventMeta(scoped) : '') +
    '<div class="jnav">' +
    (st.unit === 'all' ? '' : '<nav class="nav" aria-label="이동"><button type="button" data-move="-1" aria-label="이전">‹</button><button type="button" data-move="1" aria-label="다음">›</button></nav>') +
    '<nav class="nav" aria-label="스코프">' + (isEvent ? '<span class="on">사건</span>' : '') + UNITS.slice(1).map(function (u) { return btn('unit', u, UNIT_LABEL[u], st.unit === u); }).join('') + '</nav>' +
    '<nav class="nav" aria-label="계정 깊이"><span>깊이</span>' + depths + '</nav>' +
    '<nav class="nav" aria-label="장부 층">' + btn('layer', 'recorded', '원본', st.layer === 'recorded') + btn('layer', 'effective', '관리 · 평가 포함', st.layer === 'effective') + '</nav></div>' +
    (agg.count ? journalTable(agg, book.unit) : '<p class="meta">이 스코프에 분개가 없습니다.</p>') +
    (isEvent ? assessments(scoped) : entryList(scoped.filter(function (e) { return e.layer === 'recorded'; }), accounts, book.unit, st.unit));
}

// ---- mount(el, {archive, bookID, unit, at, depth, layer, onChange}) → {set, state}. at = 'YYYY-MM-DD' | Date | (unit=event) eventID.
function mount(el, opts) {
  var st = {unit: 'month', at: new Date(), depth: 1, layer: 'recorded'};
  Object.keys(opts).forEach(function (k) { st[k] = opts[k]; });
  function draw() { el.innerHTML = html(st); }
  function set(patch) { Object.keys(patch).forEach(function (k) { st[k] = patch[k]; }); draw(); if (st.onChange) st.onChange({unit: st.unit, at: st.at, depth: st.depth, layer: st.layer}); }
  function recorded() { return activeEntries(st.archive, st.bookID, 'recorded'); }
  function eventDate() { var e = recorded().find(function (x) { return x.eventID === st.at; }); return e ? new Date(e.occurredAt) : new Date(); }
  function stepEvent(n) { var ids = eventIDs(recorded()), i = ids.indexOf(st.at); return ids[Math.max(0, Math.min(ids.length - 1, i + n))] || st.at; }
  el.addEventListener('click', function (ev) {
    var b = ev.target.closest('[data-unit],[data-move],[data-depth],[data-layer],[data-event]');
    if (!b || !el.contains(b)) return;
    var d = b.dataset;
    if (d.unit) set({unit: d.unit, at: st.unit === 'event' ? eventDate() : st.at});
    else if (d.move) set({at: st.unit === 'event' ? stepEvent(+d.move) : shift(st.unit, st.at, +d.move)});
    else if (d.depth) set({depth: +d.depth});
    else if (d.layer) set({layer: d.layer});
    else if (d.event) set({unit: 'event', at: d.event});
  });
  draw();
  return {set: set, state: function () { return st; }};
}

root.Journal = {UNITS, UNIT_LABEL, KIND_LABEL, span, shift, title, activeEntries, inScope, eventIDs, rollup, maxDepth, aggregate, amount, html, mount};
})(globalThis);
