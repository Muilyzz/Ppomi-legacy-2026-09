# Tauri 2 셸 (소비자 표면)

소비자 제품 UI는 **`shell/`의 Tauri 2 + TypeScript**다. Swift / C# / Kotlin은 UI 대체재가 아니라 **OS body**(손쉬운 사용·화면 기록·Keychain/CredMan·미러링).

| 계층 | 코드 | 역할 |
| --- | --- | --- |
| 셸 | `shell/` | 창 + **agent 대화 셸**(Vite) + `run_path` IPC |
| brain / path | `packages/ppomi-brain`, `packages/ppomi-path` | 경로 선택 · grant · 기록 |
| secrets | `packages/ppomi-secrets` | 계좌 등 로컬 시크릿 (masked evidence) |
| body | `packages/ppomi-body`, `ppomi-body-*` | OS 한 걸음 |
| Swift `Ppomi/` | `Ppomi/` | 과도기 Mac 호스트 · 기존 AX/MCP. 빅뱅 삭제 금지 |

과거 `shell/`(실행기 플러그인 · `agent/` 번들 · Clerk 딥링크)은 `main`에 없고 병렬 브랜치에만 있다. 이 문서는 그 스택을 되살리지 않는다. 아이콘만 재사용한다. 번들 id는 제품과 같은 **`com.muilyzz.ppomi`**.

## Mac 설치 · 빌드 · 실행

Apple 실리콘 Mac, macOS 26, Node 22.6+, Rust 1.85+, Xcode.

UI 배선만:

```sh
npm --prefix agent ci          # 대화 셸(React / AI Elements) 의존
npm --prefix shell ci
npm --prefix shell test
npm --prefix shell run dev
```

**셸 UI = agent 웹 UI를 Tauri에 올린 것.** 창은 `agent/src/ui/shell.tsx`(Storybook 「대화 셸」과 같은 뼈대)다. placeholder는 동사 힌트(`시킬 일을 적어 주세요`). 보내기는 설정된 경우 Vercel AI Gateway Responses 루프(`AI_GATEWAY_API_KEY`, 키는 웹뷰에 없음)를 타고, 모델이 `run_path` 툴을 호출하면 기존 스파인(`host.ts` → brain → body / secrets)을 재사용한다. ToolCard의 `via: "gateway"`는 **모델 function_call**이다. 키/픽스처가 없으면 예전 로컬 매처로 조용히 폴백한다.

입력 `다음` → 보내기. IPC `run_path`가 Node `shell/src/host.ts`를 띄우고 `ppomi-brain`이 `path-home-next`를 고른 뒤 `ppomi-body-macos` fixture가 `Next`를 클릭한다. `내 사업자 KB계좌번호 알아?`는 `path-secrets-account` → `ppomi-secrets` get(`ppomi/kb-star-biz/account`). 말풍선은 마스킹/`****last4`만 (원문 금지). 기본은 fixture. 경로 결과는 말풍선 + 도구 카드로 보이고, `path_not_found`도 JSON(종료 0)이다.

**CEO: Gateway vs 로컬 매처.** `KB스타비즈에 넣어둔 번호 마지막만 보여줘` 는 로컬 regex에 안 걸린다. 키 없음 → `path_not_found`. `AI_GATEWAY_API_KEY` 또는 `PPOMI_CHAT=fixture` / `?chat=fixture` → 모델이 `run_path`(`사업자 계좌번호`)를 호출하고 ToolCard + `****7890`.

**Chat UX lock (CEO + 리서처).** 입력창 위에 IA 머리글(절차 · 기억 · 할 일)과 빈 화면 제안 칩(플레이북 찾기 등)을 두지 않는다. 인사 말풍선도 없다. 빈 화면은 진짜 셸 크롬 안의 입력창만. HITL/진행 중일 때만 입력창 안·바로 아래 칩 하나 — 지금은 만들지 않는다.

소비자 앱·권한 스모크는 **설치 경로 하나**: `/Applications/뽀미.app`. `tauri dev` / `target/` / `dist/` 번들에 손쉬운 사용을 주지 않는다.

```sh
# 매번 같은 Apple Development 이름 (Swift make-app.sh 와 동일)
LOCAL_SIGN_ID="Apple Development: …" scripts/install-shell.sh
open /Applications/뽀미.app
```

스크립트는 실행 중인 뽀미를 먼저 종료하고, 그 경로만 덮어쓴다. 설치 경로는 절대 `*.app`이어야 하고(`PPOMI_APP`/`PPOMI_ROOT`는 `--hygiene`/`--check` 테스트 모드에서만 읽는다), `*-prev.app`·`뽀미*.app` 형제나 `dist/backup/`이 있으면 거부하며, 빌드 사본(`shell/src-tauri/target/…/bundle/macos/*.app`)은 복사 뒤 지운다. 권한 목록의 「previous」는 그런 백업 경로/이름과 섞인 바이너리 때문에 Launch Services/TCC가 옛 사본을 따로 집은 것이다. 일상 설치에 `tccutil reset`을 쓰지 않는다. Swift `dist/Ppomi.app`도 같은 번들 id라 경고만 낸다 — 형제로 실행하지 않는다.

