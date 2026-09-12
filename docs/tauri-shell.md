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

**셸 UI = agent 웹 UI를 Tauri에 올린 것.** 창은 `agent/src/ui/shell.tsx`(Storybook 「대화 셸」과 같은 뼈대)다. placeholder는 동사 힌트(`시킬 일을 적어 주세요`). 보내기는 설정된 경우 Vercel AI Gateway Responses 루프(`AI_GATEWAY_API_KEY`, 키는 웹뷰에 없음)를 타고, 모델이 `run_path` 툴을 호출하면 기존 스파인(`host.ts` → brain → body / secrets / `ppomi-path` catalog)을 재사용한다. ToolCard의 `via: "gateway"`는 **모델 function_call**이다. 키/픽스처가 없으면 예전 로컬 매처로 조용히 폴백한다.

입력 `다음` → 보내기. IPC `run_path`가 Node `shell/src/host.ts`를 띄우고 `ppomi-brain`이 `path-home-next`를 고른 뒤 `ppomi-body-macos` fixture가 `Next`를 클릭한다. `내 사업자 KB계좌번호 알아?`는 `path-secrets-account` → `ppomi-secrets` get(`ppomi/kb-star-biz/account`). `KB스타기업뱅킹 열어` / `KB 사업자 홈`은 `ppomi-path` 카탈로그의 `kb-star-biz-iphone`(Home → KB, Face ID HITL). 말풍선은 마스킹/`****last4`만 (원문 금지). 기본은 fixture. 경로 결과는 말풍선 + 도구 카드로 보이고, `path_not_found`도 JSON(종료 0)이다.

