# 뽀미 플레이북 패키지 v1

앱의 이름·아이콘·가능한 작업·필요한 입력·사람이 개입하는 단계·절차를 하나의 데이터 패키지로 정의한다. 키오스크와 MCP는 같은 패키지를 읽는다. 재생 엔진은 같은 앱 ID로 절차와 로컬 실행 기록을 연결한다. 허브는 검토한 원본 패키지의 복사본을 읽기 전용으로 제공한다.

## 위치와 가져오기

공개 기본 패키지의 원본은 `Ppomi/Sources/Ppomi/Catalog/`다. 앱 번들 리소스와 허브 배포용 데이터는 이 원본에서 만들어진다. `hub/catalog/`는 생성물이므로 직접 편집하거나 커밋하지 않는다.

```text
Catalog/
  common.md
  sample-app/
    manifest.json
    guide.md
    icon.png
```

새 앱 패키지를 사용하려면 키오스크 **절차 → 앱 플레이북 → 가져오기**에서 `manifest.json`이 들어 있는 폴더를 선택한다. 앱이 패키지를 검사해 로컬의 `playbooks/catalog/<id>/`에 설치하고 카드를 갱신한다. 이 경로에는 코드 수정이나 앱 재빌드가 필요하지 않다. 로컬 플레이북 디렉터리는 장부 DB와 같은 부모 아래의 `playbooks/`이며 개발 환경에서는 보통 `data/playbooks/`다. 가져오기는 허브 게시나 다른 사용자의 설치를 뜻하지 않는다.

패키지 폴더 이름과 `manifest.id`는 같아야 한다. 이름이나 검색어가 바뀌어도 `id`는 유지한다. 기존 앱 이름과 별칭은 같은 ID로 조회할 수 있으며 다른 패키지와 겹치면 안 된다.

## manifest.json

```json
{
  "schemaVersion": 1,
  "id": "sample-app",
  "name": "새로운 앱",
  "version": "1.0.0",
  "aliases": ["Sample App"],
  "icon": "icon.png",
  "iconSource": "https://example.com/official-app",
  "launch": { "search": "새로운 앱" },
  "capabilities": [
    {
      "id": "browse",
      "title": "목록 탐색",
      "description": "공개 목록에서 조건에 맞는 항목을 찾습니다.",
      "inputs": [
        { "name": "query", "label": "검색어", "required": false }
      ],
      "steps": [
        { "id": "open", "title": "앱 열기", "kind": "open" },
        { "id": "read-list", "title": "목록 확인", "kind": "read" }
      ]
    }
  ],
  "humanSteps": ["로그인 화면 준비와 허용된 일반 정보 입력은 이어가고, 자격 증명 입력·본인인증·새 동의는 당사자가 처리합니다."],
  "guide": "guide.md"
}
```

| 필드 | 의미 |
|---|---|
| `schemaVersion` | 형식 버전. 현재 숫자 `1`만 지원 |
| `id` | 안정 ID. 영문 소문자로 시작하며 영문 소문자·숫자·`-`, 최대 64자 |
| `name`, `aliases` | 표시 이름과 조회용 별칭 배열 |
| `version` | 패키지 버전. `1.0.0`과 같은 세 자리 버전, 선택적으로 사전 배포·빌드 접미사 |
| `icon`, `iconSource` | 선택 필드. 패키지 안의 이미지 상대 경로와 공식 출처 웹 URL. 런타임에 임의의 아이콘을 내려받거나 합성하지 않음 |
| `launch.search` | 폰 앱의 검색어. `launch.target`이 `browser`·`windows`이면 열 HTTP(S) URL |
| `launch.target` | 선택 필드. `browser` \| `windows`. `browser`는 Mac의 Google Chrome, `windows`는 Parallels Windows의 기본 브라우저에서 열기. 생략하면 폰 실행 경로 |
| `capabilities` | 선언한 작업 배열. 작업별 안정 ID·제목·설명·입력 명세·단계 |
| `inputs` | 실제 입력값이 아닌 입력의 이름·라벨·필수 여부 |
| `steps` | 단계별 안정 ID·제목·종류. 실행 코드나 승인 증표를 포함하지 않음 |
| `humanSteps` | 사람이 수행하거나 승인해야 하는 일을 설명하는 문자열 배열 |
| `guide` | 패키지 안의 Markdown 절차 상대 경로 |
| `collection` | 선택 필드. 장부 수집용 화면 선택자와 계정 종류 명세 |

