# 가족용 앱의 웹 화면 업데이트

가족 기기에는 Mac·iPad·Android 앱 바이너리를 직접 설치한다. 이 바이너리에 고정한 HTTPS 주소와 공개키로 서명된 웹 파일을 받고, 검증한 파일만 앱 내부 저장소에서 제공한다. 브라우저 사이트를 열거나 원격 URL에 네이티브 브리지를 연결하지 않는다. 서버 주소와 서명키가 정해지기 전에는 업데이트가 꺼져 있고 기본 번들로 동작한다.

이번 변경에는 실제 운영 서명키나 배포 서버를 연결한 설정을 넣지 않았다. 아래 주소·릴리스명·sequence는 설정 절차의 예시이며, 샘플 패키지와 테스트 fixture는 가족 기기에 배포할 릴리스가 아니다. 네이티브 앱 설치, 서버 업로드, 실제 기기에서의 다운로드·화면 전환 확인도 별도로 진행해야 한다.

## 처음 배포하는 순서

1. 저장소 밖에 운영 서명키를 만들고 패키지를 제공할 HTTPS 주소를 정한다.
2. 세 플랫폼의 `preview` 설정을 각각 작성·검증한다. 공통 웹 자산을 빌드한 다음, 이 설정을 포함한 네이티브 앱을 빌드해 본인 기기에 직접 설치한다.
3. 검토한 같은 소스로 플랫폼별 `preview` 패키지를 서명하고, 각 고정 주소에 업로드한다. 채널·플랫폼마다 이전에 배포한 값보다 큰 sequence를 사용한다.
4. 본인 기기에서 업데이트를 확인하는 화면을 열어 다운로드할 시간을 준다. 다운로드 중에는 기존 화면을 사용하고, **앱 프로세스를 완전히 종료한 뒤 다시 실행해** 새 화면을 확인한다. Mac 창 닫기나 Android Activity 재생성만으로는 새 프로세스가 시작되지 않는다.
5. 실제 기기에서 대화·기록 화면과 실패 복구를 확인한다. 통과한 같은 소스를 `family` 채널로 다시 서명하고 가족 주소에 올린다. 가족 기기에는 `family` 설정이 포함된 네이티브 앱을 처음 한 번 직접 설치한다.

이후 웹 변경은 3~5단계를 반복한다. 공개키·배포 주소·채널 또는 네이티브 기능을 바꾸려면 설정과 기능을 포함한 새 바이너리를 설치한다. 다운로드 진행률이나 수동 갱신 버튼은 현재 구현에 포함하지 않는다.

## 바뀌는 범위

| 범위 | 전달 방식 |
| --- | --- |
| Mac·Android 공통 대화 UI, 웹에 포함된 공개 플레이북 | 서명된 웹 패키지 |
| iPad 기록 화면 셸, 공통 정적 HTML/CSS/JS 템플릿 | 서명된 웹 패키지 |
| 서버의 모델 설정·응답 처리 | 서버 배포 |
| 네이티브 도구·권한·암호화·회계 계산·저장 형식·새 브리지 기능 | 새 바이너리 직접 설치 |

공통 플레이북은 `agent/src/generated/playbooks.json`을 빌드할 때 `Agent/app.js`에 포함한다. 패키지의 루트 `playbooks.json`은 같은 공개 카탈로그를 검토할 수 있도록 함께 서명한 자료다. 별도로 내려받은 JSON이 Mac 네이티브 `PlaybookCatalog`를 덮어쓰는 기능은 없다. Swift가 HTML에 삽입하는 회계 데이터와 계산 로직은 이 배포로 바뀌지 않는다. 서명된 JS는 기존 네이티브 도구를 사용할 수 있으므로, 네이티브의 세션·사용자 권한·main-frame 검증은 계속 적용한다.

## 두 채널과 첫 바이너리

`preview`는 본인 기기에서 시험하고 `family`는 확인된 결과를 가족에게 전달하는 채널이다. 채널·공개키·주소는 앱 리소스의 `Updates.json`에 고정한다. 앱 화면이나 원격 manifest로 변경하지 않는다. `updates/Updates.example.json`은 복사 후 실제 값으로 채울 형식 예시이며 활성 설정이 아니다. 테스트 fixture 공개키를 실제 앱에 넣지 않는다.

설정 필드는 정확히 다음 네 개다.

```json
{
  "formatVersion": 1,
  "endpoint": "https://updates.example.org/ppomi/preview/macos.json",
  "publicKey": "실제 공개키의 base64",
  "channel": "preview"
}
```

