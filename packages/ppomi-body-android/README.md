# ppomi-body-android

Android `OsUiDriver` for `ppomi-body`. Maps focus / click / type / read-screen onto `android_*` tools.

Password fields, payment labels, and the Windows `ProtectedLabel` set plus Settings reset/erase rows (초기화 · 공장 초기화 · 재설정 · 삭제 · 제거 · 지우기, reset / erase / factory / delete / remove / uninstall …) are `protected_action`. No device-approval or payment input.

Live UI is `LiveAndroidNativeTools` (`uiautomator dump` + `input tap`). Before every `input tap` / `input text` it re-reads the screen and acts only if the same node (resource-id, class, text, description, bounds) is still there — otherwise `stale_screen`; typing also requires the field to hold focus, admits no control character but `\t`, and single-quotes the text for the device shell. Tests use `FixtureAndroidNativeTools`.

## Tests / 1-step example

```sh
npm --prefix packages/ppomi-body-android test
node --experimental-strip-types packages/ppomi-body-android/example/src/main.ts
```

Live Settings dump+tap (physical device or emulator; `adb` on PATH). A live tap needs an explicit device pin — `PPOMI_ANDROID_SERIAL` or `ANDROID_SERIAL` — a single attached phone is never auto-targeted. No adb, no pin, or a pin that is not attached: the live step SKIPs (exit 0). It taps only a known-safe Settings row (연결 / Wi-Fi / 블루투스 / 알림 / 배터리 / 디스플레이); on any other screen it skips rather than tapping the first clickable row.

```sh
PPOMI_ANDROID_SERIAL=R3CX PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-android/example/src/main.ts
ANDROID_SERIAL=R3CX PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-android/example/src/main.ts
```
