# 뽀미 에이전트

대화는 하나다. 음성은 그 안의 통화다: 📞로 걸고, 끊기로 끝내고, 시작·끝 카드와 양쪽 말이 로그에 남는다. 걸려오면 "뽀미가 부릅니다" 띠에서 받는다.

## 데이터 흐름

```text
Mac WKWebView / Android WebView — WebSocket(채팅) / WebRTC(음성) — OpenAI Realtime
           │
           ├─ 네이티브 도구 → 이 기기의 파일/Android 접근성 제어
           └─ 네이티브 Supabase 인증 → Vercel 음성 API → Supabase 기록
```

서버 `https://ppomi-agent.vercel.app`는 매 요청마다 기존 Supabase 기기 인증을 확인한다. 표준 OpenAI 키와 기록 암호화 키는 서버에만 두고, 화면에는 60초 임시 Realtime 키만 전달한다. Android는 Mac이나 ADB 없이 서버와 직접 통신한다. ADB는 개발 설치와 검증에만 사용한다.

SDK/정책와 UI는 TS로 공유한다. 마이크 권한, 안전한 브리지, 파일 작업공간, Android 접근성·foreground service는 네이티브 기능이다. 공통 에이전트 런타임의 Mac 도구는 기기 상태·파일 읽기·쓰기에 더해 2026-09-10부터 Mac MCP의 모든 도구(phone_*·windows_*·profile_*·run_combo·read_playbook·bank_profile_capture 등)를 같은 게이트·승인 경계로 제공한다(bootstrap의 `toolSpecs`·`toolGuide`, 앱 안의 `MCPServer` 인스턴스가 실행하고 승인은 작업대 버튼으로 간다). Android는 화면 읽기·앱 열기·터치·입력·스크롤·홈/뒤로를 제공한다.

## 저장 원칙

- AI가 중요한 결정·선호·할 일·확인된 결과를 골라 `save_memory`로 저장한다. 잡담이나 전사 원문을 자동 저장하지 않는다.
- `user_reported`, `tool_observed`, `ai_inferred`를 구분하고 자동 저장 표시를 붙인다. AI 기록을 금융 관측·장부 입력·소유권 증거로 승격하지 않는다.
- 수정은 이전 ID를 참조하는 새 항목이다. 삭제는 해당 기록과 이전 수정 이력의 암호문을 비우며, 중복 재실행 방지를 위한 불투명 ID·digest·삭제 시각만 남긴다.
- 저장 성공은 서버 응답 이후에만 표시한다. 네트워크 결과가 불명확한 동작은 자동 재실행하지 않는다.
- 대화 원문/오디오/접근성 트리/SDK 문맥을 DB, Web Storage, 파일, 로그에 저장하지 않는다. 종료 시 오디오 트랙·연결·대기 콜백·SDK history 참조를 정리한다. 기존 과거 기록은 이 변경으로 삭제하지 않는다.
- 통화의 입력 전사는 켠다(로그에 양쪽 말을 남기기 위해). SDK tracing은 명시적으로 끈다. 뽀미의 미보관 정책과 API 제공자의 데이터 보존 정책은 별개다.
- 새 기억의 AES-256-GCM 키는 서버가 보유한다. DB에는 암호문이 있지만 서버는 복호화할 수 있으며, 종단 간 암호화라는 뜻은 아니다. 기존 상단 기록 vault와 키를 공유하지 않는다.

Android는 앱이 보이는 상태에서 사용자가 시작한 대화를 유지한다. 채팅은 마이크·알림 권한을 요청하지 않고 specialUse foreground service를 사용하며, 음성은 기존 microphone foreground service를 사용한다. 다른 앱을 전면에 열어도 세션을 보관하며 알림에서 종료할 수 있다. 종료·오디오 포커스 상실·렌더러 종료·앱 종료 시 정리한다. 상시 감청이나 재부팅 후 자동 재시작은 없다.

파일 도구는 각 앱의 `AgentWorkspace` 안 UTF-8 텍스트(128 KiB 이하)만 다룬다. 절대 경로·경로 이동·심볼릭 링크를 거부하며 쓰기 후 재읽기/hash를 확인한다. Android 제어는 앱 허용 범위, 비밀번호·오래된 노드·다른 작업 소유권 검사를 유지한다. 알려진 결제·전송·삭제 라벨은 음성 실행기에서 차단한다. 이것이 임의 화면의 모든 의미를 자동 판별한다는 보장은 아니다.

