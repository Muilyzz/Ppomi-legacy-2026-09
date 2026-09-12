// storybook/evidence-fleet.js — 2026-09-12 증빙 잠금 면. 서버=분개·숫자. 파일은 기기/E2E. id는 디버그에서만.
// 링크: 기기 · 종류. hover=미리보기. 클릭=열기/받기(미리보기 아님). 로컬 즉시 / 피어 온라인이면 E2E+스피너 / 오프면 비활성(또는 암호문 캐시).
// 세션 미리보기 캐시: E2E 1회 후 re-hover 즉시. 원문 바이트 없음. 앱 wire·실제 E2E 암호는 없음.
// CSS 없음: .ev-fleet .jtitle .sec .card .lbl .meta .key .nav table .ev-hover .ev-tip .ev-spin.
(function (root) {
'use strict';

var OFFICIAL = ['세금계산서', '카드', '현금영수증', '계산서'];
var AUX = ['스냅샷', 'StepResult'];
var LINK = {open: '열기', e2e: 'E2E', cache: '암호문 캐시', disabled: '오프라인'};
var HOST = {mac: 'Mac', win: 'Win', phone: 'Phone'};
var PREVIEW = {
  empty: '미리보기 없음 · 기기 미부착',
  receive: '수신 중',
  session: '세션 미리보기 · 바이트 없음',
  ciphertext: '암호문 캐시 · 오프라인 · 원문 없음',
  offline: '오프라인 · 미리보기 불가',
  e2e: '미리보기 · E2E · 바이트 없음',
  local: '미리보기 · 파일은 기기 · 바이트 없음',
};

function esc(s) { return String(s).replace(/[&<>"']/g, function (c) { return {'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#x27;'}[c]; }); }

function gradeOf(kind) { return OFFICIAL.indexOf(kind) >= 0 ? '적격' : '보조'; }

function deviceOf(fleet, id) {
  for (var i = 0; i < (fleet || []).length; i++) if (fleet[i].id === id) return fleet[i];
  return null;
}

function hostLabel(fleet, host) {
  var d = deviceOf(fleet, host);
  return (d && d.label) || HOST[host] || host || 'local';
}

function collectedAt(item) {
  var n = Number(item && item.collectedAtMs);
  return Number.isFinite(n) ? n : null;
}

function timeShort(ms) {
  var d = new Date(ms);
  return (d.getUTCMonth() + 1) + '.' + d.getUTCDate() + ' ' +
    String(d.getUTCHours()).padStart(2, '0') + ':' + String(d.getUTCMinutes()).padStart(2, '0');
}

function timeFull(ms) { return new Date(ms).toISOString().replace('T', ' ').replace('Z', ''); }

function itemLabel(item, st) {
  var kind = item.kind || '';
  var label = hostLabel(st.fleet, item.host || st.here) + ' · ' + kind + (gradeOf(kind) === '보조' ? '(보조)' : '');
  var ms = collectedAt(item);
  return ms == null ? label : label + ' · ' + timeShort(ms);
}

// 자기 기기(host 없음·local·here)는 즉시. 피어가 살아 있으면 E2E. 아니면 비활성 — 암호문 캐시가 있을 때만 그 안내.
function linkState(item, fleet, here) {
  var host = item.host || here;
  if (!host || host === 'local' || host === here) return 'open';
  var peer = deviceOf(fleet, host);
  if (peer && peer.online) return 'e2e';
  return item.cache === 'ciphertext' ? 'cache' : 'disabled';
}

function linkLabel(state) { return LINK[state] || LINK.disabled; }

function flagged(map, id) { return !!(map && map[id]); }

function previewKind(it, st) {
  if (!it) return 'empty';
  var id = it.evidence_id;
  if (flagged(st && st.inflight, id)) return 'receive';
  if (flagged(st && st.session, id)) return 'session';
  var link = linkState(it, st.fleet, st.here);
  if (link === 'cache') return 'ciphertext';
  if (link === 'disabled') return 'offline';
  if (link === 'e2e') return 'e2e';
  return 'local';
}

function previewCopy(kind) { return PREVIEW[kind] || PREVIEW.local; }

function presence(fleet, here) {
  if (!fleet || !fleet.length) return '<p class="meta">기기 없음</p>';
  return '<div class="grid3">' + fleet.map(function (d) {
    var on = !!d.online, who = d.id === here ? '이 기기' : '피어';
    return '<div class="card" data-device="' + esc(d.id) + '" data-online="' + on + '">' +
      '<span class="ev-dot' + (on ? ' on' : '') + '" aria-hidden="true"></span>' +
      '<span class="lbl">' + esc(d.label || d.id) + '</span>' +
      '<div>' + esc(who + ' · ' + (on ? '온라인' : '오프라인')) + '</div></div>';
  }).join('') + '</div>';
}

function badges(item) {
  return '<small class="meta">' + esc(gradeOf(item.kind)) + ' · ' + esc(item.linked ? '연결' : '미연결') + '</small>';
}

function debugId(id, on) { return on ? ' <code>' + esc(id) + '</code>' : ''; }

function itemById(items, id) {
  for (var i = 0; i < (items || []).length; i++) if (items[i].evidence_id === id) return items[i];
  return null;
}

function previewPane(kind) {
  var spin = kind === 'receive' ? '<span class="ev-spin" aria-hidden="true"></span>' : '';
  return '<div class="ev-pop-preview">' + spin + '<span class="meta">' + esc(previewCopy(kind)) + '</span></div>';
}

function tip(it, st, id) {
  var kind = previewKind(it, st);
  var title = it ? (it.title || itemLabel(it, st)) : '미부착';
  var host = it ? hostLabel(st.fleet, it.host || st.here || 'local') : '기기 없음';
  var state = it ? linkLabel(linkState(it, st.fleet, st.here)) : '없음';
  var ms = it ? collectedAt(it) : null;
  var when = ms == null ? '' : ' · ' + timeFull(ms);
  var grade = it ? (esc(it.kind) + ' · ' + esc(gradeOf(it.kind))) : '서버 메타만';
  var link = it ? esc(it.linked ? '연결' : '미연결') : '미연결';
  return '<div class="card ev-tip" role="tooltip" data-tip="' + esc(id) + '" data-preview="' + esc(kind) + '"' +
    (kind === 'receive' ? ' aria-busy="true"' : '') + '>' +
    '<div class="jtitle"><span class="lbl">' + esc(title) + '</span></div>' +
    '<div>' + grade + '</div>' +
    '<p class="meta">' + esc(host) + ' · ' + esc(state) + ' · ' + link + when + debugId(id, st.debug) + '</p>' +
    previewPane(kind) + '</div>';
}

function hoverWrap(inner, id, st, it) {
  return '<span class="ev-hover"' + (st.hover === id ? ' data-show="1"' : '') +
    ' data-hover="' + esc(id) + '">' + inner + tip(it, st, id) + '</span>';
}

function links(st) {
  var items = st.items || [];
  if (!items.length) return '<p class="meta">증빙 없음</p>';
  var rows = items.map(function (it) {
    var state = linkState(it, st.fleet, st.here);
    var note = state === 'cache' ? ' <small class="meta">암호문만 · 원문 없음</small>' : '';
    var off = state === 'disabled';
    var ms = collectedAt(it);
    var btn = '<button type="button" class="entry" data-open="' + esc(it.evidence_id) + '"' +
      (off ? ' disabled' : '') + '>' + esc(itemLabel(it, st)) + '</button>' + note;
    return '<tr data-evidence="' + esc(it.evidence_id) + '" data-link="' + esc(state) + '"' +
      ' data-host="' + esc(it.host || st.here || 'local') + '"' +
      (ms == null ? '' : ' data-collected="' + ms + '"') + '>' +
      '<td>' + hoverWrap(btn, it.evidence_id, st, it) + '</td>' +
      '<td>' + badges(it) + ' · ' + esc(linkLabel(state)) + '</td>' +
      (st.debug ? '<td><code>' + esc(it.evidence_id) + '</code></td>' : '') + '</tr>';
  }).join('');
  return '<table class="ev-table" aria-label="증빙 링크"><thead><tr><th>링크</th><th>상태</th>' +
    (st.debug ? '<th>evidence_id</th>' : '') + '</tr></thead><tbody>' + rows + '</tbody></table>';
}

function layers(list, st) {
  if (!list || !list.length) return '';
  return '<ol>' + list.map(function (p) {
    return '<li><span class="lbl">' + esc(p.title) + '</span>' +
      (p.note ? ' <small class="meta">' + esc(p.note) + '</small>' : '') +
      debugId(p.evidence_id, st.debug) + '</li>';
  }).join('') + '</ol>';
}

function serverMeta(st) {
  var s = st.server || {};
  var ids = s.evidence_ids || [];
  var amt = s.amount == null ? '' : '<span class="key n">' + Number(s.amount).toLocaleString('ko-KR') + '</span> <small class="meta">' + esc(s.unit || '원') + '</small>';
  var refs = ids.map(function (id) {
    var it = itemById(st.items, id);
    if (it) {
      var off = linkState(it, st.fleet, st.here) === 'disabled';
      return hoverWrap(
        '<button type="button" class="entry" data-open="' + esc(id) + '"' +
          (off ? ' disabled' : '') + '>' + esc(itemLabel(it, st)) + '</button>' + debugId(id, st.debug),
        id, st, it);
    }
    return hoverWrap(
      '<button type="button" class="entry" data-open="' + esc(id) + '">미부착</button>' + debugId(id, st.debug),
      id, st, null);
  }).join(' · ');
  return '<div class="card">' +
    '<span class="lbl">' + esc(s.memo || '분개') + '</span>' +
    '<div>' + amt + '</div>' +
    '<p class="meta">서버 · 파일 없음' + (ids.length ? ' · 증빙 ' + ids.length + '건' : ' · 증빙 없음') + '</p>' +
    (refs ? '<p>' + refs + '</p>' : '') + '</div>';
}

function html(st) {
  return '<div class="ev-fleet">' +
    '<div class="jtitle"><h2 class="key">' + esc(st.title || '증빙') + '</h2> <small class="meta">파일은 기기 · 서버는 메타</small></div>' +
    '<div class="sec">서버</div>' + serverMeta(st) +
    '<div class="sec">기기</div>' + presence(st.fleet, st.here) +
    '<div class="sec">링크</div>' + links(st) +
    (st.layers && st.layers.length ? '<div class="sec">다단</div>' + layers(st.layers, st) : '') +
    '</div>';
}

function mount(el, opts) {
  var st = {title: '증빙', here: 'mac', fleet: [], items: [], layers: [], server: {}, debug: false, hover: '', session: {}, inflight: {}, receiveMs: 480};
  Object.keys(opts || {}).forEach(function (k) { if (opts[k] !== undefined) st[k] = opts[k]; });
  st.session = Object.assign({}, st.session);
  st.inflight = Object.assign({}, st.inflight);
  function draw() { el.innerHTML = html(st); }
  function paint(id) {
    if (!el.querySelector) { draw(); return; }
    var kind = previewKind(itemById(st.items, id), st);
    var nodes = el.querySelectorAll('[data-tip="' + String(id).replace(/"/g, '') + '"]');
    for (var i = 0; i < nodes.length; i++) {
      var pane = nodes[i].querySelector('.ev-pop-preview');
      if (pane) pane.outerHTML = previewPane(kind);
      nodes[i].setAttribute('data-preview', kind);
      if (kind === 'receive') nodes[i].setAttribute('aria-busy', 'true');
      else nodes[i].removeAttribute('aria-busy');
    }
  }
  function receive(id) {
    var it = itemById(st.items, id);
    if (!it || flagged(st.session, id) || flagged(st.inflight, id)) return;
    if (linkState(it, st.fleet, st.here) !== 'e2e') return;
    st.inflight[id] = true;
    paint(id);
    setTimeout(function () {
      delete st.inflight[id];
      st.session[id] = true;
      paint(id);
    }, st.receiveMs);
  }
  function set(patch) { Object.keys(patch).forEach(function (k) { st[k] = patch[k]; }); draw(); }
  el.addEventListener('click', function (ev) {
    var b = ev.target.closest('[data-open]');
    if (!b || !el.contains(b) || b.disabled) return;
    if (st.onOpen) st.onOpen(b.dataset.open);
    receive(b.dataset.open);
  });
  el.addEventListener('pointerenter', function (ev) {
    var w = ev.target.closest('[data-hover]');
    if (!w || !el.contains(w)) return;
    receive(w.dataset.hover);
  }, true);
  draw();
  return {set: set, state: function () { return st; }};
}

root.EvidenceFleet = {OFFICIAL, AUX, LINK, HOST, PREVIEW, gradeOf, hostLabel, itemLabel, collectedAt, timeShort, timeFull, linkState, linkLabel, previewKind, previewCopy, presence, html, mount};
})(globalThis);
