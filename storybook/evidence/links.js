// Links: 기기 · 종류. hover=미리보기, 클릭=열기/받기.
import {esc, itemLabel, collectedAt, linkState, linkLabel, badges, defaults, frame, wrapEv} from './kernel.js';
import {wrap} from './preview.js';
import {bind} from './bind.js';

export function html(st) {
  var items = st.items || [];
  if (!items.length) return wrapEv('links', '<p class="meta">증빙 없음</p>');
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
      '<td>' + wrap(btn, it.evidence_id, st, it) + '</td>' +
      '<td>' + badges(it) + ' · ' + esc(linkLabel(state)) + '</td>' +
      (st.debug ? '<td><code>' + esc(it.evidence_id) + '</code></td>' : '') + '</tr>';
  }).join('');
  return wrapEv('links', '<table class="ev-table" aria-label="증빙 링크"><thead><tr><th>링크</th><th>상태</th>' +
    (st.debug ? '<th>evidence_id</th>' : '') + '</tr></thead><tbody>' + rows + '</tbody></table>');
}

export function mount(el, opts) {
  return bind(el, defaults(opts), function (st) { return frame(html(st), st.title || '링크'); });
}

export const Links = {html, mount};
