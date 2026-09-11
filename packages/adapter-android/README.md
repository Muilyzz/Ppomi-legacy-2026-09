# adapter-android

Android `OsAdapter` for `playbook-runtime`. Maps focus / click / type / read-screen onto the existing Ppomi `android_*` MCP tools.

This is not a second playbook runner, and it is not a generic `adapter` / `core` / `common` / `util` package.

## Mapping

Investigated `Ppomi/Sources/Ppomi/Serve/AndroidTools.swift` and `docs/android-control.md`. Mac MCP exposes eight `android_*` tools. `OsAdapter` has four methods; the rest stay off this port.

| `OsAdapter` | This package calls | Existing Android tool today |
| --- | --- | --- |
| `focus(target)` | `android_open` `{ packageName }` | **Exists.** Allowed packages only: `com.android.settings`, `com.ppomi.androidtarget`, `com.ppomi.androidbridge`. Adapter resolves an accessibility app label from the last `android_screen` to that package. A store / bank / payment package is refused. |
| `readScreen()` | `android_screen` | **Exists.** Accessibility tree (`nodes` with snapshot-scoped `id`, text, clickable, editable). Live PNG capture is a later slice. Session `nodeId` and pixel bounds are not playbook selectors. |
| `click(target)` | fresh `android_screen`, then `android_click` `{ nodeId }` | **Exists.** Resolves accessibility name / content description to one clickable node. |
| `type(target, text)` | fresh `android_screen`, then `android_type` `{ nodeId, text }` | **Exists.** Hangul supported. Password fields are fail-closed (`protected_action`). |

| Existing Android tool | On `OsAdapter` this slice? |
| --- | --- |
| `android_swipe` | **No.** Scroll/swipe exists as pixel-to-pixel gesture. `OsAdapter` has no scroll method. Coordinates are not a playbook contract. |
| `android_tap` | **No.** Pixel tap. Same coordinate rule as `android_swipe`. |
| `android_key` | **No.** System back / home / recents. Not an `OsAdapter` method. |
| `android_status` | **No.** Connection probe. Not an `OsAdapter` method. |

Live Accessibility / emulator / ADB stays out of this slice. Tests use `FixtureAndroidNativeTools` (in-memory window + nodes). They do not start an emulator, talk to the Mac hub, or drive a real device.

`StepResult.adapter` for this package is `os-android` (sibling of `os-windows` / `os-macos`). `phone` remains the iPhone-mirroring adapter.

## Fail-closed

- `android_open` allowlist only. Play Store / payment / bank packages are not opened.
- Password `android_type` is refused. The adapter does not send secrets to the tool.
- Stale snapshot `nodeId` is refused (`stale_screen`).
- Ambiguous accessibility names are refused (`ambiguous_target`).
- There is no payment-gate bypass, device-approval input, or Mac-approver check.

## Out of scope

- Live device / emulator / scrcpy smoke (slice 2)
- Workbench / runtime assembly (later)
- Device-approval / Mac-approver / hub login (`beginSignIn`, `completeSignIn`, `configureDevice`, …)
- `playbook-kr-cert` content
- A second `playbook-runtime`
- Package titles `core`, `common`, `engine`, `util`, `shared`, `adapter`, or `runtime`

```ts
import { FixedPermissionGate, PlaybookRuntime } from "../playbook-runtime/src/index.ts";
import { AndroidAdapter, FixtureAndroidNativeTools } from "adapter-android";

const tools = new FixtureAndroidNativeTools({
  appLabel: "Demo App",
  packageName: "com.ppomi.androidtarget",
  nodes: [{ text: "Next", clickable: true, editable: false }],
});
const result = new PlaybookRuntime(
  new AndroidAdapter(tools),
  new FixedPermissionGate(["ui.read", "ui.control"]),
).run({
  id: "demo",
  steps: [{ id: "go", kind: "click", target: "Next" }],
});
```

## Tests

```sh
npm --prefix packages/adapter-android test
npm --prefix packages/playbook-runtime test
```
