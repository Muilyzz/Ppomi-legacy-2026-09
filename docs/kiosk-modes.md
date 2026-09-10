# 기기 키오스크화: 폴드 8 · 아이패드 · 맥 대칭표 (2026-09-10 조사)

## 정정: 잠그는 게 아니라 "주 앱 기기"

사용자 확인(2026-09-10): 원하는 것은 화면이 꺼지고 잠기는 보통 기기인데 **한 앱이 주로 쓰이는 상태**다. 그러면 축은 lock task가 아니라 세 가지다. ① 깨우면 그 앱이 있나(홈이 앱인가) ② 화면이 꺼져 있어도 잠금 화면에 그 앱이 있나 ③ 나머지 앱은 부수인가(몇 개만 쓰는 사람용 단순 모드).

| 축 | Galaxy Z Fold 8 (Android 17 / One UI 9) | iPad (iPadOS 26·27) | Mac (macOS 26·27) |
|---|---|---|---|
| ① 홈 = 앱 | **기본 홈 앱(런처) 교체**: MainActivity에 `HOME`+`DEFAULT` 카테고리 선언 → 설정 → 앱 → 기본 앱 선택 → 홈 앱. 커버·메인 둘 다 그 런처가 되고 홈 제스처 = 뽀미 복귀. 서드파티 런처의 커버/메인 별도 레이아웃은 Smart Launcher 정도만 지원 | **불가**(런처 교체 없음). 대체: 집중 모드에서 홈 페이지를 뽀미 한 장만 보이게. 깨우면 마지막 앱이 복원되므로 뽀미를 열어 두면 그게 곧 홈 | **전용 표준 계정 + 자동 로그인 + 로그인 항목(SMAppService) + Dock 자동 숨김**. 잠자기·화면 잠금 그대로, 깨우면 창 복원 |
| ② 잠금 화면 존재 (화면 꺼짐 허용) | **Now Bar**: Android 16 Live Updates(`Notification.ProgressStyle`, 17에서 MetricStyle 추가)를 One UI 8부터 서드파티에 개방. AOD·잠금 화면·상태바 칩. 그 외 잠금 화면 좌·우 하단 바로가기 앱, 잠금 화면 위젯 | **Live Activity**(ActivityKit, iPadOS 17+ 잠금 화면) + 잠금 화면 위젯(iPadOS 17+) | 잠금 화면 위젯 없음. 메뉴 막대 아이콘(뽀미는 이미 MenuBarExtra). macOS 26의 메뉴 막대 Live Activity는 **아이폰 것만** 표시 |
| ③ 몇 개 앱만 (부모님용) | **간편 모드**(Easy mode): 큰 글자·단순 홈, 홈 앱은 유지 | **보조 접근**(Assistive Access, iPadOS 17+): 고른 앱만, 큰 UI, 종료엔 암호. **iPadOS 26부터 앱이 전용 화면을 제공**(SwiftUI `AssistiveAccess` 씬, Info.plist `UISupportsFullScreenInAssistiveAccess`) | 없음. 집중 모드(허용 앱 알림) + 스크린 타임 앱 제한 정도 |

대칭 결론: 이 축에서는 **폴드 ↔ Mac이 대칭**(런처 교체 ↔ 로그인 항목 계정)이고 **iPad가 빈칸**(홈 교체 불가). 대신 iPad는 ③ 보조 접근이 가장 좋고 개발자 API까지 있어 부모님용 "몇 개 앱만" 기기로는 iPad가 제일 낫다. 앞서 조사한 잠금(lock task) 층은 아래에 참고로 남긴다.

### 뽀미에 적용 (가장 낮은 계단)

