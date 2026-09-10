// storybook/facts-fixture.js — 대장 다섯 개를 같은 {records, schema} 로. 도메인 지식은 여기(어떤 필드가 어떤 값 종류인지)에만 있고 뷰어엔 없다. 전부 가상 자료.
const F = (key, title, type, extra) => ({key, title, type, ...extra});
const rec = (id, fields) => ({id, fields});

// ---- 건축물대장: 층·호 경로, 면적, 사용승인일, 외곽선(SpatialData/example.json 의 가상 형상), 소유 지분, 출처 등급
const BASE = {points: [{x: 0, y: 0}, {x: 24, y: 0}, {x: 24, y: 10}, {x: 14, y: 10}, {x: 14, y: 18}, {x: 0, y: 18}]};
const UPPER = {points: [{x: 2, y: 2}, {x: 12, y: 2}, {x: 12, y: 14}, {x: 2, y: 14}]};
const RC = '철근콘크리트';
export const building = {
  schema: {fields: [F('floor', '층·호', 'path'), F('use', '용도', 'text'), F('structure', '구조', 'text'), F('area', '면적', 'amount', {unit: '㎡'}), F('approved', '사용승인일', 'time'), F('footprint', '외곽선', 'place'), F('share', '소유 지분', 'ratio'), F('prov', '출처', 'provenance')]},
  records: [
    rec('b1', {floor: '건물/지하1층', use: '주차장', structure: RC, area: 320, approved: '2004-06-15', footprint: BASE, share: 10000, prov: 'schematic'}),
    rec('f1', {floor: '건물/1층', use: '제1종근린생활시설', structure: RC, area: 320, approved: '2004-06-15', share: 10000, prov: 'schematic'}),
    rec('f2-201', {floor: '건물/2층/201호', use: '사무소', structure: RC, area: 60, approved: '2004-06-15', footprint: UPPER, share: 10000, prov: 'measured'}),
    rec('f2-202', {floor: '건물/2층/202호', use: '사무소', structure: RC, area: 60, approved: '2004-06-15', share: 10000, prov: 'measured'}),
    rec('f3-301', {floor: '건물/3층/301호', use: '사무소', structure: RC, area: 60, approved: '2004-06-15', share: 10000, prov: 'measured'}),
    rec('f3-302', {floor: '건물/3층/302호', use: '주택', structure: RC, area: 60, approved: '2004-06-15', share: 5000, prov: 'measured'}),
    rec('f4', {floor: '건물/4층', use: '주택', structure: RC, area: 120, approved: '2004-06-15', share: 10000, prov: 'measured'}),
    rec('f5', {floor: '건물/5층', use: '사무소', structure: '경량철골', area: 120, approved: '2015-03-02', share: null, prov: 'estimated'}),   // 증축 · 지분 미입력 ≠ 0
  ],
};

// ---- 대출 약정: 기간 하나(막대) + 회차별 납입일(점), 연/월 경로로 원금 트리맵
const start = 50000000;
const installments = Array.from({length: 12}, (_, i) => {
  const y = 2025 + Math.floor((9 + i) / 12), m = (9 + i) % 12 + 1, balance = start - 700000 * (i + 1), interest = Math.round((balance + 700000) * 0.045 / 12 / 10) * 10;
  return rec(`i-${y}-${m}`, {item: `${i + 1}회차 상환`, period: `${y}/${m}월`, due: `${y}-${String(m).padStart(2, '0')}-15`, principal: 700000, interest, balance, prov: 'ocr'});
});
export const loan = {
  schema: {fields: [F('item', '항목', 'text'), F('period', '연/월', 'path'), F('due', '납입일', 'time'), F('from', '약정 시작', 'time', {until: 'to'}), F('to', '약정 만기', 'time'), F('principal', '원금', 'amount', {unit: '원'}), F('interest', '이자', 'amount', {unit: '원'}), F('balance', '잔액', 'amount', {unit: '원'}), F('prov', '출처', 'provenance')]},
  records: [rec('loan', {item: '주택담보대출 약정', from: '2024-03-15', to: '2029-03-15', principal: start, balance: start, prov: 'manual'}), ...installments],
};

