// Web/playbook.js — 절차 뷰. 명세(manifest.capabilities[].steps)는 앞이 같은 단계를 접은 나무, 발자국(footprints)은 화면이 노드·걸음이 간선인 그래프.
//   나무: 기능 여러 개가 같은 앞부분(열기 → 팝업 닫기 → 로그인 → 👤인증)을 공유하면 한 줄기로 접히고, 갈라지는 곳에서 가지가 난다.
//   그래프: 노드 = 화면 지문(안정 단어, Jaccard ≥ .5 면 같은 화면 — Footprints.swift 의 threshold), 간선 = 발자국(before 화면 → 걸음 → after 화면) + 검증 횟수.
//          뒤로가기·닫기로 같은 화면에 돌아오면 사이클이라 되돌아가는 간선은 오른쪽 점선 곡선.
//   명세 단계에 글리프가 같고 대상이 맞는 성공 발자국이 있으면 그 단계는 '걸어 본' 단계로 채운다.
// 대상(폰·Mac 브라우저·Windows)은 패키지 형식이 가리지 않으니 뷰도 가리지 않는다 — 어느 앱 목록에서든 같은 뷰를 끼운다.
// CSS 없음: 기하·잉크는 SVG 속성(자료), 꾸밈은 skin 의 .pb-* 훅. 앱은 끼워 넣고 Storybook은 import — globalThis.Playbook.
//
// manifest: {name, version, launch:{search, target?}, capabilities:[{id, title, steps:[{id, title, kind}]}]}
// verification(선택): {ok, changed, fail, unverified, stale, steps:{'기능/단계': {outcome, actual?, note?, at}}} — Verify.summary 또는 Swift VerificationStore.summary 의 결과. 판정이 있으면 발자국 휴리스틱보다 앞선다
// footprints: [{id, glyph, target, fingerprintBefore:[…], fingerprintAfter:[…], verified:{ok, fail, replayOK?, replayFail?}}]
(function (root) {
'use strict';
var VW = 640, GLYPHS = /^([▶⊙⌨↓⎋👤🎟🔍✋📝👁🌐🏦️]+)\s*(.*)$/u;
var KIND = {open: '▶', tap: '⊙', input: '⌨', scroll: '↓', close: '⎋', human: '👤', read: '📝', payment: '✋', choice: '🔍', coupon: '🎟', 'payment-method': '🔍'};
var TARGET = {browser: 'Mac 브라우저', windows: 'Windows'};
var HANDOFF = {'👤': '사용자 차례', '✋': '승인 필요 지점'};   // 소뇌가 못 밟는 걸음 둘(Footprint.handoff)
var MARK = {ok: '✓', changed: '△', fail: '✗'}, FILL = {ok: '.25', changed: '.15', fail: '.05'};   // 판정 장부(verification.steps) 의 세 낱말

function esc(s) { return String(s).replace(/[&<>"']/g, function (c) { return {'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#x27;'}[c]; }); }
function r1(v) { return Math.round(v * 10) / 10; }
function clip(s, n) { return s.length > n ? s.slice(0, Math.max(1, n - 1)) + '…' : s; }
function you(glyph) { return Object.keys(HANDOFF).find(function (g) { return glyph.indexOf(g) >= 0; }); }
function glyphOf(step) {   // 제목 앞의 글리프, 없으면 kind 로
  var m = GLYPHS.exec(step.title || '');
  return m ? {glyph: m[1].replace(/️/g, ''), text: m[2]} : {glyph: KIND[step.kind] || '', text: step.title || ''};
}

// ---- 명세 → 나무: 같은 깊이의 같은 제목은 한 노드. 잎마다 열 하나, 가지는 자식들의 가운데
function tree(caps) {
  var nodes = [], top = {children: []};
  (caps || []).forEach(function (c) {
    var at = top;
    (c.steps || []).forEach(function (s, depth) {
      var g = glyphOf(s), label = g.glyph + g.text;
      var n = at.children.find(function (x) { return x.label === label; });
      if (!n) { n = {id: 'n' + nodes.length, label: label, glyph: g.glyph, text: g.text, kind: s.kind, depth: depth, caps: [], steps: [], children: [], parent: at === top ? null : at}; nodes.push(n); at.children.push(n); }
      if (n.caps.indexOf(c.id) < 0) n.caps.push(c.id);
      n.steps.push(c.id + '/' + s.id);
      at = n;
    });
  });
  var col = 0;
  (function place(n) { if (!n.children.length) { n.x = col++; return; } n.children.forEach(place); n.x = (n.children[0].x + n.children[n.children.length - 1].x) / 2; })(top);
  return {nodes: nodes, cols: nodes.length ? col : 0, depth: nodes.reduce(function (m, n) { return Math.max(m, n.depth + 1); }, 0)};
}
// ponytail: 명세 단계와 발자국은 ID 로 안 이어져 있다(playbook-format.md). 글리프가 같고 단계 제목(정규식)이 발자국 대상에 맞으면 걸은 것으로 친다 — 이어지면 이걸 지운다.
function verdict(node, ver) {   // 판정 장부에서 이 노드가 대표하는 단계들 중 가장 최근 판정
  var steps = ver && ver.steps, best = null; if (!steps) return null;
  node.steps.forEach(function (k) { var v = steps[k]; if (v && (!best || String(v.at || '') > String(best.at || ''))) best = v; });
  return best;
}
function walked(node, fps) {
  var best = null;
  (fps || []).forEach(function (f) {
    if (!f.glyph || node.glyph.indexOf(f.glyph) < 0 || !(f.verified && f.verified.ok > 0)) return;
    var t = String(f.target || '').replace(/^\^|\$$/g, ''), hit = false;
    if (t && node.text) { try { hit = new RegExp(node.text).test(t); } catch (e) { hit = false; } hit = hit || t.indexOf(node.text) >= 0 || node.text.indexOf(t) >= 0; }
    if (hit && (!best || f.verified.ok > best.verified.ok)) best = f;
  });
  return best;
}

// ---- 발자국 → 그래프: 지문을 화면으로 뭉치고, 같은 화면 쌍·같은 걸음은 간선 하나로 합쳐 횟수를 더한다. 빈 지문은 '빈 화면' 하나
function jaccard(a, b) {
  var x = new Set(a), y = new Set(b), n = 0, u = x.size;
  y.forEach(function (w) { if (x.has(w)) n++; else u++; });
  return u ? n / u : 0;
}
function screens(fps) {
  var nodes = [], edges = [];
  function node(words) {
    words = words || [];
    var best = null, bs = 0;
    nodes.forEach(function (n) { var s = words.length || n.words.length ? jaccard(words, n.words) : 1; if (s >= 0.5 && s > bs) { best = n; bs = s; } });
    if (best) return best;
    var n = {id: 's' + nodes.length, words: words, label: words.length ? words.slice(0, 3).join(' ') : '빈 화면', in: 0, out: 0}; nodes.push(n); return n;
  }
  (fps || []).forEach(function (f) {
    var a = node(f.fingerprintBefore), b = node(f.fingerprintAfter), v = f.verified || {};
    var key = a.id + '>' + b.id + ':' + f.glyph + f.target, e = edges.find(function (x) { return x.key === key; });
    if (!e) { e = {id: 'w' + edges.length, key: key, from: a, to: b, glyph: f.glyph || '', target: f.target || '', ok: 0, fail: 0, replayOK: 0, replayFail: 0, ids: []}; edges.push(e); a.out++; b.in++; }
    e.ok += v.ok || 0; e.fail += v.fail || 0; e.replayOK += v.replayOK || 0; e.replayFail += v.replayFail || 0; e.ids.push(f.id);
  });
  return {nodes: nodes, edges: edges};
}
// 층: DFS 로 되돌아가는 간선(사이클)을 표시하고, 나머지 간선으로 가장 긴 경로 깊이를 층으로 삼는다
function layers(g) {
  var state = {}, out = {};
  g.edges.forEach(function (e) { (out[e.from.id] = out[e.from.id] || []).push(e); e.back = false; });
  function dfs(n) { state[n.id] = 1; (out[n.id] || []).forEach(function (e) { if (state[e.to.id] === 1) e.back = true; else if (!state[e.to.id]) dfs(e.to); }); state[n.id] = 2; }
  g.nodes.filter(function (n) { return !n.in; }).concat(g.nodes).forEach(function (n) { if (!state[n.id]) dfs(n); });
  g.nodes.forEach(function (n) { n.layer = 0; });
  for (var i = 0, moved = true; moved && i <= g.nodes.length; i++) {
    moved = false;
    g.edges.forEach(function (e) { if (!e.back && e.to.layer < e.from.layer + 1) { e.to.layer = e.from.layer + 1; moved = true; } });
  }
  return g;
}
function evidence(fps) {   // Playbooks.swift PlaybookEvidence 와 같은 셈
  var e = {saved: 0, replayed: 0, replayOK: 0, replayFail: 0, ok: 0, fail: 0};
  (fps || []).forEach(function (f) { var v = f.verified || {}; e.saved++; if (v.replayOK > 0) e.replayed++; e.replayOK += v.replayOK || 0; e.replayFail += v.replayFail || 0; e.ok += v.ok || 0; e.fail += v.fail || 0; });
  return e;
}

// ---- 그리기
function treeSVG(st, t, fps) {
  var PITCH = 34, BH = 22, colW = VW / Math.max(1, t.cols), bw = Math.min(320, Math.max(40, colW - 14)), H = t.depth * PITCH + 12, fit = Math.max(2, Math.floor((bw - 10) / 12));
  var cx = function (n) { return (n.x + 0.5) * colW; }, ty = function (n) { return 6 + n.depth * PITCH; }, g = '';
  t.nodes.forEach(function (n) {
    if (!n.parent) return;
    var x1 = r1(cx(n.parent)), y1 = ty(n.parent) + BH, x2 = r1(cx(n)), y2 = ty(n);
    g += '<path class="pb-branch" d="M' + x1 + ' ' + y1 + 'V' + (y1 + 6) + 'H' + x2 + 'V' + y2 + '" fill="none" stroke="currentColor" stroke-opacity=".4"/>';
  });
  t.nodes.forEach(function (n) {
    var v = verdict(n, st.verification), fp = v ? null : walked(n, fps), hand = you(n.glyph), dim = st.cap && n.caps.indexOf(st.cap) < 0, hit = st.selected === n.id;
    var mark = v ? MARK[v.outcome] || '' : fp ? '·' : '', label = (mark ? mark + ' ' : '') + n.glyph + ' ' + n.text;
    var cls = 'pb-step' + (v ? ' ' + v.outcome : fp ? ' walked' : '') + (hand ? ' you' : '') + (hit ? ' hit' : '') + (dim ? ' dim' : '');
    var tip = n.glyph + ' ' + n.text + (v ? '\n판정 ' + v.outcome + (v.actual ? ' · 실제: ' + v.actual : '') + (v.note ? ' · ' + v.note : '') + ' · ' + String(v.at || '').slice(0, 10) : '') +
      (fp ? '\n걸어 봄 ' + fp.verified.ok + '회 · ' + fp.glyph + fp.target : '') + (hand ? '\n' + hand : '') + '\n' + n.caps.join(', ');
    g += '<g class="' + cls + '" data-step="' + n.id + '" role="button" tabindex="0" aria-label="' + esc(label) + '"' + (dim ? ' opacity=".3"' : '') + '><title>' + esc(tip) + '</title>' +
      '<rect x="' + r1(cx(n) - bw / 2) + '" y="' + ty(n) + '" width="' + r1(bw) + '" height="' + BH + '" rx="4" fill="currentColor" fill-opacity="' + (hit ? '.35' : v ? FILL[v.outcome] || '.05' : fp ? '.2' : '.05') + '" stroke="currentColor" stroke-opacity="' + (v || fp ? '.9' : '.45') + '"' + (hand ? ' stroke-dasharray="3 2"' : '') + '/>' +
      '<text x="' + r1(cx(n) - bw / 2 + 6) + '" y="' + (ty(n) + 15) + '" font-size="12" fill="currentColor">' + esc(clip(label, fit)) + '</text></g>';
  });
  return '<svg class="pb-tree" viewBox="0 0 ' + VW + ' ' + H + '" role="img" aria-label="명세 나무">' + g + '</svg>';
}
function walksSVG(st, g) {
  var PITCH = 64, BH = 22, W = VW - 150, rows = [], maxL = 0, s = '';   // 오른쪽 150 은 되돌아가는 곡선과 그 라벨 자리
  g.nodes.forEach(function (n) { (rows[n.layer] = rows[n.layer] || []).push(n); maxL = Math.max(maxL, n.layer); });
  g.nodes.forEach(function (n) { var row = rows[n.layer], colW = W / row.length; n.cx = (row.indexOf(n) + 0.5) * colW; n.bw = Math.min(200, colW - 12); n.y = 8 + n.layer * PITCH; });
  var H = maxL * PITCH + BH + 16;
  g.edges.forEach(function (e) {
    var hand = HANDOFF[e.glyph], hit = st.selected === e.id, label = clip(e.glyph + ' ' + e.target, 18) + (e.ok ? ' ✓' + e.ok : '') + (e.fail ? ' ✗' + e.fail : ''), d, lx, ly;
    if (e.back) {
      var self = e.from === e.to, xr1 = r1(e.from.cx + e.from.bw / 2), y1 = e.from.y + (self ? 3 : BH / 2), xr2 = r1(e.to.cx + e.to.bw / 2), y2 = e.to.y + (self ? BH - 3 : BH / 2), bx = Math.max(xr1, xr2) + 60;
      d = 'M' + xr1 + ' ' + y1 + 'C' + bx + ' ' + y1 + ' ' + bx + ' ' + y2 + ' ' + xr2 + ' ' + y2; lx = Math.max(xr1, xr2) + 48; ly = r1((y1 + y2) / 2 + 4);
    } else {
      var x1 = r1(e.from.cx), yb = e.from.y + BH, x2 = r1(e.to.cx), yt = e.to.y;
      d = 'M' + x1 + ' ' + yb + 'L' + x2 + ' ' + yt; lx = r1((x1 + x2) / 2 + 6); ly = r1((yb + yt) / 2 + 4);
    }
    var tip = e.glyph + ' ' + e.target + '\n성공 ' + e.ok + ' · 실패 ' + e.fail + ' · 재생 ' + e.replayOK + '/' + (e.replayOK + e.replayFail) + (hand ? '\n' + hand : '') + (e.back ? '\n되돌아감' : '');
    s += '<g class="pb-walk' + (e.ok ? ' ok' : '') + (hand ? ' you' : '') + (e.back ? ' back' : '') + (hit ? ' hit' : '') + '" data-walk="' + e.id + '" role="button" tabindex="0" aria-label="' + esc(label) + '"><title>' + esc(tip) + '</title>' +
      '<path d="' + d + '" fill="none" stroke="currentColor" stroke-opacity="' + (hit ? '1' : e.ok ? '.85' : '.35') + '" stroke-width="' + (hit ? '2.5' : e.ok ? '1.5' : '1') + '"' + (hand || e.back ? ' stroke-dasharray="' + (hand ? '3 2' : '5 3') + '"' : '') + '/>' +
      '<text x="' + lx + '" y="' + ly + '" font-size="10" fill="currentColor" opacity=".8">' + esc(label) + '</text></g>';
  });
  g.nodes.forEach(function (n) {
    var hit = st.selected === n.id, fit = Math.max(2, Math.floor((n.bw - 10) / 12));
    s += '<g class="pb-screen' + (hit ? ' hit' : '') + '" data-screen="' + n.id + '" role="button" tabindex="0" aria-label="' + esc('화면 ' + n.label) + '"><title>' + esc(n.words.join(' · ') || '빈 화면') + '</title>' +
      '<rect x="' + r1(n.cx - n.bw / 2) + '" y="' + n.y + '" width="' + r1(n.bw) + '" height="' + BH + '" rx="11" fill="currentColor" fill-opacity="' + (hit ? '.35' : '.1') + '" stroke="currentColor" stroke-opacity=".7"/>' +
      '<text x="' + r1(n.cx) + '" y="' + (n.y + 15) + '" font-size="12" text-anchor="middle" fill="currentColor">' + esc(clip(n.label, fit)) + '</text></g>';
  });
  return '<svg class="pb-walks" viewBox="0 0 ' + VW + ' ' + H + '" role="img" aria-label="발자국 그래프">' + s + '</svg>';
}
function btn(key, value, label, on) { return '<button type="button" data-' + key + '="' + esc(value) + '"' + (on ? ' class="on" aria-pressed="true"' : ' aria-pressed="false"') + '>' + esc(label) + '</button>'; }
function html(st) {
  var m = st.manifest || {}, caps = m.capabilities || [], fps = st.footprints || [], t = tree(caps), ev = evidence(fps), launch = m.launch || {}, ver = st.verification;
  var steps = caps.reduce(function (s, c) { return s + (c.steps || []).length; }, 0);
  var out = '<div class="pb"><div class="sec">명세 · ' + esc(m.name || '') + '<span class="r">' + esc(TARGET[launch.target] || '폰') + (m.version ? ' · v' + esc(m.version) : '') + ' · 기능 ' + caps.length + ' · 단계 ' + steps + (t.nodes.length < steps ? ' → 접어서 ' + t.nodes.length : '') +
    (ver ? ' · 판정 ✓' + (ver.ok || 0) + ' △' + (ver.changed || 0) + ' ✗' + (ver.fail || 0) + ' · 미검증 ' + (ver.unverified || 0) + (ver.stale ? ' (이전 버전 ' + ver.stale + ')' : '') : '') + '</span></div>';
  if (caps.length > 1) out += '<nav class="nav" aria-label="기능">' + btn('cap', '', '전체', !st.cap) + caps.map(function (c) { return btn('cap', c.id, c.title || c.id, st.cap === c.id); }).join('') + '</nav>';
  out += t.nodes.length ? treeSVG(st, t, fps) : '<p class="meta">명세 없음</p>';
  var g = layers(screens(fps));
  out += '<div class="sec">발자국<span class="r">화면 ' + g.nodes.length + ' · 걸음 ' + g.edges.length + ' · 재생 성공 ' + ev.replayOK + ' · 실패 ' + ev.replayFail + '</span></div>';
  out += g.edges.length ? walksSVG(st, g) : '<p class="meta">아직 걸은 적 없음 · 첫 실행 뒤 화면과 걸음이 여기에 쌓인다</p>';
  return out + '</div>';
}
function mount(el, opts) {
  var st = {cap: '', selected: null};
  Object.keys(opts).forEach(function (k) { st[k] = opts[k]; });
  function draw() { el.innerHTML = html(st); }
  function set(patch) { Object.keys(patch).forEach(function (k) { st[k] = patch[k]; }); draw(); if (st.onChange) st.onChange({cap: st.cap, selected: st.selected}); }
  el.addEventListener('click', function (ev) {
    var b = ev.target.closest('[data-cap],[data-step],[data-screen],[data-walk]'); if (!b || !el.contains(b)) return;
    var d = b.dataset, id = d.step || d.screen || d.walk;
    if (d.cap != null) set({cap: d.cap});
    else { set({selected: st.selected === id ? null : id}); if (st.onSelect) st.onSelect(st.selected ? {kind: d.step ? 'step' : d.screen ? 'screen' : 'walk', id: id} : null); }
  });
  el.addEventListener('keydown', function (ev) {   // SVG 의 role=button 은 키보드로 click 이 안 나므로
    if ((ev.key === 'Enter' || ev.key === ' ') && ev.target.matches && ev.target.matches('[data-step],[data-screen],[data-walk]')) { ev.preventDefault(); ev.target.dispatchEvent(new MouseEvent('click', {bubbles: true})); }
  });
  draw();
  return {set: set, state: function () { return st; }};
}

root.Playbook = {glyphOf, tree, verdict, walked, jaccard, screens, layers, evidence, html, mount};
})(globalThis);
