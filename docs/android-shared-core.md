# Android에서 사용하는 공통 Swift 회계 코어

Android 앱은 Mac 앱의 회계 계산을 Java/Kotlin으로 다시 구현하지 않는다. `Android/swift-core`가 아래 **원본 Swift 파일 그대로** ARM64 Android 공유 라이브러리로 컴파일한다.

- `Ppomi/Sources/Ppomi/Accounting/AccountingModel.swift`
- `Ppomi/Sources/Ppomi/Accounting/AccountingEngine.swift`
- `Ppomi/Sources/Ppomi/Records/RecordScope.swift`
- `Ppomi/Sources/Ppomi/Records/LifeModel.swift` — 회계 엔진이 사용하는 `LifeJSON` 날짜 검증·JSON 직렬화 의존성.

`stage.py`는 빌드 때 원본 바이트를 생성 디렉터리로 복사하고 SHA-256을 기록한다. 복사본은 Git에서 제외된다. 원본 동작을 Android 전용으로 수정하는 패치나 별도의 회계 산술은 없다. `build/source-manifest.json`과 성공 보고서의 `sourceHashes`에서 어떤 소스가 컴파일됐는지 확인한다.

## 호출과 데이터 경계

```text
Android Compose/Java 화면
  → SharedAccounting.report(archiveJSON)
  → JNI의 UTF-8 byte[] 변환
  → libppomi_accounting_core.so
  → 원본 AccountingEngine.validate / balances / entries
```

`SharedAccounting.report(String)`는 전체 `AccountingArchive` JSON 문자열을 받는다. 최대 크기는 4 MiB다. 결과는 다음 형태의 JSON 문자열이다.

```json
{
  "ok": true,
  "core": "Swift",
  "schemaVersion": 1,
  "sourceHashes": {"원본 Swift 경로": "SHA-256"},
  "books": [{
    "book": {"id": "장부 ID", "name": "장부 이름", "ownerID": "소유자 ID", "kind": "financial", "unit": {}},
    "scope": {"kind": "unclassified", "ownerID": "소유자 ID"},
    "accounts": [],
    "recordedBalances": {},
    "adjustedBalances": {},
    "recordedEntries": [],
    "adjustedEntries": []
  }]
}
```

위 구조는 필드 설명용이며 실제 가져오기 예제가 아니다. 계정별 잔액은 **정수 최소단위**다. 차변은 양수, 대변은 음수다. 각 장부의 단위·소유자·개인/사업 구분을 그대로 유지하고 장부 간 합계를 생성하지 않는다. `book.scope`가 없는 이전 자료는 없는 상태로 반환하고, 표시용 `scope`만 `unclassified`가 된다.

`recordedEntries`와 `recordedBalances`는 원본만 반영한다. `adjustedEntries`와 `adjustedBalances`는 원본 및 현재 유효한 평가 조정을 반영한다. 원본을 바꾸지 않으며 이전 평가를 대체하는 체인도 원본 엔진이 검증한다. 보고서 생성은 저장·가져오기·재분류 실행을 수행하지 않는다.

오류는 `{ "ok": false, "core": "Swift", "code": "accounting_validation", "error": "설명" }`처럼 반환한다. JSON/정수/날짜 형식 오류는 `invalid_archive_json`, 개인·사업 구분 검증 오류는 `scope_validation`이다. Java는 UTF-8 바이트 배열을 JNI로 넘기므로 한글과 보조 평면 이모지도 보존한다. 포인터 수명은 JNI 어댑터 내부에서만 관리한다.

## 빌드

macOS 호스트 기준으로 다음 개발 의존성을 사용한다.

| 구성 요소 | 버전 / 용도 |
| --- | --- |
| Swift.org 공개 툴체인 | Swift 6.3.3, 사용자 `~/Library/Developer/Toolchains`에 설치 |
| Swift SDK for Android | Swift 6.3.3 공식 아티팩트, 공식 SHA-256 검증 |
| Android NDK | r27d (`27.3.13750724`) |
| Android 타깃 | `aarch64-unknown-linux-android28`, APK ABI `arm64-v8a` |
| Java / Android 도구 | Java 17 이상, SDK 35, build-tools 34.0.0 |

