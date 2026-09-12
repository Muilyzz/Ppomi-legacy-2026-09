# Android 작업 화면과 앱 제어

Android 탭은 에뮬레이터 화면을 `Ppomi Android`라는 scrcpy 창으로 보여 준다. macOS 뽀미는 기존 iPhone·Windows와 같은 작업 화면에 이 창을 배치한다. Android 기기 안의 뽀미 앱은 사용자가 켠 `AccessibilityService`를 통해 다른 앱의 현재 화면을 읽고 조작한다.

이 프로젝트의 iPhone 경로는 Mac의 iPhone 미러링 창과 화면 인식·입력을 이용한다. Android 경로에서는 앱 내부의 접근성 서비스가 UI 트리, 버튼 동작, 텍스트 입력, 스크롤, 좌표 제스처, 홈·뒤로가기에 접근할 수 있다. 따라서 라벨과 노드로 조작 가능한 화면은 좌표·OCR에 대한 의존도를 줄일 수 있다. Android가 다른 앱의 비공개 데이터나 모든 화면에 무제한 접근할 수 있다는 뜻은 아니다.

## 제어 자리와 팝업 창

Mac 작업대와 같은 [제어 자리 규칙](ui-structure.md)을 따른다. 넓은 화면(720dp 이상, 펼친 Fold·태블릿)에서 뽀미 작업 화면은 오른쪽에 제어 자리를 두고, 대상 앱이 팝업(자유) 창으로 떠 있으면 `BridgeAccessibilityService.controlWindow()`가 700ms마다 발행하는 창 좌표를 읽어 그 사각형을 비운다. 테두리는 사람 차례(승인 대기)일 때만 잉크 2dp이고 그 밖에는 없다. 대상 창이 없으면 자리 안에 한 줄만 둔다(`앱 이름 팝업` 버튼 / `팝업 자리` / `뽀미 진행 중`). 버튼은 `openAsPopup`으로 런처의 최근 앱 → 앱 아이콘 → 팝업 화면으로 열기 노드를 차례로 눌러 팝업을 만들고, 처음 나타난 팝업은 `dockControlWindow`가 손잡이를 한 번 끌어 자리의 오른쪽 위에 둔다. 이후 사용자가 창을 옮겨도 자리가 따라간다. 좁은 화면과 대상 앱이 전체 화면·분할인 경우에는 자리를 두지 않고 대상 앱 위의 하단 패널을 쓴다(분할은 창이 겹치지 않으므로 자리도 드래그도 없다). 분할·팝업에서 뽀미 창이 포커스를 가지면 `allowedRoot()`가 허용 목록 안에서 자리가 따라가는 앱(마지막으로 연 앱)의 창을 읽는다. 대상이 팝업·분할 창이면 `screen_read`가 `targetWindow` 경계를 함께 주고, 그 밖의 좌표 탭·스와이프·드래그는 거부한다. 도킹 드래그는 팝업이 이 창과 겹칠 때만, 앱 재생성 뒤에도 한 번만 한다.

작업대 트리는 [docs/ui-tree.md](ui-tree.md)와 같다. 제어 열 위의 머리띠 한 줄은 허용 앱 선택기(현재 앱 이름, 없으면 `제어 앱`)와 `기록` 버튼뿐이다. 좁은 화면에서는 같은 머리띠가 대화 위에 온다. 승인 대기 작업이 있을 때만 제어 열 아래(좁은 화면은 대화 아래)에 차례 띠(제목 한 줄 · 승인 · 취소)가 생기고, 승인·취소는 작업 화면의 승인 카드와 같은 처리기를 쓰며 실패하면 그 한 줄에 오류가 대신 온다. 대상 창이 없어도 사람 차례면 빈 자리에 같은 잉크 테두리가 온다. 기록 페이지는 작업 공간을 통째로 대체하며 머리띠에 `← 대화`와 작업·기록·설정·공유 탭을 둔다.

기록 집중: 대화 화면을 떠나 작업·기록·설정·공유로 가면 제어 자리를 접고 대상 팝업을 캡션(손잡이 탭 → 최소화)으로 최소화하며, 대화로 돌아오면 대상 앱의 태스크를 앞으로 가져와 팝업을 복원하고 작업대를 그 뒤로 되돌린다(`setControlWindowHidden`). 삼성의 최소화 아이콘은 접근성 창이 아니라 태스크 실행으로 복원한다. 서비스가 재시작되면 자리가 따라가는 창의 앱을 "마지막에 연 앱"으로 다시 기억한다.

