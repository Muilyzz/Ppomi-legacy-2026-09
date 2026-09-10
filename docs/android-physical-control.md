# Android 실기기에서 뽀미 MCP 연결

실기기 준비는 `scripts/android-device.py`를 사용한다. 기존 `android-bridge.py`와 `android-emulator.sh`는 에뮬레이터 경로를 유지한다. 두 경로의 기기 선택·페어링 파일·Mac 포트가 분리되어 있어 실기기가 연결되지 않았을 때 에뮬레이터로 대신 실행하지 않는다.

현재 개발용 APK의 실기기 대상은 Android 11/API 30 이상 ARM64 기기다. 사용자가 폰에서 뽀미의 접근성 서비스를 직접 켠 뒤 제어한다. 서비스가 꺼져 있으면 MCP 제어도 연결되지 않는다. 출고용 릴리스, 모든 제조사 런처, 실제 에이전트 앱 연결이 검증되었다는 의미는 아니다.

## 연결과 설치

1. 폰의 잠금을 해제하고 개발자 옵션의 USB 디버깅을 켠다. USB 데이터 연결이 가능한 케이블로 연결한 뒤 폰에 뜨는 이 Mac의 USB 디버깅 허용 화면을 확인한다.
2. 아래 `devices` 출력에서 실제 폰의 시리얼과 `device` 상태를 확인한다. `unauthorized`는 폰에서 디버깅 허용이 필요하다는 뜻이다. `emulator-...`는 실기기 스크립트가 거절한다.
3. 최신 debug APK를 빌드하고 정확한 폰 시리얼을 지정해 설치한다. 기존 뽀미 설치가 있으면 데이터를 유지하는 업데이트 설치만 시도한다. 서명이 다르면 자동 삭제하지 않고 실패한다.
4. 폰에서 열린 뽀미의 설정에서 접근성 설정을 열고 뽀미 서비스를 직접 켠다. Samsung 등에서는 앱 정보의 제한된 설정 허용이나 별도의 설치 보안 설정이 필요할 수 있다. 스크립트는 이를 자동 변경하지 않는다.
5. `status`로 `accessibilityEnabled`와 MCP 연결을 확인한다.

```sh
python3 scripts/android-device.py devices

# Android 디렉터리에서 실행
./gradlew :app:assembleDebug :controlfixture:assembleDebug

# 저장소 루트에서 실제 출력된 폰 시리얼을 넣는다.
python3 scripts/android-device.py prepare --serial PHONE_SERIAL --with-fixture
python3 scripts/android-device.py status --serial PHONE_SERIAL
python3 scripts/android-device.py call --serial PHONE_SERIAL --tool status

# 허용된 현재 화면을 폰의 접근성 API로 캡처하고 Mac에 비공개 PNG로 저장한다.
python3 scripts/android-device.py call --serial PHONE_SERIAL --tool screen --output .ppomi/phone-screen.png
```

`--with-fixture`를 생략하면 뽀미만 설치한다. 포함하면 별도 패키지 `com.ppomi.androidtarget`의 되돌릴 수 있는 테스트 앱도 설치한다. 이 옵션은 다른 앱 설치나 기존 앱 삭제를 수행하지 않는다. 스크립트는 빌드를 자동 수행하지 않으며, 설치할 APK의 패키지 ID·debug 표시·ARM64 라이브러리를 검사한다.

Mac의 전용 포트는 기본적으로 비어 있는 `8766`부터 선택한다. `prepare --port 8770`처럼 명시할 수도 있다. 이미 다른 기기가 사용하는 ADB 포트 전달은 덮어쓰지 않는다. 기존 에뮬레이터용 `8765`는 실기기 Mac 포트로 사용할 수 없다. 폰 안의 MCP 포트는 두 환경 모두 `127.0.0.1:8765/mcp`다.

페어링 설정은 `.ppomi/android-device-<시리얼 SHA-256 앞 16자리>.json`에 `0600` 권한으로 저장한다. 토큰을 로그나 기본 명령 출력에 표시하지 않으며 Mac의 모델 키·기존 에이전트 자격 증명을 폰에 복사하지 않는다. 설정 파일은 원본 시리얼을 포함하므로 로컬 상태로 관리한다. 이 경로는 기존 `.ppomi/` 제외 규칙을 따른다.

