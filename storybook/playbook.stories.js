// 절차 뷰 — 패키지 하나(명세 나무 + 발자국 그래프)와 그 뷰를 목록에 끼운 두 조합(공공사이트 트리 · 대상별 앱 목록). 명세는 Catalog 원본, 발자국은 전부 가짜(playbook-fixture.js).
import {fn} from 'storybook/test';
import '../Ppomi/Sources/Ppomi/Web/playbook.js';
import '../Ppomi/Sources/Ppomi/Web/facts.js';
import {yeogiWalk, installed} from './playbook-fixture.js';
import {parseGovSites, govSchema} from './gov-fixture.js';
import {listWithPlaybook} from './compose.js';
import govMd from '../docs/gov-sites.md?raw';
const P = globalThis.Playbook, X = globalThis.Facts;
const manifests = import.meta.glob('../Ppomi/Sources/Ppomi/Catalog/*/manifest.json', {eager: true, import: 'default'});
const catalog = Object.fromEntries(Object.values(manifests).map((m) => [m.id, m]));
const footprints = {yeogi: yeogiWalk};

export default {
  title: '절차',
  render: (args) => { const el = document.createElement('div'); P.mount(el, args); return el; },
  argTypes: {
    cap: {control: 'text', description: '강조할 기능 ID · 비우면 전체'},
    selected: {control: 'text', description: '선택한 단계(n)·화면(s)·걸음(w) ID'},
    manifest: {table: {disable: true}}, footprints: {table: {disable: true}},
  },
  args: {manifest: catalog.yeogi, footprints: yeogiWalk, cap: '', selected: null, onSelect: fn(), onChange: fn()},
};

export const Yeogi = {name: '여기어때 · 폰 · 발자국 12걸음 · 시트 닫기 사이클'};
export const Hometax = {name: '홈택스 · Mac 브라우저 · 기능 3 · 앞 4단계 접힘 · 발자국 없음', args: {manifest: catalog.hometax, footprints: []}};
export const HometaxCap = {name: '홈택스 · 현금영수증 기능만 강조', args: {manifest: catalog.hometax, footprints: [], cap: 'cash-receipt-history'}};
export const Gov24 = {name: '정부24 · Windows · 발자국 없음', args: {manifest: catalog.gov24, footprints: []}};
export const JointCert = {name: '사업자 공동인증서 · 15단계 · 가장 깊은 나무', args: {manifest: catalog['joint-certificate'], footprints: []}};
export const KbEnterprise = {name: 'KB스타기업뱅킹 · 글리프 없는 제목 → kind 로', args: {manifest: catalog['kb-enterprise'], footprints: []}};

// 목록 + 절차 조합은 compose.js. 여기선 플레이북 ID → {manifest, footprints} 만 준다.
const resolve = (pkg) => catalog[pkg] && {manifest: catalog[pkg], footprints: footprints[pkg] || []};
const gov = parseGovSites(govMd).filter((r) => r.fields.priority <= 'P2');
export const GovSites = {name: '공공사이트 트리 + 절차 · P1·P2 · 행을 고르면 아래에',
  render: () => listWithPlaybook({records: gov, schema: govSchema, depth: 3}, gov.find((r) => r.fields.pkg === 'hometax'), resolve)};

// 대상별 앱 목록: 패키지의 대상(폰 · Mac 브라우저 · Windows)은 manifest 가 말하고, 폰이 iPhone 인지 Android 인지는 설치 여부(어댑터)가 말한다.
const F = (key, title, type) => ({key, title, type});
const TARGET = {browser: 'Mac 브라우저', windows: 'Windows'};
const apps = Object.values(catalog).flatMap((m) => {
  const devices = TARGET[m.launch.target] ? [TARGET[m.launch.target]] : ['iPhone', 'Android'].filter((d) => installed[d].includes(m.id));
  return devices.map((d) => ({id: d + '/' + m.id, fields: {name: m.name, path: d + '/' + m.name, pkg: m.id, count: 1, caps: m.capabilities.length, walks: (footprints[m.id] || []).length}}));
});
const appSchema = {fields: [F('name', '앱', 'text'), F('path', '대상/앱', 'path'), F('pkg', '플레이북', 'ref'), F('count', '앱 수', 'amount'), F('caps', '기능', 'amount'), F('walks', '발자국', 'amount')]};
export const AppList = {name: '앱 목록 · iPhone/Android/Mac 브라우저/Windows · 대상별 트리맵 + 절차',
  render: () => listWithPlaybook({records: apps, schema: appSchema, depth: 1}, apps.find((r) => r.id === 'iPhone/yeogi'), resolve)};