`steps.kind`는 `open`, `human`, `tap`, `read`, `scroll`, `close`, `payment`, `choice`, `input`, `coupon`, `payment-method` 중 하나다. 명세에 결제 단계를 적어도 승인 권한은 생기지 않는다. 폰·Windows의 자동 결제 클릭은 기존 사람 채널의 승인 1회에 결제 탭 1회만 허용하는 코드 경계를 통과해야 한다. Mac Chrome의 최종 결제 버튼은 당사자가 직접 누른다.

실행 대상 규칙: exe 설치·공동인증서 친화 사이트는 `windows`; Mac 브라우저에서 되는 사이트는 `browser`.

Windows 패키지는 `"launch": { "search": "https://www.hometax.go.kr/", "target": "windows" }`처럼 지정한다. URL 규칙은 `browser`와 같고 `collection`을 함께 지정할 수 없다. 키오스크 카드에 **Windows에서 열기**가 표시되고, 외부 에이전트는 `windows_open(app: ID)`으로 연다. `phone_open`·`phone_installed`·`run_combo`는 거부하고, `browser_open(app: ID)`은 `Windows 패키지 · windows_open` 힌트로 거부한다. Windows의 결제 클릭은 기존 `confirm_payment` 승인 1회 · `windows_click` 1회 코드 경계를 따른다.

Mac 웹사이트 패키지는 `"launch": { "search": "https://www.eais.go.kr/", "target": "browser" }`처럼 지정한다. 사용자명·비밀번호를 URL에 포함할 수 없으며 `file:`, `javascript:` 같은 주소는 거부한다. 웹 패키지는 폰 수집용 `collection`을 함께 지정할 수 없다. 키오스크의 카드 상세 화면에 **Mac Chrome에서 열기**가 표시되고, 외부 에이전트는 `browser_open(app: ID)`으로 같은 주소를 연다. Chrome이 없으면 설치 안내를 반환하며 다른 브라우저나 Windows로 자동 전환하지 않는다. `browser_open(url: HTTP(S) 주소)`는 미등록 웹사이트도 열 수 있다.

브라우저 열기는 탐색 기능이다. 뽀미 자체는 Mac 브라우저의 페이지 읽기·입력·로그인·DOM 조작·자동 재생을 제공하지 않는다. 후속 작업은 호스트 에이전트의 브라우저 도구 또는 사용자가 열린 Chrome에서 진행한다. 웹 패키지를 `phone_open`, `phone_installed`, `run_combo`에 주어도 폰에서 검색하거나 재생하지 않는다. Mac에서 진행할 수 없는 단계를 확인한 뒤의 명시적 대안으로 `windows_open(app: ID)`를 사용할 수 있다.

Mac 브라우저의 일반 탐색·로그인 진입·결제 전 준비는 이어갈 수 있지만, 최종 결제 버튼과 결제 인증은 당사자가 직접 처리한다. `browser_open` 이후 외부 브라우저 클릭에는 뽀미의 승인 코드 경계가 없다. 따라서 `confirm_payment` 승인이 있어도 Mac 브라우저의 최종 결제를 자동 클릭하지 않으며, 패키지에도 승인 후 자동 결제를 지원한다고 표시하지 않는다. Windows에서는 기존 `confirm_payment` 승인 1회에 `windows_click` 결제 클릭 1회의 코드 경계를 유지한다.

`collection`이 필요한 앱은 `key`, `account`를 지정한다. `homeLabel`, `expand`, `list`, `tx`, `txpage`, `home`은 선택 문자열이며 `scrollY`는 0~1 사이의 선택 숫자(기본 0.5)다. 여기에는 일반적인 계정 종류와 화면 선택자만 넣고 실제 계좌번호나 사용자 정보는 넣지 않는다.

아이콘은 PNG·JPEG·GIF·WebP·ICNS·TIFF를 지원한다. 안내는 `.md`다. 파일 경로는 패키지 내부의 상대 경로만 허용하며 절대 경로, 빈 경로 조각, `.`·`..`, 역슬래시, 콜론, 제어문자를 허용하지 않는다. 심볼릭 링크도 따라가지 않는다. 아이콘 출처 URL은 안내용이며 가져오기 과정의 다운로드 명령이 아니다.

## 절차와 실행 증거

`guide.md`는 사람이 검토하고 외부 에이전트가 읽는 앱 절차다. 콤보와 일반적인 화면 동작을 적을 수 있다. 공통 안전 규칙은 `common.md`에서 함께 읽는다. 자격 증명, 개인정보, 실제 금액·예약번호·사용자 이름은 공개 패키지에 넣지 않는다.

