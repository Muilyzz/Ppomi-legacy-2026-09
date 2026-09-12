// Panel: 조립만. Presence / Links / Grid / Preview / ServerMeta 를 붙인다.
import {esc, debugId, defaults} from './kernel.js';
import {bind} from './bind.js';
import {html as presenceHtml} from './presence.js';
import {html as linksHtml} from './links.js';
import {html as gridHtml} from './grid.js';
import {html as serverHtml} from './server-meta.js';

function layers(list, st) {
  if (!list || !list.length) return '';
  return '<ol>' + list.map(function (p) {
    return '<li><span class="lbl">' + esc(p.title) + '</span>' +
      (p.note ? ' <small class="meta">' + esc(p.note) + '</small>' : '') +
      debugId(p.evidence_id, st.debug) + '</li>';
  }).join('') + '</ol>';
}

export function html(st) {
  return '<div class="ev-fleet" data-ev="panel">' +
    '<div class="jtitle"><h2 class="key">' + esc(st.title || '증빙') + '</h2> <small class="meta">파일은 기기 · 서버는 메타</small></div>' +
    '<div class="sec">서버</div>' + serverHtml(st) +
    '<div class="sec">기기</div>' + presenceHtml(st) +
    '<div class="sec">그리드</div>' + gridHtml(st) +
    '<div class="sec">링크</div>' + linksHtml(st) +
    (st.layers && st.layers.length ? '<div class="sec">다단</div>' + layers(st.layers, st) : '') +
    '</div>';
}

export function mount(el, opts) { return bind(el, defaults(opts), html); }

export const Panel = {html, mount};