2026-09-10 Galaxy Fold(Android 17)에서 확인: 접근성 `GLOBAL_ACTION_TOGGLE_SPLIT_SCREEN`은 거부되고, 최근 앱 메뉴 경로로 분할·팝업 모두 만들 수 있으며, 분할과 팝업 상태에서 토스 화면 읽기가 성공했다. 같은 날 실기기에서 자리 버튼 → 팝업 생성·자동 도킹·단계 색 테두리, 기록 화면에서 최소화·전체 폭, 대화 복귀 시 복원·도킹까지 캡처로 확인했다. 삼성은 팝업의 위치·크기를 기억해 복원 뒤에도 같은 자리에 둔다.

## 폰에서 독립 실행

Android 뽀미에는 작업·기록·설정 화면이 있다. 작업을 시작한 뒤 다른 앱으로 전환하여 직접 조작하고, 결과를 확인한 화면과 실행 기록을 Android 내부에 저장한다. 이 경로에는 Mac MCP, ADB 포트 전달, scrcpy가 필요하지 않다. Mac Android 탭은 선택적으로 이 폰 화면을 보여 주는 경로로 유지한다.

```text
Android 뽀미 작업 화면 → 로컬 실행기 → 사용자 승인
                    → AccessibilityService → 별도 앱
                    → 새 화면 결과 확인 → 폰 내부 기록·PNG 증빙
```

첫 검증 절차는 별도 테스트 앱에 사용자가 입력한 한글을 그대로 넣고 적용하는 동작이다. 텍스트 변경과 적용 전에 승인을 받는다. 내장 절차임을 표시하며 AI가 판단했다고 표현하지 않는다. 작업이 실행 중이거나 승인 대기 중이면 외부 MCP의 제어 호출을 거절한다. 뽀미의 승인·설정 화면은 제어 도구로 읽거나 누를 수 없다. 다른 앱 위의 작은 상태 표시에서 작업 중지와 뽀미 복귀가 가능하다.

기록은 Android 앱 전용 저장소의 원자적 JSON 파일, 화면 PNG, 접근성 트리로 남는다. 강제 종료·서비스 연결 해제 후 미완료 작업을 자동 재실행하지 않는다. 이 실행 기록은 금융 장부가 아니다. 회계 화면의 명시적인 가상 예시는 [동일 Swift 코어](android-shared-core.md)를 JNI로 호출하는 읽기 전용 검증이다.

설정에는 HTTPS 모델 API 주소·모델·키를 사용자가 직접 연결하는 선택 기능이 있다. 키는 Android Keystore로 암호화하며 Mac의 기존 키를 복사하지 않는다. 연결한 모델을 실행하면 요청과 대상 앱 화면 텍스트가 그 제공자에게 전송된다. 모델의 제안은 동작마다 승인하고 최대 24단계로 제한한다. 기본 상태는 미연결이며 독립 실행 검증에는 모델 호출·과금이 없다.

```sh
python3 scripts/android-standalone-test.py
```

이 테스트는 해당 에뮬레이터의 MCP 포트 전달을 제거한 동안 실제 Android 작업/승인 UI로 요청을 시작한다. 다른 앱을 누르는 코드와 결과 캡처는 APK 내부에서 실행한다. 승인 차단, 한글 반영 결과, 폰 내부의 실제 PNG, 승인 전 중지, 강제 종료 후 중복 실행 방지를 확인하고 기존 포트 전달을 복원한다. 증빙은 `.ppomi/android-standalone/`에 복사한다.


2026-09-09 독립 버전 검증: Android 15/API 35 에뮬레이터에서 Mac MCP 포트 전달을 제거하고 작업·승인 UI를 통해 별도 앱의 한글 입력/적용과 실제 PNG 저장을 확인했다. 승인 전 중지, 외부 호출 및 자기 승인 차단, 강제 종료 후 자동 재실행 방지, 기록 화면과 APK 내부 Swift JNI 로딩을 확인했다. 저장·선택자·모델 주소 검증 4개와 Mac/Android 회계 코어 동일성 14개 사례가 통과했다. 기존 APK MCP 제어 14개와 설치된 Mac 뽀미 MCP 경유 5개 검사도 새 앱에서 통과했다. 최종 debug 빌드와 lint는 오류 0개다. 실제 모델 API 호출과 실기기는 이번 검증에 포함하지 않았다.

