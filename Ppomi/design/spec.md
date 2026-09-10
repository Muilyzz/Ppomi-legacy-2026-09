# 뽀미 작업대 이전 사양 — 검은 계기판(instrument) + 이식

> 이 문서는 이전 링·네 패널 키오스크 설계를 보존한 기록이다. 2026-09-06 창 구조는 미러링 바로 뒤의 단일 `MainPanel`로 바뀌었다. 현재 배치·전환·승인 영역은 [디자인 작업 컨텍스트](context.md#앱이-무엇인가)를 따른다. 아래의 `RingContent`·`BandPanel`·Esc 종료·폰 아래 캡션·채팅 탭 설명을 현재 구현 지침으로 사용하지 않는다.

승자 「검은 계기판」을 뼈대로, 심사위원 셋이 합의한 이식 다섯을 합쳤다: ① Tools.gate() 동의 게이트 복원(문구·버튼만 교체) ② Deep Chat 높이는 root cause대로 host `height:100%` + body grid ③ AI 말은 검은 시트 위 산문, 사용자 말만 회색 카드 ④ 림은 색+굵기(.agent 2pt 금, 그 외 1pt) ⑤ 키오스크 rimSpan에 화면 원점 보정, ask 시 reveal은 키오스크 밖에서만, 캡션 truncation, WebPage 흰 번쩍임 1줄. 여백은 참고 쪽(16/20, 섹션 32)으로 넓힌다. 콤보 전체 진행 띠와 미관측 금색 예외는 채택하지 않는다(§7).

## 0. 목표

폰이 주인공, 왼쪽 작업대는 계기다. 링과 페이지를 같은 검정(#000)으로 한 몸으로 만들고 색은 상태 3색만 남긴다 — 금(뽀미가 폰을 잡고 있다) · 흰(당신 차례: 링 테두리와 [승인] 하나) · 회(대기). 그 밖의 모든 것(탭·칩·배지·차트·표·사용자 말풍선·미관측 숫자)은 무채 램프 5단이다. 상태(폰 연결·진행·승인)는 폰 바로 아래 띠의 캡션 한 줄과 구멍 둘레 테두리가 말하고, 작업대는 제목·안내문을 버리고 '11px 라벨 + 헤어라인' 섹션으로 참고 디자인의 스캔 가능성을 옮긴다. 밤 흐름의 첫 동작(한 줄 입력)이 창을 열면 바로 있고, 유일한 결정([승인])은 입력창 아래 고정 띠에 있어 스크롤되지 않으며, 폰 조작의 유일한 권한 게이트(동의)는 코드에 남는다.

## 1. 토큰

색 (theme.css `:root`, AppKit은 같은 값을 하드코딩)

| 토큰 | 값 | 뜻 · 쓰는 곳 |
|---|---|---|
| `--bg` | `#000` | 페이지 = 링 = 미러링 창 여백. 유일한 바탕 |
| `--card` | `#131313` | 카드 · 입력창 · `<pre>` · 절차 카드 |
| `--pick` | `rgba(255,255,255,.08)` | 선택·호버·사용자 말풍선·차트 선택 칸 |
| `--line` | `rgba(255,255,255,.10)` | 헤어라인 하나(섹션·표·탭 줄 밑·상태 띠 위·칩) |
| `--line2` | `rgba(255,255,255,.25)` | 컨트롤 테두리(알약·dashed 칩·입력 포커스) |
| `--fg` | `#e6e6e3` | 본문 · 활성 탭 · 차트 선 |
| `--meta` | `#8a8a86` | 라벨·메타·비활성 탭·구분자·축 (4.9:1) |
| `--go` | `#c7a300` | **진행**: 뽀미가 폰을 잡고 있다. 림(2pt)만. 웹 페이지에서는 쓸 곳이 없다 |
| `--turn` | `#e6e6e3` | **승인**: 사람 차례. 림(1pt α.9)과 [승인] 흰 채움 하나 |
| `--wait` | `rgba(255,255,255,.25)` | **대기**: 림 1pt |
| `--bad` | `#d33` | 유일한 예외: 증빙 종이 위 '파서가 놓친 금액 행' 상자 1px(데이터 오류, UI 색 아님) |

크기·간격·모서리·테두리

| 항목 | 값 |
|---|---|
| 글자 | 24 disp(모노) / 15 key / 13 body / 12 lbl·탭·칩·알약·표 / 11 meta·섹션·축. 행간 1.5(표 16px 고정) |
| AppKit 글자 | 폰 캡션 12pt 흰 α.7 · 키오스크 나가기 힌트 11pt 흰 α.55 · DockView 안내 13pt α.5 |
| 굵기 | 400 / 500(라벨·숫자·앱명) / 600(강조·[승인]). 활성 탭은 굵기 변화 없음 |
| 본문 폭 | body max-width 640, 좌측 정렬, padding 16 20 24. 창(596→556)·키오스크(618→578) 같은 줄 길이 |
| 8px 그리드 | 단락 12 · 블록 16 · 섹션 위 32 아래 8(첫 섹션 0) · 표 행 24 · 카드 12 16 · 칩 2 8 · 알약 높이 26 |
| 모서리 | 6(컨트롤) / 8(카드) / 0(증빙 종이 열) |
| 테두리 | 헤어라인 1px `--line`. 림: .agent 2pt 금 α1 / .humanTurn 1pt 흰 α.9 / 그 외 1pt 흰 α.25 |
| 띠(창 모드) | rimTop = rimBottom = rimRight = 32pt (44/32/28 → 하나). 왼쪽 620(작업대 596), 작업대 inset 12 |
| 탭 줄 | padding 20/8 → 높이 32. 아래 헤어라인 폭 전체 |
| 상태 띠(대화) | 높이 36, padding 0 20, 위 헤어라인 |
| 나가기 ×(키오스크) | 히트 48×48 우상단 모서리 밀착, 원은 inset 10(보이는 지름 28), 힌트는 × 왼쪽 8pt |

## 2. 타이포

시스템 산세리프 한 벌(`-apple-system`, `'Apple SD Gothic Neo'`) + 숫자 모노(`ui-monospace`/`SF Mono`/Menlo). 외부 폰트 없음. 세리프 디스플레이는 채택하지 않는다(한글 없음, 계기판 방향과 다름).

1. `.disp` 24px/1.2 모노 500 tabular — 페이지당 1개, 타임라인 '끝 순자산'의 숫자만. '원'은 옆에 `.meta`로 분리(모노↔시스템 폴백이 한 단어에 섞이지 않게).
2. `.key` 15px 500 tabular — 방정식 3개(관측/설명/미관측). 미관측 ≠ 0 이면 `.strong`(600)만 더한다 — 색은 안 더한다.
3. 본문 13px/1.5 — 4페이지 공통(evidence 14, chat 13/1.26 → 통일).
4. `.lbl` 12px meta / `.meta` 11px meta — 필드 라벨, 축, 배지 단어, 파일 경로, 생성 시각, 섹션 라벨, 진행 띠.

컬러 이모지(👤🎟🔍✋📝👁🌐🏦)는 렌더러(chat.html glyph 맵)에서 텍스트 단어로 치환한다(사용자/쿠폰/조회/승인/기록/화면/웹/수집). 단색 글리프 ▶⊙⌨↓⎋는 유지. md 파일과 시스템 프롬프트는 그대로.

## 3. 작업대 레이아웃

**내비** — 위 가로 탭 줄 유지(세로 레일 기각: 띠 안쪽 596에서 80pt 레일은 증빙 348px 열·5열 표를 못 담는다). 메뉴바 메뉴의 Divider 묶음을 그대로: `[대화] ‹32› [타임라인 ‹12› 증빙·전표] ‹32› [절차]`, 12pt. 활성 = `Color(white:.9)` + 라벨 폭 1pt 흰 밑줄(offset 3), 비활성 = `Color(white:.54)`, 굵기 변화 없음. 줄 padding 20/8, 아래 폭 전체 1pt `rgba(255,255,255,.10)`. ⟳ 없음. 탭 텍스트 x = 12(inset)+20 = 페이지 본문 x.

**띠·림** — 창 모드 rimTop/Bottom/Right = 32. 키오스크는 화면이 정한다(≈71/71). 위·아래 띠는 구멍 폭(`hole.minX…maxX`)만 칠한다(`RingView.rimSpan`) — '#'가 아니라 폰을 두르는 사각형. 왼쪽 띠의 오른쪽 세로선(작업대/폰 경계)과 오른쪽 띠의 왼쪽 세로선은 전체 높이. 키오스크 build()에서는 띠 패널 좌표가 0에서 시작하므로 `(hole.minX − s.minX)…(hole.maxX − s.minX)`. 색·굵기는 phase: `.agent` → 금 2pt α1 / `.humanTurn` → 흰 1pt α.9 / 그 외(idle·humanUse·끊김) → 흰 1pt α.25. 평소엔 검은 링이 미러링 창의 검은 여백과 이어져 Apple 여백의 비대칭(위 42/아래 10)이 안 보인다.

**폰 캡션** — 아래 띠, 구멍 폭에 가운데 정렬, 띠 위 가장자리(림)에서 6pt 아래(`y = band.height − 22`, 높이 16), 12pt 흰 α.7, `lineBreakMode = .byTruncatingTail`, 텍스트 = `state.statusLine`. 창·키오스크 같은 규칙(오른쪽 띠에는 두지 않음). 초 카운터는 대화 상태 띠에만(시계는 하나).

**나가기** — 창 모드: ×·힌트 없음(신호등이 가구; `.miniaturizable` 제거로 노랑도 없음; 초록 = 키오스크, 메뉴에 ⌃⌘F 표기). 키오스크: × 히트 48×48을 우상단 모서리에 붙이고(무한 타겟) 원은 inset 10, 힌트 '나가기: Esc 한 번 더 · 또는 ×' 11pt α.55를 × 왼쪽 8pt에 — ×와 함께 나타나고 함께 숨는다. 아래 띠 상시 힌트 삭제(그 자리는 캡션).

**페이지별** —
- 타임라인: `[순자산 ——]` 차트(격자 월 경계만) → `[기간 —— 오늘 7일 이번 달 지난 달(.nav) · 범례 3]` 방정식 차트 + `.grid3` 3숫자 → `[9월 4일 —— 00:00 → 24:00 KST]` `.disp` 끝 순자산 + `.grid3` + 계좌 표 → `[거래 N건 —— 어디로]` 표.
- 증빙: 앱 이름 `.nav` 한 줄 → `[카카오뱅크 · 지출 통장 —— 57장 · 전표 40 · 이상 0 · 범례 2]` → 초점 줄 `.meta`('9/3 쿠팡이츠 −29,900원 · ← 타임라인') → 종이 열 1개(348px, #fff, 반경 0, 가로 스크롤 없음) → `<details>읽는 법`.
- 대화: 메시지(위, 산문) / 입력창(바닥) / 고정 상태 띠 36px(입력창 바로 아래, 3상태: 비움·진행·승인).
- 절차: 앱 카드 접힘 목록, '공통' 맨 아래, 콤보는 칩 한 줄 항상 보임.

## 4. IA 결정표

| 요소 | 위치 | 이유 |
|---|---|---|
| 기본 탭·순서·라벨 | `AppState.tab = .chat`. `[대화] · [타임라인 증빙·전표] · [절차]`. 라벨 '대화'(메뉴 항목도 '대화') | 밤 흐름의 첫 동작이 한 줄 입력인데 차트가 먼저 떴다. 메뉴바가 이미 셋을 Divider로 나눈다. '뽀미'는 앱 이름이라 무엇을 여는지 말하지 않는다 |
| 채팅 입력창 | 띠 바닥. `body{display:grid;grid-template-rows:1fr 36px;height:100%}` + `deep-chat{display:block;height:100%;min-height:0}` | 벤더 `:host{height:350px}` → `#container{height:inherit}` → `#chat-view{height:100%}` 사슬이 host의 계산값을 복사하므로 100%만 안쪽까지 정확히 전파된다. `calc(100% − 36px)`는 #container가 calc를 물려받아 36px 죽은 띠, `auto`는 붕괴 |
| 진행 상태줄 | 두 곳. (1) chat.html `#status` 고정 띠: '진행 중 ▶ ⊙ ⊙ · 12초'(지나온 글리프 + 초). (2) 폰 캡션 '뽀미가 폰 조작 중' + 림 금 2pt | 폰을 조작하는 동안 눈은 오른쪽 폰에 있다. 콤보 전체를 회색으로 그리는 띠는 onTool 2인자·Playbooks.combo·PpomiApp 클로저까지 번지고 phone_open 인자가 `title`이라 앱 매칭도 별도 — 후속(§7) |
| 폰 연결 상태 | 아래 띠 캡션 = `statusLine`. `.idle`: 연결됨 '폰 연결됨 · 대기' / 없음 '미러링 없음' / 끊김·정지 '연결 끊김 · 20초마다 다시 시도'(MirrorWatcher가 실제로 20초마다 누른다). `.agent(job)`: '뽀미가 \(job) 중'. `.humanTurn(r)`: r. `.humanUse(false)`: '손에 든 iPhone · 잠그면 돌아옴' + ' · 이어서 \(pendingJob)'. `.humanUse(true)`: idle 문구 | 밤 흐름의 첫 관문(잠긴 폰이 옆에 있나)과 마지막 관문(Face ID)이 모두 폰 상태인데 메뉴바에만 있었고 키오스크는 메뉴바를 숨긴다 |
| 동의 게이트 | **유지**. `Tools.gate()`: consented면 통과(기존). `Mirroring.state() == .connected`면 `pendingButtons = ["진행","아직"]` + '폰은 잠긴 채 연결돼 있다. 사용자에게 "폰으로 진행할까?" 한 줄로만 물어라'. 그 외 기존 문구. `talk()` ctx에 `"폰"` 한 줄 | 계기판의 `.connected면 return nil`은 잠금 확인과 동의를 혼동한 안전 후퇴(세 심사위원 일치). `consented()` 정규식이 '진행'을 이미 받으므로 되묻기 내용만 바뀌고 경계는 남는다 |
| 승인 버튼 | chat.html `#status` 세 번째 상태: `승인 대기 · [결제 승인 12,000원](.pill.primary 흰) [취소](.pill) 4:32`. 말풍선에는 요약만. 클릭 → `chat.addMessage(user)` + `post({chat:o})`(ChatSession.receive의 waiting 경로, `hasPrefix("결제 승인")` 통과). 동시에 Swift: ask 시점 `show(.chat)` + (키오스크 밖이면) `reveal()` + `phase = .humanTurn("결제 승인 · 폰 금액과 비교 후 왼쪽에서 [승인]")` → 림 흰 + 캡션 | 흐름의 유일한 결정이 스크롤되는 말풍선 안에서 칩과 같은 금색 옷을 입고 있었다. 흰 채움은 화면에 이 버튼 하나 — 금 = 뽀미 차례, 흰 = 사람 차례. 남은 시간이 보여야 왜 취소됐는지 안다 |
| 결제 후 Face ID 순간 | `Tools.onHuman` 훅 1줄(phone_tap 결제 분기) → `phase = .humanTurn("폰을 들고 Face ID → 잠그면 이어서 확인")`. 캡션·흰 림이 맡는다 | 이 순간만 시선이 화면 밖 물리 폰으로 가야 한다. `State.mirroring`의 `(.connected, .humanTurn)` 분기가 복귀를 이미 처리하므로 새 UI 없음 |
| 나가기 / × | 창 모드: 없음(신호등). 키오스크: 48pt × 우상단 모서리 + 힌트 옆에, 함께 표시/숨김. `leave()`의 창 모드 else 분기 삭제(도달 불가) | 창 모드의 ×는 빨간 버튼과 같은 동작(closeMain)이라 '닫기'가 둘이고 창에서 가장 밝은 요소였다. 키오스크는 읽는 자리(좌하)와 누르는 자리(우상)가 1700pt 떨어져 있었다 |
| 신호등 | 빨강·초록 유지, 노랑 제거(`.miniaturizable`). 메뉴 '키오스크 켜기'에 `.keyboardShortcut("f", [.control,.command])` | 노랑(최소화)은 폰 창만 바탕에 남기는 '빈 구멍의 반대'. 초록의 뜻은 툴팁에만 있었다 |
| ⟳ 다시 읽기 | 탭 줄에서 삭제, 설정 창 버튼 삭제. 메뉴바 '장부 다시 읽기' 한 곳 | 탭 줄에선 '페이지 새로고침'으로 읽히지만 장부 재읽기이고 대화 탭에선 아무 변화가 없다. '지금 수집'이 이미 자동으로 한다 |
| 설정 | 그대로(Settings 씬, 메뉴바 진입). 페이지 안 '설정 열기' 링크 없음 | 한 번 정하고 마는 값. 1인 개발자가 첫 실행에 한 번 겪는 일에 WKWebView→showSettingsWindow 배관은 과함 |
| 절차 탭 | 세 번째 묶음(참고). 모든 카드 접힘, '공통' 맨 아래. 카드 = `--card` 면, 헤더 앱명 13px 500 + 상태 단어 `.meta`(미설치/미확인만), 경로는 `title`. 콤보 = `.chip` 한 줄 항상 보임, 사람 단계(👤·✋)만 `.chip.you` dashed | 뽀미가 읽는 파일의 뷰어이지 밤 흐름의 화면이 아니다. 금색 ✋ 칩은 눌러도 아무 일 없는 '승인 버튼 모양'이었다. 정지된 계획표는 무채 |
| 증빙 진입·초점 | 진입 1순위 = 타임라인 거래 행 클릭. `.nav` 앱 선택기로 한 번에 한 열. 초점 줄 = 강조 `.row`의 textContent + '← 타임라인'(`post({timeline:1})` → `state.tab = .timeline`). hit = 종이 위 검정 2px outline. 안내문은 `<details>` | 드릴다운인데 되돌아갈 길이 없었고 안내문 230px이 열보다 먼저였다. 두 열 724px은 596 띠에서 가로 스크롤. 초점 텍스트는 DOM에서 나오므로 Swift 0줄 |
| 페이지 제목·안내문 | h1 셋 삭제. 섹션은 `.sec`. chat placeholder '말하듯이 · /help' | 탭이 이미 '어디'를 말한다. 참고의 스캔 가능성은 제목이 아니라 라벨-온-헤어라인에서 온다 |
| 색의 뜻 | 금 = 진행(림만) · 흰 = 승인(림·[승인]) · 회 = 대기. 차트·표·칩·배지·사용자 말풍선·미관측·증빙 hit 전부 무채. 빨강은 종이 위 데이터 오류 표시 하나 | '금색 하나·한 뜻'. 미관측·증빙 하이라이트는 '주의'이지 상태가 아니다 — 미관측은 `.strong` + outline 막대로, hit는 종이 위 검정 outline으로 구분된다 |
| AI/사용자 말 | AI = 말풍선 없음(transparent, padding 0, maxWidth 100%) — 검은 시트 위 산문. 사용자 = `--pick` 카드 8px, 82%. 제출 아이콘 숨김(Enter) | 밤 화면의 면(面)이 하나 줄고 승인 띠의 흰 알약이 더 도드라진다. 참고의 '본문은 종이 위 텍스트' 문법 |

## 5. theme.css 클래스 표

| 클래스 | 쓰임 |
|---|---|
| `body` | 13/1.5, max-width 640, padding 16 20 24. 페이지는 자기 `body` 규칙을 지운다(chat만 `max-width:none;padding:0` 덮어씀) |
| `.sec` + `.r` + `.r i` | 섹션 라벨 + 헤어라인 + 오른쪽 메타/범례 스와치(10px, `style="background:…"` 또는 `border:1px …`)/`.nav` |
| `.disp` `.key` `.lbl` `.meta` `.n`/`.num` `.mute` `.strong` | 타이포 4단 + 모노 숫자 + 무채 강조 |
| `.nav` `.nav>.on` | 텍스트 내비(기간 선택, 앱 선택). 자식은 `<button>`이나 `<a>` |
| `.pill` `.pill.primary` | [취소] / [승인]. 흰 채움은 primary 하나 |
| `.chip` `.chip.you` `.chip .g` `.sep` | 절차 콤보 한 단계 / 사람 단계 / 글리프 접두어 / › |
| `.card` | `--card` 면, 반경 8, padding 12 16 |
| `table` `th` `td` `td.n` `tr[data-uid]` | 12px, 행 24, 헤어라인, 숫자 오른쪽, 열리는 행 호버 |
| `.grid3` | 3열 격자(라벨 `.lbl` 위, 값 아래) |
| `details` `summary` `details p` | 접는 안내 |
| `pre` `code` `input` `textarea` `a` `hr` | 기본값 |

## 6. 파일별 변경 (최소 diff)

### 그룹 chrome — Swift

| 파일 | 무엇을 | 어떻게 |
|---|---|---|
| `Views/EvidenceView.swift` Workbench | 탭 줄 | `HStack(spacing: 32) { tab("대화", .chat); HStack(spacing: 12) { tab("타임라인", .timeline); tab("증빙·전표", .evidence) }; tab("절차", .playbooks); Spacer() }.font(.system(size: 12)).buttonStyle(.plain).padding(.horizontal, 20).padding(.vertical, 8)`. ⟳ Button 삭제. 밑줄 `Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1)`. `tab()`: `Button(title) { state.show(t) }.foregroundStyle(on ? Color(white: 0.9) : Color(white: 0.54)).overlay(alignment: .bottom) { Rectangle().fill(.white).frame(height: 1).offset(y: 3).opacity(on ? 1 : 0) }` (fontWeight·opacity 삭제) |
| `Views/EvidenceView.swift` EvidenceView | ← 타임라인 | `WebPage(html:…, focus:…, onMessage: { m in if (m as? [String: Any])?["timeline"] != nil { state.tab = .timeline } })` |
| `Views/EvidenceView.swift` Evidence.html | sub | `let sub = "생성 \(TS.string(Date())) · 거래 \(inDB.count)건"` (정의문은 evidence.html의 details로) |
| `Views/RingContent.swift` | 띠·캡션·림 | `rimTop = 32, rimBottom = 32, rimRight = 32`. `exitMark`·`onPress`·`Ring.furnish` 호출 삭제 → `let caption = Ring.caption()`; init에서 `bands[1].addSubview(caption)`. `var phase: Phase = .idle { didSet { bands.forEach { $0.phase = phase } } }`. `layout()`: `Ring.placeExit` 줄 삭제, `bands[0].rimSpan = h.minX...h.maxX; bands[1].rimSpan = h.minX...h.maxX; caption.frame = NSRect(x: h.minX, y: bands[1].bounds.height - 22, width: h.width, height: 16)`. DockView 안내 α.35 → .5. 머리 주석 갱신 |
| `Kiosk.swift` RingView | 림 | `KIOSK_BORDER` 삭제. `var rimSpan: ClosedRange<CGFloat>? { didSet { needsDisplay = true } }`, `var phase: Phase = .idle { didSet { if oldValue != phase { needsDisplay = true } } }`. draw: `let (c, t): (NSColor, CGFloat) = switch phase { case .agent: (NSColor(red: 0.78, green: 0.64, blue: 0, alpha: 1), 2); case .humanTurn: (NSColor(white: 1, alpha: 0.9), 1); default: (NSColor(white: 1, alpha: 0.25), 1) }`; `let x0 = rimSpan?.lowerBound ?? 0, w = rimSpan.map { $0.upperBound - $0.lowerBound } ?? b.width`; `.minY`/`.maxY` 사각형의 x/width를 x0/w로(.minX/.maxX는 전체 높이 그대로) |
| `Kiosk.swift` ExitMark | 히트 확대 | `draw`의 `insetBy(dx: 5, dy: 5)` → `dx: 10, dy: 10` |
| `Kiosk.swift` Ring | 캡션·힌트 | `furnish(top:bottom:exit:)` → `furnish(top: NSView, exit: ExitMark, hint: NSTextField)`: 둘 다 hidden으로 top에 addSubview. 새 `static func caption() -> NSTextField`: `labelWithString: ""`, 12pt, `NSColor(white: 1, alpha: 0.7)`, `.alignment = .center`, `.lineBreakMode = .byTruncatingTail`. `placeExit(_ exit:, hint:, in top:)`: `exit.frame = NSRect(x: top.bounds.width - 48, y: top.bounds.height - 48, width: 48, height: 48)`; `hint.sizeToFit(); hint.frame.origin = CGPoint(x: exit.frame.minX - hint.frame.width - 8, y: exit.frame.midY - hint.frame.height / 2)` |
| `Kiosk.swift` KioskController | 배관 | `private let hint = NSTextField(labelWithString: "나가기: Esc 한 번 더 · 또는 ×")`(init에서 11pt, 흰 α.55, hidden), `private var kioskCaption: NSTextField?`. `makeMain`: `c.onPress`·`c.exitMark.onClick` 줄 삭제, styleMask에서 `.miniaturizable` 제거. `closeMain`: `content?.exitMark…` 삭제. `makeWindows`: `Ring.furnish(top: windows[0].contentView!, exit: exitMark, hint: hint)`; `let cap = Ring.caption(); windows[1].contentView!.addSubview(cap); kioskCaption = cap`. `build()` setFrame 루프 뒤: `let span = (hole.minX - s.minX)...(hole.maxX - s.minX); [windows[0], windows[1]].forEach { ($0.contentView as? RingView)?.rimSpan = span }; if let b = windows[1].contentView { kioskCaption?.frame = NSRect(x: hole.minX - s.minX, y: b.bounds.height - 22, width: hole.width, height: 16) }`. `showExitMark`: `Ring.placeExit(exitMark, hint: hint, in: top); exitMark.isHidden = false; hint.isHidden = false`; `hideExitMark`: `hint.isHidden = true` 추가. `sync()` 첫머리: `content?.phase = state.phase; windows.forEach { ($0.contentView as? RingView)?.phase = state.phase }; content?.caption.stringValue = state.statusLine; kioskCaption?.stringValue = state.statusLine`. `leave()`: else 분기 삭제. 머리 주석 5~6행 갱신 |
| `Views/ChatView.swift` ChatSession | phase 배관 | `weak var state: AppState?`. `private func phase(_ p: Phase?) { DispatchQueue.main.async { MainActor.assumeIsolated { guard let s = self.state else { return }; if let p { s.phase = p } else if case .agent = s.phase { s.phase = .idle } else if case .humanTurn = s.phase { s.phase = .idle } } } }`. init: `onTool = { [weak self] name in self?.js("progress", [name]); if name.hasPrefix("phone_") || name == "collect_now" { self?.phase(.agent(job: name == "collect_now" ? "수집" : "폰 조작")) } }`; `assistant.tools.onHuman = { [weak self] r in self?.phase(.humanTurn(reason: r)) }`. `ask()`: `js("ask")` 앞에 `phase(.humanTurn(reason: "결제 승인 · 폰 금액과 비교 후 왼쪽에서 [승인]")); DispatchQueue.main.async { MainActor.assumeIsolated { self.state?.show(.chat); if self.state?.kioskOn == false { self.state?.reveal() } } }`; wait 뒤(답·타임아웃 모두) `phase(nil)`. `receive()`: `turns.async { [self] in js("reply", [assistant.handle(t)]); phase(nil) }` |
| `Views/ChatView.swift` ChatView | state 연결 | `@EnvironmentObject var state: AppState`; onAppear에서 `s.state = state` |
| `Views/WebPage.swift` | 흰 번쩍임 | `makeNSView`에 `v.underPageBackgroundColor = .black` 1줄 |
| `State.swift` | 기본 탭·문구 | `tab: Tab = .chat`. `statusLine`: §4 '폰 연결 상태' 문구 그대로 |
| `PpomiApp.swift` MenuContent | 라벨·단축키 | `Button("뽀미와 대화")` → `Button("대화")`. 키오스크 Button에 `.keyboardShortcut("f", modifiers: [.control, .command])` |
| `Views/SettingsView.swift` | ⟳ | 41행 `Button("다시 읽기")` 삭제(HStack엔 `ledgerText`만) |
| `Views/TimelineView.swift` `Views/PlaybooksView.swift` | — | 변경 없음 |

### 그룹 timeline — `Web/timeline.html`

| 무엇을 | 어떻게 |
|---|---|
| `<style>` | `:root/body/h1/h2/.chips/table/th/td/.m/.c/.u/.big/.note/.row/tr.inc|out|xf/.legend` 삭제(theme). `body{user-select:none}` 삭제(숫자 복사). 남기는 SVG 규칙만: `svg{display:block;width:100%} #chart{height:200px;cursor:pointer} #eq{height:160px} .grid{stroke:var(--line)} .axis,.htext{fill:var(--meta);font-size:11px} .zero{stroke:var(--line2)} .nw{fill:none;stroke:var(--fg);stroke-width:1.5} .pin,.sel{fill:var(--pick)} .hover{stroke:var(--line2)} .obs{fill:var(--fg)} .exp{fill:var(--meta)} .res{fill:none;stroke:var(--fg);stroke-width:1} .dayhit{fill:transparent}` |
| 마크업 | `<h1>` 삭제 → `<div class="sec">순자산<span class="r">관측된 계좌만</span></div>`. `#chips`를 `.nav`로 옮겨 두 번째 섹션 라벨의 `.r` 안에: `<div class="sec">기간<span class="r"><span class="nav" id="chips"></span><span><i style="background:var(--fg)"></i>관측 <i style="background:var(--meta)"></i>설명 <i style="border:1px solid var(--fg)"></i>미관측</span></span></div>`; 기존 `.legend` div 삭제 |
| JS 격자 | 63행 루프: `<line class="grid">`는 `d.getDate()===1`일 때만(축 라벨 조건은 그대로) |
| JS 차트 라벨 | 67행 `'순자산 (관측된 계좌만)'` text 삭제(섹션 라벨이 대신) |
| JS 칩 | 버튼은 `.nav`의 `<button>`(클래스 없음), `.on` 토글 그대로 |
| JS eqsum | `<div class="grid3">` 3칸: `<div><span class="lbl">관측된 자산 증감</span><span class="key n">…</span></div>` 식. 미관측 칸은 `class="key n'+(Math.abs(O-E)>0?' strong':'')+'"`; 보조 문장은 `.meta` |
| JS showDay | `<h2>` → `<div class="sec">'+fmtFull(d)+'<span class="r">00:00 → 24:00 KST</span></div>`. 첫 줄 `<div><span class="disp">'+won(tb.sum).replace('원','')+'</span> <span class="meta">원 · 끝 순자산</span></div>`, 이어 `.grid3`(시작 순자산 / 관측 증감 / 수입−지출)와 `.grid3`(미관측 `.n`+strong 조건 / 빈칸 / 빈칸) 또는 4칸 하나 — 값 `class="n"`, 라벨 `.lbl`. 계좌 표: 근거 셀 `class="c"/"m"/"u"` → `class="meta"`(단어 '스냅샷/API'가 구분), `'<span class="u">—</span>'` → `'<span class="mute">—</span>'`. 거래 `<h2>` → `<div class="sec">거래 N건<span class="r">어디로: …</span></div>`; 행 class inc/out/xf는 남겨도 되나 CSS 없음(마지막 열 단어가 구분); 금액 `td.n`, 마지막 열 `class="meta"` |

### 그룹 evidence — `Web/evidence.html` (+ `Ledger/Column.swift` 변경 없음)

| 무엇을 | 어떻게 |
|---|---|
| `<style>` | `body/h1/h3/.sub/.note/.legend/@media` 삭제(다크 하나, theme). 남김·수정: `.evidence{display:none} .evidence.on{display:block} .col{position:relative;width:348px;background:#fff;border:0}` `.row/.row span/.peek/.peek img/@keyframes` 그대로(img border 1px #ddd 유지) `.box{position:absolute;left:4px;width:338px;border:1px solid;border-radius:0;box-sizing:border-box;background:none} .box.warn{border-style:dashed;border-color:#8a8a86} .box.bad{border-color:var(--bad);background:rgba(221,51,51,.10)} .row.hit{outline:2px solid #111;outline-offset:2px}` |
| 마크업 | `<h1>`·`.sub`·`.legend`·`.note` 삭제 → `<nav class="nav" id="apps"></nav><div class="sec" id="hd"></div><div class="meta" id="crumb"></div><div id="cols"></div><details><summary>읽는 법</summary><p>입력: 폰 화면 스크린샷과 그 OCR 결과(원시증빙). 출력: 옮겨 적은 거래 행(전표) = transactions 테이블. 글자가 보이면 OCR이 읽은 것이고 전표가 된 거래는 따로 표시하지 않습니다. 이상만 상자로: 점선 = 파싱됐지만 전표에 없음, 빨강 = 금액 행인데 파싱 안 됨.</p><p>(기존 .note 2단락)</p></details>` |
| JS 구성 | 앱마다 `#apps`에 `<a>`(i===0이면 `.on`), `#cols`에 `<div class="evidence">`(i===0이면 `.on`) + `a.col`. `function show(i)`: `#apps`·`#cols` 자식의 `.on`을 i만 켜고 `#hd.innerHTML = esc(title+' · '+account)+'<span class="r">'+frames+'장 · 전표 '+ok+' · 이상 '+bad+' <i style="border:1px dashed #8a8a86"></i>전표 없음 <i style="border:1px solid #d33"></i>파싱 안 됨</span>'`. 기본 `#crumb.textContent = E.sub`(생성 시각·건수). `post()` 3줄 복사 |
| JS focus(id) | 행을 `.hit`로 → 그 행의 `.closest('.evidence')` 인덱스로 `show(i)` → `#crumb.innerHTML = esc(r.textContent.trim().replace(/\s+/g,' '))+' · <a id="back">← 타임라인</a>'`, `back.onclick = function(){post({timeline:1});}` → `scrollIntoView({block:'center'})`. null이면 hit 제거·crumb 기본값 |
| Column.swift | 변경 없음. `.col/.row/.box.warn/.box.bad/.peek`, `id=evidID`, `data-app/data-frames`를 새 CSS가 새 값으로 그린다. 종이 열 348×766·#fff는 '증거'의 근거 |

### 그룹 chat — `Web/chat.html` (+ `Serve/Assistant.swift` chatHTML 변경 없음)

| 무엇을 | 어떻게 |
|---|---|
| `<title>` | `대화` |
| `<style>` | `html,body{height:100%} body{display:grid;grid-template-rows:1fr 36px;max-width:none;padding:0} deep-chat{display:block;width:100%;height:100%;min-height:0;border:0} /* 벤더 #container{height:inherit}가 host의 100%를 물려받는다 — calc/auto 금지 */ #status{height:36px;box-sizing:border-box;display:flex;align-items:center;gap:8px;padding:0 20px;font-size:11px;color:var(--meta);border-top:1px solid var(--line);white-space:nowrap;overflow:hidden} #status b{font-weight:400;color:var(--fg);font-size:12px;letter-spacing:2px} #status .t{margin-left:auto;font-family:var(--mono);font-variant-numeric:tabular-nums} #status .pill{height:22px;padding:0 10px}`. 기존 `#status.on` 토글 삭제(띠는 늘 있음, 비움 상태는 내용 없음) |
| Deep Chat 설정(값은 hex — shadow DOM 안 var() 파싱 위험 회피) | `chat.style.backgroundColor='#000'; chat.chatStyle={backgroundColor:'#000',borderColor:'#000'}; chat.messageStyles={default:{shared:{bubble:{backgroundColor:'transparent',color:'#e6e6e3',fontSize:'13px',lineHeight:'1.5',padding:'0',marginTop:'12px',maxWidth:'100%'}},user:{bubble:{backgroundColor:'rgba(255,255,255,.08)',color:'#e6e6e3',padding:'8px 12px',borderRadius:'8px',maxWidth:'82%'}}},loading:{message:{styles:{bubble:{backgroundColor:'transparent'}}}}}; chat.textInput={placeholder:{text:'말하듯이 · /help'},styles:{container:{backgroundColor:'#131313',color:'#e6e6e3',border:'1px solid rgba(255,255,255,.10)',borderRadius:'6px',boxShadow:'none'},text:{color:'#e6e6e3'}}}; chat.submitButtonStyles={submit:{container:{default:{display:'none'}}},loading:{container:{default:{display:'none'}}},stop:{container:{default:{display:'none'}}}}; chat.auxiliaryStyle='::-webkit-scrollbar{width:6px}::-webkit-scrollbar-thumb{background:rgba(255,255,255,.15);border-radius:3px}::-webkit-scrollbar-track{background:transparent}'; chat.htmlClassUtilities={chip:{styles:{default:{opacity:'0.65',fontSize:'12px'}}}}` (`pay` 삭제) |
| glyph 맵 | `{phone_open:'▶',phone_tap:'⊙',phone_type:'⌨',phone_scroll:'↓',phone_key:'⎋',phone_screen:'화면',phone_installed:'조회',pay_preference:'결제수단',confirm_payment:'승인',record_spend:'기록',web_text:'웹',collect_now:'수집'}`, 폴백 `esc(name)`(🔧 없음) |
| status()/done() | `bar.innerHTML='진행 중 <b>'+run.moves.join(' ')+'</b><span class="t">'+secs+'초</span>'`. `done()`: 타이머 정리 + `bar.innerHTML=''`(className 토글 삭제) |
| window.ask | `window.reply(html)`(요약만 말풍선에) 뒤 `var left=300; bar.innerHTML='<span>승인 대기</span>'+options.map(function(o,i){return '<button class="pill'+(i?'':' primary')+'">'+esc(o)+'</button>';}).join('')+'<span class="t" id="cd">5:00</span>'`; `run.timer=setInterval(…1초: left--; #cd = m:ss; left<=0이면 done() 후 bar='<span>시간 초과 · 결제 안 함</span>', 5초 뒤 비움)`; 각 버튼 `onclick`: `chat.addMessage({role:'user',text:o}); done(); post({chat:o})` — options[0] 원문('결제 승인 12,000원')을 그대로 보내야 Swift의 `hasPrefix("결제 승인")`이 통과 |
| window.reply | 변경 없음(설정 열기 버튼 부착은 하지 않는다) |
| Assistant.chatHTML | 변경 없음 |

### 그룹 밖 — Serve/ 4줄 (오케스트레이터 또는 chrome 그룹이 별도 커밋으로)

| 파일 | 무엇을 | 어떻게 |
|---|---|---|
| `Serve/Tools.swift` | 동의 게이트 문구 | `gate()`: consented 통과 줄 다음에 `if Mirroring.state() == .connected { pendingButtons = ["진행", "아직"]; return "실행 안 함: 폰은 잠긴 채 연결돼 있다. 사용자에게 '폰으로 진행할까?' 한 줄로만 물어라(선택 버튼은 자동으로 붙는다)." }`. 기존 분기 그대로. `collect_now` 설명의 "'폰 잠겨 있어?'라고 확인한 뒤" → "gate가 알려주는 한 줄을 물은 뒤" |
| `Serve/Tools.swift` | Face ID 훅 | `onTool` 옆 `var onHuman: ((String) -> Void)? = nil`; phone_tap 결제 분기 `Notify.post` 앞에 `onHuman?("폰을 들고 Face ID → 잠그면 이어서 확인")` |
| `Serve/Assistant.swift` talk() | 폰 상태 컨텍스트 | ctx에 `"폰": Mirroring.state() == .connected ? "미러링 연결됨(잠긴 채 옆에 있음) — 잠금 여부를 묻지 말 것" : Mirroring.state().rawValue` |

## 7. 하지 않을 것

- 콤보 전체 진행 띠(남은 단계 회색): onTool 2인자·Playbooks.combo·PpomiApp `--ask` 클로저까지 번지고 phone_open 인자는 `title`이라 앱 매칭이 별도. onTool에 인자가 실릴 때 후속.
- 미관측·증빙 hit의 금색: 금색 = '뽀미가 폰을 잡고 있다' 한 뜻. 미관측은 `.strong` + outline 막대, hit는 종이 위 검정 outline.
- 흰 primary를 [승인] 외에 하나라도 더(사용자 말풍선·칩·활성 탭). 금색 채움 승인.
- 세리프 디스플레이, 3단 음영 토글, `data-shade` 주입, WKWebView 4개 유지 구조 변경.
- 세로 레일 내비, 페이지 안 '다시 읽기'·'설정 열기' 링크, `showSettingsWindow:` 셀렉터.
- 캡션에 초 카운터(시계는 대화 띠 하나). 창 모드 ×·힌트·⌘M.
- `Tools.gate()`에서 `.connected면 return nil`. 동의 규칙(`consented`)·pendingButtons 흐름 변경.
- 증빙 종이 열의 크기·흰색·글자색 샘플링(Column.swift) 변경. md 파일·시스템 프롬프트의 이모지 변경.
- 새 의존성·프레임워크·외부 폰트.

## 8. 구현 후 확인

1. Deep Chat: 입력창이 띠 바닥, 메시지 스크롤이 안쪽에서 됨, 36px 빈 띠 없음. 안 되면 `chat.style.height='100%'` 인라인 → 그래도 안 되면 `#container` 계산값을 Web Inspector로 본다. 제출 아이콘이 loading 상태에서 되살아나면 `filter:'invert(.6)'`로 후퇴.
2. 승인: [결제 승인 N원] 클릭 → 사용자 말풍선 기록 + Swift waiting 경로로 답 도착 + 림 흰→금 복귀. 5분 타임아웃 문구.
3. 림: 창·키오스크 모두 네 선이 폰 모서리에서 만남(보조 디스플레이 포함 — `s.minX` 보정). `.agent`에서 2pt 금, idle 1pt α.25가 '테두리가 사라졌다'로 느껴지면 α.35.
4. 탭 줄: rimTop 32에서 신호등이 28pt 제목줄 안에 들어오는지, 위 띠 드래그가 되는지. 탭 밑줄 offset 3이 헤어라인과 겹치지 않는지.
5. 캡션: 긴 문구('손에 든 iPhone · 잠그면 돌아옴 · 이어서 폰 조작')가 폰 폭에서 … 로 잘림. 창·키오스크 같은 y.
6. 키오스크 위 띠에 메뉴바가 남으면(kiosk2.png는 옛 캡처) `BandPanel`에 `override func constrainFrameRect(_ r: NSRect, to: NSScreen?) -> NSRect { r }` 1줄.
7. ⌃⌘F가 메뉴 단축키와 로컬 모니터로 두 번 토글되면 `.keyboardShortcut` 제거(표시만 포기).
8. `Mirroring.state()`를 turns 큐(비메인)에서 부르는 gate()·talk(): AX 호출이 MirrorWatcher와 겹쳐 문제가 보이면 watcher가 마지막 값을 static에 적고 그것을 읽는다.
9. phase 배관: 사람이 도중에 폰을 들면 `(.inUse, .agent)`가 pendingJob을 채운다 — reply 뒤 `phase(nil)`은 .agent/.humanTurn만 되돌리므로 humanUse 중 도착한 답 뒤 pendingJob이 남을 수 있다(무해: 다음 connected에서 .agent → 곧 idle).
10. 재캡처(`screencapture -l <windowid>`)로 4탭 + 키오스크 확인 후 기록.
