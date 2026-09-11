# ppomi-body-android example

One-step `ppomi-body` smoke. Default: fixture `Runtime` click.

Live device: `PPOMI_BODY_LIVE=1` with `adb` and an authorized device opens Settings. Multiple devices need `ANDROID_SERIAL` or `PPOMI_ANDROID_SERIAL`. No device / no adb skips (exit 0).

```sh
node --experimental-strip-types packages/ppomi-body-android/example/src/main.ts
PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-android/example/src/main.ts
```