## Tauri 셸 1-step (UIAutomator)

소비자 셸(`shell/`)은 Kotlin 접근성 APK를 띄우지 않는다. `run_path --body android`가 `ppomi-body-android`의 dump+tap을 호출한다. 픽스처는 기기 없이, live는 에뮬레이터 또는 폰에 시리얼을 명시한다.

```sh
npm --prefix shell run host -- --intent 다음 --body android
scripts/android-emulator.sh boot
PPOMI_ANDROID_SERIAL=emulator-5554 PPOMI_BODY_LIVE=1 npm --prefix shell run host -- --intent 다음 --body android --live
```

한 대만 붙어 있어도 자동 선택하지 않는다. 안전한 설정 행(연결 / Wi-Fi / …)만 탭한다. 온디바이스 접근성 MCP는 아래 보조 앱 경로다.

## 에뮬레이터 실행

현재 개발 환경은 Android Studio, Android SDK, `Pixel_8_API_35` AVD, scrcpy 4.1을 사용한다. AVD는 Android 15/API 35, Google APIs, ARM64 이미지다. 기본 테스트에는 Google Play 로그인이나 실기기가 필요하지 않다.

```sh
scripts/android-emulator.sh status
scripts/android-emulator.sh boot
scripts/android-emulator.sh mirror
```

`mirror`는 실행 중인 에뮬레이터가 없으면 기존 AVD를 부팅하고 Android 부팅 완료를 기다린다. 그 다음 제목이 정확히 `Ppomi Android`인 scrcpy 창을 하나 연다. 다시 호출하면 같은 에뮬레이터의 기존 미러 창을 재사용한다. 에뮬레이터의 기본 창도 열리므로 scrcpy 없이 화면을 직접 확인할 수 있다. `boot`만 실행하면 scrcpy가 필요하지 않다.

- SDK 탐색 순서: `ANDROID_HOME`, `ANDROID_SDK_ROOT`, `~/Library/Android/sdk`, `~/Android/Sdk`.
- Java는 `JAVA_HOME`을 유지하고, 없으면 Android Studio의 번들 JBR을 사용한다.
- 실행 중인 에뮬레이터가 하나이면 그것을 선택한다. 여러 개이면 `PPOMI_ANDROID_SERIAL=emulator-5554`처럼 명시해야 한다. USB·네트워크 실기기 시리얼은 거절한다.
- 새로 부팅할 AVD 이름은 `PPOMI_ANDROID_AVD`로 지정한다. 기본값은 `Pixel_8_API_35`다. AVD를 자동 생성하거나 초기화하지 않는다.
- `PPOMI_SCRCPY`로 실행 파일을 지정할 수 있다. 기본은 PATH의 scrcpy다. 미설치 시 `brew install scrcpy`로 설치한다.
- Python 3가 프로세스를 별도 세션으로 실행하여 호출한 셸이 종료되어도 에뮬레이터와 미러 창을 유지한다.
- 로그: `~/Library/Caches/Ppomi/android/emulator.log`, `scrcpy.log`. 부팅 대기 제한은 120초다.

스크립트는 APK 설치, 접근성 서비스 활성화, 페어링을 수행하지 않는다. 에뮬레이터 종료는 Android Emulator 창에서 하거나, 선택한 시리얼에 `adb -s emulator-5554 emu kill`을 실행한다. AVD 데이터를 지우는 `-wipe-data`는 사용하지 않는다.

## 보조 앱 준비와 테스트

```sh
# APK 빌드·설치·로컬 페어링·에뮬레이터 접근성 설정 + 미러 창 열기
python3 scripts/android-bridge.py start

# 미러 창 없이 보조 앱만 준비하거나 연결 확인
python3 scripts/android-bridge.py prepare
python3 scripts/android-bridge.py status

# 별도 테스트 앱을 보조 앱의 MCP 경로로 조작
python3 scripts/android-bridge.py test

# Swift 빌드 이후 Mac stdio MCP부터 보조 앱까지 검증
python3 scripts/android-bridge.py test-mac
```

`prepare`는 AVD를 부팅하고 APK가 없으면 빌드한 다음, 보조 앱과 별도 테스트 앱을 설치한다. 개발 에뮬레이터임을 확인한 뒤 접근성 서비스를 켜며, 이미 활성화된 다른 접근성 서비스는 유지한다. 일반 기기의 접근성 권한을 자동 설정하는 경로는 없다.

