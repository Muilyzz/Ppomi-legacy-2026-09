// 개발자 페이지 — 플레이북 검증 현황. 실제 로컬 자료(번들 Catalog + data/playbooks 의 설치 패키지·발자국·판정 장부, 전부 이 Mac 의 비공개 파일)를 그대로 읽는다.
// 위: 값 종류 뷰(대상/패키지/기능 트리맵 = 미검증 단계 수, 표). 아래: 고른 기능의 플레이북(명세 나무에 판정 ✓△✗, 발자국 그래프). 판정은 MCP verify_step 이 남기고, 파일이 바뀌면 Vite 가 다시 그린다.
import '../Ppomi/Sources/Ppomi/Web/playbook.js';
import '../Ppomi/Sources/Ppomi/Web/facts.js';
import '../Ppomi/Sources/Ppomi/Web/verify.js';
import {listWithPlaybook} from './compose.js';
import {yeogiWalk, fakeLedger} from './playbook-fixture.js';
const V = globalThis.Verify;
const bundled = import.meta.glob('../Ppomi/Sources/Ppomi/Catalog/*/manifest.json', {eager: true, import: 'default'});
const local = import.meta.glob('../data/playbooks/catalog/*/manifest.json', {eager: true, import: 'default'});
const files = import.meta.glob('../data/playbooks/*.jsonl', {eager: true, query: '?raw', import: 'default'});
const catalog = {};
[...Object.values(bundled), ...Object.values(local)].forEach((m) => { catalog[m.id] = m; });   // 설치본이 번들을 덮는다(PlaybookCatalog.load 와 같은 순서)
const lines = (raw) => raw.split('\n').filter(Boolean).map((l) => { try { return JSON.parse(l); } catch (e) { return null; } }).filter(Boolean);
const nfc = (s) => s.normalize('NFC').toLowerCase();   // macOS 파일명은 NFD(자모 분해)로 온다 — Swift 는 정준 동치로 비교하지만 JS 는 아니다
const byIdentity = (name) => Object.values(catalog).find((m) => [m.id, m.name, ...(m.aliases || [])].some((k) => nfc(k) === nfc(name)));
const footprints = {}, ledgers = {};
Object.entries(files).forEach(([path, raw]) => {   // <id>.verify.jsonl = 판정, 나머지 <id|이름>.jsonl = 발자국(옛 파일은 앱 이름)
  const name = path.split('/').pop().replace(/\.jsonl$/, '').normalize('NFC');
  if (name.endsWith('.verify')) ledgers[name.slice(0, -7)] = lines(raw);
  else { const m = byIdentity(name); if (m) footprints[m.id] = (footprints[m.id] || []).concat(lines(raw)); }
});
function page(catalog, footprints, ledgers, pick) {
  const packages = Object.values(catalog).map((m) => ({manifest: m, footprints: footprints[m.id] || [], ledger: ledgers[m.id] || []}));
  const list = V.records(packages);
  const resolve = (pkg) => catalog[pkg] && {manifest: catalog[pkg], footprints: footprints[pkg] || [], verification: V.summary(catalog[pkg], ledgers[pkg] || [])};
  return listWithPlaybook({...list, depth: 2}, list.records.find(pick) || list.records[0], resolve);
}
export default {title: '개발자'};
export const Real = {name: '플레이북 검증 · 실제 로컬 자료 · 이 Mac 의 비공개 파일', render: () => page(catalog, footprints, ledgers, (r) => r.fields.pkg === 'yeogi')};
export const Fake = {name: '플레이북 검증 · 가짜 판정 · 여기어때 ✓△✗ · 홈택스는 이전 버전 판정뿐',
  render: () => page({yeogi: catalog.yeogi, hometax: catalog.hometax, gov24: catalog.gov24}, {yeogi: yeogiWalk}, fakeLedger, (r) => r.fields.pkg === 'yeogi')};