```sh
# 최초 개발 의존성 설치. 시스템 Xcode 선택이나 셸 프로필은 바꾸지 않는다.
Android/swift-core/setup.sh

# Android .so 및 재귀 런타임 의존성 패키징
Android/swift-core/build.sh android

# Mac 비교용 실행 파일
Android/swift-core/build.sh host
```

`PPOMI_SWIFT_TOOLCHAIN`, `PPOMI_SWIFT_ANDROID_SDK`, `ANDROID_NDK_HOME`으로 기존 설치 위치를 지정할 수 있다. 일반 Android 빌드가 의존성을 자동 다운로드하는 것은 아니며 누락되면 `setup.sh` 실행 안내와 함께 실패한다.

공유 라이브러리는 `Android/swift-core/build/jniLibs/arm64-v8a`에 생성된다. `libppomi_accounting.so`는 작은 JNI 어댑터, `libppomi_accounting_core.so`는 공통 Swift 코어다. `package-runtime.py`가 ELF 의존성을 따라 필요한 Swift/Foundation/ICU/C++ 라이브러리만 함께 패키징한다. 현재 18개 라이브러리의 압축 전 총합은 약 79 MiB다. API 28 이상을 요구하며 현재 x86_64·실기기 배포는 검증하지 않았다.

## 합성 예시와 검증

빌드 시 원본 `AccountingData/example.json`을 `build/assets/accounting-example.json`에 복사하고 원본 경로·SHA-256·`synthetic` 출처를 기록한다. Android의 예시 보고서는 **합성 데이터**라고 표시하며 실사용자 장부에 저장하지 않는다. Mac의 개인 SQLite 파일, 인증 프로필, Keychain 자료를 Android로 가져오지 않는다.

```sh
python3 Android/swift-core/tests/test-parity.py --serial emulator-5554
```

테스트는 같은 합성 입력을 Mac Swift 실행 파일, Android Swift 실행 파일, Android Java의 실제 `SharedAccounting` JNI 래퍼에 각각 전달한다. 단순한 결과 일치뿐 아니라 알려진 기대 금액·범위·오류도 확인한다. JNI 경로는 Android `app_process`에서 실행하며 앱 UI를 열거나 ADB 포트 전달을 바꾸지 않는다.

2026-09-09, Pixel 8 API 35 ARM64 에뮬레이터에서 **14개 사례 모두 통과**했다. 세 경로의 JSON 결과가 일치했다.

- 화폐 100000 원본 → 평가 비용 40000 + 관리 자산 60000, 시간 120 → 48 + 72. 별도 사업 장부는 빈 상태 유지.
- `9007199254740993`의 정수 정확성, 한글·이모지 보존.
- 이전 자료의 scope 미분류와 원문 누락 보존, 평가 철회와 원본 보존.
- 소유자 불일치, 다른 장부 계정, 차대 불일치, 소수 최소단위, 잔액 오버플로, 중복 ID, 잘못된 날짜, 사업 ID 소유자 충돌, 재무 장부의 시간 단위 거절.

기계 판독 결과는 `Android/swift-core/build/parity-result.json`에 기록한다. 이 작업은 기존 공통 회계 소스의 동작을 변경하지 않았다. Android SQLite 저장·사용자 장부 가져오기·공간 데이터 코어는 이번 공통 라이브러리 범위에 포함되지 않는다.

## 공식 자료

[Swift SDK for Android 시작 안내](https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html)는 버전이 일치하는 공개 Swift 툴체인, Android SDK, NDK와 Android 공유 라이브러리/JNI 배포 방식을 설명한다. [Swift macOS 설치 안내](https://www.swift.org/install/macos/)의 Swiftly를 사용자 범위로 설치했다. 자동 바인딩 생성기가 필요하지 않은 작은 JSON 경계이므로 이 프로젝트는 C ABI와 JNI 어댑터를 직접 사용한다.
