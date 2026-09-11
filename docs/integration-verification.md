# 브랜치 통합 검증 — 2026-09-11

`codex/family-updates`의 가족 업데이트·웹 홈·프로필 잠금·공통 화면 작업에,
별도 Tauri 작업의 macOS/Android/Windows 실행기를 통합한 체크포인트다.
main 병합이나 새 배포를 뜻하지 않는다.

## 통합 내용

- 기존 WebView의 서명된 업데이트 검증·준비 확인·복구를 유지한다. Tauri는 번들 화면을 사용한다.
- 공통 `ChatPanel`과 `Workbench`에 상단 바·대화·콘텐츠를 연결한다. 넓은 화면은 왼쪽 콘텐츠와 오른쪽 대화, 좁은 화면은 대화와 명시적으로 여는 콘텐츠 시트다.
- macOS 실행기는 기존 Google 세션, 잠긴 프로필, 이미지 요청과 도구 구현을 재사용한다.
- Android 실행기는 기존 대화 수명·업데이트와 호스트 소유권 보호를 함께 사용한다.
- macOS/Android에 포함하는 JS·CSS와 Tauri 웹 번들을 최종 공통 소스에서 다시 생성했다. 플레이북은 현재 Catalog의 22개 항목에서 생성했다.

## 이 체크포인트에서 실행한 검증

| 검증 | 결과 |
| --- | --- |
| `agent` 정식 `build`·`build:shell` | TypeScript 검사와 두 번들 생성 성공 |
| TypeScript·서버 테스트 | 80개 중 79개 통과, 아래 기존 문구 단언 1개 실패 |
| 플레이북 생성 검사 / 브라우저 종료 회귀 | 각각 4개 / 2개 통과 |
| Storybook 실제 ChatPanel 통합 경로 | 프레임 1개와 세 영역, 704→360→1100→360 크기 전환, 시트 탐색·Escape, 초안 유지·합성 대화 2회 확인. 콘솔 오류 없음 |
| `Ppomi` 전체 `swift test` | 빌드 성공. 549개 실행, 11개 건너뜀, 3개 테스트에서 실패 8건 |
| Rust `cargo test --offline --manifest-path shell/src-tauri/Cargo.toml --lib` | 11개 통과 |
| Windows 합성 정책·프록시 | 72개 통과 |
| Android Kotlin·Java·계측 테스트 소스 컴파일 | 성공 |
| Android 오프라인 프로토콜 | 브리지 20·도구 오류 52·보호 정책 67·소유권 14개 및 가족 업데이트 검증 통과 |
| Hub `node --test` | 120개 통과 |
| 가족 업데이트 스크립트 검사 | 11개 통과 |

## 남아 있는 실패

테스트 실패를 별도 요청 없이 수정하지 않는 저장소 지침에 따라 다음은 그대로 남겼다.

- `agent/src/native-tools.test.ts`: 연결되지 않은 상태의 안내가 `계정·기기 연결을 확인해 주세요.`로 변경됐지만 기존 테스트는 `설정에서 서버 주소`를 기대한다.
- `EvidenceDefaultDayTests.testShowEvidenceFallsBackToNewestDay`: 로컬 `data/ledger.db`를 열지 못한다.
- `LedgerTests.testAugustLineCount`: 실제 장부가 없어 발생한 `XCTSkip`이 `XCTAssertEqual` 안에서 실패로 처리된다.
- `PhoneProfileFormFillerTests.testLiveCaptureGeometryIfPresent`: 로컬 캡처의 입력 칸을 판별하지 못해 실패 6건이 기록된다.

현재 브랜치에서 Android 기기 설치·계측 실행, 실제 OAuth·음성·OS 앱 제어,
Windows 전체 Tauri 패키지 실행은 다시 검증하지 않았다. 테스트용 공개 픽스처와
배포용 폰트·아이콘·WASM은 포함하지만 개인 기록, 서명 비밀키, 빌드 캐시와 로그는 제외한다.
