# 뽀미 공유 서버

맥과 Android가 공유하는 **작업 상태와 절차·규칙 문서의 최종본은 Supabase에 둔다.** 기기는 서버에 기록된 버전을 읽고, 실제 앱 제어는 각 기기의 뽀미가 수행한다. 현재 프로젝트는 서울 리전의 [ppomi](https://supabase.com/dashboard/project/nafutfqfbbmknzmyspus)다.

```text
Mac 에이전트 → Mac 뽀미 MCP → Supabase ← Android 뽀미
                                         └ 접근성 서비스 → 기기의 앱
```

공유 작업·기록 경로에서 두 앱은 Supabase에 HTTPS로 직접 연결하며 ADB 중계나 Mac의 상시 실행이 필요하지 않다. 새 음성 에이전트는 별도의 Vercel API에서 Realtime 임시 키를 발급받고, AI가 고른 기억만 암호화해 Supabase에 저장한다. 대화 원문은 이 SSOT에 넣지 않는다. [음성 에이전트 구조](../agent/README.md)를 참고한다.

## 서버와 기기의 역할

| 대상 | 최종 확정 위치 | 기기에 남는 것 |
|---|---|---|
| 공유 작업의 요청·실행 기기·상태 | 서버 `ppomi_runs` | 표시용 캐시, 실행 중인 작업 기록 |
| 공유 작업의 상태 변경 이력 | 서버 `ppomi_run_events` | 아직 전송하지 못한 상태 이벤트 |
| 공용 절차·규칙 | 서버 `ppomi_documents` | 조회용 캐시 |
| 실제 화면 관찰·터치·입력 결과 | 실행 기기 | 접근성 트리, 화면 PNG, 상세 실행 기록 |

공유 작업을 만들면 `queued` 상태가 된다. 지정된 Android 기기에서 **이 기기에서 실행**을 눌러 시작하며, 현재 실행기는 기존 내장 테스트 절차를 사용한다. 도착한 요청이나 내려받은 문서가 자동으로 기기 동작을 실행하지 않는다. 서버 문서는 데이터로 표시하며, 코드나 실행 절차로 자동 적용하지 않는다.

공유 작업의 실행 기기는 생성 후 바뀌지 않는다. 해당 기기만 작업을 시작하고 실행 이벤트를 보고할 수 있다. Mac에서 Android 작업을 요청하거나 읽을 수 있지만, Mac의 인증으로 Android의 실행권을 가져올 수는 없다.

## 버전과 재시도

- 문서는 새로 만들 때 `expectedVersion=0`, 수정할 때 최근 읽은 `version`을 보낸다. 서버는 현재 버전과 일치하는 경우에만 저장하고 버전을 하나 올린다. 충돌하면 최신 내용을 읽고 변경을 검토해야 한다.
- 작업 상태도 예상 버전을 확인한 뒤 변경한다. 실행 이벤트는 추가만 가능하며 완료·실패·취소한 작업의 상태를 다시 수정할 수 없다.
- 작업 생성에는 고정 `runId`, 문서 변경에는 고정 `operationId`, 상태 보고에는 고정 이벤트 UUID를 사용한다. 같은 ID와 동일한 입력을 다시 보내면 원래 응답을 돌려주고, 다른 입력으로 ID를 재사용하면 거절한다.
- 네트워크 오류가 나면 새 ID를 만들어 같은 작업을 다시 실행하지 않는다. 특히 실행권 획득의 응답이 불명확하면 서버와 기기의 기록을 먼저 확인한다.

Android는 로컬 실행 기록과 전송 대기 이벤트를 같은 원자적 파일에 저장한다. 연결이 돌아오면 **상태 이벤트만** 기존 ID·순서로 재전송한다. 서버가 아직 받지 못한 기기 상태와 서버 확정 상태는 화면에서 구분한다. 앱 강제 종료나 제어 연결 해제 후 실제 터치·입력을 자동 재생하지 않으며, 결과가 불명확한 동작은 로컬 복구 검사에서도 막는다.

## 기기 인증과 범위

Mac·에뮬레이터·실기기는 서로 다른 Supabase Auth 계정과 기기 ID를 사용한다. 서버는 인증된 계정을 활성 기기에 연결하고, 같은 작업공간의 데이터만 읽도록 RLS를 적용한다. 변경은 제한된 RPC로만 허용한다. 작업공간은 기기 접근 경계이며 회계의 소유자·장부·개인/사업 `RecordScope`를 대신하지 않는다.

본인증을 Clerk로 옮기는 스파이크는 [Clerk 이전](clerk-migration.md)을 본다. Google PKCE·기기 이메일/비밀번호 경로는 슬라이스 2–3까지 유지한다. Clerk JWT는 신원이지 기록 암호 키가 아니다(MZZ-27).

연결 정보는 `url`, `publishableKey`, `email`, `password`, `deviceId` 다섯 필드다. Mac은 전용 Keychain 항목에, Android는 Android Keystore 키로 암호화한 저장소에 보관한다. 클라이언트에는 프로젝트 관리 키나 `service_role` 키를 넣지 않는다. 토큰·암호는 상태 화면과 MCP 응답에 표시하지 않으며, 인증 요청의 HTTP 리디렉션을 허용하지 않는다.

**기존 장부·거래·건강 기록·인증 프로필·로컬 작업 기록은 자동 업로드하지 않는다.** 현재 서버 도입은 공유 작업과 공용 문서부터 검증하는 단계다. 모든 뽀미 데이터를 서버 SSOT로 옮기는 작업, 기존 자료의 명시적 이전, 원본 증빙 공유, 범용 원격 실행은 별도 설계와 구현이 남아 있다. Android의 서버 조회는 앱 프로세스에서 주기적으로 수행하며, 푸시 알림이나 항상 실행되는 백그라운드 서비스까지 구현한 것은 아니다.

## 설정

저장소 루트에서 로그인된 Supabase CLI를 사용한다. 먼저 대상 프로젝트와 [마이그레이션](../supabase/migrations/20260909070000_ppomi_ssot.sql)을 확인해 적용한다.

```sh
supabase link --project-ref nafutfqfbbmknzmyspus
supabase db push --linked --dry-run
supabase db push --linked
python3 scripts/shared-server.py bootstrap --project-ref nafutfqfbbmknzmyspus
```

`bootstrap`은 대상 프로젝트가 CLI에 연결되어 있는지 확인한 뒤 작업공간과 기기 계정을 준비한다. 관리 키는 로그인된 CLI에서 메모리로만 읽는다. 기기별 연결 파일은 Git에서 제외된 `.ppomi/ssot/mac.json`, `emulator.json`, `fold.json`에 권한 `600`으로 저장한다. 이 파일의 내용을 로그나 대화에 출력하지 않는다.

새 기능을 포함해 빌드한 Mac 앱에 Mac 전용 연결 정보를 가져온다.

```sh
dist/Ppomi.app/Contents/MacOS/Ppomi --configure-shared .ppomi/ssot/mac.json
```

앱의 **설정 → 공유 서버 → 연결 확인**, 또는 MCP의 `shared_status`로 서버·작업공간·기기 ID를 확인한다. Android에서는 **설정 → 기기 연결 정보 가져오기 → 공유 서버 연결**에 해당 기기의 연결 정보를 가져온다. Mac 설정 파일을 Android에 재사용하지 않는다.

Mac MCP 도구는 `shared_status`, `shared_tasks`, `shared_task_create`, `shared_documents`, `shared_document_put`이다. 생성한 작업을 조회하는 것은 실행 요청을 반복하는 동작이 아니다.

## 검증

단위 검증은 Mac `SharedServerTests`, Android의 공유 작업 관련 테스트, [서버 SQL 회귀 검사](../supabase/tests/ppomi_ssot_regression.sql)로 구분한다. 원격 경로는 [검증 스크립트](../scripts/shared-server-test.py)로 가상 작업과 문서를 만들어 확인한다.

```sh
python3 scripts/shared-server-test.py seed --executor emulator
# Android 공유 탭에서 배정된 테스트 작업을 시작하고 기존 승인 단계를 완료한다.
python3 scripts/shared-server-test.py verify --executor emulator
```

실기기는 `--executor fold`를 사용한다. 기본 Mac 바이너리는 `dist/Ppomi.app/Contents/MacOS/Ppomi`이며 `--binary`로 명시할 수 있다. `seed`는 고정 ID의 검증 기록을 저장하고, 이미 기록이 있으면 중복 작업을 만들지 않는다. `verify`는 Mac MCP로 서버의 완료 상태와 이벤트를 다시 읽는다. 결과는 비공개 `.ppomi/ssot/proof-<executor>.json`에 남는다.

2026-09-09 실제 검증 결과:

- 서울 리전 `ppomi` 프로젝트에 전용 테이블 6개와 RPC를 적용했다. 기존 테이블의 스키마를 변경하지 않았다. CLI 직접 연결 지연으로 `supabase db query --linked --file`의 Management API 경로에서 트랜잭션을 적용했고, 공식 CLI v2.109.1의 43개 문장 그대로 이력을 등록했다. `supabase migration list --linked`에서 로컬·원격 `20260909070000` 일치를 확인했다.
- 원격 PostgreSQL에서 권한·RLS·버전 충돌·중복 요청·상태 전이 검사 **68개**가 통과했다. 테스트 자료는 트랜잭션으로 롤백했다.
- Mac 공유 기능·MCP 등록·실행 기록 검사 **27개**, Android 기존 단독 실행/복구/저장 검사 **8개**, 공유 설정·전송 대기열 검사 **4개**가 통과했다.
- 설정 화면을 열었다가 실제 뽀미 작업 화면으로 복귀하는 추가 회귀 검사도 통과했다. 접근성 설정은 별도 작업으로 열고, 작업 화면 복귀는 기존 자식 화면을 정리해 뽀미로 돌아온다.
- 설치된 Mac 앱의 MCP로 작업을 생성하고, 에뮬레이터 UI에서 실행·승인하여 테스트 앱에 실제 입력했다. 에뮬레이터 MCP의 ADB 포워드를 제거한 상태에서 Android 앱이 Supabase HTTPS로 직접 보고했고, 서버 완료 **버전 6**, 남은 전송 이벤트 **0개**를 확인했다. 같은 결과를 Mac MCP와 폴드의 공유 화면 캐시에서 읽었다.
- 폴드에도 0.4.0 디버그 앱을 설치하고 별도 기기 인증으로 서버 연결을 확인했다. 폴드의 이번 검증 범위는 공유 기록 조회이며, 이번 공유 작업의 실제 실행 기기는 에뮬레이터다.

테스트 작업 ID는 `733d711a-4743-466d-b97e-661a3d1707b9`다. 비공개 증거는 `.ppomi/ssot/proof-emulator.json`, `android-shared-workflow-proof.json`, `android-shared-workflow.png`, `fold-connection-proof.json`에 보관한다. 원본 스크린샷은 Supabase에 업로드하지 않았다.

Android 개발 설치의 연결 정보는 다음 명령으로 해당 기기에만 가져올 수 있다. 이 명령은 설정 가져오기를 시작하며, 연결 완료는 앱의 공유 탭에서 확인한다.

```sh
python3 scripts/shared-server.py configure-android --device emulator --serial emulator-5554
python3 scripts/shared-server.py configure-android --device fold --serial RFKL8093BGE
```

이미 완료한 작업은 재실행하지 않는다. 새 가상 작업에 대한 에뮬레이터 종단 검증에는 `scripts/shared-android-test.py --run-id UUID`를 사용한다. 이 스크립트는 실기기를 거부하며 기존에 활성화된 에뮬레이터 접근성 서비스만 테스트 프로세스 재시작 뒤 다시 연결한다.

## 상단 기록의 서버 확인 모드

`20260909100000_encrypted_records.sql`은 암호화 조각, 현재 버전, 변경 이력, 중복 요청 처리용 영수증을 추가한다. 기존 테이블과 수집 원본을 바꾸지 않는다. 서버는 작업공간·작성 기기·불투명한 기록 ID·버전·암호문 해시만 해석한다. 내용, 원본 파일명, 복호화 키, 평문 해시는 서버에 보내지 않는다.

Mac의 명시적 이전 명령은 `ledger`, `evidence`, `accounting`, `spatial`, `health`, `playbooks`를 각각 버전이 있는 자료로 게시한다. 장부에는 원본 스냅샷·거래 행과 기존 계산 규칙의 입력을 함께 보존한다. 회계·공간·생활 자료는 기존 공통 아카이브를 그대로 사용하며, 소유 구분·원본 근거·관측/추정 구분·수정 이력을 유지한다. 증빙은 상단 화면용 미리보기이며, 고해상도 스크린샷과 생활 기록 첨부 파일은 수집한 Mac에 남는다. 플레이북은 표시용 명세·사용법·실행 이력을 공유하고, 실행 패키지를 자동 설치하지 않는다.

자료는 Mac에서 LZFSE 압축 후 AES-256-GCM으로 암호화한다. 조각마다 무작위 nonce를 사용하고 작업공간·키 ID·기록 ID·버전·조각 순서를 인증한다. 무작위 복호화 키와 자료 ID 매핑은 Mac Keychain에만 저장한다. 새 디스크 캐시는 암호문과 버전 메타데이터이며 기존 SQLite·원본 파일을 암호화해 교체하는 기능은 아니다. Android 기기로 이 키를 전달하는 안전한 연결·복구 기능은 아직 제공하지 않는다.

```sh
dist/Ppomi.app/Contents/MacOS/Ppomi --migrate-records
dist/Ppomi.app/Contents/MacOS/Ppomi --verify-records
```

두 명령은 동일한 서명·번들 ID의 배포 앱으로 실행한다. 이전은 실제 서버 GET으로 모든 조각을 내려받아 복호화·대조한 뒤에만 `sharedRecordsEnabled.v1`을 켠다. 검증 명령은 빈 임시 캐시에서 다시 내려받고, 장부의 실제 타임라인 입력까지 원본과 비교한다. 출력에는 자료 종류·버전·일치 여부만 포함된다. 키와 금융/생활 값은 출력하지 않는다.

전환 뒤 상단 6개 화면은 확인된 서버 자료를 읽는다. 기존 수집기는 Mac의 원본 저장소에 기록하고, 별도의 단방향 게시자가 변경분을 서버에 확정한다. 저장 화면도 서버 확인 이후의 자료를 표시한다. 연결 오류 시 새 원본은 보존하고 마지막으로 확인한 서버 자료를 캐시로 표시하며, 상단에 반영 대기 상태를 알린다. 조회만으로 서버를 초기화하거나 로컬 값으로 대체하지 않는다. 기존 작성 기기만 CAS로 버전을 올릴 수 있고, 응답 유실은 같은 작업 ID·암호문으로 재시도한다. 원본 DB 경로 변경은 자동 병합하지 않는다.

이 단계의 서버 확정 범위는 **상단에 공유하는 기록 자료**다. 원본 수집 저장소와 기기 실행 상태 전체를 서버 전용 쓰기로 바꾼 것은 아니다. 키 복구/다른 기기 연결은 별도 단계이며, 현재 키를 잃으면 남아 있는 원본으로 다시 이전해야 한다.

검증: `SharedRecordVaultTests`는 암호문 변조·바인딩·응답 유실/재시작·중복 게시·버전 충돌·암호화 캐시·원본 행과 계산 결과 보존을 검사한다. `WebPageDOMTests`는 빈 캐시에서 읽은 암호화 서버 자료가 실제 WKWebView의 타임라인 값으로 표시되는 경로를 검사한다. [서버 회귀 검사](../supabase/tests/encrypted_records_regression.sql)는 별도 가상 기기/작업공간으로 34개 조건을 확인하고 모두 롤백한다.

2026-09-09 설치 검증: Mac 0.5.0을 기존 개발 서명으로 설치했다. 관련 Swift 검사 77개와 증빙 직렬화 안정화 후 화면/암호화 검사 10개가 통과했다. 원격 권한·CAS·불변 이력 검사 34개도 통과했으며 공식 CLI의 23개 SQL 문장으로 두 번째 마이그레이션 이력을 등록하고 로컬/원격 일치를 확인했다. 설치된 앱의 빈 캐시 검증에서 6종 자료가 모두 수집 원본과 일치했다. 타임라인 입력도 기존 계산 결과와 같으며, 실행 중인 상단에 `Supabase · 서버 v1`과 실제 그래프가 표시되는 것을 확인했다. 증빙은 키 순서를 고정해 재실행마다 불필요한 버전이 생기지 않도록 했다. 비공개 검증 결과는 `.ppomi/ssot/records-verification.json`에 보관한다.
