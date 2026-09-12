// Presence: 이 기기 / 피어 · 온라인 점.
import {esc, defaults, frame, wrapEv} from './kernel.js';
import {bind} from './bind.js';

export function html(st) {
  var fleet = st.fleet, here = st.here;
  if (!fleet || !fleet.length) return wrapEv('presence', '<p class="meta">기기 없음</p>');
  return wrapEv('presence', '<div class="grid3">' + fleet.map(function (d) {
    var on = !!d.online, who = d.id === here ? '이 기기' : '피어';
    return '<div class="card" data-device="' + esc(d.id) + '" data-online="' + on + '">' +
      '<span class="ev-dot' + (on ? ' on' : '') + '" aria-hidden="true"></span>' +
      '<span class="lbl">' + esc(d.label || d.id) + '</span>' +
      '<div>' + esc(who + ' · ' + (on ? '온라인' : '오프라인')) + '</div></div>';
  }).join('') + '</div>');
}

export function mount(el, opts) {
  return bind(el, defaults(opts), function (st) { return frame(html(st), st.title || '기기'); });
}

export const Presence = {html, mount};