- **폴드 8**: 두 갈래. (a) 홈 교체: MainActivity intent-filter에 `HOME`/`DEFAULT` 두 줄 추가. 앱 서랍은 `BridgeAccessPolicy`가 이미 `CATEGORY_LAUNCHER`를 나열하므로 그 목록을 화면 하나로 보이면 끝. (b) 홈 유지 + 존재만: 에이전트 세션 동안 `ProgressStyle` Live Update 알림 하나 → Now Bar·AOD에 뽀미가 산다. 잠금 화면 하단 바로가기를 뽀미로. 커버 화면은 "커버 화면에서 앱 이어서 사용 = 항상". (b)가 코드가 적고 기존 홈을 안 건드린다.
- **iPad**: 집중 모드 홈 한 장 + Live Activity. 부모님 기기는 보조 접근에 뽀미만 넣고 `AssistiveAccess` 씬으로 큰 화면 하나 제공.
- **Mac**: 로그인 항목 등록(SMAppService, 현재 없음) + 부모님 Mac mini는 표준 계정 자동 로그인. 그 이상은 필요 없다.

## 참고: 진짜 잠그는 층 (lock task / Single App Mode)

"키오스크화" = 한 기기를 뽀미(또는 지정 앱 몇 개)만 쓰는 전용 기기로 묶는 것. 세 플랫폼 모두 같은 세 층으로 나뉜다.

| 층 | Galaxy Z Fold 8 (SM-F971N, Android 17 / One UI 9) | iPad (iPadOS 26·27) | Mac (macOS 26·27) |
|---|---|---|---|
| ① 사람이 켜는 고정 (설정만, 코드 없음) | **앱 고정** (screen pinning): 설정 → 보안 및 개인정보 보호 → 기타 보안 설정 → 앱 고정 + "고정 해제 전 잠금 화면 요구". 최근 앱에서 아이콘 → 이 앱 고정. 해제 = 뒤로+최근 앱 길게. 재부팅하면 풀림 | **사용법 유도** (Guided Access): 설정 → 손쉬운 사용 → 사용법 유도. 앱 열고 상단 버튼 3번. 터치 영역·하드웨어 버튼·키보드·시간 제한 지정. 26·27에서 변경 없음, 잠긴 동안 윈도잉 꺼짐 | **없음**. 가장 가까운 것은 스크린 타임 앱 제한 + 표준 계정 |
| ② 앱이 스스로 들어감 | `activity.startLockTask()` — 허용 목록 밖이면 ①의 확인 대화상자가 뜨는 screen pinning | `UIAccessibility.requestGuidedAccessSession(enabled:)` = **ASAM**. 감독(supervised) 기기 + Restrictions 프로파일의 `autonomousSingleAppModePermittedAppIDs` 필요. Apple Configurator 편집기엔 이 키가 없어 .mobileconfig 손편집 | `NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching, .disableForceQuit, .disableSessionTermination, .disableHideApplication, .disableAppleMenu]` + 전체화면 + 자동 로그인 + 로그인 항목 (Apple TN2062 "Creating Kiosks"). 흉내일 뿐, ⌘Q·전원 버튼·ssh는 못 막음 |
| ③ 관리자 완전 키오스크 | **Device Owner + lock task**: `adb shell dpm set-device-owner` → `setLockTaskPackages` / `setLockTaskFeatures` / `addPersistentPreferredActivity(HOME)` / `setKeyguardDisabled` / `setStatusBarDisabled` / `STAY_ON_WHILE_PLUGGED_IN`. 잠금화면 기본 꺼짐, 알림·상태바 기본 꺼짐(플래그로 켬). 조건: 기기에 **계정이 하나도 없어야** 함(구글·삼성 계정 모두) → 사실상 초기화 후 설정 | **Single App Mode**: Apple Configurator(감독 필요, 초기화 동반) 또는 MDM `com.apple.app.lock`. 재부팅해도 유지 | **없음**. Mac용 ASAM 페이로드(`com.apple.asam`)는 있으나 ABM/ASM 등록 기기 + 앱스토어 앱 불가 + 진입 API는 사실상 평가 entitlement 필요 (개발자 포럼 미해결) |
| ④ 시험 모드 (양쪽 동일 API) | — | `AEAssessmentSession` | `AEAssessmentSession` — **macOS 27에서 대폭 확장**: 메뉴막대·Dock 허용 목록, `allowOnlyParticipantsToRun`, 파일 접근 허용 목록, 입력기 제한. 하지만 여전히 제한 entitlement(`com.apple.developer.automatic-assessment-configuration`) 신청·승인 필요 |

