# Tauri 2와 OS별 실행기

새 진입점은 `shell/`이다. TypeScript/React 대화 화면, 모델 연결, 도구 정의,
플레이북 탐색은 `agent/`를 재사용한다. Rust는 창·권한·프로세스 수명과 IPC를
담당하고, 실제 OS 기능과 장기 인증정보는 각 OS의 네이티브 실행기가 갖는다.

| 계층 | 구현 | 역할 |
| --- | --- | --- |
| 공통 화면 | React/TypeScript + Tauri 2 | 글·음성 대화, 설정, 사용자 확인 |
| macOS 실행기 | 기존 Swift 프로그램의 `--executor` 모드 | 기존 MCP·기록·저장소·서버 프록시, JSONL |
| Windows 실행기 | .NET 10 C# 콘솔 EXE | Windows UI Automation·파일·서버 프록시, JSONL |
| Android 실행기 | Kotlin `AndroidExecutor` + Tauri 모바일 플러그인 | 기존 접근성·포그라운드 서비스·서버 프록시 |
| 회계 엔진 | 기존 Swift Accounting | macOS 직접 호출, Android 기존 Swift JNI |

Windows 앱은 Windows에서 직접 실행하며 해당 Windows 실행기가 서버에 연결한다.
Parallels는 Windows 개발·시험용 VM으로 쓸 수 있지만 새 macOS 실행기의 미러링
대상이 아니다. 새 macOS 실행기는 `phone_*`, `windows_*`, `android_*`와 이들에
의존하는 복합 도구를 광고하거나 실행하지 않는다. iPhone 제어의 별도 제한은
Tauri 전환으로 해결되지 않는다.

## 실행과 패키징

데스크톱 개발은 대상 OS에서 Node.js, Rust/Tauri 빌드 도구를 준비한다.
macOS에는 Xcode/Swift 및 macOS 26이, Windows에는 MSVC 빌드 도구·WebView2와
.NET 10 SDK가 필요하다. Windows 배포 EXE에는 .NET 런타임을 포함한다.

저장소 루트에서:

```sh
npm --prefix agent ci
npm --prefix shell ci
npm --prefix shell run dev
```

`dev`는 해당 OS 실행기를 먼저 빌드하고 고정 리소스 경로에 배치한 뒤 Tauri를
실행한다. 화면은 개발 중에도 번들 파일을 사용한다. 프런트엔드 코드 변경은
다시 빌드하여 반영한다. 릴리스 패키지는 `npm --prefix shell run build`로 만든다.
서명·공증 및 배포 자격 증명은 별도 릴리스 설정 대상이다.

macOS 실행기는 `resources/executor/ppomi-executor`와 Swift 리소스 번들을,
Windows는 `resources/executor/ppomi-executor.exe`를 패키징한다. OS별 Tauri
설정으로 분리하므로 Android APK에 macOS 실행기가 포함되지 않는다.

Android는 `npm --prefix shell run android:init` 후 JDK/SDK/NDK 환경에서
`npm --prefix shell run android -- build --debug --target aarch64 --apk --ci`를
사용한다. 현재 Swift JNI 타깃에 맞춰 ARM64만 지원한다.
[Android 실행기](android-executor.md), [Windows 실행기](windows-executor.md)에
환경과 검증 범위를 기록했다.

## IPC와 수명

기존 `NativeBridge`의 요청 `{id,method,args}`와 응답 `{id,result}` 또는
`{id,error:{code,message}}`을 유지한다. `agent/src/tauri-host.ts`가 Tauri 호스트를
감지한다. 기존 Swift WKWebView/Android WebView는 기존 브리지를 계속 사용하되
같은 추출 실행기에 위임한다. 이벤트는 이름이 제한된 `{event,payload}` 데이터이며
네이티브가 JavaScript 코드를 보내 실행하는 경로를 추가하지 않는다.

Rust 셸에는 `executor_request`와 UI 관리용 `executor_manage`만 열려 있다.
프로세스 경로·임의 셸 명령·범용 파일시스템 플러그인을 웹뷰에 노출하지 않는다.
사용자 확인 응답, 기기 등록 파일 선택, 앱 허용 변경, 계정 동작(`signIn`·`signOut`·`refreshAccount`)은 모델 도구가 아니다.
확인 응답은 실행기의 현재 질문 ID/선택지와 일치해야 한다.

