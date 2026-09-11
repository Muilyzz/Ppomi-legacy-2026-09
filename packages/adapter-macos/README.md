# adapter-macos

macOS `OsAdapter` for `playbook-runtime`. Maps focus / click / type / read-screen onto existing Mac native tool names where they exist.

This is not a second playbook runner, and it is not a generic `adapter` package.

## Mapping

Investigated Swift MCP (`Ppomi/Sources/Ppomi/Serve/Tools.swift`, `MCP.swift`) and the Mac bridge (`MacBrowser.swift`, `AgentNative.swift`, `Mirroring.swift`).

| `OsAdapter` | This package calls | Existing Mac native today |
| --- | --- | --- |
| `focus(target)` | `browser_open` `{ app }` | **Exists.** `Tools.browser_open` → `MacBrowser.open`. Chrome navigation only (`com.google.Chrome`). Args are `app` (playbook ID) or `url` (HTTP(S)). There is no Mac `app_open`. |
| `readScreen()` | `screen_read` | **No Mac MCP tool.** Same name as the Windows executor / Android voice bridge (`AX` / `screen_read`-class). Internal AX text walk in `Mirroring.texts` is the iPhone-mirroring overlay, not a desktop tool. Other surfaces: `phone_screen`, `windows_screen`. |
| `click(target)` | fresh `screen_read`, then `ui_tap` `{ nodeId }` | **No Mac MCP tool.** Same planned AX-class name as Windows/Android `ui_tap`. Other surfaces: `phone_tap`, `windows_click`. AX press exists only as `AXUIElementPerformAction(kAXPressAction)` inside mirroring recovery. |
| `type(target, text)` | fresh `screen_read`, then `ui_type` `{ nodeId, text }` | **No Mac MCP tool.** Same planned AX-class name as Windows/Android `ui_type`. Other surfaces: `phone_type`, `windows_type`. |

Live Accessibility stays out of this slice. Tests use `FixtureMacosNativeTools` (in-memory window + nodes). They do not grant Accessibility, drive Chrome/Safari, or talk to the Mac hub.

## Out of scope

- Live Mac Accessibility / Chrome / Safari automation (slice 2)
- Device-approval / Mac-approver / hub login (`beginSignIn`, `completeSignIn`, `configureDevice`, …)
- `playbook-kr-cert` content
- A second `playbook-runtime`
- Package titles `core`, `common`, `engine`, `util`, `shared`, `adapter`, or `runtime`

```ts
import { FixedPermissionGate, PlaybookRuntime } from "../playbook-runtime/src/index.ts";
import { FixtureMacosNativeTools, MacosAdapter } from "adapter-macos";

const tools = new FixtureMacosNativeTools({
  appLabel: "Demo App",
  nodes: [{ text: "Next", clickable: true, editable: false }],
});
const result = new PlaybookRuntime(
  new MacosAdapter(tools),
  new FixedPermissionGate(["ui.read", "ui.control"]),
).run({
  id: "demo",
  steps: [{ id: "go", kind: "click", target: "Next" }],
});
```

## Tests

```sh
npm --prefix packages/adapter-macos test
```
