# 청약홈 (Parallels Windows)
- 대상 `windows`: `windows_open(app: applyhome)`로 Parallels 기본 브라우저 새 탭에 연다. Mac Chrome(`browser_open`)은 거부된다. 근거(2026-09-10 로그인 페이지 관찰): 공동인증서 안내에 "Mac OS 10.15(Parallels) 이상버전 이용은 현재 불가", 보안프로그램(공동인증 보안프로그램·순위확인서 위변조방지·암호화코드 검증) 설치 안내, 권장 브라우저 Edge·Chrome.
- 같은 탭 이동: `windows_key ctrl+l → windows_type URL → windows_key enter`. 다 쓴 탭 `ctrl+w`. 휠은 포인터가 창 안에 있어야 먹는다(도구가 들여보냄). 안 움직이면 빈 곳 windows_click 뒤 재시도 또는 `pagedown`. 위젯 보드가 덮으면 `windows_key win` → `escape`. 자바스크립트 알림은 `escape`.
- 보안프로그램 설치 알림은 재설치 반복 금지. 이미 허용된 공식 설치만 이어가고, 관리자 인증·새 권한은 그 지점에서 당사자에게.

## 관찰 (2026-09-10, 공개 페이지 curl/WebFetch)
- 홈 https://www.applyhome.co.kr/ → 실제 화면 /co/coa/selectMainView.do. 상단 메뉴: 청약신청 / 청약당첨조회 / 청약자격확인 / 공고단지 청약연습 / 청약일정 및 통계 / 청약제도안내 / 청약소통방. 오른쪽 위 마이페이지·검색. 홈에 공지 팝업("팝업 닫기"), 청약문의 1644-7445.
- 로그인 페이지 https://www.applyhome.co.kr/ap/apj/reqst/selectPblancChoise.do (경로 "홈으로 > 로그인"). 탭: 공동 인증서 / 금융 인증서 / 네이버 인증서 / KB국민 인증서 / 토스 인증서 / 신한 인증서 / 카카오톡 인증서. 안내: 증권용 공동인증서 불가, 청약통장 미가입자는 공동·금융인증서. 간편 인증서는 해당 폰 앱 설치·알림 허용 필요 → 폰 승인은 당사자.
- 보안프로그램 페이지 /co/coz/selectSecurityProgrmView.do: 공동인증 보안프로그램·순위확인서 위변조방지·암호화코드 검증(PC)·마크애니(모바일). "브라우저 모두 닫고 설치" 안내. 실제 설치 팝업·순서 미검증.

## 청약 공고 조회 (로그인 불필요)
- 청약일정 및 통계 → 분양정보/경쟁률 → APT = /ai/aia/selectAPTLttotPblancListView.do (2026-09-10 비로그인 200). 화면: "APT 분양정보/경쟁률", 주택조회 폼(시작년도·월, 최대 12개월). 오피스텔 등 /ai/aia/selectOtherLttotPblancListView.do, APT 잔여세대 /ai/aia/selectAPTRemndrLttotPblancListView.do, 청약캘린더 /ai/aib/selectSubscrptCalenderView.do.
- 조회 뒤 공고 목록에서 공고명 클릭 → 상세(공급 유형·접수일·주택형·경쟁률). 상세 화면 구성은 미검증. 여기서 "청약신청" 버튼은 누르지 않는다.

## 청약통장 순위 확인 (로그인 필요)
- 청약자격확인 → 청약통장 → 가입내역 /ap/apd/selectSubscrptBnkbSbscrbDesc.do, 순위확인서 발급 /cu/cud/selectRankCnfrmnIssuView.do, 발급내역 /cu/cue/…(2026-09-10 비로그인 접근 시 로그인 페이지로 대체됨).
- 순서: 메뉴 진입 → 로그인 탭 선택까지 준비 → 👤 인증서 암호 또는 폰 간편인증 → 새 화면에서 로그인 확인 → 가입내역 읽기. 순위확인서 발급은 위변조방지 프로그램·PDF 저장 창이 뜰 수 있다(미검증). 발급은 mode가 발급일 때만.
- 보고: 통장 종류·가입일·납입 회차·인정 금액·순위. 이름·주민번호·계좌번호는 적지 않는다.

## 당첨 조회 (로그인 필요)
- 청약당첨조회 → APT /wa/waa/selectAptPrzwinDescList.do (비로그인 시 로그인 페이지). 오피스텔 등 /wa/wab/selectOfctlUrbtyPrzwinHouseList.do, 공공지원민간임대 /wa/wac/selectPrvateRentPrzwinHouseList.do, 주택조합 동·호수 /wa/wad/selectMxtrHouseDrwtList.do.
- 로그인 없이 보는 청약소통방 → APT당첨사실조회 /wa/waa/selectAptPrzwinCnfrmnList.do 는 별도 조건이 있을 수 있음(미검증). 당첨자 발표일 이후 조회.
- 보고: 단지·당첨/예비 여부·예비번호·계약 일정. 로그인 후 화면의 실제 표 구성은 미검증.

## 가족별 로그인과 재개
- 공통 플레이북 계정 절차. 당사자 인증서만 사용, 가족 세션·승인 물려받지 않음. 사람 차례에는 현재 단계·필요한 행동·완료 판별 화면·복귀 작업을 한 번만 안내한다. 세대원 정보제공 동의 팝업("재당첨 제한 정보제공 관련 세대원의 정보제공동의 안내")은 새 동의이므로 당사자가 처리한다.
- 검증 상태: 공개 페이지 메뉴·URL·로그인 방식 목록만 확인. Windows 실기(보안프로그램 설치, 인증서 로그인, 가입내역·당첨 화면)는 전부 미검증.
