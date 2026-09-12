// Preview 종류만. bind가 여기를 보고, Preview HTML은 preview.js.
import {esc, flagged, linkState} from './kernel.js';

export const PREVIEW = {
  empty: '미리보기 없음 · 기기 미부착',
  receive: '수신 중',
  session: '세션 미리보기 · 바이트 없음',
  ciphertext: '암호문 캐시 · 오프라인 · 원문 없음',
  offline: '오프라인 · 미리보기 불가',
  e2e: '미리보기 · E2E · 바이트 없음',
  local: '미리보기 · 파일은 기기 · 바이트 없음',
};

export function kind(it, st) {
  if (!it) return 'empty';
  var id = it.evidence_id;
  if (flagged(st && st.inflight, id)) return 'receive';
  if (flagged(st && st.session, id)) return 'session';
  var link = linkState(it, st.fleet, st.here);
  if (link === 'cache') return 'ciphertext';
  if (link === 'disabled') return 'offline';
  if (link === 'e2e') return 'e2e';
  return 'local';
}

export function copy(k) { return PREVIEW[k] || PREVIEW.local; }

export function pane(k) {
  var spin = k === 'receive' ? '<span class="ev-spin" aria-hidden="true"></span>' : '';
  return '<div class="ev-pop-preview">' + spin + '<span class="meta">' + esc(copy(k)) + '</span></div>';
}
