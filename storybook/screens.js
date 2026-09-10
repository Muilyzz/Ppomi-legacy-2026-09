// storybook/screens.js — 가짜 폰 화면. 캔버스에 그리고, 그린 글자의 상자를 그대로 '읽은 글자'로 내놓는다: OCR 없이 OCR 결과와 같은 형태.
// 실제 은행 캡처는 비공개라 여기 것은 전부 가상이다. 브라우저 전용(캔버스) — 스토리만 import 한다.
export const W = 348, H = 766;
const S = 2, FONT = "-apple-system, 'Apple SD Gothic Neo', sans-serif";

function screen(draw) {
  const c = document.createElement('canvas'); c.width = W * S; c.height = H * S;
  const g = c.getContext('2d'); g.scale(S, S); g.fillStyle = '#fff'; g.fillRect(0, 0, W, H);
  const words = [];
  const text = (str, x, y, o = {}) => {
    g.font = `${o.weight || 400} ${o.size || 15}px ${FONT}`; g.fillStyle = o.color || '#222'; g.textAlign = o.align || 'left'; g.textBaseline = 'alphabetic';
    g.fillText(str, x, y);
    const m = g.measureText(str), left = o.align === 'right' ? x - m.width : x;
    words.push({text: str, x: left / W, y: (y - m.actualBoundingBoxAscent) / H, w: m.width / W, h: (m.actualBoundingBoxAscent + m.actualBoundingBoxDescent) / H});
  };
  const line = (y) => { g.strokeStyle = '#eee'; g.lineWidth = 1; g.beginPath(); g.moveTo(16, y + 0.5); g.lineTo(W - 16, y + 0.5); g.stroke(); };
  const chrome = (title) => { text('9:41', 16, 24, {size: 13, weight: 600}); text(title, W / 2, 62, {size: 17, weight: 600, align: 'center'}); };
  draw({g, text, line, chrome});
  return {image: c.toDataURL('image/png'), words};
}
const won = (n) => (n < 0 ? '-' : '+') + Math.abs(n).toLocaleString('ko-KR') + '원';

// ---- 은행 앱 거래 목록: 두 장(스크롤)이 6행 겹친다. 4열 태그(커스텀 세부)와 전표 없음·파싱 안 됨 하나씩.
const TX = [
  ['09.10 12:31', '김밥천국 역삼점', -11000, '비용/식비/점심/회사앞'],
  ['09.10 08:41', '서울교통공사', -1550, '비용/교통/지하철'],
  ['09.09 19:02', '배달의민족', -24000, '비용/식비/배달'],
  ['09.09 15:12', '스타벅스 강남R', -5800, '비용/식비/카페'],
  ['09.09 12:28', '본죽 역삼', -9500, '비용/식비/점심/회사앞'],
  ['09.08 23:11', '카카오T 택시', -13400, '비용/교통/택시'],
  ['09.08 12:33', '샐러디 강남', -12500, '비용/식비/점심/회사앞'],
  ['09.07 20:15', 'GS25 역삼', -4300, '비용/식비/간식', 'warn'],
  ['09.06 11:00', '홍길동', -50000, '', 'bad'],
  ['09.05 03:02', '넷플릭스', -17000, '비용/구독/영상'],
  ['09.05 03:01', '유튜브 프리미엄', -14900, '비용/구독/영상'],
  ['09.03 12:30', '한솥도시락', -6800, '비용/식비/점심/회사앞'],
  ['09.01 09:00', '월세 홍길동', -650000, '비용/주거/월세'],
  ['08.31 23:59', '이자', 2130, '수익/이자'],
  ['08.25 09:00', '(주)회사 급여', 3200000, '수익/급여'],
];
const LIST_TOP = 140, ROW = 70, OFFSETS = [0, 6];
let balance = 2481230; const balances = TX.map((t) => { const b = balance; balance -= t[2]; return b; });