플랫폼별 마지막 파일명은 `macos.json`, `ipados.json`, `android.json`이다. 가족 바이너리의 경로는 `family/<platform>.json`이고 `channel`도 `family`여야 한다. 인증정보·query·fragment 없는 HTTPS 주소를 사용한다. 계정 비밀이나 개인 기록을 이 공개 웹 경로에 올리지 않는다. 개인 기록은 기존 암호화 동기화 경로를 그대로 사용한다.

Mac은 `PPOMI_UPDATES_CONFIG`에 설정 파일의 경로를 지정해 `scripts/make-app.sh`를 실행하면 서명할 앱의 `Contents/Resources/Updates.json`에 넣는다. iPad는 로컬 `iPad/Updates.json`을 리소스로 포함한다. 이 실제 설정 파일은 Git에서 제외한다. Android는 Gradle에 `-PfamilyUpdatesConfig=/절대경로/Updates.json`을 전달하면 생성된 앱 자산에 포함하고, 이 옵션을 생략한 빌드는 설정을 제거해 업데이트를 끈다. 각 플랫폼의 실제 바이너리를 다시 설치해야 이 설정이 적용된다.

설정을 넣기 전에 `node scripts/family-update.mjs validate-config --config /설정/Updates.json`으로 검증한다. 성공 결과에는 공개키 값이 출력되지 않는다.

## 서명키와 패키지 만들기

저장소 루트에서 Node로 실행한다. 개인키는 저장소 밖의 명시적 절대 경로에 한 번 만들고 별도로 보관한다. 명령은 기존 키를 덮어쓰지 않으며 자동으로 생성하거나 배포에 사용할 키를 선택하지 않는다.

```sh
mkdir -p "$HOME/.ppomi-release"
node scripts/family-update.mjs keygen --key "$HOME/.ppomi-release/signing.pem"
```

개인키 파일은 권한 `0600`의 PKCS#8 PEM이며 공개키는 옆의 `signing.pem.public-key.txt`에 기록한다. 공개키 형식은 P-256 비압축 X9.63 점 65바이트의 표준 base64다. 서명은 ECDSA SHA-256, DER 형식이다. 운영 키를 잃으면 기존 앱들이 받아들일 수 있는 패키지를 새로 만들 수 없으므로 키를 안전하게 백업한다. 키 교체는 새로운 공개키를 포함한 바이너리를 설치해서 진행한다.

먼저 공통 agent를 빌드한다. 기존 프로젝트 프런트엔드 빌드 명령을 사용하면 공개 플레이북·테마 생성, TypeScript 검사, Vite 빌드와 Mac·Android 자산 복사가 함께 실행된다. 일반적인 명령은 다음과 같다.

```sh
npm --prefix agent run build
node --test scripts/family-update.test.mjs
```

빌드 결과를 검토하고 플랫폼별 패키지를 만든다. 다음 명령은 로컬 산출물만 만들며 업로드하지 않는다.

```sh
node scripts/family-update.mjs pack --platform macos --channel preview --release 2026-09-11.1 --sequence 1 --key "$HOME/.ppomi-release/signing.pem" --out /tmp/ppomi-preview/macos.json
node scripts/family-update.mjs pack --platform ipados --channel preview --release 2026-09-11.1 --sequence 1 --key "$HOME/.ppomi-release/signing.pem" --out /tmp/ppomi-preview/ipados.json
node scripts/family-update.mjs pack --platform android --channel preview --release 2026-09-11.1 --sequence 1 --key "$HOME/.ppomi-release/signing.pem" --out /tmp/ppomi-preview/android.json
node scripts/family-update.mjs verify --package /tmp/ppomi-preview/macos.json --public-key "$HOME/.ppomi-release/signing.pem.public-key.txt" --platform macos --channel preview --after-sequence 0
```

`pack`은 임의 디렉터리를 받지 않는다. `Ppomi/Sources/Ppomi/Web`의 정적 파일 및 생성된 공개 플레이북만 읽고, iPad는 `iPad/Web` 파일을 같은 이름 위에 덮어쓴다. 심볼릭 링크를 거부하고 허용된 확장자만 포함한다. `Agent/index.html`의 로컬 script/CSS와 CSP, 생성된 `Agent/app.js`의 `updateReady`, 비어 있지 않은 CSS와 카탈로그를 확인하므로 프런트엔드 빌드가 필요하다. 산출물은 기존 파일을 덮어쓰지 않는다. 이 검사는 코드 검토를 대신하지 않는다. 생성한 HTML/JS/JSON에 개인 정보가 없는지도 배포 전 확인한다. 번들 폰트 등의 라이선스 고지는 기존 앱과 배포 자료에 계속 포함한다.