## Android 앱 제어

0.6.1부터 음성 화면에 실제 접근성 연결 상태와 허용 앱을 표시한다. **제어 앱 선택**에서 사용자가 실행 가능한 앱을 선택하면 기존 설정·홈·테스트 앱 외의 일반 앱도 제어 대상으로 추가할 수 있다. 대화나 작업이 진행 중이면 종료 후 선택한다. 이 설정은 해당 기기에 저장되며 음성 에이전트나 MCP가 스스로 바꿀 수 없다.

`app_list`는 앱 이름/패키지 검색과 허용 여부를 제공한다. `app_open`은 조회한 패키지명 또는 명확한 앱 표시명을 사용한다. 예를 들어 토스를 선택한 뒤 “토스를 열고 현재 화면을 읽어 줘”라고 요청할 수 있다. 앱의 인증 화면이나 접근성 정보 미제공 영역은 별개 제한이며, 이 기능이 다른 앱의 비공개 DB나 보호 화면에 접근 권한을 부여하지 않는다.

접근성 미연결·허용하지 않은 앱·설치되지 않은 앱·변경된 화면·보호 동작은 구분된 실패로 모델에 전달한다. 기기 예외 원문은 전달하지 않는다. 금융·인증·권한 변경 등 보호 동작은 현재 음성 실행기로 승인할 수 없으며 사용자가 직접 처리한다. 화면 읽기와 실제 결과 확인 없이 완료를 주장하지 않는다.

## 개발

```sh
cd agent
npm ci
npm test
npm run build
```

`build`가 네이티브 패키지용 `Web/Agent/`와 `assets/agent/`에 같은 번들을 복사한다. 브라우저 단독 공개 화면에는 기기 브리지가 없으며 실행할 수 없다. 패키지 잠금 파일과 생성된 네이티브 자산을 함께 갱신한다.

Mac 개발 서명 패키징은 저장소 루트의 `scripts/make-app.sh`를 사용한다. 설치된 번들 실행 파일에 `--configure-agent-endpoint https://ppomi-agent.vercel.app`를 전달하고 `--voice`로 화면을 연다. 단축키는 ⌥Space다. Android는 설정으로 복귀할 수 있는 채팅 기본 화면을 사용한다. 개발용 초기 설정은 `android.permission.DUMP`로 보호된 `.DebugProvisioningActivity`에 ADB shell로 전달하며, 일반 실행 화면은 provisioning extra를 무시한다.

[프로토콜](PROTOCOL.md)과 [서버 설정](server/README.md)을 참고한다. `scripts/provision-server.mjs`는 기존 비공개 기기 설정과 `.env`를 읽어 Vercel production secret을 설정하고 새 기록 키를 `.ppomi/agent/server.env`에 권한 600으로 보관한다. 기록 키를 단순 교체하면 기존 기록을 읽을 수 없으므로 보존해야 한다.

`scripts/smoke.mjs`는 실제 인증·저장·다른 기기 조회·중복·삭제를 검사하고 자신이 만든 가상 항목만 삭제한다. `scripts/model-smoke.ts`는 마이크를 열지 않고 실제 Realtime 모델의 도구 호출·음성 응답을 검증한다. SQL 회귀 검사는 가상 작업공간을 트랜잭션 안에서 만들고 롤백한다.

`scripts/control-model-smoke.ts`는 실제 Realtime 모델에 생산용 프롬프트·도구 정의·오류 처리기를 연결하고 합성 기기 응답으로 앱 검색·열기·화면 확인 및 미허용 안내를 검증한다. 실제 기기 제어·마이크·저장 도구·대화 원문 보관은 사용하지 않는다.

## 이번 검증

2026-09-09 기준 공통 TS/서버·브라우저 SDK 검사 17개, Mac 네이티브·번들 화면 관련 검사 22개, 실제 Supabase 롤백 회귀 39개가 통과했다. 마이그레이션 `20260909130000`과 14개 SQL 문장 이력을 함께 적용했다. 실제 배포 API 검사 7개에서 기기 인증·임시 키·저장·폴드 인증을 통한 동일 기록 조회·중복·삭제를 확인했다. 실제 `gpt-realtime-2.1`의 도구 호출 1회·음성 출력·서버 저장도 합성 시나리오로 검증하고 테스트 기록을 삭제했다. 실제 사용자 음성을 녹음한 검사는 아니다.

