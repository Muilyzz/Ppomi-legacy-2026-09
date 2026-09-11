# ppomi-body-macos example

One-step `ppomi-body` smoke. Default: fixture `Runtime` click (no hardware).

Live Safari/Chrome **Accessibility** 1-step: open example.com, `screen_read` the AX tree, `ui_tap` “More information” through `MacosDriver` + `LiveMacosNativeTools`. This is System Events / AX, not window-title Automation and not Playwright.

```sh
node --experimental-strip-types packages/ppomi-body-macos/example/src/main.ts
PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-macos/example/src/main.ts
PPOMI_BODY_AX=1 node --experimental-strip-types packages/ppomi-body-macos/example/src/main.ts
```

`PPOMI_MAC_BROWSER=chrome` optional. Off-macOS, without 손쉬운 사용 / Automation, or with no Safari/Chrome: live **SKIP** (exit 0). Fixture still PASSes.

Grant **손쉬운 사용** (and Safari/Chrome Automation) to the app that launches `node` (Terminal, iTerm, or Cursor).

Deprecated alias (same process):

```sh
PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/adapter-macos/example/src/main.ts
```
