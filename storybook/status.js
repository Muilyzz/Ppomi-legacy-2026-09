// storybook/status.js — 「상태·비밀」 큰 면. 기기·연결 요약 + 시크릿 슬롯(Secrets.mount, 없으면 같은 훅의 빈 자리).
// 앱 셸 wire는 MZZ-54. CSS 없음: .status .jtitle .sec .card .lbl .meta .key. 꾸밈은 theme.css / simple.css 의 .status.
(function (root) {
'use strict';

var PHASE = {idle: '유휴', connected: '연결됨', busy: '진행 중'};

function esc(s) { return String(s).replace(/[&<>"']/g, function (c) { return {'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#x27;'}[c]; }); }
function phaseLabel(phase) { return PHASE[phase] || PHASE.idle; }

function surfaceCards(list) {
  if (!list || !list.length) return '<p class="meta">기기 없음</p>';
  return list.map(function (s) {
    return '<div class="card"><span class="lbl">' + esc(s.label || s.id) + '</span><div>' + esc(s.hint || '—') + '</div></div>';
  }).join('');
}

function html(st) {
  return '<div class="status">' +
    '<div class="jtitle"><h2 class="key">' + esc(st.title || '상태·비밀') + '</h2> <small class="meta">' + esc(phaseLabel(st.phase)) + '</small></div>' +
    '<div class="sec">기기·연결</div>' +
    surfaceCards(st.surfaces) +
    '<div data-secrets></div>' +
    '</div>';
}

function fillSecrets(slot, st) {
  if (root.Secrets) {
    root.Secrets.mount(slot, {
      blob: st.blob, unlocked: !!st.unlocked, expanded: !!st.expanded,
      accountKeys: st.accountKeys, onUnlock: st.onUnlock, onCopy: st.onCopy,
    });
    return;
  }
  slot.innerHTML = '<div class="sec">로컬 시크릿</div><p class="meta">시크릿 자리</p>';
}

function mount(el, opts) {
  var st = {title: '상태·비밀', phase: 'idle', surfaces: [], blob: null, unlocked: false, expanded: false};
  Object.keys(opts || {}).forEach(function (k) { if (opts[k] !== undefined) st[k] = opts[k]; });
  function draw() {
    el.innerHTML = html(st);
    var slot = el.querySelector('[data-secrets]');
    if (slot) fillSecrets(slot, st);
  }
  function set(patch) { Object.keys(patch).forEach(function (k) { st[k] = patch[k]; }); draw(); }
  draw();
  return {set: set, state: function () { return st; }};
}

root.Status = {PHASE, phaseLabel, surfaceCards, html, mount};
})(globalThis);