**CEO: paraphrase → secrets.** `내 사업자 KB계좌번호 알아?` 와 `KB스타비즈에 넣어둔 번호 마지막만 보여줘` 는 같은 `path-secrets-account` (`****7890`). Gateway/fixture는 `run_path(사업자 계좌번호)` 로 정규화하고, 로컬 매처·카탈로그 alias(`스타비즈` / `넣어둔 번호` / `마지막만`)도 같은 path. `KB스타기업뱅킹 열어` 는 `kb-star-biz-iphone` (MZZ-69/#93). Gateway/`complete()` 실패는 코드가 보이는 `모델 연결에 실패했습니다. 게이트웨이 오류: <code>` 이며 로컬 `run_path`로 숨기지 않는다. `run_path` IPC 실패는 `실행에 실패했습니다.` — `path_not_found` 말풍선으로 숨기지 않는다. `안녕` / `뭐해` / `thanks` / `너 모델 뭐야?` 는 fixture·로컬에서 비서 답(강아지 마스코트는 시각만). 라이브 Gateway는 같은 말을 툴 없이 텍스트로 답해도 된다. `지금 데이터 뭐 있어?` 는 Gateway가 꺼져 있을 때만 진짜 `path_not_found`. 라이브 키는 `~/.ppomi/.env`의 `AI_GATEWAY_API_KEY`(없으면 `$PPOMI_ROOT/shell/.env`). Dock/`open`에 `--env` 불필요. `PPOMI_CHAT=fixture` 일 때만 픽스처. 키는 출력하지 않는다. 입력창 아래 `fixture` / `Gateway` 한 줄.

**Chat UX lock (CEO + 리서처).** 입력창 위에 IA 머리글(절차 · 기억 · 할 일)과 빈 화면 제안 칩(플레이북 찾기 등)을 두지 않는다. 인사 말풍선도 없다. 빈 화면은 진짜 셸 크롬 안의 입력창만. HITL/진행 중일 때만 입력창 안·바로 아래 칩 하나 — 지금은 만들지 않는다.

소비자 앱·권한 스모크는 **설치 경로 하나**: `/Applications/뽀미.app`. `tauri dev` / `target/` / `dist/` 번들에 손쉬운 사용을 주지 않는다.

```sh
# 매번 같은 Apple Development 이름 (Swift make-app.sh 와 동일)
LOCAL_SIGN_ID="Apple Development: …" scripts/install-shell.sh
open /Applications/뽀미.app
```

스크립트는 실행 중인 뽀미를 먼저 종료하고, 그 경로만 덮어쓴다. `*-prev.app`·`dist/backup/` 복사본은 만들지 않으며, 있으면 거부한다. 권한 목록의 「previous」는 그런 백업 경로/이름과 섞인 바이너리 때문에 Launch Services/TCC가 옛 사본을 따로 집은 것이다. 일상 설치에 `tccutil reset`을 쓰지 않는다.

애드혹 서명은 패키징 확인용이다. 권한 스모크에 쓰지 않는다. 배포 공증은 `SIGN_ID` / `NOTARY_PROFILE`(후속).

패키지 앱도 TS 호스트를 위해 `node`(또는 `PPOMI_NODE`)가 PATH에 있어야 한다. Swift `Ppomi/`는 과도기 body 호스트 — `swift run` 또는 `scripts/make-app.sh`의 `dist/Ppomi.app`이며, `/Applications/뽀미.app`의 형제 백업이 아니다.

## 실패는 실패로 (Gateway · IPC)

`run_path` / `ai_gateway`는 node 자식의 stdout·stderr를 파이프로 받고(타임아웃 60 s / 120 s, 넘기면 kill), 마지막 JSON 객체만 결과로 쓴다. 실패는 전부 `{ code, message }` — `run_path_host_failed` / `gateway_host_failed` — 이고 빈 결과나 지어낸 결과는 없다. 창에서는 IPC 실패가 `실행에 실패했습니다.` + `output-error` 카드(`run_path_ipc_failed: <code>`), Gateway 실패가 `모델 연결에 실패했습니다. 게이트웨이 오류: <code>`(`gateway_ipc_failed` · `gateway_host_failed` · `model_unavailable`)로 보인다 — `path_not_found` 말풍선으로 숨기지 않고, 로컬 regex 매처로 조용히 내려가지 않는다. 키도 픽스처도 없을 때만 로컬 매처가 답하고, 그 카드는 `via: "local"`이다(`via: "gateway"`는 모델 function_call만). 브라우저 `previewSpine`은 `vite dev` 또는 `?chat=fixture`에서만 쓰이고 `(미리보기)`로 표시된다; 그 밖에 IPC가 없으면 `run_path_ipc_failed: no_tauri_ipc`. 자식 환경은 허용 목록만 넘긴다(`PATH`·`HOME`·`TMPDIR`·`LANG`/`LC_*`·`PPOMI_CHAT`·`PPOMI_NODE`·`PPOMI_MAC_BROWSER`·`AI_GATEWAY_API_KEY`·`AI_GATEWAY_BASE_URL`·`AI_TEXT_MODEL`); `PPOMI_BODY_LIVE`·`PPOMI_BODY_AX`·`PPOMI_BODY`·`PPOMI_SECRETS_LIVE`·`NODE_*`·`DYLD_*`/`LD_*`는 창에서 절대 자식에 닿지 않는다. 창의 `live` 거부(`live_refused`)는 #79와 함께 온다.

## Live Mac body

기본은 fixture(단위). 실기기 AX:

```sh
PPOMI_BODY_LIVE=1 npm --prefix shell run host -- --intent 다음 --body macos --live
```

Safari(또는 `PPOMI_MAC_BROWSER=chrome`)로 example.com을 열고 "More information"만 클릭한다. 손쉬운 사용이 없거나 Mac이 아니면 skip(실패 아님). 예제는 `packages/ppomi-body-macos/example`.

시크릿 live(Keychain / CredMan)는 fixture가 아니라 OS get. 키가 없으면 빈 값(말풍선: 저장된 계좌 없음). Linux는 skip.

```sh
PPOMI_SECRETS_LIVE=1 npm --prefix shell run host -- --intent '내 사업자 KB계좌번호 알아?' --live
PPOMI_BODY_LIVE=1 npm --prefix shell run host -- --intent '내 사업자 KB계좌번호 알아?' --live
PPOMI_SECRETS_LIVE=1 node --experimental-strip-types packages/ppomi-secrets/example/src/main.ts
```

KB스타기업뱅킹 UI path(카탈로그 SSOT). 기본은 fixture, live는 `PPOMI_BODY_LIVE` + iPhone Mirroring body 훅. Face ID/로그인은 당사자. 계좌 원문은 말풍선/StepResult에 없음.

```sh
npm --prefix shell run host -- --intent 'KB스타기업뱅킹 열어'
PPOMI_BODY_LIVE=1 npm --prefix shell run host -- --intent 'KB스타기업뱅킹 열어' --live
PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-iphone-mirroring/example/src/main.ts
```

Mac 창 재설치는 계속 같은 서명:

```sh
LOCAL_SIGN_ID="Apple Development: …" scripts/install-shell.sh
```

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

KB 풀 E2E, vault, Clerk 이전, Swift `Ppomi/` 삭제, `adapter-*` 제품 표면 부활, Android/Win live 시크릿, AI Elements 재설계.
