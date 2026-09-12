# Tauri 2 셸 (소비자 표면)

소비자 제품 UI는 **`shell/`의 Tauri 2 + TypeScript**다. Swift / C# / Kotlin은 UI 대체재가 아니라 **OS body**(손쉬운 사용·화면 기록·Keychain/CredMan·미러링).

| 계층 | 코드 | 역할 |
| --- | --- | --- |
| 셸 | `shell/` | 창 + TS UI + `run_path` IPC |
| brain / path | `packages/ppomi-brain`, `packages/ppomi-path` | 경로 선택 · grant · 기록 |
| body | `packages/ppomi-body`, `ppomi-body-*` | OS 한 걸음 |
| Swift `Ppomi/` | `Ppomi/` | 과도기 Mac 호스트 · 기존 AX/MCP. 빅뱅 삭제 금지 |

과거 `shell/`(실행기 플러그인 · `agent/` 번들 · Clerk 딥링크)은 `main`에 없고 병렬 브랜치에만 있다. 이 문서는 그 스택을 되살리지 않는다. 식별자 `com.ppomi.shell`과 아이콘만 재사용한다.

## Mac 설치 · 빌드 · 실행

Apple 실리콘 Mac, macOS 26, Node 22.6+, Rust 1.77+, Xcode.

```sh
npm --prefix shell ci
npm --prefix shell test
npm --prefix shell run dev
```

창에서 intent `다음` → **실행**. IPC `run_path`가 Node `shell/src/host.ts`를 띄우고 `ppomi-brain`이 `path-home-next`를 고른 뒤 `ppomi-body-macos` fixture가 `Next`를 클릭한다.

릴리스 스모크: `npm --prefix shell run build`. 패키지 앱도 TS 호스트를 위해 `node`(또는 `PPOMI_NODE`)가 PATH에 있어야 한다. 스토어 배포 번들은 후속.

기존 Swift 앱 스모크(`scripts/make-app.sh`, `/Applications/뽀미.app`)는 그대로 둔다.

## Live Mac body

기본은 fixture(단위). 실기기 AX:

```sh
PPOMI_BODY_LIVE=1 npm --prefix shell run host -- --intent 다음 --body macos --live
```

창의 **live** 체크와 같다. Safari(또는 `PPOMI_MAC_BROWSER=chrome`)로 example.com을 열고 "More information"만 클릭한다. 손쉬운 사용이 없거나 Mac이 아니면 skip(실패 아님). 예제는 `packages/ppomi-body-macos/example`.

## Windows / Android 호출 자리

같은 `run_path` / `host.ts --body windows|android`가 각 fixture 1-step을 돌린다. Live UIA · UIAutomator는 기존 패키지 예제(MZZ-55b / MZZ-55c):

```sh
PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-windows/example/src/main.ts
PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-android/example/src/main.ts
```

## 비범위

KB 풀 E2E, vault, Clerk 이전, Swift `Ppomi/` 삭제, `adapter-*` 제품 표면 부활.