보조 앱 패키지는 `com.ppomi.androidbridge`, 서비스는 `.BridgeAccessibilityService`다. 조작을 받는 테스트 앱은 **별도 패키지** `com.ppomi.androidtarget`이다. 수동 빌드는 다음과 같다.

```sh
cd Android
./gradlew :app:assembleDebug :controlfixture:assembleDebug
```

빌드에는 Java 17 이상, Android SDK 35, Android Gradle Plugin 8.7.3, Gradle 8.11.1을 사용한다. 출력 APK는 `Android/app/build/outputs/apk/debug/app-debug.apk`와 `Android/controlfixture/build/outputs/apk/debug/controlfixture-debug.apk`다.

보조 앱의 MCP HTTP 엔드포인트는 Android 내부 `127.0.0.1:8765/mcp`이고, Mac은 선택한 에뮬레이터에 ADB 포트 전달을 설정한다. 세션 토큰은 `.ppomi/android-bridge.json`에 소유자만 읽을 수 있는 권한 `0600`으로 저장한다. 명령 출력에는 토큰을 표시하지 않는다. 이 파일은 로컬 상태이며 Git에서 제외된다.

현재 보조 앱 도구는 다음과 같다. Mac 뽀미의 Android 도구는 이 API를 호출한다.

| 도구 | 입력과 동작 |
| --- | --- |
| `status` | 에뮬레이터·서비스·허용 범위 확인 |
| `ui_tree` | 현재 화면의 노드와 경계 조회 |
| `click` | 최신 `nodeId`의 접근성 클릭 |
| `type_text` | 최신 `nodeId`에 `text` 입력 |
| `tap` | 화면 픽셀 좌표 `x`, `y` 탭 |
| `swipe` | `x1`, `y1`, `x2`, `y2`, 선택적 `durationMs` 제스처 |
| `back`, `home`, `recents` | 시스템 탐색 동작 |
| `open_app` | 허용된 `packageName` 실행 |

개발용 디버그 빌드는 에뮬레이터와 사용자가 접근성을 켠 실기기에서 동작한다. Android 설정(`com.android.settings`), 별도 테스트 앱, 현재 선택한 홈 런처는 기본 허용이다. 0.6.1부터 뽀미의 **제어 앱 선택**에서 사용자가 추가로 고른 일반 앱에도 같은 제어 경로를 사용할 수 있다. 선택은 해당 기기에만 저장하며 진행 중인 대화·작업이 끝나야 변경할 수 있다. 실기기는 [별도 연결 절차](android-physical-control.md)를 사용한다. 뽀미 자체 화면은 사용자가 직접 조작한다. 접근성 설정에서 보조 서비스를 끄면 서버도 종료된다.

새 음성 에이전트는 `app_list`로 앱 이름·패키지·허용 여부를 확인하고 `app_open`으로 연다. 화면 읽기·노드 클릭·입력·스크롤·홈·뒤로가기가 연결돼 있으며, 기존 MCP의 길게 누르기·드래그 도구는 아직 음성에 연결하지 않았다. 미허용 앱은 접근성 권한 전체가 없다는 뜻이 아니며, 앱 선택 설정을 안내한다. 토스처럼 금융 앱인 경우에도 허용된 화면 열기·조회는 가능하지만 인증·송금·결제 등 보호 동작을 실행하지 않는다. 다른 앱이 제공하지 않는 접근성 정보나 보안 화면을 우회하지 않는다.