function bankFrame(offset) {
  return screen(({text, line, chrome}) => {
    chrome('입출금통장');
    text('123456-01-******', 16, 96, {size: 12, color: '#888'});
    text(balances[0].toLocaleString('ko-KR') + '원', 16, 124, {size: 22, weight: 700});
    TX.forEach((t, i) => {
      const y = LIST_TOP + (i - offset) * ROW; if (i < offset || y + ROW > H + 20) return;
      text(t[0], 16, y + 20, {size: 12, color: '#888'});
      text(t[1], 16, y + 44, {size: 15});
      text(won(t[2]), W - 16, y + 44, {size: 15, weight: 600, align: 'right', color: t[2] > 0 ? '#1a56db' : '#222'});
      text('잔액 ' + balances[i].toLocaleString('ko-KR') + '원', W - 16, y + 64, {size: 12, color: '#888', align: 'right'});
      line(y + ROW - 1);
    });
  });
}
export const bank = (() => {
  const frames = OFFSETS.map((o, k) => ({...bankFrame(o), top: o * ROW / H, clip: LIST_TOP / H, bottom: 1}));
  const records = TX.map((t, i) => {
    const k = OFFSETS.findIndex((o) => i >= o && LIST_TOP + (i - o) * ROW + ROW <= H);   // 이 행이 온전히 보이는 첫 장
    const y = LIST_TOP + (i - OFFSETS[k]) * ROW;
    const bad = t[4] === 'bad';
    return {id: 'tx-' + i, tag: t[3], occurredAt: '2026.' + t[0], status: t[4] || 'ok', note: t[4] === 'warn' ? '전표 없음' : bad ? '파싱 안 됨' : '',
      fields: bad ? {} : {merchant: t[1], amount: t[2], balance: balances[i]},
      anchors: [{frame: k, x: 12 / W, y: (y + 4) / H, w: (W - 24) / W, h: (ROW - 8) / H}]};
  });
  const schema = {fields: [{key: 'merchant', title: '가맹점'}, {key: 'amount', title: '금액', unit: '원'}, {key: 'balance', title: '잔액', unit: '원'}]};
  return {frames, records, schema};
})();

// ---- 인바디 결과 상세: 한 장, 기록 하나에 근거 상자 일곱 개. 스키마는 InBodyImport.fields 와 같은 제목·단위.
const METRICS = [['체중', 'weight', 72.3, 'kg'], ['골격근량', 'skeletalMuscleMass', 31.2, 'kg'], ['체지방량', 'bodyFatMass', 14.5, 'kg'], ['체지방률', 'bodyFatPercent', 20.1, '%'],
  ['BMI', 'bmi', 24.1, 'kg/m²'], ['내장지방레벨', 'visceralFatLevel', 7, 'level'], ['세포외수분비', 'extracellularWaterRatio', 0.382, 'ratio']];
const M_TOP = 190, M_ROW = 54;
export const inbody = (() => {
  const frame = screen(({text, line, chrome}) => {
    chrome('인바디 결과관리');
    text('2026.09.06 (금) 08:00', 16, 110, {size: 14});
    text('InBody 770', W - 16, 110, {size: 12, color: '#888', align: 'right'});
    text('체성분 분석', 16, 160, {size: 13, color: '#888'});
    METRICS.forEach((m, i) => {
      const y = M_TOP + i * M_ROW;
      text(m[0], 16, y + 34, {size: 15});
      text(m[2] + (m[3] === 'level' || m[3] === 'ratio' ? '' : ' ' + m[3]), W - 16, y + 34, {size: 17, weight: 600, align: 'right'});
      line(y + M_ROW - 1);
    });
  });
  const fields = {}; METRICS.forEach((m) => { fields[m[1]] = m[2]; });
  return {
    frames: [{...frame, top: 0, clip: 90 / H, bottom: 1}],
    records: [{id: 'inbody-20260906-0800', tag: '건강/체성분/인바디', occurredAt: '2026-09-06 08:00', status: 'ok', fields,
      anchors: METRICS.map((m, i) => ({frame: 0, x: 12 / W, y: (M_TOP + i * M_ROW + 4) / H, w: (W - 24) / W, h: (M_ROW - 8) / H}))}],
    schema: {fields: METRICS.map((m) => ({key: m[1], title: m[0], unit: m[3]}))},
  };
})();