`--output`은 `call --tool screen`에서만 사용할 수 있다. 응답의 PNG 형식·청크 체크섬·크기를 검사하고, 폰이 반환한 폭·높이·접근성 캡처 출처·앱 패키지·캡처 시각과 일치할 때만 `0600` 파일로 원자적으로 저장한다. 터미널에는 이미지의 base64나 인증 토큰 대신 파일 경로·메타데이터·SHA-256만 출력한다. 각 MCP 호출 전에 포트 전달 대상 시리얼을 다시 확인하며, HTTP 리다이렉트와 환경 프록시를 사용하지 않는다.

## 무선 디버깅으로 개발 연결

Android 11 이상에서는 같은 Wi-Fi의 Mac과 폰을 무선 디버깅으로 페어링해 APK 설치와 scrcpy 미러링에 사용할 수 있다. 폰의 `무선 디버깅 → 페어링 코드로 기기 페어링`에 표시된 주소로 `adb pair IP:PAIRING_PORT`를 실행하고, 프롬프트에서 일회성 코드를 입력한다. 자동 연결되지 않으면 무선 디버깅의 기본 화면에 표시된 별도의 연결 주소로 `adb connect IP:CONNECT_PORT`를 실행한다. 페어링 포트와 연결 포트는 서로 다를 수 있다. 코드는 설정 파일이나 검증 기록에 저장하지 않는다.

