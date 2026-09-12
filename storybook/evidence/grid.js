// Grid: 기기(행) × collectedAtMs(열). 온라인·열림=채운 칸, 오프·미부착=빈 칸. hover=미리보기.
import {esc, collectedAt, hostLabel, itemLabel, timeCol, linkState, defaults, frame, wrapEv} from './kernel.js';
import {wrap} from './preview.js';
import {bind} from './bind.js';

export function thumbFilled(item, fleet, here) {
  var s = linkState(item, fleet, here);
  return s === 'open' || s === 'e2e';
}

export function timesOf(items) {
  var seen = {}, out = [];
  (items || []).forEach(function (it) {
    var ms = collectedAt(it);
    if (ms == null || seen[ms]) return;
    seen[ms] = 1;
    out.push(ms);
  });
  out.sort(function (a, b) { return a - b; });
  return out;
}

export function hostsOf(st) {
  var seen = {}, rows = [];
  (st.fleet || []).forEach(function (d) { if (d.id && !seen[d.id]) { seen[d.id] = 1; rows.push(d.id); } });
  (st.items || []).forEach(function (it) {
    var h = it.host || st.here;
    if (h && !seen[h]) { seen[h] = 1; rows.push(h); }
  });
  return rows;
}

export function html(st) {
  var items = st.items || [];
  var cols = timesOf(items);
  var rows = hostsOf(st);
  if (!rows.length || !cols.length) return wrapEv('grid', '<p class="meta">그리드 없음</p>');
  var head = '<th scope="col">기기</th>' + cols.map(function (ms) {
    return '<th scope="col" data-collected="' + ms + '">' + esc(timeCol(ms)) + '</th>';
  }).join('');
  var body = rows.map(function (host) {
    var cells = cols.map(function (ms) {
      var it = null;
      items.forEach(function (x) {
        if (it) return;
        if ((x.host || st.here) === host && collectedAt(x) === ms) it = x;
      });
      if (!it) return '<td></td>';
      var state = linkState(it, st.fleet, st.here);
      var fill = thumbFilled(it, st.fleet, st.here);
      var off = state === 'disabled';
      var btn = '<button type="button" class="ev-thumb" data-open="' + esc(it.evidence_id) + '"' +
        ' data-fill="' + (fill ? '1' : '0') + '" data-link="' + esc(state) + '"' +
        (off ? ' disabled' : '') +
        ' aria-label="' + esc(itemLabel(it, st)) + '">' +
        '<span class="ev-thumb-face">' + (fill ? esc(it.kind) : '') + '</span>' +
        '<small class="meta">' + esc(itemLabel(it, st)) + '</small></button>';
      return '<td>' + wrap(btn, it.evidence_id, st, it) + '</td>';
    }).join('');
    return '<tr data-device="' + esc(host) + '"><th scope="row">' + esc(hostLabel(st.fleet, host)) + '</th>' + cells + '</tr>';
  }).join('');
  return wrapEv('grid', '<div class="ev-grid-wrap"><table class="ev-grid ev-table" aria-label="기기 × 시각"><thead><tr>' +
    head + '</tr></thead><tbody>' + body + '</tbody></table></div>');
}

export function mount(el, opts) {
  return bind(el, defaults(opts), function (st) { return frame(html(st), st.title || '그리드'); });
}

export const Grid = {html, mount, thumbFilled, timesOf, hostsOf};
