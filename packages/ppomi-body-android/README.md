# ppomi-body-android

Android `OsUiDriver` for `ppomi-body`. Maps focus / click / type / read-screen onto `android_*` tools.

Password fields and payment labels are `protected_action`. No device-approval or payment input.

Live UI is `LiveAndroidNativeTools` (`uiautomator dump` + `input tap`). Tests use `FixtureAndroidNativeTools`.

## Tests / 1-step example

```sh
npm --prefix packages/ppomi-body-android test
node --experimental-strip-types packages/ppomi-body-android/example/src/main.ts
```

Live Settings dump+tap (physical device or emulator; `adb` on PATH). No adb / no device the live step SKIPs (exit 0):

```sh
PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-android/example/src/main.ts
ANDROID_SERIAL=R3CX PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-android/example/src/main.ts
```