데스크톱의 `signIn`은 실행기의 `beginSignIn`이 돌려준 Supabase 구글 authorize 주소(프로젝트 호스트의 HTTPS
`/auth/v1/authorize`만)를 tauri-plugin-opener로 **시스템 브라우저**에 열고, 브라우저가 돌려보내는
`ppomi://auth?code=…` 딥 링크(tauri-plugin-deep-link, 두 번째 인스턴스는 tauri-plugin-single-instance가
실행 중인 창으로 넘긴다)를 실행기의 `completeSignIn`에 전달한다. 웹뷰는 주소·코드·토큰을 보지 못한다.
Windows 번들만 `ppomi` 스킴을 등록한다(`tauri.windows.conf.json`); macOS 는 Swift 계정 창이 스스로 로그인한다.

일반 사용자에게 서버 주소를 입력받지 않는다. 기존 제품의
`PpomiServer.agentEndpoint`와 같은 기본 서비스 주소를 실행기에 둔다.
`setEndpoint`는 Tauri IPC에서 허용하지 않으며 주소 재정의는 개발 경로에만 남는다.
macOS 인증은 기존 Google PKCE·키체인 세션·기기 등록 구현을 재사용한다.
장기 토큰은 프런트엔드에 전달하지 않고, 로그인 표시는 실제 계정 상태로 정한다.

데스크톱은 셸이 소유한 stdin/stdout 파이프로 고정 실행기를 시작한다.
실행기 종료·잘못된 프로토콜·창 종료 시 대기 요청을 실패 처리하고 세션을 끝낸다.
페이지 재로드도 기존 세션을 중지한다. 시간 초과한 쓰기를 자동 재전송하지 않는다.
Windows의 대상 앱 허용은 프로세스 수명에 묶여 있으므로 재시작 후 다시 선택한다.

번들 페이지에만 IPC를 허용하고 외부 탐색·새 창·iframe을 막는다.
마이크는 네이티브가 승인한 활성 음성 세션과 신뢰된 로컬 페이지에서만 허용한다.
macOS는 main frame·마이크 전용 요청을 확인하고 종료 시 기존 capture도 해제한다.
Windows는 WebView2 권한을 프로필에 저장하지 않으며 동일 출처·음성 세션을 확인한다.
Android는 기존 OS 마이크 권한·활성 세션·현재 페이지 출처를 함께 확인한다.
카메라 권한은 부여하지 않는다. 기존 프런트엔드의 종료 시 MediaStream 정리도 유지한다.

## 화면 및 호환 범위

`ExecutorPanel`은 `topBar`, `contentPane`, `contentLabel` 슬롯을 공급한다.
상단 왼쪽은 기록, 오른쪽은 계정과 설정이다. 로그인 전에는 `로그인`, 로그인 후에는
`나`를 표시하고 톱니 아이콘으로 권한 설정을 연다. 계정과 설정을 같은 시트에
섞지 않는다. OS 제목과 중복되는 앱 이름·플랫폼 표시는 넣지 않는다.
네이티브 질문은 콘텐츠 슬롯, 대화는 기존 공통 컴포넌트에 둔다.
`ChatPanel`은 `ChatHost`를 통해 브리지에 연결하고, `Shell`의 프레임 어댑터는
하나의 `Workbench`에 상단 바·대화·콘텐츠를 배치한다. 600px 이상에서는 콘텐츠가
왼쪽·대화가 오른쪽이며, 콘텐츠가 없으면 대화가 전체 공간을 쓴다. 600px 미만에서는
대화가 기본 화면이고 콘텐츠는 상단 버튼으로 여는 시트에 표시한다. 크기 변경이나
시트 탐색으로 대화 컴포넌트·컨트롤러·입력 초안을 다시 만들지 않는다.

이번 전환에서 기존 모든 네이티브 화면을 TypeScript로 다시 만들지는 않았다.
macOS의 기록 버튼은 기존 기록 창을, `로그인`/`나`는 별도 네이티브 계정 시트를 연다.
계정 시트는 Google 로그인과 `IdentityVault`의 잠긴 프로필을 포함한 기존 `MeSheet`를
재사용한다. Android 기록과 권한·앱 선택도 각각
기존 네이티브 화면을 연다. Windows에는 아직 기록/회계 화면과 은행 입력 기능이
없으며, UIA로 노출되는 허용 앱의 화면 읽기와 제한된 조작을 지원한다.
기존 macOS 작업대와 standalone Android 앱도 호환 진입점으로 남아 있다.

