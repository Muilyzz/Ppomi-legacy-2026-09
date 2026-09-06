# 뽀미 (Ppomi)

**뽀미는 당신 폰을 대신 만지는 손입니다. 돈 앞에서는 멈추고, 한 일은 증거를 남깁니다.**

> **English.** Ppomi is a Mac app that drives your *locked* iPhone through iPhone Mirroring on behalf of an AI agent (Claude app, Claude Code, Codex, or any stdio MCP client). It reads the mirrored screen with on-device OCR, taps, types and scrolls, and stops at every pay button: money leaves only after you press one approval button, one approval per attempt, enforced in code. Everything it does lands in a local SQLite ledger with screenshots as evidence, and what it learns about each app is written to plain Markdown playbooks. Nothing leaves your Mac unless you plug in a brain. By Muilyzz.

## 무엇인가

| | |
|---|---|
| **손** | iPhone 미러링 창을 읽고(온디바이스 OCR) 탭·입력·스크롤합니다. 폰은 잠긴 채 Mac 옆에 둡니다. |
| **문지기** | 결제·구매·주문·송금 같은 버튼은 `confirm_payment` 승인이 있어야 눌립니다. 승인 한 번 = 시도 한 번, 그 금액에만. 코드가 막습니다. |
| **증거** | 한 일은 `data/ledger.db` 에 적히고, 읽은 화면은 `data/shots/` 에 남습니다. |
| **발자국** | 앱마다 알게 된 버릇을 `data/playbooks/*.md` 에 한 줄씩 적습니다. 다음번에 더 잘 합니다. |
| **MCP** | `Ppomi --mcp` 가 위 전부를 도구로 내놓습니다. 두뇌는 밖(Claude 앱·Claude Code·Codex)에 둡니다. |

그 밖에 미러링 바로 뒤에 놓이는 검은 작업대 창과 음성("뽀미야", ⌥Space, `--voice`)이 있습니다. 절차와 장부는 옆에서 보고, 상태 안내와 승인 버튼은 작업대 하단에서 확인합니다.

일반 모드는 현재 디스플레이의 사용 가능한 영역을 채우는 고정 크기 창입니다. iPhone·Windows를 바꿔도 배경 창의 크기는 유지하고 작업 화면 옆에 장부와 승인 버튼을 배치합니다. 초록 버튼이나 `⌃⌘F`는 다른 창과 메뉴 막대를 가리는 키오스크로 전환합니다. 키를 누르면 나가기 버튼이 나타나며 일반 창으로 돌아올 수 있습니다. Dock의 뽀미 아이콘은 현재 모드를 유지한 채 작업 화면과 함께 다시 엽니다. 미러링 창을 직접 옮기면 옆 콘텐츠의 배치가 바뀝니다.

**몸과 생활** 탭은 인바디 결과 화면·이미지, 식사·운동·컨디션을 비공개 기록으로 모읍니다. 발생·수집 시각, 단위, 측정 기기, 원본 증빙과 수정 이력을 함께 저장합니다. 외부 에이전트와 음성도 같은 기록을 사용하고, Schema.org JSON-LD를 내보낼 수 있습니다. 인바디 API 자동 동기화는 포함하지 않습니다. [사용법과 공통 데이터 규격](docs/life-records.md)을 참고하세요.

## 요구사항

- Apple 실리콘 Mac, macOS 26
- iPhone 미러링이 되는 지역·Apple 계정(같은 계정, Wi‑Fi·Bluetooth 켜짐)
- 아이폰은 **잠근 채** Mac 옆에. 잠금을 풀거나 손에 들면 미러링이 끊깁니다 — 그때는 뽀미가 멈추고 다시 잠가 달라고 합니다.

## 설치