## 폴드 8 특이점

- 삼성 Knox SDK `KioskMode`는 Knox 3.7(API 33)에서 폐기, **Android 16 이상에서는 아예 없음**. 삼성이 미는 대체는 Knox Configure의 **ProKiosk** (Dynamic Edition, 1대 $12.50/년, 2대 이상 $25/대) 또는 Knox Manage 키오스크 위저드(체험판). 개인 1대면 Android 표준 lock task가 더 싸고 같은 결과.
- 계정 제약 우회로로 쓰는 **보조 사용자(pm create-user) 키오스크는 삼성 폰에서 막혀 있음**(태블릿만 가능). 폴드 8에서도 같다고 봐야 함(미검증).
- One UI 8.0 태블릿에서 키오스크 진입이 팝업/멀티윈도우(독립 DeX)를 안 막는 버그가 있었고 8.5 펌웨어에서 수정. 폴드 8은 One UI 9라 해당 없다고 보지만, 키오스크 안에서 팝업 뷰가 열리는지는 한 번 확인.
- Android 17: 키오스크(lock task) 기기는 외부 디스플레이 연결 시 **미러링만** 됨(확장 DeX 불가).
- 커버 화면: 앱 고정/lock task는 기기 단위라 접었을 때 커버에서 뽀미가 이어질지는 "설정 → 디스플레이 → 커버 화면에서 앱 이어서 사용"(항상/안 함/위로 쓸기)에 달림. lock task 상태에서의 실제 동작은 **미검증**.
- Knox Configure로 폴더블 배경·잠금화면을 바꾸면 메인 화면만 적용(KBA-661). ProKiosk를 고를 때 커버 화면 꾸밈은 기대하지 말 것.

## 뽀미에 적용한다면 (가장 낮은 계단)

- **폴드 8(계정 있는 개인 폰)**: ① 앱 고정 켜 두고, 뽀미 `MainActivity`에서 `startLockTask()` 한 줄. 재부팅·해제 후엔 다시 고정 필요. 완전 키오스크(③)는 초기화가 필요하니 부모님용 전용 기기처럼 계정을 안 넣을 기기에만. (사용자 정정 후에는 이 층 자체가 불필요.)
- **iPad(개인)**: ① 사용법 유도로 충분. 뽀미 앱이 스스로 잠그려면 ② ASAM — Mac의 Apple Configurator로 감독 전환(초기화) 후 손편집 프로파일 설치. 이 경로는 한 번 해 두면 코드 한 줄.
- **Mac**: ② `presentationOptions`가 전부. `Ppomi/Sources/Ppomi/Kiosk.swift`의 KioskController는 지금 창 배치만 하고 presentationOptions는 안 씀. 진짜 잠금(④)은 entitlement 신청이 벽. 부모님 Mac mini "게시판"이라면 표준 계정 + 자동 로그인 + 로그인 항목 + Dock 숨김으로 끝.

## 대칭 요약

- **양쪽 다 "한 층씩" 존재**: 사람이 켜는 고정(앱 고정 ↔ 사용법 유도), 앱이 스스로(`startLockTask` ↔ `requestGuidedAccessSession`), 관리자 완전 키오스크(Device Owner ↔ Single App Mode). 이 세 층은 폴드와 아이패드 사이엔 깔끔히 대칭.
- **Mac만 비대칭**: 사람이 켜는 층도, 관리자 층도 없다. 앱 자체의 `presentationOptions`(흉내)와 entitlement 벽 뒤의 `AEAssessmentSession`(진짜)뿐. Apple은 macOS 27에서도 assessment 쪽만 키웠다.
- **진짜 공통 API**는 `AEAssessmentSession` 하나(iPadOS·macOS 동일 프레임워크)인데 승인이 필요해 개인 개발자에게는 사실상 닫혀 있음.

## 출처