Android 0.6.0 에뮬레이터에서는 파일/영속 작업 회귀 6개와 음성 실행 검사 2개가 통과했다. 실제 WebRTC 연결(HTTP 201)·합성 오디오·음소거·다른 테스트 앱 뒤에서 연결 유지·종료 시 트랙/peer/audio 요소/foreground service/이전 WebView 정리를 확인했다. 알림 종료와 TaskStore 파일 불변도 검사했다. 실제 폴드의 마이크 수음·접기/펼치기 중 음성 연속성은 이 자동 검사 범위에 포함하지 않는다.

Mac과 연결된 폴드에 0.6.0을 설치하고 production 음성 endpoint를 설정했다. Mac의 실제 번들 화면 렌더링을 확인했다. 폴드는 설치 시 잠긴 상태였으며 마이크·알림 권한은 사용자가 아직 허용하지 않았다. 실기기 음성 수음은 잠금 해제 후 시작 버튼과 Android 권한 허용이 필요하다.

### 0.6.1 앱 제어 수정

같은 날 사용자가 폴드에 설치한 토스를 음성으로 제어하려 했을 때, 접근성은 정상 연결됐으나 초기 테스트용 앱 목록이 토스를 차단하고 있음을 확인했다. 마이크·알림 권한도 이미 허용돼 있었다. 앱 선택·이름 검색·실패 사유 전달을 수정하고 공통 TS/서버·브라우저 검사 22개를 통과했다. 실제 Realtime 모델과 합성 기기 응답을 사용한 두 경우에서 허용된 앱은 상태→검색→열기→화면 확인, 미허용 앱은 조회 후 앱 선택 안내로 진행했다.

Android 추가·강화 검사 8개도 통과했다. 실제 네이티브 선택 UI, 앱 검색/이름 해결, 선택 해제, 설정 입력 보호, 새로 읽은 노드의 정상 클릭과 오래된 ID 거절, 민감한 자식 라벨을 가진 클릭 부모의 차단, 실제 Realtime 연결과 합성 오디오 종료를 포함한다. instrumentation이 재시작한 에뮬레이터에서 접근성 재연결과 테스트 종료 대기를 보강해 검증했으며 실기기 접근성 설정은 변경하지 않았다.

폴드에 0.6.1/code5를 설치한 후 접근성 서비스가 다시 정상 연결됐고 기존 권한·서버 endpoint가 유지됨을 확인했다. APK SHA-256은 `e167af08ebee70eb871f3979c284e996e76234f13af932b2ac3d32d918ec9a2a`다. 0.6.1 검증 당시에는 토스 허용과 실제 화면 읽기가 남아 있었다. 이후 채팅을 통한 실기기 검증은 아래 0.6.2 항목에 기록한다.

### 0.7.1 대화 셸을 AI Elements 로

2026-09-10. 대화 셸(`src/ui/shell.tsx`)을 Vercel **AI Elements**(shadcn/ui + Tailwind v4, radix) 위에 다시 그렸다. 로그는 `Conversation`(바닥 고정 스크롤 use-stick-to-bottom), 말풍선은 `Message` + `MessageResponse`(streamdown 마크다운, 한국어 줄바꿈 플러그인만), 도구는 `Tool` 카드(입력·결과 펼침, 우리말 상태 배지), 입력은 `PromptInput`(자동 높이, Enter 전송·한글 조합 제외, 상태에 따라 보내기/정지), 첫 화면은 `Suggestion` 칩(누르면 바로 전송). 색은 새로 만들지 않는다: `src/index.css` 의 `@theme inline` 이 Tailwind 색 이름을 `tokens.css` 두 색 파생 토큰에 매핑하고, `dark:` 는 `html[data-theme]`·시스템 다크를 tokens 와 같은 규칙으로 따른다. 남은 자체 CSS(`style.css`)는 셸 격자·오류 띠·질문/은행 카드뿐이며 `@layer components` 로 감싸 Tailwind 유틸리티가 이긴다. 컴포넌트 파일은 `src/components/{ai-elements,ui}` 에 우리 소유로 들어왔다(`npx shadcn add https://elements.ai-sdk.dev/api/registry/<name>.json`, `components.json`). 코드 강조(shiki)·수식·mermaid·motion 은 뺐다(번들 2.9 MB). 스토리북은 `.storybook/main.js` 에 Tailwind 플러그인과 `@/` 별칭을 붙여 같은 셸을 본다.

