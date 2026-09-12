// storybook/compose.js — 목록 + 절차 조합. 위는 값 종류 Panel(표·트리맵), 행을 고르면 그 기록의 플레이북(ref 필드 pkg)을 아래에 끼운다. 조합은 페이지 몫이고 두 뷰는 서로 모른다.
// resolve(pkg) → {manifest, footprints, verification?} 또는 falsy(플레이북 없음).
export function listWithPlaybook(list, initial, resolve) {
  const P = globalThis.Playbook, X = globalThis.Facts;
  const el = document.createElement('div'), top = document.createElement('div'), bottom = document.createElement('div');
  el.append(top, bottom);
  const show = (rec) => {
    const pkg = rec && rec.fields && rec.fields.pkg, pack = pkg && resolve(pkg);
    if (pack) { P.mount(bottom, pack); return; }
    bottom.innerHTML = '<div class="sec">절차</div><p class="meta">' + (rec && rec.fields ? '플레이북 없음 · 후보' : '행을 고르면 절차가 여기에') + '</p>';
  };
  X.Panel.mount(top, {...list, selected: initial ? initial.id : null, onSelect: show});
  show(initial);
  return el;
}
