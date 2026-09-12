// Web/evidence.js — 증거 = 화면(스크롤로 이어진 여러 장이어도) + 그 위에서 읽은 글자 + 거기서 유도한 기록. 출처가 무엇이든 같다:
// 은행 앱 거래 목록, 인바디 결과, 영수증. 글자는 읽힌 그 자리에 놓이고(해석된 렌더링), 기록은 자기 근거 상자를 가리킨다.
// 태그는 '비용/식비/점심/회사앞'처럼 경로다 — 계정과목 계층에 커스텀 세부 계정을 이어 붙인다. 깊이로 접고 접두어로 거른다(journal.js 의 계정 깊이와 같은 축).
// 스키마는 주어지면 그대로, 없으면 fields 키의 합집합에서 유도한다. 없는 값은 빈 칸이지 0이 아니다.
// CSS 없음: 위치·크기·잉크색은 자료라 inline 이고, 꾸밈(종이·상자 색·깜박임)은 theme.css 의 .ev-* 훅이다. 앱은 끼워 넣고 Storybook은 import — globalThis.Evidence.
//
// frames:  [{image, words:[{text,x,y,w,h}], top, clip, bottom}]  x·y·w·h 는 화면 비율(0~1). top = 열에서의 위치(화면 높이 단위, 스티치가 계산), clip~bottom = 이 장에서 쓰는 띠.
// records: [{id, tag, occurredAt, fields:{...}, anchors:[{frame, x, y, w, h}], status:'ok'|'warn'|'bad', note}]
// schema:  {fields:[{key, title, unit}]}  없으면 유도.
(function (root) {
'use strict';
var TOL = 0.012;   // 같은 행으로 보는 y 차이 — OCR.rowGroups 와 같다

function esc(s) { return String(s).replace(/[&<>"']/g, function (c) { return {'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#x27;'}[c]; }); }
function px(v) { return Math.round(v) + 'px'; }
function segs(tag) { return String(tag || '').split('/').filter(Boolean); }

// ---- 태그 경로
function tagAt(tag, depth) { var p = segs(tag); return (depth === Infinity ? p : p.slice(0, depth)).join('/'); }
function tagDepth(records) { return records.reduce(function (m, r) { return Math.max(m, segs(r.tag).length); }, 0); }
function underTag(record, prefix) { var t = String(record.tag || ''); return !prefix || t === prefix || t.indexOf(prefix + '/') === 0; }
function tagCounts(records, depth) {
  var c = {}; records.forEach(function (r) { var k = tagAt(r.tag, depth); c[k] = (c[k] || 0) + 1; });
  return Object.keys(c).sort().map(function (k) { return {tag: k, count: c[k]}; });
}

// ---- 스키마: 주어지면 그대로, 아니면 fields 키의 합집합(처음 나온 순서)
function schemaOf(records, schema) {
  if (schema && schema.fields) return schema.fields;
  var seen = {}, out = [];
  records.forEach(function (r) { Object.keys(r.fields || {}).forEach(function (k) { if (!seen[k]) { seen[k] = 1; out.push({key: k, title: k}); } }); });
  return out;
}
function cellText(v, f) {
  if (v == null || v === '') return '';
  return (typeof v === 'number' ? v.toLocaleString('ko-KR') : String(v)) + (f.unit ? ' ' + f.unit : '');
}

// ---- 배치: 글자를 y 중심으로 행으로 묶고, 프레임의 top 을 더해 열에 놓는다. 겹치는 행은 먼저 온 프레임의 읽기 하나만.
function rowsOf(words) {
  var rows = [];
  words.slice().sort(function (a, b) { return (a.y + a.h / 2) - (b.y + b.h / 2); }).forEach(function (w) {
    var cy = w.y + w.h / 2, last = rows[rows.length - 1];
    if (last && Math.abs(last.cy - cy) < TOL) { last.words.push(w); last.y0 = Math.min(last.y0, w.y); last.y1 = Math.max(last.y1, w.y + w.h); }
    else rows.push({cy: cy, y0: w.y, y1: w.y + w.h, words: [w]});
  });
  rows.forEach(function (r) { r.words.sort(function (a, b) { return a.x - b.x; }); });
  return rows;
}
function band(f) { return {top: f.top || 0, clip: f.clip || 0, bottom: f.bottom == null ? 1 : f.bottom}; }
function extent(frames) {
  var top = Infinity, bot = -Infinity;
  frames.forEach(function (f) { var b = band(f); top = Math.min(top, b.top + b.clip); bot = Math.max(bot, b.top + b.bottom); });
  return frames.length ? {base: top, height: bot - top} : {base: 0, height: 0};
}
function place(frames) {
  var taken = [], out = [];
  frames.forEach(function (f, i) {
    var b = band(f);
    rowsOf(f.words || []).forEach(function (r) {
      if (r.y0 < b.clip || r.y0 >= b.bottom || r.words.map(function (w) { return w.text; }).join('').trim().length < 2) return;
      var y = b.top + r.y0;
      if (taken.some(function (t) { return Math.abs(t - y) < TOL; })) return;
      taken.push(y); out.push({frame: i, y: y, y0: r.y0, y1: r.y1, words: r.words});
    });
  });
  return out;
}
// 오른쪽 정렬: 가장 많은 행이 끝나는 x 가 목록의 오른쪽 여백. 거기서 끝나는 글자는 오른쪽 끝으로 붙여 숫자가 앱과 같은 자리에서 끝난다.
function rightMargin(rows) {
  var c = {}; rows.forEach(function (r) { var w = r.words[r.words.length - 1], e = Math.round((w.x + w.w) * 100) / 100; c[e] = (c[e] || 0) + 1; });
  var best = 1, n = 0; Object.keys(c).forEach(function (k) { if (c[k] > n || (c[k] === n && +k > best)) { n = c[k]; best = +k; } });
  return best;
}

// ---- 마크업
function btn(key, value, label, on) { return '<button type="button" data-' + key + '="' + esc(value) + '"' + (on ? ' class="on" aria-pressed="true"' : ' aria-pressed="false"') + '>' + esc(label) + '</button>'; }
function label(r) { var f = r.fields || {}; return Object.keys(f).map(function (k) { return f[k]; }).filter(function (v) { return v != null && v !== ''; }).slice(0, 2).join(' ') || r.tag || r.id; }
function paper(st, frames, records, W, H) {
  var ext = extent(frames), rows = place(frames), rm = rightMargin(rows);
  var imgs = frames.map(function (f, i) { return '<img hidden data-frame="' + i + '" src="' + esc(f.image || '') + '" alt="">'; }).join('');
  var text = rows.map(function (r) {
    var words = r.words.map(function (w) {
      var pos = Math.abs(w.x + w.w - rm) < TOL ? 'right:' + px((1 - w.x - w.w) * W) : 'left:' + px(w.x * W);
      return '<span class="ev-word" data-b="' + [w.x, w.y, w.w, w.h].map(function (v) { return v.toFixed(4); }).join(',') + '" style="position:absolute;' + pos + ';top:' + px((w.y - r.y0) * H) + ';font-size:' + px(w.h * H) + ';line-height:1;white-space:nowrap">' + esc(w.text) + '</span>';
    }).join('');
    return '<div class="ev-row" data-frame="' + r.frame + '" style="position:absolute;left:0;width:' + W + 'px;top:' + px((r.y - ext.base) * H) + ';height:' + px((r.y1 - r.y0) * H) + '">' + words + '</div>';
  }).join('');
  var boxes = records.map(function (r) {
    return (r.anchors || []).map(function (a) {
      var f = frames[a.frame]; if (!f) return '';
      var cls = 'ev-box' + (r.status && r.status !== 'ok' ? ' ' + esc(r.status) : '') + (st.selected === r.id ? ' hit' : '');
      return '<div class="' + cls + '" data-record="' + esc(r.id) + '" role="button" tabindex="0" aria-label="근거: ' + esc(label(r)) + '" style="position:absolute;left:' + px(a.x * W) + ';top:' + px((band(f).top + a.y - ext.base) * H) + ';width:' + px(a.w * W) + ';height:' + px(a.h * H) + '"></div>';
    }).join('');
  }).join('');
  var peek = '<img class="ev-peek" hidden alt="" style="position:absolute;left:0;top:0;width:' + W + 'px;height:' + H + 'px;pointer-events:none">';
  return '<section class="ev-paper" aria-label="원본 화면과 읽은 글자" style="position:relative;width:' + W + 'px;height:' + px(ext.height * H) + '">' + imgs + boxes + text + peek + '</section>';
}
function table(st, records, depth) {
  var shown = records.filter(function (r) { return underTag(r, st.tag); }), fields = schemaOf(records, st.schema);
  var hasTime = records.some(function (r) { return r.occurredAt; }), hasStatus = records.some(function (r) { return r.status && r.status !== 'ok'; });
  var head = (hasTime ? '<th scope="col">시각</th>' : '') + '<th scope="col">태그</th>' + fields.map(function (f) { return '<th scope="col"' + (f.numeric ? ' class="n"' : '') + '>' + esc(f.title || f.key) + '</th>'; }).join('') + (hasStatus ? '<th scope="col">상태</th>' : '');
  var body = shown.map(function (r) {
    var t = tagAt(r.tag, depth), f = r.fields || {};
    return '<tr data-record="' + esc(r.id) + '" aria-selected="' + (st.selected === r.id) + '">' + (hasTime ? '<td><small class="meta">' + esc(r.occurredAt || '') + '</small></td>' : '') +
      '<td>' + (t ? esc(t) : '<small class="meta">미분류</small>') + '</td>' +
      fields.map(function (fd) { var v = f[fd.key]; return '<td' + (typeof v === 'number' ? ' class="n"' : '') + '>' + esc(cellText(v, fd)) + '</td>'; }).join('') +
      (hasStatus ? '<td><small class="meta">' + esc(r.status && r.status !== 'ok' ? r.note || r.status : '') + '</small></td>' : '') + '</tr>';
  }).join('');
  if (!shown.length) body = '<tr><td colspan="9"><small class="meta">이 태그에 기록이 없습니다.</small></td></tr>';
  return '<table class="ev-table" aria-label="유도된 기록"><thead><tr>' + head + '</tr></thead><tbody>' + body + '</tbody></table>';
}
function html(st) {
  var frames = st.frames || [], records = st.records || [], W = st.width || 348, H = st.height || 766;
  var deepest = tagDepth(records), depth = Math.max(1, Math.min(st.depth == null ? Infinity : st.depth, deepest));
  var depths = ''; for (var d = 1; d <= deepest; d++) depths += btn('depth', d, String(d), depth === d);
  var chips = btn('tag', '', '전체', !st.tag) + tagCounts(records, depth).map(function (c) { return btn('tag', c.tag, (c.tag || '미분류') + ' ' + c.count, st.tag === c.tag); }).join('');
  var notes = {}; records.forEach(function (r) { if (r.status && r.status !== 'ok') notes[r.status] = r.note || r.status; });
  var legend = Object.keys(notes).map(function (s) { return '<i class="ev-box ' + esc(s) + '" style="display:inline-block;width:10px;height:10px"></i>' + esc(notes[s]); }).join(' ');
  return '<div class="ev">' + paper(st, frames, records, W, H) +
    '<section class="ev-records" aria-label="유도된 기록">' +
    '<div class="sec">기록 ' + records.length + '건 · 화면 ' + frames.length + '장' + (legend ? '<span class="r">' + legend + '</span>' : '') + '</div>' +
    '<div class="jnav">' + (deepest > 1 ? '<nav class="nav" aria-label="태그 깊이"><span>깊이</span>' + depths + '</nav>' : '') + '<nav class="nav ev-tags" aria-label="태그">' + chips + '</nav></div>' +
    table(st, records, depth) + '</section></div>';
}

// ---- 원본에서 가져오는 글자의 모양: 잉크색은 상자 안 가장 어두운 15% 픽셀의 평균, 크기는 그린 너비가 상자 너비와 같아지도록 맞춘다(높이보다 훨씬 안정적).
function ink(d, b) {
  var W = d.width, H = d.height, x0 = Math.round(b[0] * W), y0 = Math.round(b[1] * H), x1 = Math.round((b[0] + b[2]) * W), y1 = Math.round((b[1] + b[3]) * H), px = [];
  for (var y = y0; y < y1; y++) for (var x = x0; x < x1; x++) { var i = (y * W + x) * 4; px.push(d.data[i] + d.data[i + 1] + d.data[i + 2]); }
  if (!px.length) return '';
  px.sort(function (a, b) { return a - b; });
  var n = Math.max(1, Math.floor(px.length * 0.15)), c = [0, 0, 0], m = 0;
  for (var y = y0; y < y1 && m < n; y++) for (var x = x0; x < x1 && m < n; x++) { var i = (y * W + x) * 4; if (d.data[i] + d.data[i + 1] + d.data[i + 2] <= px[n - 1]) { c[0] += d.data[i]; c[1] += d.data[i + 1]; c[2] += d.data[i + 2]; m++; } }
  return 'rgb(' + Math.round(c[0] / m) + ',' + Math.round(c[1] / m) + ',' + Math.round(c[2] / m) + ')';
}
function fit(el, W, H) {
  var imgs = Array.prototype.slice.call(el.querySelectorAll('img[data-frame]'));
  return Promise.all(imgs.map(function (im) { return im.decode().catch(function () {}); })).then(function () {
    var canv = document.createElement('canvas'), ctx = canv.getContext('2d', {willReadFrequently: true}), cache = {};
    function pixels(i) {
      if (i in cache) return cache[i];
      var im = imgs[i]; if (!im || !im.naturalWidth) return cache[i] = null;
      canv.width = im.naturalWidth; canv.height = im.naturalHeight; ctx.drawImage(im, 0, 0);
      try { return cache[i] = ctx.getImageData(0, 0, canv.width, canv.height); } catch (e) { return cache[i] = null; }   // 교차 출처 이미지: 색은 건너뛴다
    }
    el.querySelectorAll('.ev-row').forEach(function (r) {
      var d = pixels(+r.dataset.frame);
      r.querySelectorAll('.ev-word').forEach(function (sp) {
        var b = sp.dataset.b.split(',').map(Number), h = b[3] * H, w = b[2] * W;
        if (d) { var c = ink(d, b); if (c) sp.style.color = c; }
        sp.style.fontSize = h + 'px';
        var mw = sp.getBoundingClientRect().width; if (mw > 0) sp.style.fontSize = (h * w / mw).toFixed(1) + 'px';
      });
    });
  });
}

// ---- mount(el, {frames, records, schema, depth, tag, selected, width, height, onChange, onSelect}) → {set, state}
function mount(el, opts) {
  var st = {depth: Infinity, tag: '', selected: null};
  Object.keys(opts).forEach(function (k) { st[k] = opts[k]; });
  var W = st.width || 348, H = st.height || 766, cur = -1;
  function draw() { el.innerHTML = html(st); fit(el, W, H); }
  function set(patch) { Object.keys(patch).forEach(function (k) { st[k] = patch[k]; }); draw(); if (st.onChange) st.onChange({depth: st.depth, tag: st.tag, selected: st.selected}); }
  el.addEventListener('click', function (ev) {
    var b = ev.target.closest('[data-depth],[data-tag],[data-record]');
    if (!b || !el.contains(b)) return;
    var d = b.dataset;
    if (d.depth) set({depth: +d.depth});
    else if (d.tag != null) set({tag: st.tag === d.tag ? '' : d.tag});
    else if (d.record) {
      set({selected: st.selected === d.record ? null : d.record});
      var hit = el.querySelector('.ev-box.hit'); if (hit && b.tagName === 'TR') hit.scrollIntoView({block: 'center'});
      if (st.onSelect) st.onSelect((st.records || []).find(function (r) { return r.id === st.selected; }) || null);
    }
  });
  // 깜박임 비교기: 종이 위 어디든 포인터가 있으면, 그 높이가 화면 가운데에 가장 가까운 원본 한 장 전체가 제자리에 나타난다
  el.addEventListener('mousemove', function (ev) {
    var paper = ev.target.closest('.ev-paper'), peek = el.querySelector('.ev-peek'); if (!peek) return;
    if (!paper) { peek.hidden = true; cur = -1; return; }
    var frames = st.frames || [], ext = extent(frames), y = (ev.clientY - paper.getBoundingClientRect().top) / H + ext.base, best = -1, bd = 9;
    frames.forEach(function (f, i) { var b = band(f), l = y - b.top; if (l >= b.clip && l < b.bottom && Math.abs(l - 0.5) < bd) { bd = Math.abs(l - 0.5); best = i; } });
    if (best < 0) { peek.hidden = true; cur = -1; return; }
    if (best !== cur) { cur = best; peek.src = el.querySelector('img[data-frame="' + best + '"]').src; peek.style.top = px((band(frames[best]).top - ext.base) * H); }
    peek.hidden = false;
  });
  el.addEventListener('mouseleave', function () { var peek = el.querySelector('.ev-peek'); if (peek) peek.hidden = true; cur = -1; });
  draw();
  return {set: set, state: function () { return st; }};
}

root.Evidence = Object.assign(root.Evidence || {}, {tagAt, tagDepth, underTag, tagCounts, schemaOf, cellText, rowsOf, place, extent, rightMargin, html, mount});
})(globalThis);