**다운로드**: 현재 [v0.1.0 프리릴리스](https://github.com/Muilyzz/Ppomi/releases)는 애드혹 서명된 테스트 빌드이며, Apple 공증 전입니다. `.zip`을 풀어 `Ppomi.app`을 `/Applications`로 옮길 수 있지만 macOS에서 실행이 차단될 수 있습니다. 일반 배포용 Developer ID 서명·공증 빌드는 준비 중입니다.

```sh
# 로컬 설치용 앱: 보유한 Apple Development 인증서 이름 사용
LOCAL_SIGN_ID="Apple Development: …" scripts/make-app.sh
# → dist/Ppomi.app. 이후 빌드도 같은 인증서와 설치 경로를 사용하세요.

# 또는 소스로
cd Ppomi && swift run Ppomi
```

미러링 창을 만지는 `phone` CLI(저장소 루트 `phone.swift`)는 첫 사용 때 자동으로 빌드됩니다.

인증서 없이 `scripts/make-app.sh`를 실행하면 패키징 확인용 애드혹 빌드를 만듭니다. 애드혹 빌드는 코드가 바뀔 때마다 macOS 권한 연결이 끊길 수 있으므로 기존 설치본에 반복해서 덮어쓰지 마세요. 개발 서명으로 처음 전환할 때는 손쉬운 사용·화면 기록을 다시 허용해야 합니다. 배포용 서명·공증에는 별도의 `SIGN_ID`·`NOTARY_PROFILE`을 사용합니다.

권한이 켜져 있는데도 앱에서 거부된다면 이전 빌드의 서명 조건이 남아 있을 수 있습니다. 이 경우 현재 앱의 해당 권한 항목을 갱신해야 합니다. [개발 서명 전환 후 권한 복구 기록](docs/release-status.md#개발-서명-전환-후-권한-복구)을 참고하세요.

장부 위치는 기본이 저장소의 `data/ledger.db`(저장소 밖에서 실행하면 `~/Library/Application Support/Ppomi/data/ledger.db`)이고, 환경변수 `PPOMI_DB` 또는 설정 창에서 바꿀 수 있습니다(`Ledger/Model.swift` 의 `AppSettings.dbPath`). 발자국·스크린샷·`.env` 는 그 옆을 따라갑니다.

## 권한

에이전트가 처음 폰을 만지려 할 때 설정 창(시작하기)이 열립니다. 시스템 설정 › 개인정보 보호 및 보안에서 셋을 켭니다.

| 권한 | 왜 |
|---|---|
| 손쉬운 사용 | 미러링 창에 탭·키 입력을 보내려고 |
| 화면 기록 | 미러링 창을 찍어 읽으려고 |
| 마이크(·음성 인식) | 음성을 쓸 때만. 깨우는 말은 온디바이스로 듣습니다 |

## 두뇌 연결

뽀미는 손이고, 무엇을 할지는 MCP 클라이언트가 정합니다. 어디에 붙이든 형식은 같습니다: 명령 `Ppomi`, 인자 `--mcp`, stdio.

**Claude 앱** — `~/Library/Application Support/Claude/claude_desktop_config.json`

```json
{
  "mcpServers": {
    "ppomi": {
      "command": "/Applications/Ppomi.app/Contents/MacOS/Ppomi",
      "args": ["--mcp"]
    }
  }
}
```

**Claude Code**

```sh
claude mcp add ppomi -- /Applications/Ppomi.app/Contents/MacOS/Ppomi --mcp
```

**Codex** — `~/.codex/config.toml`

```toml
[mcp_servers.ppomi]
command = "/Applications/Ppomi.app/Contents/MacOS/Ppomi"
args = ["--mcp"]
```

**Grok Build 등 stdio MCP 를 받는 곳** — `{"command": "/Applications/Ppomi.app/Contents/MacOS/Ppomi", "args": ["--mcp"]}`.

소스로 쓸 때는 경로를 `Ppomi/.build/debug/Ppomi` 로 바꾸면 됩니다.

내놓는 도구: `phone_screen` `phone_tap` `phone_type` `phone_key` `phone_scroll` `phone_open` `phone_installed` `pay_preference` `confirm_payment` `record_spend` `ask_choice` `balances` `today_spending` `transactions` `sql`(읽기 전용) `list_playbooks` `read_playbook` `note_footprint` `run_combo` `health_records` `record_health` `inbody_capture`.

## 첫 사용

폰을 잠가 옆에 두고, 두뇌에게 말합니다.

> 타니베이 9/5~9/8 3박 예약해줘

뽀미가 앱을 열고, 날짜를 넣고, 객실을 고르고, 결제 화면까지 갑니다. 거기서 멈추고 승인 버튼을 보냅니다 — 클라이언트가 엘리시테이션을 지원하면 그 창에, 아니면 뽀미 작업대의 옆 열 하단에.

> 💳 결제 승인 요청 · 타니베이 디럭스 9/5–9/8 3박 · 406,600원 · 토스페이
> [결제 승인 406,600원] [취소]

누르면 결제 버튼이 눌리고, Face ID 는 당신이 폰을 들어 합니다. 완료 화면(예약번호·취소 조건)은 장부에 적힙니다.

## 결제 문지기

- 돈이 나가는 버튼("…결제하기", "구매", "주문", "송금", "이체" 등)은 `phone_tap` 이 글자를 보고 알아챕니다. 좌표로 탭해도 같은 높이에 그 글자가 있으면 같이 막습니다.
- 승인은 도구 인자로 넘길 수 없습니다. `confirm_payment` 가 사람에게 버튼을 보내고, 5분 안에 답이 없으면 취소입니다.
- 승인 한 번은 결제 시도 한 번입니다. 눌리는 순간 소모되고, 실패해도 다시 시도하지 않고 보고만 합니다.
- 비밀번호·카드번호·Face ID 는 대신 하지 않습니다.

## 발자국

앱 ID·이름·아이콘·실행 방법·가능한 작업과 입력·절차는 하나의 [플레이북 데이터 패키지](docs/playbook-format.md)로 정의합니다. 기본 패키지 원본은 `Ppomi/Sources/Ppomi/Catalog/`이며 키오스크·MCP·앱 실행·허브가 이를 함께 읽습니다. **절차 → 가져오기**에서 새 패키지 폴더를 추가하면 코드 수정·재빌드 없이 표시됩니다.

두뇌는 `list_playbooks`로 앱 ID를 찾고 `read_playbook`으로 명세를 읽습니다. `phone_open`도 같은 ID를 받습니다. 현장에서 배운 버릇은 기존 `data/playbooks/*.md`, 재생할 동작은 로컬 `.jsonl`에 보존합니다. `run_combo`는 기록된 화면이 맞는 동안만 재생하며, 현재 패키지 버전의 실제 재생 결과를 별도로 셉니다. 새 명세를 추가한 것만으로 전체 절차가 검증된 것은 아닙니다. 금액·이름·예약번호 같은 개인정보는 플레이북에 적지 않습니다.

## 개인정보

- 장부·화면·발자국은 Mac 안에 있고 밖으로 나가지 않습니다. 두뇌에 붙이면 두뇌가 요청한 것만 그 두뇌로 갑니다.
- 실행 기록(도구 이름·성공/실패·걸린 시간만)은 장부 옆 `data/telemetry.jsonl` 에 남습니다. 밖으로 보내는 것은 설정 창의 옵트인, 기본 꺼짐이고 보낼 곳(`PPOMI_TELEMETRY_URL`)이 없으면 켜도 아무 데도 가지 않습니다. 이름·금액·화면은 담기지 않습니다(`Serve/Telemetry.swift` 의 화이트리스트).
- 음성은 당신의 OpenAI 키로 OpenAI 에 직접 붙습니다. 키는 키체인에 있습니다.
- 자세한 것은 [site/privacy.html](site/privacy.html).

## 개발

```sh
cd Ppomi
swift build
swift test
swift run Ppomi            # 콘솔
swift run Ppomi --mcp      # MCP 서버(stdio)
```

## 라이선스

[MIT](LICENSE). 발자국 허브 서비스(`hub/`)는 이 저장소의 앱과 별개로 운영됩니다.

---

Muilyzz · [muilyzz.com](https://muilyzz.com)
