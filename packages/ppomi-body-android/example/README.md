# ppomi-body-android example

One-step `ppomi-body` smoke. Default: fixture `Runtime` click (no device).

Live **UIAutomator** 1-step: open Settings, `android_screen` via `uiautomator dump`, `android_click` via `input tap` through `AndroidDriver` + `LiveAndroidNativeTools`. This is dump+tap, not only `adb shell am start`. The Tauri shell uses the same tools via `run_path --body android` (MZZ-58).

```sh
node --experimental-strip-types packages/ppomi-body-android/example/src/main.ts
PPOMI_ANDROID_SERIAL=emulator-5554 PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-android/example/src/main.ts
```

A live tap needs `PPOMI_ANDROID_SERIAL` or `ANDROID_SERIAL`. A single attached device is never auto-targeted. Emulator: `scripts/android-emulator.sh boot`, then pin `emulator-5554`. No adb, no pin, pin not attached, or no safe Settings row: live **SKIP** (exit 0). Fixture still PASSes.