0.6.3의 채팅·음성 에이전트에는 `store_search(query)`가 추가됐다. 제어 앱 선택에서 Google Play 스토어를 허용하면 공식 스토어의 앱 검색 결과를 열 수 있다. 목적지는 `com.android.vending`으로 고정하고 검색어를 URI 값으로 인코딩한다. 이 도구는 활성 대화의 제어 소유자만 호출할 수 있으며, 앱 설치나 권한 변경을 수행하지 않는다. [Google Play 공식 링크 규격](https://developer.android.com/distribute/marketing-tools/linking-to-google-play)을 따른다.

사용자가 설치를 명시적으로 요청하면 검색 결과와 상세 화면에서 앱 이름·공식 발행자를 확인한 뒤 무료 설치 버튼을 기존 `ui_tap`으로 누른다. 설치 중에는 반복해서 누르지 않으며, 새 `app_list` 결과로 설치 완료를 확인한다. 설치된 앱의 제어 허용은 별도 설정이다. 스토어가 접근성에 제공하지 않는 안내·보안 버튼, 유료 구매·인증·권한 허용은 자동 완료했다고 처리하지 않는다. 검색어 입력 뒤 키보드 앱을 제어할 필요 없이 `store_search`로 검색 결과를 연다.

2026-09-09 폴드 실기기에서는 폰의 채팅 에이전트가 `store_search`로 공식 어카운트인포를 찾고, 발행자 확인과 설치 버튼 클릭까지 수행했다. Play 스토어의 설치됨 표시와 Android 패키지 정보에서 `com.kftc.payinfo.android` 3.1.5/code 257, 설치 출처 `com.android.vending`을 확인했다. 스토어 첫 실행 안내의 확인 버튼은 일반 접근성 트리에서 누락되어 Mac의 ADB 검증 UI로 한 번 닫았다. 모델은 설치 대기 중이라고 응답한 뒤 종료했으므로 이 결과를 설치 완료까지 무인 대기한 검증으로 표현하지 않는다.

어카운트인포를 제어 대상으로 추가한 뒤 뽀미 접근성으로 앱을 열고 시작 안내 화면을 읽었다. 이어 앱 자체의 `USBDEBUG / USB Debugging` 차단창이 나타났다. 본인인증과 실제 계좌 목록·잔액 읽기는 아직 검증되지 않았으며 USB 디버깅을 끈 기기 내 실행에서 확인해야 한다. 발행자 이름에 포함된 한글 `결제`를 결제 동작으로 오인하던 문제는 업체별 예외 없이 동작 라벨 경계로 수정했다. 실제 결제·송금 버튼과 보호 버튼을 포함한 부모 노드 차단은 유지한다. 로컬 검증 상태는 `.ppomi/agent/accountinfo-verification.json`에 금융 원문 없이 기록한다.

### 플레이북으로 준비하고 인증 후 이어가기

아래 0.6.4의 어카운트인포 앱 절차는 이전 검증 기록이다. 현재 기본 경로는 다음 절의 0.6.6 Mac 웹 플레이북이며 Android 앱 실행으로 자동 대체하지 않는다.

0.6.4의 공유 에이전트는 `list_playbooks`와 `read_playbook`으로 앱 절차를 읽는다. 원본은 Mac과 같은 `Ppomi/Sources/Ppomi/Catalog/`이며 빌드할 때 기존 카탈로그 검증기를 통과한 공개 패키지만 번들에 포함한다. 로컬 실행 증거·사용자 입력·인증값은 플레이북에 포함하지 않는다. 도구는 안내를 읽을 뿐 제어 권한, 설치 승인, 재생 성공을 부여하지 않는다. 실제 실행에는 현재 기기에 제공된 네이티브 도구와 최신 화면을 사용한다.

사용자는 뽀미에 “어카운트인포에서 내 계좌 목록을 조회해 줘”처럼 목적만 요청한다. 에이전트가 플레이북을 읽고 설치·제어 허용 상태 확인, 앱 열기, 일반 안내와 조회 준비를 맡는다. 비밀번호·인증서 암호·OTP·생체인증·새 필수 동의 등 실제 사용자 단계에 도달했을 때 필요한 행동만 짧게 안내한다. 인증 대기는 대화 종료가 아니며, 사용자가 “완료했어”라고 하면 현재 화면을 새로 읽어 인증 결과를 확인하고 원래 조회를 이어간다. 사용자의 완료 발언이나 인증 성공만으로 계좌 조회가 완료됐다고 기록하지 않는다.

텍스트 세션은 다른 앱으로 전환해도 전경 서비스를 통해 유지되므로 인증 후 뽀미의 진행 중 알림 또는 앱으로 돌아와 답할 수 있다. 연결 종료·앱 종료는 임시 대화 문맥을 지우며 자동으로 작업을 다시 실행하지 않는다. 음성 세션은 다른 앱에 오디오 포커스를 잃으면 종료될 수 있다. 이 플레이북은 백그라운드 인증 감시나 자동 재개 기능을 설치하는 것이 아니다.

에이전트 UI·지침·도구·플레이북은 현재 APK 안의 자산이다. 서버 배포만으로 이미 설치된 앱에 이번 기능이 들어가지는 않으며 최초 APK 업데이트가 필요하다. 설치 후 폰 내부 실행에는 USB 디버깅이 필요하지 않다. 실제 어카운트인포의 인증·계좌 조회는 USB 디버깅을 끈 실기기에서 별도로 검증해야 한다.

2026-09-09 검증: 카탈로그 생성·공개 필드 제한·SDK 도구 호출·세션 종료 등 공유 에이전트 검사 44개가 통과했다. `agent/scripts/playbook-model-smoke.ts`는 실제 모델과 배포용 도구 정의에 합성 Android 화면만 연결한다. 플레이북 읽기 → 앱 열기 → 일반 안내 탭 → 인증 대기, 실제 인증이 아직 남은 상태에서 완료 발언을 받아도 새 화면으로 재확인, 합성 인증 완료 후 원래 앱을 전면에 가져와 목록을 찾아 읽는 세 턴을 확인했다. 보호 입력·금융 정보 저장은 0회이며 이는 실제 은행 앱 검증이 아니다. 에뮬레이터의 기존 실제 채팅 UI 테스트에서도 마이크·알림 권한 없이 테스트 앱의 단일 클릭·재조회·앱 전환 중 세션 유지·종료 시 임시 문맥 정리를 확인했다. 이 UI 테스트는 마지막 인증 안내 문구 보강 직전 번들로 실행했으며, 최종 지침은 모델 합성 검증을 다시 거쳐 APK에 포함했다. 실제 검증 메타데이터는 `.ppomi/agent/playbook-model-proof.json`에 저장하고 대화 원문은 저장하지 않는다.

### 어카운트인포는 Mac 웹에서 초기 목록 확인

0.6.6의 공유 카탈로그는 `accountinfo`를 0.2.0으로 갱신하고 `launch.target=browser`, 공식 `https://www.payinfo.or.kr/`를 기본 경로로 사용한다. 목적은 초기 계좌 목록 확인과 새 계좌·누락 범위를 확인할 때의 재조회다. 일일 거래내역 수집이나 결산 스케줄을 만들지 않으며, 한 번 인증했다고 지속 수집 연결이 만들어지지는 않는다.

브라우저 제어 도구가 실제 연결된 Mac에서 사이트 열기와 일반 조회 준비를 맡고, 인증·새 필수 동의 등 사용자 단계 후 새 화면으로 결과를 확인한다. 사용자 지정 또는 실제 Windows 전용 요건이 확인되면 연결된 Parallels 경로를 검토한다. 웹 본인인증·실제 계좌 조회·인증 프로그램 연동과 Windows ARM 가상머신 호환성은 아직 검증하지 않았다.

Mac 호스트 MCP는 로컬 설치 카탈로그의 웹 경로를 읽을 수 있다. 공유 TS 에이전트에 상태·파일 도구만 연결된 Mac 세션, 그리고 현재 Android 세션에는 이 웹 제어가 제공되지 않는다. 이때 필요한 Mac 브라우저 환경을 안내하며 작업이 다른 기기로 전달되거나 실행됐다고 표시하지 않는다. Android에 이미 어카운트인포 앱이 설치돼 있어도 이 웹 플레이북 대신 열지 않는다.

공유 도구는 이름·별칭이 명시된 검색에서 부가적인 요청 문구 때문에 해당 플레이북을 놓치지 않게 했으며 실행 대상을 검색 요약에 포함한다. Android 세션에서 웹 플레이북이 선택되면 앱 열기·설치 검색·화면 조작을 네이티브 실행 전에 차단하고 절차 읽기와 필요한 환경을 안내한다. 상태·앱 목록·플레이북·파일 도구는 유지하며, 새 일반 앱 작업이나 새 세션에는 이전 대상이 남지 않는다. 이는 서비스별 권한 예외나 자동 기기 이관 기능이 아니다.

설치·검증 결과는 `.ppomi/agent/accountinfo-web-route-verification.json`, 합성 환경에서 실제 모델이 고른 도구와 실행 차단 결과는 `.ppomi/agent/playbook-routing-model-proof.json`에 기록한다. 합성 인증 재개 검사는 실제 계좌 조회 증거로 사용하지 않는다. 현재 로컬 Mac 카탈로그와 APK 자산 적용은 공개 허브의 프로덕션 배포와 구분한다.

### 키보드와 채팅 영역

Android 채팅은 키보드 위에 남는 WebView 높이에 맞춰 대화 목록이 줄어들고, 입력창과 보내기 버튼은 같은 화면 안에 남도록 구성한다. 네이티브 Activity가 IME 공간을 반영하며 Web UI가 키보드 높이를 별도로 더하지 않는다. 입력 중 공간이 부족할 때는 주변 상태·기억 영역보다 메시지 작성을 우선한다. 키보드를 닫아도 작성 중인 메시지나 진행 중인 세션은 초기화하지 않는다. 검증은 실제 소프트 키보드를 띄워 입력창·보내기 버튼의 화면 좌표와 키보드 영역을 비교하고, 메시지를 서버에 전송하지 않은 상태로 입력과 복원을 확인한다.

0.6.5에서는 Activity의 `adjustResize`와 Compose IME 인셋을 사용하고, AndroidView 안의 WebView에 `MATCH_PARENT` 크기를 명시한다. 기본 `WRAP_CONTENT` 상태에서는 실제 WebView 높이와 JavaScript `innerHeight`가 있어도 CSS `dvh`와 높이 미디어 쿼리가 0 높이로 평가되는 현상이 에뮬레이터에서 관찰됐다. 따라서 DOM 좌표만으로 화면이 보인다고 판단하지 않고 실제 렌더링과 키보드 입력까지 확인한다.

2026-09-09 검증: 0.6.5/code9의 실제 도킹 키보드를 1080×2400 및 1920×2160 에뮬레이터 화면에서 열어 입력창·보내기 버튼이 키보드 위에 남는지 확인했다. 두 화면 모두 작성 내용과 보내기 활성 상태를 유지하고, 키보드를 닫으면 원래 WebView 높이로 복원되며 IME 공간이 중복 적용되지 않았다. 테스트는 합성 초안만 입력하고 에이전트·미디어 세션을 시작하지 않았다. `assembleDebug`, `assembleDebugAndroidTest`, `lintDebug`가 통과했다(lint 오류 0, 경고 12). Gboard 필기 모드는 도킹 키보드 검사 동안만 끄고 화면 크기·밀도·IME 설정을 복원했다. 이는 삼성 실기기 검증과 구분하며 최신 설치·검증 상태는 `.ppomi/agent/keyboard-verification.json`에 기록한다.

같은 날 폴드 실기기(SM-F971N)에 무선 ADB로 0.6.5/code9를 업데이트 설치했다. 펼친 2448×1848 화면에서 삼성 한국어 분할 키보드를 실제로 누르며 입력창·보내기 버튼의 노출, 한글 입력과 보내기 활성화, 키보드 닫기·재열기 후 초안 유지를 확인했다. 테스트 초안은 전송하지 않고 지웠으며, 화면 꺼짐 시간을 원래 30초로 복원했다. 접근성과 어카운트인포·Play 스토어 제어 선택도 유지됐다. 접힌 전면 화면은 실기기에서 별도로 검사하지 않았다. USB 디버깅은 꺼져 있었고 무선 디버깅만 켜진 상태였다. 이 상태의 어카운트인포도 `USB Debugging (TCP/IP)` 경고로 차단됨을 별도로 확인했다.

`test`는 ADB 입력 명령을 사용하지 않고 APK의 MCP 서버를 통해 한글 입력, 노드 클릭, 좌표 제스처 탭, 설정 앱 열기, 오래된 노드·잘못된 인증·허용하지 않은 앱 거절을 검사한다. 성공 결과는 `.ppomi/android-smoke-result.json`에 저장한다. 실제 성공 여부와 검사 개수는 이 파일의 해당 실행 결과를 확인한다.

Mac MCP는 `android_status`, `android_screen`, `android_click`, `android_tap`, `android_type`, `android_key`, `android_swipe`, `android_open`을 제공한다. `android_screen`은 접근성 트리를 읽은 직후 ADB로 화면 PNG를 별도 캡처해 함께 반환한다. 좌표는 원본 화면의 픽셀 단위이며 iPhone의 0~1 좌표와 다르다. 캡처 실패 시 트리와 실패 안내만 반환하고 이전 이미지를 재사용하지 않는다. 화면 PNG는 기존 로컬 증빙 경로 `data/shots/android/`에 저장된다.

`test-mac`은 `.ppomi/android-mcp-test.db`의 별도 테스트 장부를 사용한다. 기본 실행 파일은 `Ppomi/.build/debug/Ppomi`이며 `PPOMI_TEST_BINARY`로 설치된 앱 실행 파일을 지정할 수 있다. 마지막 반환 이미지는 `.ppomi/android-mcp-screen.png`에 저장한다. 일반 금융 장부에 테스트 거래를 기록하지 않는다.

2026-09-08 검증: Pixel 8 / Android 15(API 35) 에뮬레이터에서 보조 앱 MCP의 교차 앱 제어 14개 검사, Mac stdio MCP 경유 검사 5개를 통과했다. 한글 입력과 반영 결과, 카운터 변화, 설정 스와이프 후 내용·위치 변화, 제스처 완료 콜백을 확인했다. Android 두 APK의 debug 빌드·lint는 오류 없이 통과했고 전송·인증 정책 20개 검사를 통과했다. 실제 미러 창의 위치·크기 변경과 복원도 확인했다. 실기기는 테스트하지 않았다.

## 앱 제어 경로

```text
MCP 클라이언트 → Mac 뽀미 Android 도구 → adb 포트 전달
             → Android 보조 앱 → AccessibilityService → 대상 앱

Android 화면 → scrcpy → Ppomi Android 창 → 뽀미 Android 탭
```

scrcpy의 마우스·키보드 제어와 보조 앱의 접근성 제어는 서로 다른 경로다. 다른 앱 제어를 검증할 때는 보조 앱 API로 실행한 동작과 그 뒤의 화면·접근성 트리를 확인해야 한다. ADB의 `shell input`으로만 성공한 것을 보조 앱이 직접 제어했다고 기록하지 않는다.

루팅은 필요하지 않다. 일반 기기에서는 사용자가 Android 설정에서 해당 접근성 서비스를 명시적으로 켠다. 개발 에뮬레이터의 테스트용 활성화 절차가 있더라도 실기기 사용자의 권한 설정을 대체하지 않는다. 보조 앱이 종료되거나 서비스가 비활성화되면 제어 도구가 연결 상태를 알려야 한다.

## 범위와 제한

- 접근성 트리는 대상 앱이 제공하는 정보에 의존한다. 커스텀 캔버스, 게임, 일부 WebView는 충분한 노드를 제공하지 않을 수 있다. 화면 전환 후에는 새 트리를 읽고 노드를 다시 선택한다.
- 접근성 동작의 성공 응답만으로 업무 완료를 판단하지 않는다. 탭·텍스트 입력·스크롤 후 새 화면에서 결과를 확인한다.
- `FLAG_SECURE`로 보호한 창은 화면 캡처가 차단될 수 있다. 보안 화면 캡처 실패를 우회하는 기능은 제공하지 않는다.
- 인증·결제·생체 인식, 기기 무결성 검사, 제조사별 동작은 에뮬레이터 결과만으로 실기기 지원을 보장할 수 없다. 초기 검증은 Android 설정이나 별도의 테스트 앱처럼 되돌릴 수 있는 조작으로 한다.
- 기존 `android-emulator.sh`와 `android-bridge.py`는 에뮬레이터만 선택한다. 실기기는 `android-device.py`에서 시리얼을 명시해 연결한다.

## 근거

- Android 공식 [접근성 서비스 만들기](https://developer.android.com/guide/topics/ui/accessibility/service): UI 트리 조회, 노드 동작, 전역 동작, `dispatchGesture` 구성.
- Android 공식 [AccessibilityService API](https://developer.android.com/reference/android/accessibilityservice/AccessibilityService): 사용자의 서비스 활성화, 변경될 수 있는 노드 정보, 보안 창 스크린샷 오류.
- Android 공식 [WindowManager.LayoutParams.FLAG_SECURE](https://developer.android.com/reference/android/view/WindowManager.LayoutParams#FLAG_SECURE): 캡처와 비보안 디스플레이에 대한 보호.
- Android 공식 [에뮬레이터로 앱 실행](https://developer.android.com/studio/run/emulator), [명령행 실행 옵션](https://developer.android.com/studio/run/emulator-commandline): 실기기 없는 테스트와 AVD 실행.
- scrcpy 공식 [저장소](https://github.com/Genymobile/scrcpy), [창 설정](https://github.com/Genymobile/scrcpy/blob/master/doc/window.md), [기기 선택](https://github.com/Genymobile/scrcpy/blob/master/doc/connection.md): 루팅 없는 미러링·입력, 제목과 시리얼 지정.

확인일: 2026-09-08.