// ---- 임대차 계약서 2페이지: 스크롤이 아니라 페이지라 top 을 0, 1 로 쌓는다(겹침 없음). 주민번호는 원본부터 가려져 있고 기록엔 임차인 ref 만 간다.
const PAGE1 = [
  ['부동산 임대차 계약서', null, {size: 18, weight: 700, align: 'center', x: W / 2}],
  ['1. 소재지: 서울 강남구 역삼동 000-0 2층 201호', 'unit'],
  ['2. 임대인: 홍길동', null],
  ['3. 임차인: 김OO (900101-1******)', 'tenant'],
  ['4. 보증금: 금 이천만원정 (₩20,000,000)', 'deposit'],
  ['5. 월세: 금 구십만원정 (₩900,000) 매월 5일 선불', 'rent'],
  ['6. 계약기간: 2025년 3월 1일 ~ 2027년 2월 28일', 'term'],
  ['7. 관리비: 월 80,000원 별도', 'fee'],
];
const PAGE2 = [
  ['특약사항', null, {size: 16, weight: 700}],
  ['1. 임차인은 애완동물을 기르지 않는다.', 'clause'],
  ['2. 계약 만료 1개월 전까지 갱신 여부를 통지한다.', 'clause2'],
  ['3. 원상복구 비용은 임차인이 부담한다.', 'clause3'],
  ['2025년 2월 20일', null],
  ['임대인 홍길동 (인)      임차인 김OO (인)', null],
];
function page(lines) {
  const boxes = {};
  const frame = screen(({text, line}) => {
    lines.forEach(([str, key, o = {}], i) => {
      const y = 70 + i * 52, x = o.x || 24;
      text(str, x, y, {size: 15, ...o});
      if (key) boxes[key] = {x: 12 / W, y: (y - 26) / H, w: (W - 24) / W, h: 40 / H};
      if (!o.size || o.size < 16) line(y + 16);
    });
  });
  return {frame, boxes};
}
export const lease = (() => {
  const p1 = page(PAGE1), p2 = page(PAGE2), U = '건물/2층/201호';
  const R = (id, frame, key, tag, item, value, extra = {}) => ({id, tag, fields: {item, value}, anchors: [{frame, ...(frame ? p2 : p1).boxes[key]}], status: 'ok', ...extra});
  return {
    frames: [{...p1.frame, top: 0, clip: 0, bottom: 1}, {...p2.frame, top: 1, clip: 0, bottom: 1}],
    records: [
      R('unit', 0, 'unit', U, '소재지', '역삼동 000-0 2층 201호'),
      R('tenant', 0, 'tenant', U + '/임차인', '임차인', 'tenant-kim'),
      R('deposit', 0, 'deposit', U + '/보증금', '보증금', 20000000),
      R('rent', 0, 'rent', U + '/월세', '월세', 900000),
      R('term', 0, 'term', U + '/기간', '계약기간', '2025-03-01 ~ 2027-02-28'),
      R('fee', 0, 'fee', '', '관리비', 80000, {status: 'warn', note: '분개 없음'}),
      R('clause', 1, 'clause', U + '/특약', '특약 1', '애완동물 금지'),
      R('clause2', 1, 'clause2', U + '/특약', '특약 2', '만료 1개월 전 갱신 통지'),
      R('clause3', 1, 'clause3', U + '/특약', '특약 3', '원상복구 임차인 부담'),
    ],
    schema: {fields: [{key: 'item', title: '항목'}, {key: 'value', title: '값'}]},
  };
})();