// ---- 자동차등록증 + 보험 + 정비: 경로 없음 → 트리맵 없음, 시간축만
export const car = {
  schema: {fields: [F('item', '항목', 'text'), F('plate', '번호판', 'ref'), F('registered', '최초등록일', 'time'), F('at', '정비일', 'time'), F('insuredFrom', '보험 시작', 'time', {until: 'insuredTo'}), F('insuredTo', '보험 만기', 'time'), F('mileage', '주행거리', 'amount', {unit: 'km'}), F('value', '시세', 'amount', {unit: '원'}), F('cost', '비용', 'amount', {unit: '원'}), F('prov', '출처', 'provenance')]},
  records: [
    rec('reg', {plate: '12가3456', item: '자동차등록증', registered: '2021-03-10', mileage: 48210, value: 18500000, prov: 'ocr'}),
    rec('ins', {plate: '12가3456', item: '자동차보험', insuredFrom: '2025-11-01', insuredTo: '2026-11-01', cost: 842000, prov: 'manual'}),
    rec('m1', {plate: '12가3456', item: '엔진오일 교환', at: '2026-04-12', mileage: 45100, cost: 98000, prov: 'manual'}),
    rec('m2', {plate: '12가3456', item: '타이어 교체', at: '2026-08-20', mileage: 47900, cost: 520000, prov: 'manual'}),
  ],
};

// ---- 지출 장소: 가맹점 좌표(위도·경도) → 평면도, 태그 경로 → 트리맵, 시각 → 시간축
const P = (lat, lng) => ({lat, lng});
export const spending = {
  schema: {fields: [F('merchant', '가맹점', 'text'), F('tag', '태그', 'path'), F('amount', '금액', 'amount', {unit: '원'}), F('at', '시각', 'time'), F('place', '위치', 'place'), F('prov', '출처', 'provenance')]},
  records: [
    rec('s1', {merchant: '김밥천국 역삼점', tag: '비용/식비/점심/회사앞', amount: 11000, at: '2026-09-10', place: P(37.5012, 127.0371), prov: 'ocr'}),
    rec('s2', {merchant: '스타벅스 강남R', tag: '비용/식비/카페', amount: 5800, at: '2026-09-09', place: P(37.4998, 127.0352), prov: 'ocr'}),
    rec('s3', {merchant: '본죽 역삼', tag: '비용/식비/점심/회사앞', amount: 9500, at: '2026-09-09', place: P(37.5021, 127.0389), prov: 'ocr'}),
    rec('s4', {merchant: '배달의민족', tag: '비용/식비/배달', amount: 24000, at: '2026-09-09', place: P(37.4975, 127.0330), prov: 'ocr'}),
    rec('s5', {merchant: '서울교통공사', tag: '비용/교통/지하철', amount: 1550, at: '2026-09-10', place: P(37.5007, 127.0366), prov: 'ocr'}),
    rec('s6', {merchant: '카카오T 택시', tag: '비용/교통/택시', amount: 13400, at: '2026-09-08', place: P(37.5040, 127.0480), prov: 'ocr'}),
    rec('s7', {merchant: 'GS25 역삼', tag: '비용/식비/간식', amount: 4300, at: '2026-09-07', place: P(37.5015, 127.0340), prov: 'aiEstimate'}),
    rec('s8', {merchant: '한솥도시락', tag: '비용/식비/점심/회사앞', amount: 6800, at: '2026-09-03', place: P(37.5003, 127.0398), prov: 'ocr'}),
  ],
};

// ---- 보유 종목: 분류 경로 + 평가액 → 트리맵, 비중 → <meter>
export const holdings = {
  schema: {fields: [F('name', '종목', 'text'), F('path', '분류', 'path'), F('value', '평가액', 'amount', {unit: '원'}), F('weight', '비중', 'ratio'), F('asOf', '기준일', 'time'), F('prov', '출처', 'provenance')]},
  records: [
    rec('h1', {name: '삼성전자', path: '주식/국내/반도체', value: 4200000, weight: 3500, asOf: '2026-09-10', prov: 'api'}),
    rec('h2', {name: 'SK하이닉스', path: '주식/국내/반도체', value: 1800000, weight: 1500, asOf: '2026-09-10', prov: 'api'}),
    rec('h3', {name: '카카오', path: '주식/국내/플랫폼', value: 600000, weight: 500, asOf: '2026-09-10', prov: 'api'}),
    rec('h4', {name: 'VOO', path: '주식/해외/ETF', value: 3600000, weight: 3000, asOf: '2026-09-10', prov: 'api'}),
    rec('h5', {name: '채권형 펀드', path: '펀드/채권', value: 1200000, weight: 1000, asOf: '2026-09-10', prov: 'manual'}),
    rec('h6', {name: '예수금', path: '현금', value: 600000, weight: 500, asOf: '2026-09-10', prov: 'api'}),
  ],
};
