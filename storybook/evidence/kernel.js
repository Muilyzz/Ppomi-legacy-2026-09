// 증빙 공통: 등급·링크·시각·이스케이프. 화면 HTML 없음. 도메인 분기 없음.
export const OFFICIAL = ['세금계산서', '카드', '현금영수증', '계산서'];
export const AUX = ['스냅샷', 'StepResult'];
export const LINK = {open: '열기', e2e: 'E2E', cache: '암호문 캐시', disabled: '오프라인'};
export const HOST = {mac: 'Mac', win: 'Win', phone: 'Phone'};

export function esc(s) { return String(s).replace(/[&<>"']/g, function (c) { return {'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#x27;'}[c]; }); }

export function gradeOf(kind) { return OFFICIAL.indexOf(kind) >= 0 ? '적격' : '보조'; }

export function deviceOf(fleet, id) {
  for (var i = 0; i < (fleet || []).length; i++) if (fleet[i].id === id) return fleet[i];
  return null;
}

export function hostLabel(fleet, host) {
  var d = deviceOf(fleet, host);
  return (d && d.label) || HOST[host] || host || 'local';
}

export function collectedAt(item) {
  var n = Number(item && item.collectedAtMs);
  return Number.isFinite(n) ? n : null;
}

export function timeShort(ms) {
  var d = new Date(ms);
  return (d.getUTCMonth() + 1) + '.' + d.getUTCDate() + ' ' +
    String(d.getUTCHours()).padStart(2, '0') + ':' + String(d.getUTCMinutes()).padStart(2, '0');
}

export function timeFull(ms) { return new Date(ms).toISOString().replace('T', ' ').replace('Z', ''); }

export function timeCol(ms) {
  var d = new Date(ms);
  var s = timeShort(ms) + ':' + String(d.getUTCSeconds()).padStart(2, '0');
  var frac = ms % 1000;
  return frac ? s + '.' + String(frac).padStart(3, '0') : s;
}

export function itemLabel(item, st) {
  var kind = item.kind || '';
  var label = hostLabel(st.fleet, item.host || st.here) + ' · ' + kind + (gradeOf(kind) === '보조' ? '(보조)' : '');
  var ms = collectedAt(item);
  return ms == null ? label : label + ' · ' + timeShort(ms);
}

// 자기 기기(host 없음·local·here)는 즉시. 피어가 살아 있으면 E2E. 아니면 비활성 — 암호문 캐시가 있을 때만 그 안내.
export function linkState(item, fleet, here) {
  var host = item.host || here;
  if (!host || host === 'local' || host === here) return 'open';
  var peer = deviceOf(fleet, host);
  if (peer && peer.online) return 'e2e';
  return item.cache === 'ciphertext' ? 'cache' : 'disabled';
}

export function linkLabel(state) { return LINK[state] || LINK.disabled; }

export function flagged(map, id) { return !!(map && map[id]); }

export function itemById(items, id) {
  for (var i = 0; i < (items || []).length; i++) if (items[i].evidence_id === id) return items[i];
  return null;
}

export function badges(item) {
  return '<small class="meta">' + esc(gradeOf(item.kind)) + ' · ' + esc(item.linked ? '연결' : '미연결') + '</small>';
}

export function debugId(id, on) { return on ? ' <code>' + esc(id) + '</code>' : ''; }

export function defaults(opts) {
  var st = {title: '증빙', here: 'mac', fleet: [], items: [], layers: [], server: {}, debug: false, hover: '', session: {}, inflight: {}, receiveMs: 480};
  Object.keys(opts || {}).forEach(function (k) { if (opts[k] !== undefined) st[k] = opts[k]; });
  st.session = Object.assign({}, st.session);
  st.inflight = Object.assign({}, st.inflight);
  return st;
}

export function frame(inner, title) {
  return '<div class="ev-fleet">' +
    (title ? '<div class="jtitle"><h2 class="key">' + esc(title) + '</h2></div>' : '') +
    inner + '</div>';
}

export function wrapEv(name, inner) {
  return '<div data-ev="' + esc(name) + '">' + inner + '</div>';
}