`adb devices -l`에 나타난 실제 폰의 식별자를 명시해 설치·제어한다. `scripts/android-device.py`는 네트워크 식별자도 받지만, 현재 Mac Android 탭의 자동 미러링은 에뮬레이터 전용이다. 직접 미러링은 `scrcpy --serial EXACT_DEVICE_ID --window-title "Ppomi Fold"`로 실행할 수 있다. 연결되지 않은 실기기 대신 에뮬레이터를 선택하지 않는다. 공식 절차는 [Android 무선 연결 안내](https://developer.android.com/studio/run/device.html)와 [scrcpy 연결 문서](https://github.com/Genymobile/scrcpy/blob/master/doc/connection.md)를 따른다.

무선 디버깅도 ADB 개발 연결이다. 2026-09-09 폴드 실기기에서는 USB 디버깅을 끄고 무선 디버깅만 켠 상태에서도 어카운트인포가 `USBDEBUG / USB Debugging (TCP/IP)`로 실행을 차단했다. Mac 에이전트가 무선 ADB의 임시 포트 전달로 기존 인증된 뽀미 MCP를 호출하여 앱 열기와 접근성 경고 읽기를 확인했으며, 인증·계좌 조회는 수행하지 않았다. 임시 포트 전달은 제거했고 결과는 `.ppomi/agent/accountinfo-wireless-verification.json`에 저장했다. 금융 앱의 동작을 다른 앱으로 일반화하지 않으며, 이 기기의 어카운트인포는 개발 연결을 끈 폰 내부 뽀미 경로로 검증해야 한다. 앱의 차단 검사는 변경하지 않는다.

이 Mac의 최초 연결 실패 원인은 ChatGPT의 로컬 네트워크 권한이 꺼져 있었던 것이었다. 사용자 승인 후 `개인정보 보호 및 보안 → 로컬 네트워크 → ChatGPT`를 켜자 기존 페어링된 폴드의 mDNS 연결 주소가 발견되고 접속됐다. 연결이 막힐 때 페어링 코드부터 반복 재발급하지 말고 실제 `adb devices`, mDNS 발견, Mac 앱의 네트워크 권한을 확인한다.

## 폰의 에이전트 앱에서 연결

Android 뽀미의 MCP 서버는 폰의 loopback 주소에 바인딩된다. 같은 폰의 에이전트 앱이 로컬 HTTP MCP와 Bearer 인증을 지원하면 다음 경로로 호출할 수 있다.

```text
같은 폰의 에이전트 앱 → 127.0.0.1:8765/mcp → 뽀미 접근성 서비스 → 허용된 앱·홈 화면
```

Mac의 ADB 포트 전달은 개발 검증용이다. 폰 안에서 직접 연결할 때에는 Mac·USB·scrcpy가 필요하지 않다. 에이전트 앱이 서버 측에서만 MCP를 실행하거나 로컬 HTTP 연결을 지원하지 않으면 이 주소에 직접 연결할 수 없다. 원격 공개 바인딩이나 자동 터널은 제공하지 않는다. 인증 토큰은 사용자가 뽀미 설정에서 확인해 해당 에이전트 앱에 등록한다.

서버는 기존 네이티브 클라이언트용 HTTP MCP 서브셋을 사용한다. 브라우저의 `Origin` 요청은 허용하지 않는다. 따라서 에이전트 앱의 WebView 안에서 일반 웹 페이지가 직접 요청하는 형태는 별도 네이티브 연결 구현이 필요할 수 있다. 로컬 실행 작업 또는 승인 대기 중에는 외부 MCP가 동시에 앱을 조작할 수 없다.

## 홈 화면 정리 검증 범위

아이콘 이동은 Android 기본 앱 권한만으로 런처 데이터를 직접 쓰는 방식이 아니다. 사용자가 허용한 홈 앱의 접근성 화면을 읽고 길게 누른 상태를 유지하는 드래그 제스처를 실행한다. 폴더 생성·해제와 빈칸 배치는 런처의 실제 동작을 따른다.

실기기 검증은 현재 홈 앱과 아이콘 위치를 먼저 기록한 뒤, 테스트용 아이콘의 단일 이동을 수행하고 새 화면에서 위치 변화를 확인한다. 이후 두 테스트용 아이콘을 폴더로 묶는 동작을 검사하며, 원래 위치로 복구할 수 있는 범위에서 진행한다. 기존 사용자의 전체 아이콘을 추측으로 재배치하거나 앱을 삭제하지 않는다. 제스처 완료 콜백만으로 성공을 기록하지 않고 이동 전후의 화면·접근성 정보로 확인한다.

에뮬레이터 성공은 Samsung One UI 등 다른 런처의 성공을 보장하지 않는다. 홈 화면 레이아웃 잠금, 폴더 드롭 목표, 길게 누르는 시간, 아이콘 크기가 다를 수 있다. 실기기 성공 여부는 별도의 해당 기기 실행 결과와 증빙을 확인한다. 이 문서의 준비 절차 자체는 실기기 제어가 이미 성공했다는 기록이 아니다.

2026-09-09 에뮬레이터 검증: Pixel 8/API 35의 기본 홈 런처에서 뽀미 MCP만으로 앱 서랍의 뽀미·Ppomi Control Test 아이콘을 홈에 추가하고, 두 아이콘을 폴더로 묶고, 이름을 `뽀미 테스트`로 저장했다. 새 접근성 화면의 `Folder: 뽀미 테스트, 2 items`, 폴더 내부의 두 앱 이름, Android가 직접 캡처한 PNG로 결과를 확인했다. 로컬 증빙은 `.ppomi/android-gestures/home-two-icons.json`, `home-folder.json`, `home-folder-named.json` 및 같은 이름의 PNG다. 이 결과는 Mac의 개발용 MCP 클라이언트가 폰 내부 서비스를 호출한 것으로, 별도 Android 에이전트 앱이나 Samsung 실기기의 성공 기록은 아니다.

2026-09-09 실기기 검증: Galaxy Fold 8로 연결한 `SM-F971N`은 Android 17/API 37, ARM64, 4KB 메모리 페이지, 펼친 화면 2448×1848을 보고했다. debug APK v0.3.0과 테스트 앱을 설치하고, 사용자가 직접 접근성을 켠 뒤 삼성 One UI 홈(`com.sec.android.app.launcher`)에서 검증했다. 별도 테스트 앱에서 실제 길게 누르기·드래그·취소·동시 제어 차단·오래된 노드와 범위 밖 좌표 거절·네이티브 PNG를 포함한 23개 검사가 통과했다. 홈 화면에서는 테스트 앱 아이콘을 빈칸으로 이동하고 뽀미와 묶어 `뽀미 테스트` 폴더를 만들었다. 이름 저장 후 홈으로 돌아와 폴더가 유지되는지, 폴더 안에 두 앱이 있는지 확인했으며 기존 아이콘 20개의 위치도 일치했다.

실기기 증빙은 `.ppomi/android-gestures/2113afb7461d1f2f.json` 및 PNG, `.ppomi/android-physical-home/`의 이동 전후·폴더 생성·이름 저장 화면, `.ppomi/android-physical-verification.json`에 저장했다. 제어는 Mac 개발 클라이언트 → 인증된 폰 MCP → 접근성 서비스로 실행했다. 별도 Android 에이전트 앱 연결, 실제 모델 API 호출, 접었다 펴는 도중의 제스처 중단은 이 실기기 실행에 포함하지 않았다.

## 개발 점검

```sh
python3 -m unittest discover -s scripts/tests -p 'test_android_device.py'
python3 scripts/android-device.py --help
```

준비 스크립트의 검증은 명시적 기기 선택, 다른 ADB 포트 보존, 페어링 파일 권한, 에뮬레이터 위장 거절을 다룬다. 이 테스트는 실제 폰에 설치하거나 화면을 조작하지 않는다.