새 패키지를 가져오면 앱 카드·작업 명세·앱 열기에 필요한 검색어를 사용할 수 있다. 명세의 단계 목록만으로 자동 조작 절차가 만들어지지는 않는다. 실제 콤보 재생에는 해당 앱에서 기록한 로컬 발자국과 화면 지문이 필요하며, 기록이 없거나 화면이 다르면 기존 안전 경계에서 멈춘다.

재생 성공·실패는 앱의 안정 ID에 연결된 발자국에 저장하고, 현재 패키지 버전에서 얻은 재생 횟수를 구분한다. 재생 성공 표시는 기록된 동작이 재생됐다는 의미이며, 선언한 모든 작업이나 예약·구매의 전체 과정이 검증됐다는 뜻이 아니다. 이전 형식의 성공 기록도 현재 버전의 재생 검증으로 올리지 않는다.

명세 단계별 판정은 별도의 **검증 장부** `playbooks/<id>.verify.jsonl`에 쌓인다. 한 줄은 `{app, version, capability, step, outcome, actual?, note?, at, by}`이고 `outcome`은 `ok`(명세대로 됨) · `changed`(실제 라벨·경로가 다름, `actual`에 적는다) · `fail`(진행 불가) 셋뿐이다. 에이전트는 검증 작업에서 단계마다 MCP 도구 `verify_step(app, capability, step, outcome, actual?, note?)`을 부르고, 도구는 명세에 있는 기능·단계만 받는다. 판정은 패키지 버전에 묶인다: `read_playbook`·`list_playbooks`의 `verification`은 현재 버전에서 단계마다 마지막 판정 하나와 `ok`·`changed`·`fail`·`unverified` 수를 주고, 다른 버전의 판정은 `stale`로만 센다. 개인정보·금액·예약번호는 판정에도 적지 않는다.

검증 현황은 개발자 페이지에서 본다: 루트 `storybook/`의 **개발자 › 플레이북 검증** 스토리가 번들 카탈로그와 이 Mac의 `data/playbooks/`(설치 패키지·발자국·검증 장부)를 그대로 읽어, 대상/패키지/기능별 미검증 단계 수 트리맵과 표, 고른 기능의 명세 나무(판정 ✓△✗)·발자국 그래프를 보여 준다.

사용자의 실제 입력값과 화면 기록은 공개 매니페스트로 편입하지 않는다. 공개 패키지의 절차를 바꿀 때는 버전도 올리고 다시 검증한다. 버전별 재생 카운터가 패키지 내용 자체를 해시로 검증하는 것은 아니므로, 같은 버전의 내용을 바꾼 뒤 기존 성공 기록을 새 내용의 검증 결과로 주장해서는 안 된다.

## 허브 응답과 배포

`GET /api/playbooks`는 `{schemaVersion:1,playbooks:[...]}`를 반환한다. 각 항목에는 원본 `manifest`, 안내 문자열 `guide`, 공통 안내 문자열 `commonGuide`, 정적 파일의 상대 URL `assets`가 있다. `GET /api/playbooks?id=sample-app`은 같은 항목 하나를 반환하며 표시 이름과 별칭으로도 조회할 수 있다.

```json
{
  "manifest": "위 manifest.json 원문에 해당하는 JSON 객체",
  "guide": "# 새로운 앱\n…",
  "commonGuide": "# 공통\n…",
  "assets": {
    "manifest": "/catalog/sample-app/manifest.json",
    "guide": "/catalog/sample-app/guide.md",
    "icon": "/catalog/sample-app/icon.png",
    "commonGuide": "/catalog/common.md"
  }
}
```

위 응답 예시에서 `manifest` 설명 문자열은 실제 응답에서는 JSON 객체다. 아이콘이 없는 패키지에는 `assets.icon`도 없다. API에는 로컬 실행 증거를 포함하지 않으며 패키지 게시용 POST를 제공하지 않는다. 현재 앱 가져오기는 로컬 폴더를 대상으로 하고, 허브에서 자동 설치하는 클라이언트는 별도 작업이다.

`cd hub && npm run deploy`는 원본 검증 → `hub/catalog/` 생성 → 기존 Vercel `ppomi` 프로젝트 배포 순서로 실행한다. 복사 대상은 검증된 `manifest.json`·참조된 안내·아이콘·`common.md`뿐이다. 로컬 `.jsonl`, DB, 화면, `.env` 같은 임의 파일은 복사하지 않는다. 앱 카탈로그 내용 변경은 원본 패키지에서 한 번만 하고 앱과 허브에 같은 데이터로 전달한다.
