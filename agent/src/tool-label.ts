// 실행 내역 한 줄의 라벨: 무엇을 · 어떻게 봤는지. OCR = 화면 글자 인식, VLM(유료) = 보조 눈, DOM = 브라우저 문서, 비공개 OCR = 값이 대화로 오지 않는 경로.
// 이름은 앱이 번들한 도구 이름이며 모델 출력이 아니다.
const fixed: Record<string, string> = {
  device_status: "기기 상태 확인", app_list: "앱 찾기", app_open: "앱 열기", store_search: "Play 스토어 검색",
  screen_read: "화면 읽기 · DOM", ui_tap: "화면 누르기 · DOM", ui_type: "텍스트 입력 · DOM",
  ui_scroll: "화면 스크롤 · DOM", device_home: "홈으로 이동", device_back: "뒤로 이동",
  file_list: "파일 목록 확인", file_read: "파일 읽기", file_write: "파일 쓰기",
  list_memories: "기억 확인", save_memory: "기억 저장", end_conversation: "대화 종료",
  list_playbooks: "절차 찾기", read_playbook: "절차 읽기",
  request_user_input: "답변 대기", request_bank_profile: "은행정보 대기",
  phone_wait: "폰 잠금 대기", run_combo: "알려진 동작 재생 · OCR", screen_inspect: "화면 관찰 · VLM(유료)", browser_open: "Mac Chrome 열기",
  profile_fill: "기본정보 입력 · 비공개 OCR", bank_profile_capture: "은행정보 수집 · 비공개 OCR", inbody_capture: "인바디 수집 · 비공개 OCR",
  profile_status: "기본정보 확인", profile_save: "기본정보 저장", profile_delete: "기본정보 삭제",
  verify_step: "단계 판정", note_footprint: "동작 기록", confirm_payment: "결제 승인 요청", ask_choice: "선택 요청",
  pay_preference: "결제 수단 조회", record_spend: "지출 기록", balances: "잔액 조회", transactions: "거래 조회", sql: "장부 조회",
};
const devices: Record<string, string> = { phone: "iPhone", windows: "Windows", android: "Android" };
const actions: Record<string, string> = {
  screen: "화면 읽기", tap: "누르기", click: "누르기", type: "입력", key: "키 입력", scroll: "스크롤", open: "앱 열기",
  installed: "설치 확인", status: "상태 확인", swipe: "밀기",
};
export function toolLabel(name: string): string {
  if (fixed[name]) return fixed[name];
  const m = /^(phone|windows|android)_([a-z]+)$/.exec(name);
  if (m) {
    const method = m[1] === "android" ? "DOM" : "OCR";   // Android는 접근성 트리, iPhone·Windows는 화면 글자 인식
    return `${devices[m[1]]} ${actions[m[2]] ?? m[2]} · ${method}`;
  }
  if (/^dom_|_dom$/.test(name)) return `${name} · DOM`;
  return "도구 실행";
}
