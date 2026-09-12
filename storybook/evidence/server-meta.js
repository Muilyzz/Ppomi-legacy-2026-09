// ServerMeta: 분개·숫자·불투명 ref. 파일 없음. 링크 hover=미리보기.
import {esc, itemById, itemLabel, linkState, debugId, defaults, frame, wrapEv} from './kernel.js';
import {wrap} from './preview.js';
import {bind} from './bind.js';

export function html(st) {
  var s = st.server || {};
  var ids = s.evidence_ids || [];
  var amt = s.amount == null ? '' : '<span class="key n">' + Number(s.amount).toLocaleString('ko-KR') + '</span> <small class="meta">' + esc(s.unit || '원') + '</small>';
  var refs = ids.map(function (id) {
    var it = itemById(st.items, id);
    if (it) {
      var off = linkState(it, st.fleet, st.here) === 'disabled';
      return wrap(
        '<button type="button" class="entry" data-open="' + esc(id) + '"' +
          (off ? ' disabled' : '') + '>' + esc(itemLabel(it, st)) + '</button>' + debugId(id, st.debug),
        id, st, it);
    }
    return wrap(
      '<button type="button" class="entry" data-open="' + esc(id) + '">미부착</button>' + debugId(id, st.debug),
      id, st, null);
  }).join(' · ');
  return wrapEv('server', '<div class="card">' +
    '<span class="lbl">' + esc(s.memo || '분개') + '</span>' +
    '<div>' + amt + '</div>' +
    '<p class="meta">서버 · 파일 없음' + (ids.length ? ' · 증빙 ' + ids.length + '건' : ' · 증빙 없음') + '</p>' +
    (refs ? '<p>' + refs + '</p>' : '') + '</div>');
}

export function mount(el, opts) {
  return bind(el, defaults(opts), function (st) { return frame(html(st), st.title || '서버'); });
}

export const ServerMeta = {html, mount};
