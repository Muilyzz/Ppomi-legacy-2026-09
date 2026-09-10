// storybook/playbook-fixture.js — 가짜 발자국. 실제 발자국(data/playbooks/*.jsonl)은 비공개라 여기 것은 전부 가상이고 모양만 같다(Footprints.swift 의 Footprint).
// 화면 지문 = 안정 단어 8개 이하. 여기어때를 한 번 걸었고, 객실 제목을 잘못 눌러 요금 상세 시트가 열렸다 닫혀 사이클이 하나, 쿠폰 받기는 같은 화면에 머물러 자기 고리 하나.
const S = {
  home: ['App', 'Store', 'YouTube', '설정', '카메라', '사진', '메시지', '캘린더'],
  yeogi: ['여기어때', '국내숙소', '해외숙소', '항공', '패키지', '여행', '지역', '이벤트'],
  search: ['숙소명', '지역', '검색', '최근', '인기', '제주', '부산', '강릉'],
  results: ['타니베이', '검색결과', '호텔', '리조트', '부산', '추천순', '거리순', '지도'],
  hotel: ['타니베이', '호텔', '객실', '편의시설', '후기', '위치', '모든', '보기'],
  rooms: ['객실', '디럭스', '스탠다드', '룸온리', '조식포함', '예약하기', '더보기', '쿠폰'],
  fare: ['요금', '상세', '객실요금', '세금', '봉사료', '총액', '닫기', '안내'],
  login: ['로그인', '카카오로', '시작하기', '비회원으로', '예약', '회원가입', '아이디', '비밀번호'],
  booking: ['예약자', '정보', '이름', '휴대폰', '필수', '약관', '동의', '결제하기'],
  payment: ['결제수단', '토스페이', '카카오페이', '페이코', '계좌이체', '휴대폰', '쿠폰', '결제하기'],
  paymentCoupon: ['결제수단', '토스페이', '카카오페이', '페이코', '계좌이체', '휴대폰', '쿠폰적용', '결제하기'],   // 쿠폰 뒤 같은 화면(Jaccard .78)
  done: ['예약완료', '예약번호', '취소규정', '체크인', '체크아웃', '숙소', '문의', '홈으로'],
};
let n = 0;
const fp = (glyph, target, before, after, ok, replayOK = 0, fail = 0, replayFail = 0) => ({
  id: 'fp-' + (++n), app: '여기어때', glyph, target, fingerprintBefore: S[before], fingerprintAfter: S[after],
  createdAt: '2026-09-05T17:1' + n + ':00Z', source: 'brain', verified: {ok, fail, replayOK, replayFail},
});
export const yeogiWalk = [
  fp('▶', '여기어때', 'home', 'yeogi', 3, 2),
  fp('⊙', '^검색$', 'yeogi', 'search', 3, 2),
  fp('⌨', '타니베이', 'search', 'results', 2, 1),
  fp('⊙', '타니베이', 'results', 'hotel', 2, 1),
  fp('⊙', '모든 객실', 'hotel', 'rooms', 2, 1),
  fp('⊙', '디럭스', 'rooms', 'fare', 1, 0, 1),            // 객실 제목을 눌러 요금 상세 시트가 열림(잘못 든 길)
  fp('⎋', 'X', 'fare', 'rooms', 1),                       // 시트 닫기 → 객실 목록으로 되돌아감(사이클)
  fp('⊙', '예약하기', 'rooms', 'login', 2, 1),
  fp('👤', '로그인', 'login', 'booking', 1),               // 사용자 차례
  fp('↓', '필수', 'booking', 'payment', 1, 0, 0, 1),
  fp('🎟', '쿠폰 받기', 'payment', 'paymentCoupon', 1),    // 같은 화면에 머묾(자기 고리)
  fp('⊙', '결제하기', 'paymentCoupon', 'done', 1),         // 승인 뒤의 결제 탭 한 번
];
// 폰 패키지가 iPhone 인지 Android 인지는 manifest 가 아니라 설치 여부(어댑터)가 말한다 — 여기선 가짜 설치 목록
export const installed = {iPhone: ['yeogi', 'kb', 'kb-enterprise', 'toss', 'kakao', 'kbank'], Android: ['toss', 'kakao']};
// 가짜 판정 장부(MCP verify_step 이 남기는 줄과 같은 모양, data/playbooks/<id>.verify.jsonl). 여기어때 v0.1.0: 앞 4단계 ok, 필수 체크는 라벨이 달라 changed,
// 결제수단은 fail 뒤 ok(마지막 판정이 이긴다). 홈택스는 이전 버전(0.0.9)의 판정만 → 전부 stale 이라 미검증.
let t = 0;
const J = (app, version, capability, step, outcome, extra = {}) => ({id: 'v-' + app + '-' + (++t), app, version, capability, step, outcome, at: '2026-09-10T05:' + String(t).padStart(2, '0') + ':00Z', by: 'agent', ...extra});
export const fakeLedger = {
  yeogi: [
    J('yeogi', '0.1.0', 'prepare-booking', 'step-1', 'ok'), J('yeogi', '0.1.0', 'prepare-booking', 'step-2', 'ok'), J('yeogi', '0.1.0', 'prepare-booking', 'step-3', 'ok'), J('yeogi', '0.1.0', 'prepare-booking', 'step-4', 'ok'),
    J('yeogi', '0.1.0', 'prepare-booking', 'step-6', 'changed', {actual: '필수 동의 항목 전체 선택', note: '한 번에 체크하는 토글이 생김'}),
    J('yeogi', '0.1.0', 'prepare-booking', 'step-8', 'fail', {note: '결제수단 목록이 시트 아래에 가려짐'}),
    J('yeogi', '0.1.0', 'prepare-booking', 'step-8', 'ok', {note: '스크롤 뒤 보임'}),
  ],
  hometax: [J('hometax', '0.0.9', 'yearend-simplified', 'step-1', 'ok'), J('hometax', '0.0.9', 'yearend-simplified', 'step-2', 'ok'), J('hometax', '0.0.9', 'yearend-simplified', 'step-3', 'changed', {actual: '로그인 · 오른쪽 위'})],
};
