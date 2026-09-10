// Web/facts.js — 값 종류 여덟 개와 그 뷰어. 도메인(부동산·차량·건강·종목)은 여기 없다: 스키마가 필드마다 값 종류를 말하면 그 종류의 뷰어가 붙는다.
//   amount 수량+단위 · time 시각(until 로 기간) · place 좌표·다각형 · ratio 1/10000 · path 계층 경로 · ref 대상 ID · provenance 출처 등급 · image 원본 · text
// 표는 항상. 시간축은 time 이 있으면, 트리맵은 path+amount 가 있으면, 평면도는 place 가 있으면. 비율은 표 안의 <meter>, 출처 등급은 모든 표시에 prov-* 클래스로 겹친다.
// 어떤 도메인이 자기만의 뷰어를 요구하면 위 목록에 빠진 값 종류가 있다는 뜻이다 — 도메인 분기를 넣지 않는다.
// CSS 없음: 기하는 SVG 좌표(자료), 꾸밈은 skin 의 .fx-* 훅. 앱은 끼워 넣고 Storybook은 import — globalThis.Facts.
//
// records: [{id, fields:{...}}]   schema: {fields:[{key, title, type, unit, until}]}   until = 기간의 끝을 담은 다른 time 필드의 key.
(function (root) {
'use strict';
var TYPES = ['amount', 'time', 'place', 'ratio', 'path', 'ref', 'provenance', 'image', 'text'];
var PROV = {measured: '실측', observed: '관측', estimated: '추정', schematic: '개략', ocr: '화면에서 읽음', manual: '직접 기록', api: 'API', legacyImport: '이전 장부', aiEstimate: 'AI 추정', reported: '보고', derived: '계산'};
var DAY = 86400000, VW = 640, LIMIT = 200;   // SVG viewBox 너비 · 표 행 상한(그래픽이 표에 묻히지 않게)

function esc(s) { return String(s).replace(/[&<>"']/g, function (c) { return {'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#x27;'}[c]; }); }
function segs(p) { return String(p || '').split('/').filter(Boolean); }
function pathAt(p, depth) { return segs(p).slice(0, depth).join('/'); }
function r1(v) { return Math.round(v * 10) / 10; }
function t(v) { return typeof v === 'number' ? v : Date.parse(v); }   // 'YYYY-MM-DD' 는 UTC 자정 — 축도 UTC 로 그린다
function ymd(ms) { return new Date(ms).toISOString().slice(0, 10); }
function isPolygon(v) { return v && Array.isArray(v.points); }

// ---- 값 → 글자 · 칸
function fmt(v, f) {
  if (v == null || v === '') return '';
  switch (f.type) {
    case 'amount': return (typeof v === 'number' ? v.toLocaleString('ko-KR') : String(v)) + (f.unit ? ' ' + f.unit : '');
    case 'ratio': return (v / 100).toLocaleString('ko-KR', {maximumFractionDigits: 2}) + '%';
    case 'time': return typeof v === 'number' ? ymd(v) : String(v);
    case 'place': return isPolygon(v) ? '다각형 ' + v.points.length + '점' : v.lat != null ? v.lat.toFixed(5) + ', ' + v.lng.toFixed(5) : String(v.address || v);
    case 'provenance': return PROV[v] || String(v);
    default: return String(v);
  }
}
function cell(v, f) {
  if (f.type === 'ratio') return '<td>' + (v == null ? '<small class="meta">미입력</small>' : '<meter min="0" max="10000" value="' + esc(v) + '"></meter> ' + esc(fmt(v, f))) + '</td>';
  if (f.type === 'provenance' && v) return '<td><small class="prov prov-' + esc(v) + '">' + esc(fmt(v, f)) + '</small></td>';
  if (f.type === 'image' && v) return '<td><img src="' + esc(v) + '" alt="" height="40"></td>';
  if (f.type === 'ref' && v) return '<td><code>' + esc(v) + '</code></td>';
  return '<td' + (f.type === 'amount' ? ' class="n"' : '') + '>' + esc(fmt(v, f)) + '</td>';
}
function labelOf(r, schema) {   // 스키마 순서상 첫 text·path·ref 가 이름이다
  var f = schema.find(function (x) { return x.type === 'text' || x.type === 'path' || x.type === 'ref'; });
  var v = f && r.fields[f.key]; return v == null || v === '' ? String(r.id) : String(v);
}
function table(st, schema, records) {
  var head = schema.map(function (f) { return '<th scope="col"' + (f.type === 'amount' ? ' class="n"' : '') + '>' + esc(f.title || f.key) + '</th>'; }).join('');
  var shown = records.slice(0, LIMIT), body = shown.map(function (r) {
    return '<tr data-record="' + esc(r.id) + '" aria-selected="' + (st.selected === r.id) + '">' + schema.map(function (f) { return cell(r.fields[f.key], f); }).join('') + '</tr>';
  }).join('') || '<tr><td colspan="' + schema.length + '"><small class="meta">기록이 없습니다.</small></td></tr>';
  if (records.length > shown.length) body += '<tr><td colspan="' + schema.length + '"><small class="meta">… 외 ' + (records.length - shown.length) + '건</small></td></tr>';
  return '<table class="fx-table" aria-label="기록"><thead><tr>' + head + '</tr></thead><tbody>' + body + '</tbody></table>';
}

// ---- 계층 트리맵: path 를 depth 마디에서 접어 amount 크기를 합친다(절대값). 이분할 배치: 합이 반쯤 되는 곳에서 긴 변을 가른다.
function nodes(records, pathKey, valueKey, rootPath, depth) {
  var rd = segs(rootPath).length, sum = {}, deeper = {};
  records.forEach(function (r) {
    var p = String(r.fields[pathKey] || ''), v = Math.abs(+r.fields[valueKey] || 0);
    if (rootPath && !(p === rootPath || p.indexOf(rootPath + '/') === 0)) return;
    var k = pathAt(p, rd + depth); if (!k || !v) return;
    sum[k] = (sum[k] || 0) + v; if (segs(p).length > rd + depth) deeper[k] = 1;
  });
  return Object.keys(sum).map(function (k) { return {path: k, label: segs(k).slice(rd).join('/'), value: sum[k], deeper: !!deeper[k]}; }).sort(function (a, b) { return b.value - a.value; });
}
function layout(items, x, y, w, h, out) {
  if (!items.length) return out;
  if (items.length === 1) { out.push({item: items[0], x: x, y: y, w: w, h: h}); return out; }
  var total = items.reduce(function (s, i) { return s + i.value; }, 0), acc = 0, i = 0;
  while (i < items.length - 1 && acc + items[i].value <= total / 2) acc += items[i++].value;
  if (i === 0) { acc = items[0].value; i = 1; }
  var a = items.slice(0, i), b = items.slice(i), r = acc / total;
  if (w >= h) { layout(a, x, y, w * r, h, out); layout(b, x + w * r, y, w * (1 - r), h, out); }
  else { layout(a, x, y, w, h * r, out); layout(b, x, y + h * r, w, h * (1 - r), out); }
  return out;
}
function treemap(st, items, amountF) {
  var H = 260, boxes = layout(items, 0, 0, VW, H, []), total = items.reduce(function (s, i) { return s + i.value; }, 0);
  var g = boxes.map(function (b) {
    var big = b.w > 44 && b.h > 20, cls = 'fx-node' + (b.item.deeper ? ' deeper' : '') + (st.selected === b.item.path ? ' hit' : '');
    var fit = Math.max(1, Math.floor((b.w - 10) / 12)), label = b.item.label.length > fit ? b.item.label.slice(0, fit - 1) + '…' : b.item.label;   // 12px 한글 폭 기준으로 자른다
    return '<g class="' + cls + '" data-path="' + esc(b.item.path) + '" role="button" tabindex="0" aria-label="' + esc(b.item.label + ' ' + fmt(b.item.value, amountF)) + '">' +
      '<rect x="' + r1(b.x) + '" y="' + r1(b.y) + '" width="' + r1(b.w) + '" height="' + r1(b.h) + '" fill="currentColor" fill-opacity=".08" stroke="currentColor" stroke-opacity=".5"/>' +
      (big ? '<text x="' + r1(b.x + 6) + '" y="' + r1(b.y + 15) + '" font-size="12">' + esc(label) + '</text>' : '') +
      (big && b.h > 34 ? '<text x="' + r1(b.x + 6) + '" y="' + r1(b.y + 30) + '" font-size="11" opacity=".7">' + esc(fmt(b.item.value, amountF)) + ' · ' + Math.round(b.item.value / total * 100) + '%</text>' : '') + '</g>';
  }).join('');
  return '<svg class="fx-treemap" viewBox="0 0 ' + VW + ' ' + H + '" role="img" aria-label="계층 트리맵">' + g + '</svg>';
}

// ---- 시간축: time 필드마다 점, until 이 있으면 막대. 눈금은 일·주·월·분기·년 중 12개 이하가 되는 첫 단위.
function spans(records, schema) {
  var timeF = schema.filter(function (f) { return f.type === 'time' && !schema.some(function (g) { return g.until === f.key; }); }), out = [];
  records.forEach(function (r) {
    timeF.forEach(function (f) {
      var s = r.fields[f.key]; if (s == null || s === '') return;
      var e = f.until ? r.fields[f.until] : null, prov = schema.find(function (g) { return g.type === 'provenance'; });
      out.push({record: r.id, label: labelOf(r, schema) + (timeF.length > 1 ? ' · ' + (f.title || f.key) : ''), start: t(s), end: e == null || e === '' ? null : t(e), prov: prov ? r.fields[prov.key] : null});
    });
  });
  return out.sort(function (a, b) { return a.start - b.start; });
}
function ticks(a, b) {
  var units = [['day', 1], ['week', 7], ['month', 30], ['quarter', 91], ['year', 365]], d = (b - a) / DAY, u = units.find(function (x) { return d / x[1] <= 12; }) || units[4];
  var s = new Date(a), out = [];
  if (u[0] === 'day' || u[0] === 'week') { s = Date.UTC(s.getUTCFullYear(), s.getUTCMonth(), s.getUTCDate()); for (var x = s; x <= b; x += u[1] * DAY) if (x >= a) out.push({t: x, label: (new Date(x).getUTCMonth() + 1) + '/' + new Date(x).getUTCDate()}); }
  else { var step = u[0] === 'month' ? 1 : u[0] === 'quarter' ? 3 : 12, y = s.getUTCFullYear(), m = s.getUTCMonth(); if (step > 1) m -= m % step;
    for (var k = 0; k < 400; k++) { var x2 = Date.UTC(y, m + k * step, 1); if (x2 > b) break; if (x2 >= a) out.push({t: x2, label: step === 12 ? String(new Date(x2).getUTCFullYear()) : new Date(x2).getUTCFullYear() + '-' + String(new Date(x2).getUTCMonth() + 1).padStart(2, '0')}); } }
  return out;
}
function timeline(st, items) {
  var LIMIT = 60, shown = items.slice(0, LIMIT), L = 160, R = 12, T = 22, RH = 18, H = T + shown.length * RH + 8;
  var min = Math.min.apply(null, items.map(function (i) { return i.start; })), max = Math.max.apply(null, items.map(function (i) { return i.end || i.start; }));
  if (max - min < 30 * DAY) { min -= 15 * DAY; max += 15 * DAY; } else { var pad = (max - min) * 0.04; min -= pad; max += pad; }
  var X = function (ms) { return L + (ms - min) / (max - min) * (VW - L - R); }, today = Date.now(), g = '';
  ticks(min, max).forEach(function (k) { g += '<line class="fx-grid" x1="' + r1(X(k.t)) + '" y1="' + T + '" x2="' + r1(X(k.t)) + '" y2="' + (H - 8) + '" stroke="currentColor" stroke-opacity=".15"/><text class="fx-axis" x="' + r1(X(k.t) + 3) + '" y="12" font-size="10" opacity=".6">' + esc(k.label) + '</text>'; });
  if (today >= min && today <= max) g += '<line class="fx-today" x1="' + r1(X(today)) + '" y1="' + T + '" x2="' + r1(X(today)) + '" y2="' + (H - 8) + '" stroke="currentColor" stroke-opacity=".6" stroke-dasharray="2 2"/>';
  shown.forEach(function (i, n) {
    var y = T + n * RH + RH / 2, cls = 'fx-span' + (i.prov ? ' prov-' + esc(i.prov) : '') + (st.selected === i.record ? ' hit' : '');
    g += '<g class="' + cls + '" data-record="' + esc(i.record) + '"><text x="' + (L - 8) + '" y="' + r1(y + 4) + '" font-size="11" text-anchor="end">' + esc(i.label.length > 22 ? i.label.slice(0, 21) + '…' : i.label) + '</text>' +
      (i.end != null ? '<rect x="' + r1(X(i.start)) + '" y="' + r1(y - 5) + '" width="' + r1(Math.max(2, X(i.end) - X(i.start))) + '" height="10" fill="currentColor" fill-opacity=".25" stroke="currentColor" stroke-opacity=".6"/>'
        : '<circle cx="' + r1(X(i.start)) + '" cy="' + r1(y) + '" r="4" fill="currentColor"/>') + '</g>';
  });
  if (items.length > LIMIT) g += '<text x="' + L + '" y="' + (H - 2) + '" font-size="10" opacity=".6">… 외 ' + (items.length - LIMIT) + '건</text>';
  return '<svg class="fx-timeline" viewBox="0 0 ' + VW + ' ' + H + '" role="img" aria-label="시간축">' + g + '</svg>';
}

// ---- 평면도: 위도·경도는 첫 좌표를 원점으로 미터로 펴고(등장방형), {x,y} 는 이미 미터. 타일 지도는 없다 — 네트워크 없이 형상·거리·관계만.
function project(shapes) {
  var o = null, M = 111320;
  shapes.forEach(function (s) { s.pts.forEach(function (p) { if (!o && p.lat != null) o = p; }); });
  shapes.forEach(function (s) { s.xy = s.pts.map(function (p) { return p.lat != null && o ? [(p.lng - o.lng) * M * Math.cos(o.lat * Math.PI / 180), (p.lat - o.lat) * 110574] : [+p.x || 0, +p.y || 0]; }); });
  return shapes;
}
function shapesOf(records, schema) {
  var out = [], placeF = schema.filter(function (f) { return f.type === 'place'; }), prov = schema.find(function (g) { return g.type === 'provenance'; });
  records.forEach(function (r) { placeF.forEach(function (f) {
    var v = r.fields[f.key]; if (!v || (v.lat == null && !isPolygon(v))) return;
    out.push({record: r.id, label: labelOf(r, schema), pts: isPolygon(v) ? v.points : [v], polygon: isPolygon(v), prov: prov ? r.fields[prov.key] : null});
  }); });
  return project(out);
}
function places(st, shapes) {
  var H = 320, P = 24, xs = [], ys = [];
  shapes.forEach(function (s) { s.xy.forEach(function (q) { xs.push(q[0]); ys.push(q[1]); }); });
  var x0 = Math.min.apply(null, xs), x1 = Math.max.apply(null, xs), y0 = Math.min.apply(null, ys), y1 = Math.max.apply(null, ys);
  var span = Math.max(x1 - x0, y1 - y0, 10), k = Math.min((VW - 2 * P) / (x1 - x0 || span), (H - 2 * P) / (y1 - y0 || span), (VW - 2 * P) / span);
  var cx = (x0 + x1) / 2, cy = (y0 + y1) / 2, X = function (x) { return VW / 2 + (x - cx) * k; }, Y = function (y) { return H / 2 - (y - cy) * k; };   // 북쪽이 위
  var g = shapes.map(function (s) {
    var cls = 'fx-place' + (s.prov ? ' prov-' + esc(s.prov) : '') + (st.selected === s.record ? ' hit' : ''), lab = '<text x="' + r1(X(s.xy[0][0]) + 6) + '" y="' + r1(Y(s.xy[0][1]) - 6) + '" font-size="11">' + esc(s.label) + '</text>';
    if (s.polygon) return '<g class="' + cls + '" data-record="' + esc(s.record) + '"><polygon points="' + s.xy.map(function (q) { return r1(X(q[0])) + ',' + r1(Y(q[1])); }).join(' ') + '" fill="currentColor" fill-opacity=".08" stroke="currentColor"/>' + lab + '</g>';
    return '<g class="' + cls + '" data-record="' + esc(s.record) + '"><circle cx="' + r1(X(s.xy[0][0])) + '" cy="' + r1(Y(s.xy[0][1])) + '" r="4" fill="currentColor"/>' + lab + '</g>';
  }).join('');
  var bar = Math.pow(10, Math.floor(Math.log10(span / 4))), bw = bar * k;   // 눈금자: 10^n m
  g += '<g class="fx-scale"><line x1="' + P + '" y1="' + (H - 10) + '" x2="' + r1(P + bw) + '" y2="' + (H - 10) + '" stroke="currentColor"/><text x="' + P + '" y="' + (H - 14) + '" font-size="10" opacity=".7">' + (bar >= 1000 ? bar / 1000 + ' km' : bar + ' m') + '</text></g>';
  return '<svg class="fx-places" viewBox="0 0 ' + VW + ' ' + H + '" role="img" aria-label="평면도">' + g + '</svg>';
}

// ---- 디스패처: 스키마의 값 종류만 보고 붙일 뷰를 고른다
function btn(key, value, label, on) { return '<button type="button" data-' + key + '="' + esc(value) + '"' + (on ? ' class="on" aria-pressed="true"' : ' aria-pressed="false"') + '>' + esc(label) + '</button>'; }
function html(st) {
  var schema = (st.schema && st.schema.fields) || [], records = st.records || [];
  var pathF = schema.find(function (f) { return f.type === 'path'; }), amountF = schema.find(function (f) { return f.type === 'amount'; });
  var out = '<div class="fx"><div class="sec">값 종류<span class="r"><span>' + schema.map(function (f) { return esc(f.title || f.key) + ' <small class="meta">' + esc(f.type) + '</small>'; }).join(' · ') + '</span></span></div>';
  var sp = spans(records, schema);
  if (sp.length) out += '<div class="sec">시간<span class="r">' + sp.length + '건</span></div>' + timeline(st, sp);
  if (pathF && amountF) {
    var maxD = records.reduce(function (m, r) { return Math.max(m, segs(r.fields[pathF.key]).length); }, 0) - segs(st.root).length, depth = Math.max(1, Math.min(st.depth || 1, maxD));
    var items = nodes(records, pathF.key, amountF.key, st.root, depth), nav = '';
    for (var d = 1; d <= maxD; d++) nav += btn('depth', d, String(d), depth === d);
    out += '<div class="sec">계층 · ' + esc(amountF.title || amountF.key) + '<span class="r">' + (st.root ? '<nav class="nav">' + btn('root', pathAt(st.root, segs(st.root).length - 1), '← ' + st.root, false) + '</nav>' : '') + '<nav class="nav" aria-label="깊이"><span>깊이</span>' + nav + '</nav></span></div>' + (items.length ? treemap(st, items, amountF) : '<p class="meta">크기가 있는 기록이 없습니다.</p>');
  }
  var sh = shapesOf(records, schema);
  if (sh.length) out += '<div class="sec">장소<span class="r">' + sh.length + '건 · 북쪽이 위</span></div>' + places(st, sh);
  return out + '<div class="sec">기록<span class="r">' + records.length + '건</span></div>' + table(st, schema, records) + '</div>';
}
function mount(el, opts) {
  var st = {depth: 1, root: '', selected: null};
  Object.keys(opts).forEach(function (k) { st[k] = opts[k]; });
  function draw() { el.innerHTML = html(st); }
  function set(patch) { Object.keys(patch).forEach(function (k) { st[k] = patch[k]; }); draw(); if (st.onChange) st.onChange({depth: st.depth, root: st.root, selected: st.selected}); }
  el.addEventListener('click', function (ev) {
    var b = ev.target.closest('[data-depth],[data-root],[data-path],[data-record]'); if (!b || !el.contains(b)) return;
    var d = b.dataset;
    if (d.depth) set({depth: +d.depth});
    else if (d.root != null) set({root: d.root, depth: 1});
    else if (d.path) { if (b.classList.contains('deeper')) set({root: d.path, depth: 1}); else set({selected: st.selected === d.path ? null : d.path}); if (st.onSelect) st.onSelect({path: d.path}); }
    else if (d.record) { set({selected: st.selected === d.record ? null : d.record}); if (st.onSelect) st.onSelect((st.records || []).find(function (r) { return r.id === st.selected; }) || null); }
  });
  draw();
  return {set: set, state: function () { return st; }};
}

root.Facts = {TYPES, PROV, fmt, cell, labelOf, nodes, layout, spans, ticks, shapesOf, project, html, mount};
})(globalThis);
