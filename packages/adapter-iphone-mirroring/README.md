# adapter-iphone-mirroring

`OsAdapter` for `playbook-runtime` over **iPhone Mirroring on Mac**. Maps read / focus / click / type onto the existing `phone_*` MCP tools.

This is **not** on-device iOS Accessibility. Control is the Mac-side iPhone Mirroring window (`com.apple.ScreenContinuity` / `phone.swift`): OCR + pointer/key forwarding. It is also **not** `adapter-macos` desktop AX (`browser_open` / planned `screen_read` / `ui_tap` / `ui_type`). Do not name this package `adapter-phone`.

This is not a second playbook runner, and it is not a generic `adapter` package.

`StepResult.adapter` for this surface is already `"phone"` in `playbook-runtime`. Do not add `os-iphone` or `mirroring`.

## Mapping

Investigated Swift MCP (`Ppomi/Sources/Ppomi/Serve/Tools.swift`) and `phone.swift` (iPhone Mirroring window, not a device-side AX tree).

| `OsAdapter` | This package calls | Existing `phone_*` today |
| --- | --- | --- |
| `readScreen()` | `phone_screen` | **Exists.** OCR of the mirrored iPhone screen. Not Mac desktop AX. |
| `focus(target)` | `phone_open` `{ app }` | **Exists.** Spotlight / playbook launch inside the mirroring window. |
| `click(target)` | `phone_tap` `{ text }` | **Exists.** Text/regex tap. Live tool also accepts `x`/`y`; those are not the playbook contract. |
| `type(target, text)` | `phone_type` `{ text }` | **Exists.** Types into the current field. Target must be on the last `phone_screen`. |
| — | `phone_key` `{ name }` | **Exists.** `home`, `spotlight`, `return`, `escape`, … Not an `OsAdapter` method. |
| — | `phone_scroll` `{ dy }` | **Exists.** Not an `OsAdapter` method. |

`FixtureIphoneMirroringTools` is an in-memory mirrored screen for unit tests. No live mirroring, no iOS AX, no Mac desktop AX.

## Live constraints (not this slice)

Documented here so slice 2 does not rediscover them. This package does **not** open a mirroring session.

- The iPhone must stay **locked** and beside the Mac. Unlocking or using the phone disconnects mirroring (`iPhone 사용 중`).
- The Mac login and the iPhone must use the **same Apple ID** (Continuity / iPhone Mirroring).

## Out of scope

- Live iPhone Mirroring smoke (slice 2)
- On-device iOS Accessibility
- Mac desktop AX (`adapter-macos`)
- Device-approval / Mac-approver / hub login (`beginSignIn`, `completeSignIn`, `configureDevice`, …)
- `playbook-kr-cert` content
- A second `playbook-runtime`
- Package titles `core`, `common`, `engine`, `util`, `shared`, `adapter`, `runtime`, or `adapter-phone`

```ts
import { FixedPermissionGate, PlaybookRuntime } from "../playbook-runtime/src/index.ts";
import { FixtureIphoneMirroringTools, IphoneMirroringAdapter } from "adapter-iphone-mirroring";

const tools = new FixtureIphoneMirroringTools({
  appLabel: "Demo App",
  rows: [{ text: "Next", tappable: true, editable: false }],
});
const result = new PlaybookRuntime(
  new IphoneMirroringAdapter(tools),
  new FixedPermissionGate(["ui.read", "ui.control"]),
).run({
  id: "demo",
  steps: [{ id: "go", kind: "click", target: "Next" }],
});
```

## Tests

```sh
npm --prefix packages/adapter-iphone-mirroring test
```