- Fold 8 출시·OS: https://www.sammobile.com/news/samsung-galaxy-z-fold-8-everything-to-know/ · https://www.androidauthority.com/samsung-one-ui-9-wifi-restriction-3692279/
- Knox KioskMode 폐기·Android 16 미지원: https://docs.samsungknox.com/devref/knox-sdk/reference/com/samsung/android/knox/kiosk/KioskMode.html · https://docs.samsungknox.com/dev/knox-sdk/features/system-integrators/customization/kiosk-mode/
- One UI 8.0 키오스크+멀티윈도우 버그: https://docs.samsungknox.com/admin/knox-platform-for-enterprise/kbas/kba-1838-entering-kiosk-mode-doesnt-automatically-disable-multi-windows-mode-on-one-ui-8.0-tablet-devices/
- Knox Configure 가격: https://image-us.samsung.com/SamsungUS/business/solutions/industries/government/msrp-price-sheets/01152026/Samsung_Knox_MSRP_Price_File_(December_2025).pdf
- Android lock task: https://developer.android.com/work/dpc/dedicated-devices/lock-task-mode · Android 17 기업 변화: https://bayton.org/android/android-enterprise-faq/android-17-enterprise-features/
- Device owner 계정 제약: https://ccswe.com/app-manager/device-owner/ · 삼성 폰 다중 사용자 불가: https://r2.community.samsung.com/t5/Tech-Talk/Multi-Users-Guest-mode-on-Samsung-Devices/td-p/11044830
- 앱 고정(삼성): https://tapblogging.com/갤럭시-화면-고정-설정-방법-특정-앱-잠금-항상-표시/ · 커버 화면 이어서 사용: https://www.makeuseof.com/i-change-these-android-settings-every-foldable/ · KBA-661: https://docs.samsungknox.com/admin/knox-configure/kbas/kba-661-cannot-set-home-and-lock-screen-for-foldable-devices/
- 사용법 유도: https://support.apple.com/ko-kr/HT202612 · iPadOS 26/27 변화 없음: https://instacheckin.io/blog/ipad-single-app-mode/ · ASAM 키·Configurator 한계: https://support.kioskgroup.com/article/959-autonomous-single-app-mode
- Mac ASAM 페이로드: https://support.apple.com/guide/deployment/autonomous-single-app-mode-payload-settings-dep8a42c4c4a/web · 미해결 포럼: https://developer.apple.com/forums/thread/794852
- macOS presentationOptions: https://developer.apple.com/documentation/appkit/nsapplication/presentationoptions · TN2062: https://developer.apple.com/library/mac/technotes/tn2062/_index.html
- Assessment: https://developer.apple.com/videos/play/wwdc2026/230/ · https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.automatic-assessment-configuration · https://support.apple.com/en-us/101976
- WWDC26 기기 관리 변화(키오스크 관련 없음): https://support.apple.com/guide/deployment/device-management-updates-depd638aa061/web
- Now Bar 서드파티 개방(One UI 8, Live Updates): https://www.androidauthority.com/one-ui-8-live-updates-support-3573794/ · One UI 9 확대: https://www.sammyfans.com/2026/05/21/samsung-now-bar-to-support-more-third-party-apps-in-one-ui-9/
- 보조 접근 개발자 API: https://developer.apple.com/documentation/swiftui/assistiveaccess · https://developer.apple.com/documentation/bundleresources/information-property-list/uisupportsfullscreeninassistiveaccess · https://developer.apple.com/videos/play/wwdc2025/238/
- iPad Live Activity(iPadOS 17+): https://developer.apple.com/documentation/activitykit · 집중 모드 홈 페이지: https://www.ithinkdiff.com/how-focus-mode-ipad-profiles-ipados/
- 폴더블 서드파티 런처: https://www.smartlauncher.net/blog/smart-launcher-embraces-foldables-independent-layouts · 커버 화면 앱 허용: https://www.gadgetbridge.com/how-to/3-ways-to-launch-any-app-on-samsung-galaxy-z-flips-cover-screen/