애드혹 서명은 패키징 확인용이다. 권한 스모크에 쓰지 않는다. 배포 공증은 `SIGN_ID` / `NOTARY_PROFILE`(후속). `Info.plist`의 `NSAppleEventsUsageDescription`은 live 경로(AppleScript·System Events)의 자동화 권한 프롬프트에 필요하다.

패키지 앱도 TS 호스트를 위해 `node`(또는 `PPOMI_NODE`)가 필요하다. Finder/Dock에서 연 앱의 PATH는 `/usr/bin:/bin:/usr/sbin:/sbin`뿐이라 Homebrew·nvm의 node가 보이지 않는다: `launchctl setenv PPOMI_NODE "$(command -v node)"` 뒤 앱을 다시 열면 된다(로그아웃까지 유지). 실패하면 창에 `host_spawn: node host failed to start (<경로>)`가 그대로 뜬다. Swift `Ppomi/`는 과도기 body 호스트 — `swift run` 또는 `scripts/make-app.sh`의 `dist/Ppomi.app`이며, `/Applications/뽀미.app`의 형제 백업이 아니다.

미결(오너 결정): `shell/`·`ppomi-shell` 이름은 `ppomi-*` 잠금 목록 밖이고, 「Swift `Ppomi/`는 UI 대체재가 아니다」는 [#61](https://github.com/Muilyzz/Ppomi/pull/61)의 「테스트는 메인 앱에서」와 방향이 갈린다 — 이 문서는 결정하지 않는다.

## Live Mac body

기본은 fixture(단위). 실기기 AX는 **CLI 전용**이고 열쇠가 둘이다 — `--live` 플래그와 환경 `PPOMI_BODY_LIVE=1`:

```sh
PPOMI_BODY_LIVE=1 npm --prefix shell run host -- --intent 다음 --body macos --live
```

플래그만 있으면 거부(종료 1, fixture를 live로 꾸미지 않는다). 변수만 있으면 fixture(다른 프로브용으로 export해 둔 값이 무장시키면 안 된다). `PPOMI_BODY_AX`는 `packages/ppomi-body-macos/example`의 스위치일 뿐 셸을 무장시키지 않는다. 창의 `run_path`는 `live`를 거부하고(`live_refused`), 자식 node 환경으로 `PPOMI_BODY_LIVE`·`PPOMI_BODY_AX`·`PPOMI_BODY`·`PPOMI_SECRETS_LIVE`를 절대 넘기지 않는다(실기기 제어도, 실제 Keychain/CredMan 읽기도 창에서는 무장되지 않는다) — 승인 게이트가 생기기 전까지 창에서 live는 없다.

Safari(또는 `PPOMI_MAC_BROWSER=chrome`)로 example.com을 열고 "More information"만 클릭한다. 멈춤은 `completed`가 아니다: 손쉬운 사용 거부 = `grant_denied`, Mac 아님·Safari/Chrome 없음·링크 없음 = `needs_human`, 도구 오류 = `failed`(드라이버 코드 + URL 리댁션 메시지). `completed`는 `Runtime`이 게이트를 지나 클릭을 끝냈을 때만 나오고, JSON의 `run`(core `RunResult`: `driver`·`code`·`attempt`·`target`)이 그 증거다. 예제는 `packages/ppomi-body-macos/example`.

시크릿 live(Keychain / CredMan)는 fixture가 아니라 OS get. 키가 없으면 빈 값(말풍선: 저장된 계좌 없음). Linux는 skip.

```sh
PPOMI_SECRETS_LIVE=1 npm --prefix shell run host -- --intent '내 사업자 KB계좌번호 알아?' --live
PPOMI_BODY_LIVE=1 npm --prefix shell run host -- --intent '내 사업자 KB계좌번호 알아?' --live
PPOMI_SECRETS_LIVE=1 node --experimental-strip-types packages/ppomi-secrets/example/src/main.ts
```

Mac 창 재설치는 계속 같은 서명:

```sh
LOCAL_SIGN_ID="Apple Development: …" scripts/install-shell.sh
```

## Windows / Android 호출 자리

같은 `run_path` / `host.ts --body windows|android`가 각 fixture 1-step을 돌린다. `--live`를 붙이면 fixture를 돌리지 않고 `failed`(미배선, MZZ-55b / MZZ-55c)로 멈춘다. Live UIA · UIAutomator는 기존 패키지 예제:

```sh
PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-windows/example/src/main.ts
PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-android/example/src/main.ts
```

## TCC / Launch Services

| 고정 | 값 |
| --- | --- |
| 설치 경로 | `/Applications/뽀미.app` |
| 번들 id | `com.muilyzz.ppomi` |
| 로컬 서명 | `LOCAL_SIGN_ID` (매 빌드 같은 Apple Development) |

하지 말 것: 옛 앱을 `뽀미-prev.app`으로 남기기, `dist/backup/`에 실행 가능한 `.app` 두기, 애드혹으로 권한 스모크, 일상 `tccutil reset`. 서명 전환 사고의 일회 복구 기록은 [release-status](release-status.md#개발-서명-전환-후-권한-복구)에만 있다.

## 비범위

KB 풀 E2E, vault, Clerk 이전, Swift `Ppomi/` 삭제, `adapter-*` 제품 표면 부활, Android/Win live 시크릿, AI Elements 재설계.
