# ppomi-body-android

Android `OsUiDriver` for `ppomi-body`. Maps focus / click / type / read-screen onto `android_*` tools.

Password fields are `protected_action`. No device-approval or payment input.

```sh
npm --prefix packages/ppomi-body-android test
node --experimental-strip-types packages/ppomi-body-android/example/src/main.ts
```
