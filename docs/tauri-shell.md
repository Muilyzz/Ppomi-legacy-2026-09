# Tauri 2 셸 (소비자 표면)

소비자 제품 UI는 **`shell/`의 Tauri 2 + TypeScript**다. Swift / C# / Kotlin은 UI 대체재가 아니라 **OS body**(손쉬운 사용·화면 기록·Keychain/CredMan·미러링).

| 계층 | 코드 | 역할 |
| --- | --- | --- |
| 셸 | `shell/` | 창 + TS UI + `run_path` IPC |
| brain / path | `packages/ppomi-brain`, `packages/ppomi-path` | 경로 선택 · grant · 기록 |
| body | `packages/ppomi-body`, `ppomi-body-*` | OS 한 걸음 |
| Swift `Ppomi/` | `Ppomi/` | 과도기 Mac 호스트 · 기존 AX/MCP. 빅뱅 삭제 금지 |

과거 `shell/`(실행기 플러그인 · `agent/` 번들 · Clerk 딥링크)은 `main`에 없고 병렬 브랜치에만 있다. 이 문서는 그 스택을 되살리지 않는다. 아이콘만 재사용한다. 번들 id는 제품과 같은 **`com.muilyzz.ppomi`**.

## Mac 설치 · 빌드 · 실행

Apple 실리콘 Mac, macOS 26, Node 22.6+, Rust 1.85+, Xcode.

UI 배선만:

```sh
npm --prefix shell ci
npm --prefix shell test
npm --prefix shell run dev
```

창은 빈 메시지 칸 + 입력만. placeholder는 동사 힌트(`시킬 일을 적어 주세요`). 입력 `다음` → 보내기. IPC `run_path`가 Node `shell/src/host.ts`를 띄우고 `ppomi-brain`이 `path-home-next`를 고른 뒤 `ppomi-body-macos` fixture가 `Next`를 클릭한다.

**Chat UX lock (CEO + 리서처).** 입력창 위에 IA 머리글(절차 · 기억 · 할 일)과 빈 화면 제안 칩(플레이북 찾기 등)을 두지 않는다. 인사 말풍선도 없다. HITL/진행 중일 때만 입력창 안·바로 아래 칩 하나 — 지금은 만들지 않는다.

소비자 앱·권한 스모크는 **설치 경로 하나**: `/Applications/뽀미.app`. `tauri dev` / `target/` / `dist/` 번들에 손쉬운 사용을 주지 않는다.

```sh
# 매번 같은 Apple Development 이름 (Swift make-app.sh 와 동일)
LOCAL_SIGN_ID="Apple Development: …" scripts/install-shell.sh
open /Applications/뽀미.app
```

스크립트는 실행 중인 뽀미를 먼저 종료하고, 그 경로만 덮어쓴다. `*-prev.app`·`dist/backup/` 복사본은 만들지 않으며, 있으면 거부한다. 권한 목록의 「previous」는 그런 백업 경로/이름과 섞인 바이너리 때문에 Launch Services/TCC가 옛 사본을 따로 집은 것이다. 일상 설치에 `tccutil reset`을 쓰지 않는다.

애드혹 서명은 패키징 확인용이다. 권한 스모크에 쓰지 않는다. 배포 공증은 `SIGN_ID` / `NOTARY_PROFILE`(후속).

패키지 앱도 TS 호스트를 위해 `node`(또는 `PPOMI_NODE`)가 PATH에 있어야 한다. Swift `Ppomi/`는 과도기 body 호스트 — `swift run` 또는 `scripts/make-app.sh`의 `dist/Ppomi.app`이며, `/Applications/뽀미.app`의 형제 백업이 아니다.

## Live Mac body

기본은 fixture(단위). 실기기 AX:

```sh
PPOMI_BODY_LIVE=1 npm --prefix shell run host -- --intent 다음 --body macos --live
```

Safari(또는 `PPOMI_MAC_BROWSER=chrome`)로 example.com을 열고 "More information"만 클릭한다. 손쉬운 사용이 없거나 Mac이 아니면 skip(실패 아님). 예제는 `packages/ppomi-body-macos/example`.

## Windows / Android 호출 자리

같은 `run_path` / `host.ts --body windows|android`가 각 fixture 1-step을 돌린다. Live UIA · UIAutomator는 기존 패키지 예제(MZZ-55b / MZZ-55c):

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

KB 풀 E2E, vault, Clerk 이전, Swift `Ppomi/` 삭제, `adapter-*` 제품 표면 부활.
