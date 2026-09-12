// Preview: hover 미리보기. 클릭은 열기/받기다(미리보기 아님). 원문 바이트 없음.
import {esc, hostLabel, itemLabel, collectedAt, timeFull, linkState, linkLabel, debugId, gradeOf, itemById, defaults, frame} from './kernel.js';
import {PREVIEW, kind, copy, pane} from './preview-kind.js';
import {bind} from './bind.js';

export {PREVIEW, kind, copy, pane};

export function html(it, st, id) {
  var k = kind(it, st);
  var title = it ? (it.title || itemLabel(it, st)) : '미부착';
  var host = it ? hostLabel(st.fleet, it.host || st.here || 'local') : '기기 없음';
  var state = it ? linkLabel(linkState(it, st.fleet, st.here)) : '없음';
  var ms = it ? collectedAt(it) : null;
  var when = ms == null ? '' : ' · ' + timeFull(ms);
  var grade = it ? (esc(it.kind) + ' · ' + esc(gradeOf(it.kind))) : '서버 메타만';
  var link = it ? esc(it.linked ? '연결' : '미연결') : '미연결';
  return '<div class="card ev-tip" role="tooltip" data-tip="' + esc(id) + '" data-preview="' + esc(k) + '"' +
    (k === 'receive' ? ' aria-busy="true"' : '') + '>' +
    '<div class="jtitle"><span class="lbl">' + esc(title) + '</span></div>' +
    '<div>' + grade + '</div>' +
    '<p class="meta">' + esc(host) + ' · ' + esc(state) + ' · ' + link + when + debugId(id, st.debug) + '</p>' +
    pane(k) + '</div>';
}

export function wrap(inner, id, st, it) {
  return '<span class="ev-hover"' + (st.hover === id ? ' data-show="1"' : '') +
    ' data-hover="' + esc(id) + '">' + inner + html(it, st, id) + '</span>';
}

function shown(st) {
  var id = st.hover || ((st.items || [])[0] && st.items[0].evidence_id) || 'ev_gone_1';
  var it = itemById(st.items, id);
  return frame(wrap('<button type="button" class="entry">미리보기</button>', id, Object.assign({}, st, {hover: id}), it), st.title || '미리보기');
}

export function mount(el, opts) { return bind(el, defaults(opts), shown); }

export const Preview = {PREVIEW, kind, copy, pane, html, wrap, mount};
