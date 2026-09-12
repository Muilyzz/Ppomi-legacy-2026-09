// 공통 마운트: 클릭=열기/받기, hover=E2E 수신. Panel과 자식이 같은 세션·암호문 캐시를 쓴다.
import {flagged, itemById, linkState} from './kernel.js';
import {kind as previewKind, pane as previewPane} from './preview-kind.js';

export function bind(el, st, render) {
  function draw() { el.innerHTML = render(st); }
  function paint(id) {
    if (!el.querySelector) { draw(); return; }
    var k = previewKind(itemById(st.items, id), st);
    var nodes = el.querySelectorAll('[data-tip="' + String(id).replace(/"/g, '') + '"]');
    for (var i = 0; i < nodes.length; i++) {
      var paneEl = nodes[i].querySelector('.ev-pop-preview');
      if (paneEl) paneEl.outerHTML = previewPane(k);
      nodes[i].setAttribute('data-preview', k);
      if (k === 'receive') nodes[i].setAttribute('aria-busy', 'true');
      else nodes[i].removeAttribute('aria-busy');
    }
  }
  function receive(id) {
    var it = itemById(st.items, id);
    if (!it || flagged(st.session, id) || flagged(st.inflight, id)) return;
    if (linkState(it, st.fleet, st.here) !== 'e2e') return;
    st.inflight[id] = true;
    paint(id);
    setTimeout(function () {
      delete st.inflight[id];
      st.session[id] = true;
      paint(id);
    }, st.receiveMs);
  }
  function set(patch) { Object.keys(patch).forEach(function (k) { st[k] = patch[k]; }); draw(); }
  el.addEventListener('click', function (ev) {
    var b = ev.target.closest('[data-open]');
    if (!b || !el.contains(b) || b.disabled) return;
    if (st.onOpen) st.onOpen(b.dataset.open);
    receive(b.dataset.open);
  });
  el.addEventListener('pointerenter', function (ev) {
    var w = ev.target.closest('[data-hover]');
    if (!w || !el.contains(w)) return;
    receive(w.dataset.hover);
  }, true);
  draw();
  return {set: set, state: function () { return st; }};
}
