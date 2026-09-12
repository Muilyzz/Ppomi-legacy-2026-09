// storybook/evidence-fleet.js — 2026-09-12 증빙 잠금 면. 서버=분개·숫자·evidence_id. 파일은 기기/E2E.
// 링크: 로컬 즉시 / 피어 온라인이면 E2E / 오프면 비활성(또는 암호문 캐시). 적격 4종 vs 보조(스냅샷/StepResult) — 스냅샷을 적격으로 포장하지 않는다.
// 앱 wire·실제 E2E 암호는 없음. CSS 없음: .ev-fleet .jtitle .sec .card .lbl .meta .key .nav table. 꾸밈은 theme.css / simple.css.
(function (root) {
'use strict';

var OFFICIAL = ['세금계산서', '카드', '현금영수증', '계산서'];
var AUX = ['스냅샷', 'StepResult'];
var LINK = {open: '열기', e2e: 'E2E', cache: '암호문 캐시', disabled: '오프라인'};

function esc(s) { return String(s).replace(/[&<>"']/g, function (c) { return {'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#x27;'}[c]; }); }

function gradeOf(kind) { return OFFICIAL.indexOf(kind) >= 0 ? '적격' : '보조'; }

function deviceOf(fleet, id) {
  for (var i = 0; i < (fleet || []).length; i++) if (fleet[i].id === id) return fleet[i];
  return null;
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

function links(st) {
  var items = st.items || [];
  if (!items.length) return '<p class="meta">증빙 없음</p>';
  var rows = items.map(function (it) {
    var state = linkState(it, st.fleet, st.here);
    var note = state === 'cache' ? ' <small class="meta">암호문만 · 원문 없음</small>' : '';
    return '<tr data-evidence="' + esc(it.evidence_id) + '" data-link="' + esc(state) + '">' +
      '<td><button type="button" class="entry" data-open="' + esc(it.evidence_id) + '"' + (state === 'disabled' ? ' disabled' : '') + '>' +
      esc(linkLabel(state)) + '</button>' + note + '</td>' +
      '<td>' + esc(it.kind) + ' ' + badges(it) + '</td>' +
      '<td><code>' + esc(it.evidence_id) + '</code></td>' +
      '<td><small class="meta">' + esc(it.host || st.here || 'local') + '</small></td></tr>';
  }).join('');
  return '<table class="ev-table" aria-label="증빙 링크"><thead><tr><th>링크</th><th>종류</th><th>evidence_id</th><th>위치</th></tr></thead><tbody>' + rows + '</tbody></table>';
}

function layers(list) {
  if (!list || !list.length) return '';
  return '<ol>' + list.map(function (p) {
    return '<li><span class="lbl">' + esc(p.title) + '</span> → <code>' + esc(p.evidence_id) + '</code>' +
      (p.note ? ' <small class="meta">' + esc(p.note) + '</small>' : '') + '</li>';
  }).join('') + '</ol>';
}

function serverMeta(st) {
  var s = st.server || {};
  var refs = (s.evidence_ids || []).map(function (id) { return '<code>' + esc(id) + '</code>'; }).join(' ');
  var amt = s.amount == null ? '' : '<span class="key n">' + Number(s.amount).toLocaleString('ko-KR') + '</span> <small class="meta">' + esc(s.unit || '원') + '</small>';
  return '<div class="card">' +
    '<span class="lbl">' + esc(s.memo || '분개') + '</span>' +
    '<div>' + amt + '</div>' +
    '<p class="meta">서버 · 파일 없음 · evidence_id ' + (refs || '없음') + '</p></div>';
}

function html(st) {
  return '<div class="ev-fleet">' +
    '<div class="jtitle"><h2 class="key">' + esc(st.title || '증빙') + '</h2> <small class="meta">파일은 기기 · 서버는 메타</small></div>' +
    '<div class="sec">서버</div>' + serverMeta(st) +
    '<div class="sec">기기</div>' + presence(st.fleet, st.here) +
    '<div class="sec">링크</div>' + links(st) +
    (st.layers && st.layers.length ? '<div class="sec">다단</div>' + layers(st.layers) : '') +
    '</div>';
}

function mount(el, opts) {
  var st = {title: '증빙', here: 'mac', fleet: [], items: [], layers: [], server: {}};
  Object.keys(opts || {}).forEach(function (k) { if (opts[k] !== undefined) st[k] = opts[k]; });
  function draw() { el.innerHTML = html(st); }
  function set(patch) { Object.keys(patch).forEach(function (k) { st[k] = patch[k]; }); draw(); }
  el.addEventListener('click', function (ev) {
    var b = ev.target.closest('[data-open]');
    if (!b || !el.contains(b) || b.disabled) return;
    if (st.onOpen) st.onOpen(b.dataset.open);
  });
  draw();
  return {set: set, state: function () { return st; }};
}

root.EvidenceFleet = {OFFICIAL, AUX, LINK, gradeOf, linkState, linkLabel, presence, html, mount};
})(globalThis);