Android Tauri 앱은 기존 APK와 다른 앱 ID를 사용한다. 기존 데이터·키·권한을
자동 이전하지 않으며 새 설치에서 기기를 등록해야 한다. 기존 release 빌드의
접근성 자동제어 차단 정책도 유지한다. 삼성 팝업 화면에 의존하는 기존 UI는
공통 Tauri 채팅의 필수 경로가 아니지만, 기기별 백그라운드 음성·IME·권한 동작의
실기기 검증과 출시 정책 검토는 별도로 필요하다.

Windows는 Mac·iPad와 같은 Google 로그인(Supabase PKCE)으로 기기를 등록하고, 소유자가
Mac의 나 › 기기 승인에서 승인해야 `configured`가 된다([Windows 실행기](windows-executor.md)).
Windows의 `로그인`/`나`는 앱 안의 계정 시트(로그인 전 · Mac 승인 대기 · 기기 등록됨)를 열고,
설정 시트에는 `제어할 앱`만 남는다(개발용 기기 파일 등록은 `PPOMI_DEVELOPER_DEVICE_IMPORT=1`일 때만).
Android에는 Google 로그인 구현이 아직 없다. 로그인 버튼이나 로그인 완료 상태를 가장하지 않는다.
Android는 debug 전용 provisioning 경로로 시험하며, 소비자용 계정 연결은 후속 이식 범위다.
macOS 계정 시트에서 돌아와도 공통 대화 문서와 입력 초안은 유지하며 bootstrap만
새로 읽어 로그인 상태를 갱신한다.
활성 대화에서는 계정 창을 열 수 없고, 계정 창이 열려 있는 동안에는 새 대화를
시작할 수 없다. 실행기를 종료하면 그 실행기가 연 계정 창도 종료한다.

기존 네이티브 WebView는 서명된 가족 웹 업데이트의 시험 로드·준비 확인·복구 경로를
유지한다. Tauri는 패키지에 포함한 번들을 사용하고 가족 업데이트 메타데이터를
광고하지 않으므로 같은 준비 확인 호출을 요구하지 않는다. Tauri에 동적 웹 업데이트를
도입한 것은 아니다.

## 검증

```sh
npm --prefix agent run build:shell
npm --prefix agent test
npm --prefix shell test
dotnet run --project executors/windows/PolicyTests/Ppomi.Executor.PolicyTests.csproj
```

제한된 환경에서 `tsx` CLI의 임시 IPC 소켓 생성이 막히면 같은 TypeScript 테스트를
`agent/`에서 `node --import tsx --test src/*.test.ts server/*.test.ts`로 실행하고,
`node --test scripts/*.test.mjs`, `npm run test:browser`를 각각 실행할 수 있다.
빌드 성공은 실제 OS 앱 제어·음성 통화나 스토어 출시 검증을 대신하지 않는다.
음성 모델과 과금 경로는 이번 변경에서 바꾸지 않았다.

### Tauri 작업에서 확인한 결과 (통합 전, 2026-09-11)

| 확인 | 결과 |
| --- | --- |
| 공통 UI TypeScript 검사 및 Tauri/기존 WebView 번들 | 성공 |
| 로그인 전/후 상단 바 렌더링 | 로그인·나·설정 구분, 서버 폼 없음 확인 |
| 실제 macOS Tauri 초기화 | Swift 실행기 연결, 기록·나·설정 표시 확인 |
| Swift 실행기·계정·수명 집중 테스트 | 34개 통과 |
| Rust IPC·종료·미디어 정책 | 11개 통과 |
| Windows 합성 정책·프록시 | 72개 통과, 자체 포함 win-x64 EXE 생성 |
| Android 정책·호스트 수명 | 기존 정책 및 새 수명 검사 14개 통과 |
| macOS 앱 번들·Tauri/standalone Android APK | 생성 성공 |
| 공통 TypeScript/서버 테스트 | 62개 중 61개 통과. 나머지는 삭제한 `설정에서 서버 주소` 문구를 기대하는 기존 단언이며 테스트를 변경하지 않음 |
| 별도 브라우저 종료 회귀·플레이북 생성 검사 | 각 2개·4개 통과 |

기존 `AgentVoiceWebTests`는 제한된 WebKit 환경의 sandbox 오류와 로딩 시간 초과가
발생했다. 당시 Android 계측 테스트 빌드의 Java 문자열 문법 오류는 별도 작업의
수정본과 통합한 뒤 재컴파일에 성공했다. 현재 브랜치 통합 검증은
[통합 검증 기록](integration-verification.md)을 따른다.
Windows 전체 Tauri 패키지의 링크·실행, Windows UIA/DPAPI의 실제
동작, Android 실기기·실제 OAuth/음성 통화는 검증하지 않았다.
