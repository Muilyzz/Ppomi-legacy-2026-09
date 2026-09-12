// 2026-09-12 잠금용 합성 증빙. 서버 칸에는 분개·숫자만(id는 디버그). 스냅샷·엑셀 바이트는 없음.
export const title = '증빙';
export const here = 'mac';

export const fleet = [
  {id: 'mac', kind: 'mac', label: 'Mac', online: true},
  {id: 'win', kind: 'win', label: 'Win', online: true},
  {id: 'phone', kind: 'phone', label: 'Phone', online: false},
];

export const server = {
  memo: '소액현금 9월',
  amount: 164000,
  unit: '원',
  evidence_ids: ['ev_tax_001', 'ev_card_002', 'ev_cash_003', 'ev_bill_004', 'ev_snap_1', 'ev_step_1', 'ev_gone_1'],
};

// 로컬 파일 키 = (host, collectedAtMs). ms. 서버 칸의 evidence_id 와 별개.
export const items = [
  {evidence_id: 'ev_tax_001', kind: '세금계산서', linked: true, host: 'mac', collectedAtMs: Date.parse('2026-09-12T01:10:00.123Z')},
  {evidence_id: 'ev_card_002', kind: '카드', linked: true, host: 'win', collectedAtMs: Date.parse('2026-09-11T08:22:33.456Z')},
  {evidence_id: 'ev_cash_003', kind: '현금영수증', linked: true, host: 'mac', collectedAtMs: Date.parse('2026-09-12T01:10:00.789Z')},
  {evidence_id: 'ev_bill_004', kind: '계산서', linked: false, host: 'win', collectedAtMs: Date.parse('2026-09-10T15:00:00.001Z')},
  {evidence_id: 'ev_snap_1', kind: '스냅샷', linked: false, host: 'phone', collectedAtMs: Date.parse('2026-09-12T00:05:12.321Z')},
  {evidence_id: 'ev_step_1', kind: 'StepResult', linked: false, host: 'phone', cache: 'ciphertext', collectedAtMs: Date.parse('2026-09-12T00:06:44.654Z')},
];

export const layers = [
  {title: '1 폰 훑어보기', evidence_id: 'ev_snap_1', note: '보조'},
  {title: '2 PC 추출', evidence_id: 'ev_step_1', note: '보조 · StepResult'},
  {title: '3 공식 첨부', evidence_id: 'ev_tax_001', note: '적격 · 세금계산서'},
];

export const pick = (ids) => items.filter((it) => ids.includes(it.evidence_id));