HTTPS 서버에는 검증한 패키지를 해당 채널·플랫폼의 고정 주소에 원자적으로 교체해서 올린다. 가능하면 다운로드에 `Content-Length`를 제공하고 갱신 확인이 오래 지연되지 않도록 캐시를 설정한다. 미리보기 검증을 마친 같은 소스를 `--channel family`로 다시 서명해 가족 주소에 올린다. 미리보기 패키지의 JSON을 수정해서 승격하면 서명 검증에 실패한다.

## 서명 및 호환성 규약

외부 JSON은 정확히 `{ "payload": "...", "signature": "..." }`다. payload는 UTF-8 JSON 바이트의 표준 base64이고 signature는 **그 바이트 그대로** 서명한 DER 서명의 표준 base64다. 검증 전에 JSON을 재직렬화해서 서명 대상을 만들지 않는다.

payload에는 정확히 아래 필드만 들어간다.

```json
{
  "formatVersion": 1,
  "release": "2026-09-11.1",
  "sequence": 1,
  "channel": "preview",
  "platform": "macos",
  "bridgeVersion": 1,
  "minNativeBuild": 1,
  "capabilities": ["agent.v1", "records.v1"],
  "files": [{ "path": "Agent/index.html", "sha256": "64자리 소문자 16진수", "data": "파일 바이트 base64" }]
}
```

- `release`: `^[a-z0-9][a-z0-9._-]{0,63}$`; `sequence`: 1부터 2147483647까지 정수.
- 현재 호스트와 publisher는 format 1, bridge 1, native build 1을 지원한다. 필요한 capability는 Mac `agent.v1`+`records.v1`, Android `agent.v1`, iPad `records.v1`이다.
- 파일 최대 512개, 파일당 8 MiB, 전체 디코딩 파일 16 MiB, 외부 JSON 32 MiB다.
- 경로는 최대 240자의 상대 경로이며 `/`로 나눈 각 부분은 `[A-Za-z0-9_-][A-Za-z0-9._-]*`다. 절대 경로·역슬래시·`.`/`..` 부분·percent·query·fragment는 허용하지 않는다. 대소문자를 무시한 중복과 파일/디렉터리 충돌도 거부한다.
- 확장자는 `html js css json woff2 png jpg jpeg svg webp`만 허용한다. 파일에는 정확히 `path`, `sha256`, `data`만 있다.
- Mac·Android 공통 필수 파일은 `Agent/index.html`, `Agent/app.js`, `Agent/app.css`, `playbooks.json`이다. Mac은 `timeline.html`, `evidence.html`, `tokens.css`, `theme.css`, `simple.css`, `evidence.js`, `playbook.js`, `facts.js`, `journal.js`, `schedule.js`, `verify.js`도 요구한다. iPad 필수 파일은 `pad.html`, `pad.js`, `pad.css`, `timeline.html`, `tokens.css`, `theme.css`, `journal.html`, `journal.js`다.

서명뿐 아니라 플랫폼·채널·호환성·필수 파일·모든 파일 해시와 용량을 확인하고 저장한다. 앱이 기억한 sequence 이하의 패키지는 다시 적용하지 않는다. 옛 화면으로 되돌리려면 **이전 파일을 더 큰 sequence로 다시 서명**한다. 서버에 옛 JSON을 다시 올리는 방식은 재전송 공격과 구분할 수 없으므로 허용하지 않는다. 앱 내부의 시작 실패 복구는 별도이며 사용자 장부를 되돌리지 않는다.

## 화면 준비 확인

Mac·Android bootstrap은 `nativeBuild`, `bridgeVersion`, `webRelease`, `capabilities`를 포함한다. React가 셸을 실제로 마운트하고 bootstrap 검증을 끝낸 뒤 문서당 한 번 `updateReady`에 `{ "bridgeVersion": 1 }`을 보낸다. **네이티브의 성공 응답까지 받은 다음에만** 텍스트·대기열·발신·OS에서 이미 받은 통화가 세션을 시작할 수 있다. 준비 확인 실패나 호환되지 않는 bootstrap 갱신은 해당 문서의 세션 시작을 차단하며, 재시도에서 오래된 bootstrap을 다시 사용하지 않는다. 새 필드가 전혀 없는 기존 호스트에는 지원하지 않는 준비 확인을 보내지 않는다.