### 0.7 글 대화는 Vercel AI SDK + AI Gateway

2026-09-10. 글 대화(텍스트)는 더 이상 Realtime WebSocket 세션을 쓰지 않는다. 화면은 `@ai-sdk/react`의 `useChat`(상태 submitted/streaming/ready/error, 메시지 parts)이고, 전송은 `src/chat.ts`의 `DirectChatTransport` + `ToolLoopAgent`(`stopWhen: stepCountIs(40)`)다. 모델은 `@ai-sdk/openai`의 Responses 모델을 네이티브 브리지 fetch로 감싼 것이라 페이지는 키를 갖지 않는다: 브리지 `request` → 앱 서버 `/v1/responses` → Vercel AI Gateway(`https://ai-gateway.vercel.sh/v1`, 기본 모델 `openai/gpt-6-astra`, env `AI_TEXT_MODEL`/`AI_GATEWAY_API_KEY`/`AI_GATEWAY_BASE_URL`, 키가 없으면 배포의 `VERCEL_OIDC_TOKEN`). 서버는 model·`stream:false`·`store:false`를 강제한다(프록시가 SSE를 중계할 때까지 `simulateStreamingMiddleware`). 도구는 통화와 같은 `createAgentTools` 정의를 `chatTools`가 AI SDK 도구로 감싸며, 실행 내역·실패 코드는 기존 `ToolProgress`로 표시한다. `/v1/session`의 `mode: text`는 임시 키 없이 `{model}`만 돌려준다. 통화(음성)는 그대로 OpenAI Realtime이다.

### 0.6.2 임시 채팅과 실제 기기 검증

같은 날 기본 화면에 채팅 입력·답변·접을 수 있는 도구 실행 내역을 추가하고 기존 음성을 유지했다. 텍스트는 마이크 없이 Realtime WebSocket을 사용하며 서버에 `mode: text` 임시 키 발급을 배포했다. 종료하면 입력 초안·메시지·도구 상태·SDK history를 비우고 연결을 닫는다. 모드 전환은 이전 네이티브 세션 종료가 끝날 때까지 기다린다.

최종 APK `0.6.2/code6`을 연결된 폴드에 설치했다. ADB로 뽀미의 네이티브 앱 선택 화면에서 토스를 선택하고, 실제 채팅 화면의 “토스를 열고 화면 읽기” 입력과 보내기 버튼을 조작했다. 이후 동작은 뽀미의 실제 모델과 기기 내 접근성 실행기가 수행했다. `device_status → app_list → app_open → screen_read` 네 도구가 모두 성공했고, 실제 토스증권 화면의 메뉴·안내와 일치하는 한국어 답변을 뽀미 채팅에서 확인했다. 송금·거래·인증 입력은 실행하지 않았다. 앱을 연 직후 전환 중인 창을 읽던 문제는 대상 전면 상태가 안정될 때까지 기다리도록 수정했다.

폴드에서 대화 종료를 누른 후 메시지·도구 이력이 사라지고 foreground service도 종료됨을 확인했다. 검증 중 임시 변경한 화면 꺼짐 시간은 원래 30초로 복원했다. Android 에뮬레이터에서는 마이크·알림 권한을 거부한 상태로 실제 채팅 UI를 통해 테스트 앱의 카운터를 정확히 한 번 증가시키고, 화면 재확인·모델 답변·UI 종료·문맥 정리·기존 TaskStore 파일 불변을 확인했다. 공통 TS/서버 31개와 브라우저 SDK 2개, Mac 네이티브/번들 7개 검사가 통과했다. 최종 APK의 Android 연결 검사 4개(텍스트 UI 제어, 합성 음성, 파일·알림 종료, 앱 탐색·보호 정책)와 프로토콜·오류 경계 검사도 통과했다.

최종 APK SHA-256: `c68781da4d6d09069f27d8d79fe77040f444e87a3123c57baf844edd2303785b`. 공통 JS SHA-256: `960f59b1c095168799dbadbe5bdb532fbd861976fa2f5338ec9e9fdf5f04c2b1`. 폴드 검증은 펼친 화면에서 진행했고, 접기/펼치기 중 실시간 세션 연속성은 이번 범위에 포함하지 않았다. 실제 대화 원문 대신 검증 단계와 결과만 로컬 개발 증빙에 기록한다.
