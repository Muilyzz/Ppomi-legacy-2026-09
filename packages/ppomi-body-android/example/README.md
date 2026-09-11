# ppomi-body-android example

One-step `ppomi-body` smoke. Default: fixture `Runtime` click (no device).

Live **UIAutomator** 1-step: open Settings, `android_screen` via `uiautomator dump`, `android_click` via `input tap` through `AndroidDriver` + `LiveAndroidNativeTools`. This is dump+tap, not only `adb shell am start`.

```sh
node --experimental-strip-types packages/ppomi-body-android/example/src/main.ts
PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-android/example/src/main.ts
```

`ANDROID_SERIAL` / `PPOMI_ANDROID_SERIAL` optional when more than one device. No adb, no authorized device, or dump with no clickable row: live **SKIP** (exit 0). Fixture still PASSes.