iPad 셸은 탭과 초기 기록 iframe을 만든 뒤 main-frame에서 `ppomiUpdateReady`에 같은 객체를 보낸다. 기록 iframe에는 `sandbox="allow-scripts"`를 적용하므로 증빙 HTML이 부모 셸 문서에 접근할 수 없다. 정적 폰트 응답에만 CORS 헤더를 제공하고 기록·HTML·JSON 응답에는 제공하지 않는다. 준비 확인은 화면 셸의 시작 확인이며, 네트워크에서 기록을 모두 내려받았다는 뜻은 아니다.

## 적용과 복구 시점

백그라운드 다운로드는 프로세스당 한 번 요청한다. Mac은 GUI 앱 시작, iPad는 기록 뷰 준비, Android는 대화 WebView 구성에서 확인을 시작한다. 완료된 패키지는 **다음 프로세스 시작(cold launch)**에 활성화하며 현재 문서의 파일을 중간에 교체하지 않는다. 검증 실패나 오프라인 상황에서는 이미 사용 가능한 버전 또는 기본 번들을 유지한다.

| 플랫폼 | 새 화면 초기화 실패 시 현재 실행 | 다음 프로세스 시작 |
| --- | --- | --- |
| Mac | 20초 준비 확인 제한 또는 로드 실패 후 재실행 안내. 실패한 대화 화면은 같은 프로세스에서 세션을 다시 시작할 수 없다. | 이전에 준비 확인을 마친 버전으로 복구. 없으면 앱 기본 번들 사용. |
| Android | 30초 준비 확인 제한 또는 로드 실패 후 안내. 사용할 수 있는 WebView에는 브리지 없는 안내 화면을 표시하고 실패 버전의 세션 재시작을 막는다. | 이전에 준비 확인을 마친 버전으로 복구. 없으면 APK 기본 번들 사용. |
| iPad | 준비 확인 전의 20초 제한 또는 초기 로드 실패 시 진행 중인 기록 요청을 취소하고 **즉시 앱 기본 번들로 전체 기록 뷰를 다시 연다**. 현재 실행에서 이전 다운로드 버전으로 전환하는 방식은 아니다. | 저장된 이전 확정 버전으로 복구. 없으면 앱 기본 번들 사용. |

시험 버전에서 준비 확인을 받지 못한 채 프로세스가 종료된 경우도 다음 실행에서 복구한다. 실패 중 다른 새 패키지를 받아 둔 경우에는 먼저 이전 정상 버전으로 복구하고, 그 후보는 다음번 실행에서 시험한다. 복구는 웹 파일 선택을 바꾸며 장부·암호화 기록을 되돌리지 않는다. 준비 확인은 시작 단계의 검사이므로 이후의 모든 화면 오류나 작업 결과까지 판정하지는 않는다.

Mac의 MCP·수집·검증 등 화면 없는 명령은 업데이트 상태를 바꾸거나 다운로드하지 않고 앱 기본 템플릿을 사용한다. 이런 작업이 실행 중인 GUI의 시작 확인을 대신하거나 다음 업데이트를 소비하지 않도록 분리한다.

## 검증 자료

`scripts/family-update.test.mjs`는 실제 P-256 서명, 변조, 잘못된 키, 재전송, 플랫폼/채널 혼동, 호환성, 경로 탈출·충돌, 용량 제한을 검사한다. `agent/src/update-readiness.test.ts`는 기존 bootstrap 호환성, 네이티브 응답을 기다리는 세션 순서, 준비 확인 실패, 갱신 후 오래된 bootstrap의 재사용 방지를 검사한다. `tests/updates/`는 Swift·Android·Node가 함께 검증하는 테스트 전용 서명 fixture다. 개인키는 보관하지 않았으며 fixture는 실행할 앱 화면이 아니다.

검증 결과는 해당 실행의 로그와 함께 확인한다. 프런트엔드·서명 검증 통과만으로 네이티브 설치나 실제 WebView의 전체 동작까지 확인된 것으로 취급하지 않는다. 이 작업에서 발견한 테스트 실패와 실제 기기 검증 여부는 별도로 남기고, 해결하지 않은 실패가 있는 상태를 가족 배포 완료로 표시하지 않는다.

자동 머지·배포·가족 앱 설치는 이 스크립트의 역할에 포함하지 않는다. 각 워크트리 변경을 통합하고 검증한 한 릴리스를 채널에 올린다.
