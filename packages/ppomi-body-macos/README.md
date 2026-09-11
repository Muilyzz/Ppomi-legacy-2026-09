# ppomi-body-macos

macOS `OsUiDriver` for `ppomi-body`. Maps focus / click / type / read-screen onto Mac native tool names (`browser_open` / `screen_read` / `ui_tap` / `ui_type`) — the same AX-class names as `MacUI.swift` (PR #12).

`focus` names an already-running app (`browser_open({ app })`). It is never `browser_open({ url })`.

Live Accessibility is `LiveMacosNativeTools` (System Events / AX + HID click fallback for web content). Tests use `FixtureMacosNativeTools`.

## Tests / 1-step example

```sh
npm --prefix packages/ppomi-body-macos test
node --experimental-strip-types packages/ppomi-body-macos/example/src/main.ts
```

Live Safari AX (physical Mac; 손쉬운 사용 + Automation). Off-macOS or without a grant the live step SKIPs (exit 0):

```sh
PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-macos/example/src/main.ts
PPOMI_BODY_AX=1 node --experimental-strip-types packages/ppomi-body-macos/example/src/main.ts
PPOMI_MAC_BROWSER=chrome PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-macos/example/src/main.ts
```
