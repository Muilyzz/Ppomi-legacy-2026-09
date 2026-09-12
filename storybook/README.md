# storybook

`npm run storybook` — 작업대·분개·증거·절차·시크릿 트리·상태.

코드 보기: 스토리를 연 뒤 하단 패널 **Code** 탭.

블록 스토리(분개·증거·시크릿·상태·값 종류 등)는 컴포넌트 루트에 `outline: 1px dotted red`로 실제 경계를 표시하고, 패딩이 있으면 그 바깥에만 둔다. 대화 셸·작업대는 면 자체가 캔버스라 `parameters.componentOutline: false`.

상태 큰 면(유휴 / 시크릿 잠김 / 시크릿 열림): http://localhost:6006 → 사이드바 **상태**. 툴바 **스타일 = 뽀미 테마**.

- http://localhost:6006/?path=/story/상태--idle — 기기·연결 요약 + 시크릿 자리
- http://localhost:6006/?path=/story/상태--locked — 같은 면, 트리 마스킹·접힘
- http://localhost:6006/?path=/story/상태--unlocked — 같은 면, 원문 트리

앱 「상태·비밀」 wire는 [MZZ-54](https://linear.app/muilyzz/issue/MZZ-54). 이 모듈은 Storybook만.

시크릿 트리(잠김 마스킹 / 열림 원문)는 UI만. Ppomi.app wire는 [MZZ-44](https://linear.app/muilyzz/issue/MZZ-44) 앱 셸 이후.

- 잠김에서 뒷 4자리(`****뒷4`)가 보이는 잎은 **키가 계좌 키 허용 목록에 있는 것만**이다(`accountKeys`, 기본 `account`·`accountNumber`·`accountNo`·`acct`·`계좌`·`계좌번호`; 마지막 경로 토큰을 대소문자·공백·`_-` 무시로 비교, `ppomi/kb/account` → `account`). 값이 숫자로 보인다는 것은 근거가 아니다: OTP·PIN·전화·주민·사업자 모양의 숫자, 숫자 잎, `accountName` 은 전부 `••••`로 가리고 상단 칩에도 올리지 않는다.
- 「인증하고 열기」는 스토리북의 step-up 흉내(Face ID 없음)이고, 복사는 `onCopy` 스텁만 부른다(클립보드 없음). 스토리의 액션 패널에는 원문 대신 잠김 표기만 기록된다.
- 트리 깊이는 32에서 `…`로 자른다. 테스트: `cd storybook && node --test secrets.test.mjs`.
