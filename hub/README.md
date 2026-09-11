# ppomi-hub

뽀미 로그인 웹 홈·앱 다운로드·공개 플레이북 카탈로그와 발자국 공유 API. Vercel 정적 파일 + 서버리스 + KV로 구성하며 런타임·명령은 [package.json](package.json), 라우팅·보안 헤더는 [vercel.json](vercel.json)에서 관리한다.

[운영 웹 홈](https://ppomi.muilyzz.com/)의 로그인은 적용되어 있다. 이 워크트리의 새 기록 화면·Mac 바이너리 배포는 보류 중이며, 공통 UI가 main에 통합된 뒤 연결한다. 로컬 구현을 운영 적용 상태로 간주하지 않는다.

## 카탈로그·발자국 API

| 메서드 | 경로 | 역할 |
|---|---|---|
| GET | `/api/playbooks` | 공식 카탈로그. `{schemaVersion:1, playbooks:[{manifest,guide,commonGuide,assets}]}`. 앱 UI와 MCP가 사용하는 원본 패키지에서 생성 |
| GET | `/api/playbooks?id=` | 안정 ID·앱 이름·별칭으로 하나 조회. 같은 `{manifest,guide,commonGuide,assets}`. 없으면 `404` |
| POST | `/api/footprints` | 발자국 게시. 검사 통과 → 저장, `201 {id}`. 중복 id `409`, 분당 10건 초과 `429` |
| GET | `/api/footprints?app=&since=&tier=` | 목록. 격리 제외, verified 등급 먼저, `verified.ok` 내림차순, 최대 200 |
| POST | `/api/verify` | `{id, ok, publisher, appVersion?, step?}` → 검증 카운터 갱신. 같은 publisher 는 하루 1회만 반영(`counted:false`) |
| POST | `/api/report` | `{id, reason}` → 신고 수 +1, 1 이상이면 `quarantined:true` |
| GET | `/api/export?app=` | 그 앱의 발자국을 `data/playbooks/<앱>.md` 형식 텍스트로 (`# 앱` / `콤보: …` / `- 날짜 버릇`) |
| POST | `/api/telemetry` | 앱 텔레메트리(옵트인). `{ts, event, fields}` — `fields` 키는 `name tool ok ms app step reason` 안에서만, 값은 40자 이하 문자열·bool·숫자. `tm:<event>:<name|tool>:<ok|fail>` 카운터 +1 후 `204`. 앱 기본 주소가 이 경로다(`PPOMI_TELEMETRY_URL` 로 바꿈) |

## 플레이북 카탈로그

원본은 `Ppomi/Sources/Ppomi/Catalog/<id>/`의 `manifest.json`, 안내 Markdown, 공식 아이콘이다. 공통 안전 절차는 같은 카탈로그의 `common.md`에 있다. [패키지 명세](../docs/playbook-format.md)에 데이터 구조와 로컬 가져오기 방법을 설명한다.

`npm run sync:catalog`는 [생성 스크립트](../scripts/sync-catalog.mjs)로 원본을 검증하고 `hub/catalog/`를 만든다. 생성물을 직접 수정하지 않는다. `npm run deploy`도 이 단계를 실행하므로 원본에 공개할 패키지만 포함되어 있는지 먼저 검토한다.

카탈로그 API는 읽기 전용이다. 공개 카탈로그는 검토한 원본만 배포하며, 로컬에서 가져온 패키지를 자동 게시하지 않는다. 실제 실행 성공·실패, 화면 지문, 개인별 입력은 이 응답에 섞지 않는다. 기존 `/api/footprints`의 명시적인 공유·검증 흐름은 별도로 유지한다.

## 발자국 레코드

```json
{
  "id": "fp-abc123", "app": "여기어때", "appVersion": "5.2.0",
  "glyph": "⊙", "target": "모든 객실 보기",
  "fingerprintBefore": ["숙소", "상세", "모든", "객실", "보기"],
  "fingerprintAfter": ["객실", "목록", "예약하기"],
  "note": "객실 목록은 아래로만 스크롤된다.",
  "publisher": "<ed25519 공개키 raw 32바이트 base64>",
  "sig": "<ed25519 서명 base64>",
  "createdAt": "2026-09-05T01:00:00.000Z",
  "verified": { "ok": 0, "fail": 0, "lastOk": "…", "lastFail": "…", "versions": [] },
  "tier": "community", "quarantined": false
}
```

- 기호: `▶` 앱 열기 `⊙` 탭(정규식, `|` 택일) `⌨` 입력 `↓` 스크롤 뒤 탭 `⎋` 닫기 `👤` 사용자 차례 `🎟` 쿠폰 `🔍` 결제수단 `✋` 승인 `📝` 기록
- 서명 대상: `sig`·`verified`·`tier`·`quarantined` 를 뺀 나머지를 키 정렬 JSON 으로 직렬화한 바이트. 클라이언트가 보낸 `verified`/`tier`/`quarantined` 는 무시하고 서버가 채운다.
- `tier: "verified"` 는 환경변수 `VERIFIED_PUBLISHERS`(공개키 콤마 목록)에 있는 publisher 에만 붙는다. 없으면 전부 community.

## 검증과 저장

게시 자료에 개인정보나 결제 실행 단계를 포함하지 않는 것이 원칙이다. 허용 필드·정규식·길이 제한·서명 검사는 [validate.js](lib/validate.js)와 [검증 사례](test/validate.test.js), 승인에서 끝나는 내보내기는 [export.js](lib/export.js)를 기준으로 한다.

저장 키·중복·호출 제한은 [store.js](lib/store.js)에서 관리한다. 로컬 테스트는 메모리 저장소를 쓸 수 있지만, 운영 Vercel에는 `KV_REST_API_URL`과 `KV_REST_API_TOKEN`이 필요하다. 운영에서 메모리 저장소로 대체하면 인스턴스마다 기록이 유실되므로 시작을 거부한다.

## 실행

```sh
npm install && npm test        # node --test
npm run sync:catalog           # 개발용 정적 카탈로그 생성
npm run prepare:downloads -- --offline  # 현재 Mac/Android 다운로드 파일의 크기·SHA-256 검증
npm run deploy                 # 카탈로그 복사·다운로드 파일 준비 후 기존 ppomi 프로젝트 / muilyzz 팀에 배포
```

위 명령은 `hub/`에서 실행한다. 배포 대상은 기존 `ppomi` 프로젝트·`muilyzz` 팀이며 git 자동 배포는 꺼져 있다. 선택 환경변수 `VERIFIED_PUBLISHERS`는 공식 게시자 공개키 목록이다. 배포 제외 파일은 [.vercelignore](.vercelignore)에서 관리한다. 현재처럼 배포를 보류한 작업 사본에서는 배포 명령을 실행하지 않는다.

[downloads.json](downloads.json)이 배포할 바이너리의 파일명·크기·해시를 정한다. [준비 스크립트](../scripts/prepare-downloads.mjs)는 누락된 파일을 운영 사이트에서 받으므로, 아직 공개하지 않은 새 바이너리는 `hub/releases/`에 직접 준비해야 한다. `--offline`으로 다운로드 없이 준비 상태를 검증한다. 이 과정은 바이너리를 빌드하거나 설치하지 않는다.


## 로그인 웹 홈

`/`는 뽀미 작업대(대화 + 내 기록), `/download`는 설치 파일 안내다. 화면은 Mac·Android 앱과 같은 공통 React `Workbench`/`ChatPanel`이다: `agent/`에서 `npm run build:web`으로 만든 [번들](web/workbench/)을 [index.html](index.html)이 싣고, [home.js](web/home.js)는 브라우저 전용 계층 — Supabase 로그인, 기기 키·등록, 기록 세션, 샌드박스 프레임 렌더러 — 을 만들어 `mountWebWorkbench(root, host)`에 넘기는 접착제만 남았다. 토큰·기기 키·평문 기록은 host 상태에 들어가지 않는다.

텍스트 대화는 앱과 같은 에이전트 서버([config.js](web/config.js)의 `AGENT_ENDPOINT`)로 간다. 브라우저는 Supabase 세션 토큰과 `X-Ppomi-Device`(이 브라우저의 등록 기기)를 붙여 `/v1/session`·`/v1/responses`만 부르고, 모델·Gateway 키는 그 서버에만 있다. 대화 원문은 클라이언트가 `ppomi_transcript_*` RPC로 올리며 서버가 Vault 키로 봉한다. Realtime은 암호문 INSERT를 신호로만 쓰고, 이 브라우저는 복호화 RPC로 다시 읽어 합친다. 접근은 작업 공간 구성원 Auth/RLS이며 기기 승인이나 감싼 기록 키가 필요 없다. 서버 쪽 Origin 허용 목록은 [agent/server/README.md](../agent/server/README.md)를 따른다. 통화·기기 제어·기억 저장은 웹에 없고 화면과 지침이 그렇게 말한다. 번들을 다시 만들면 [service-worker.js](service-worker.js)의 캐시 버전을 올린다.

구현과 사용 예시는 다음을 기준으로 한다.

| 책임 | 구현 | 검증 사례 |
|---|---|---|
| 작업대 마운트·브라우저 계층 연결 | [home.js](web/home.js), [index.html](index.html), [workbench/](web/workbench/) | [화면 연동](test/web-home-lifecycle.test.js), [페이지·정책·번들 계약](test/web-workbench.test.js) |
| 로그인·공개 설정 | [auth.js](web/auth.js), [config.js](web/config.js) | [인증](test/web-auth.test.js) |
| 로그인 서버·응답 검증 | [auth-client.js](web/auth-client.js) | [토큰·사용자·통신](test/web-auth-client.test.js) |
| 기기 키 저장·기록 읽기 | [device-store.js](web/device-store.js), [records.js](web/records.js) | [기록](test/web-records.test.js), [조건부 조회](test/web-records-conditional.test.js) |
| 인증된 기록 통신 | [record-rpc.js](web/record-rpc.js) | [통신·취소·응답 제한](test/web-record-rpc.test.js) |
| 기록 응답·소유 범위 검증 | [record-protocol.js](web/record-protocol.js) | [메타데이터·버전·청크](test/web-record-protocol.test.js) |
| 연결·갱신·계정 정리 | [record-session.js](web/record-session.js) | [세션](test/web-record-session.test.js), [화면 연동](test/web-home-lifecycle.test.js) |
| 복호화·압축 해제 | [record-crypto.js](web/record-crypto.js), [lzfse.js](web/lzfse.js) | [암호화](test/web-records-crypto.test.js) |
| 대화 transcript·Realtime | [transcript-client.js](web/transcript-client.js), [transcript-protocol.js](web/transcript-protocol.js), [transcript-realtime.js](web/transcript-realtime.js), [transcript-session.js](web/transcript-session.js) | [payload 검증](test/web-transcripts-crypto.test.js), [세션·Realtime](test/web-transcript-session.test.js) |
| 격리 렌더링 | [record-views.js](web/record-views.js) | [화면 연동](test/web-home-lifecycle.test.js), [테마 계약](test/web-theme.test.js) |
| 공통 테마·토큰 | [home.css](web/home.css), [record-frame.css](web/record-frame.css), [frame-theme.js](web/frame-theme.js) | [테마 계약](test/web-theme.test.js) |

색·글꼴·글자 단·모서리는 Mac·Android·작업대와 같은 [tokens.css](web/vendor/tokens.css)(`agent/theme.json`에서 생성)만 쓴다. 라이트/다크는 시스템을 따르고 `html[data-theme]`로 강제할 수 있으며, 격리 프레임은 부모 문서의 명시적 `data-theme`만 URL 질의(`?theme=`)로 넘겨받는다. 홈 CSS에는 색 값이나 새 토큰을 두지 않는다(`web-theme.test.js`가 검사). 작업대 번들의 CSS는 `/web/vendor/Agent/fonts/`의 공유 글꼴을 가리킨다.

브라우저는 Mac의 키체인을 읽지 않고 독립된 기기 키를 사용한다. 렌더링 프레임에는 인증 토큰과 기기 키를 넘기지 않으며, 공개 앱 캐시에 개인 기록을 저장하지 않는다. 계정 전환 때 기다려야 하는 정리와 렌더러의 버퍼 수명 계약은 `record-session.js`의 주석과 사용 예시를 따른다.

웹 기기용 [서버 마이그레이션](../supabase/migrations/20260911020000_web_record_devices.sql)은 아직 운영에 적용하지 않았다. 이 권한 구분은 기존 계정 JWT와 기기 헤더에 기반하며, 기기 소유 증명을 추가하는 변경은 아니다. 위 검증은 `npm test`로 실행하며 로컬 테스트 통과와 운영 적용을 구분한다.

렌더러 생성은 저장소 루트의 `node scripts/sync-web-records.mjs`, LZFSE 재빌드는 `sh scripts/build-web-lzfse.sh`로 한다. 출처·버전은 각 스크립트와 [생성 출처 목록](web/vendor/sources.json)을 따른다. 정적 앱 파일을 바꿀 때는 [service-worker.js](service-worker.js)의 캐시 버전을 올린다. 로그인은 온라인 검증이 필요하며 새 worker는 기존 앱 창을 닫은 뒤 활성화된다.
