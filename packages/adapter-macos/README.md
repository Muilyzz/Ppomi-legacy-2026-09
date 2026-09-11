# adapter-macos

macOS `OsAdapter` for `playbook-runtime`. Maps focus / click / type / read-screen onto the Mac MCP / native-tools names.

This is not a second playbook runner, and it is not a generic `adapter` package.

## Mapping

Investigated Swift MCP (`Ppomi/Sources/Ppomi/Serve/Tools.swift`, `MCP.swift`, `MacUI.swift`) and the Mac bridge (`MacBrowser.swift`, `AgentNative.swift`, `AgentExecutor.swift`).

Agents already call these through MCP `tools/call` and the in-app executor `executeTool`. There is no second parallel API.

| `OsAdapter` | This package calls | Mac native today |
| --- | --- | --- |
| `focus(target)` | `browser_open` `{ app }` | **Exists.** `Tools.browser_open` → `MacBrowser.open`. Chrome by default; `browser: "safari"` opens Safari. Args are `app` (playbook ID), `url` (HTTP(S)), optional `browser`. |
| `readScreen()` | `screen_read` | **Exists.** AX tree of the frontmost Chrome/Safari, or `app=chrome\|safari`. JSON matches Windows: `snapshotId`, `packageName`, `appLabel`, `nodes[]`, `truncated`. |
| `click(target)` | fresh `screen_read`, then `ui_tap` `{ nodeId }` | **Exists.** `ui_tap` also accepts screen `x,y` (same point space as `nodes[].bounds`). |
| `type(target, text)` | fresh `screen_read`, then `ui_type` `{ nodeId, text }` | **Exists.** `ui_type` can omit `nodeId` and type into the focused field. |

Live Accessibility is implemented in `MacUI.swift`. Tests in this package still use `FixtureMacosNativeTools` (in-memory window + nodes). They do not grant Accessibility, drive Chrome/Safari, or talk to the Mac hub.

## How to invoke (MCP / native-tools)

Register Ppomi as MCP (`/Applications/뽀미.app/Contents/MacOS/Ppomi --mcp`) or use the in-app / Tauri executor `executeTool`. Names are the same.

### `browser_open`

```json
{ "name": "browser_open", "arguments": { "url": "https://example.com/" } }
{ "name": "browser_open", "arguments": { "app": "accountinfo" } }
{ "name": "browser_open", "arguments": { "url": "https://example.com/", "browser": "safari" } }
```

Chrome is the default. `browser` is `chrome` or `safari`. Success text names the browser that opened.

### `screen_read`

```json
{ "name": "screen_read", "arguments": {} }
{ "name": "screen_read", "arguments": { "app": "chrome" } }
{ "name": "screen_read", "arguments": { "app": "safari" } }
```

`app` omitted → frontmost Chrome or Safari. Named values: `chrome`, `safari`, `Google Chrome`, `Safari`, or those bundle IDs. Other apps are rejected. Ppomi's own windows are not read.

Reply JSON (also `structuredContent` on MCP / executor):

```json
{
  "snapshotId": "…",
  "packageName": "com.google.Chrome",
  "appLabel": "Google Chrome",
  "truncated": false,
  "nodes": [
    {
      "id": "snapshot:1",
      "parentId": "snapshot:0",
      "text": "More information",
      "role": "link",
      "clickable": true,
      "editable": false,
      "visible": true,
      "enabled": true,
      "password": false,
      "bounds": { "left": 20, "top": 80, "right": 180, "bottom": 104 }
    }
  ]
}
```

`nodes[].id` is valid only until the next `ui_tap` / `ui_type` or 15 seconds. Password fields are `[protected]`. Tree cap: 500 nodes, 20 levels, 5 seconds.

### `ui_tap`

```json
{ "name": "ui_tap", "arguments": { "nodeId": "snapshot:1" } }
{ "name": "ui_tap", "arguments": { "x": 100, "y": 92 } }
```

Use `nodeId` **or** `x,y`, not both. Coordinates are screen points in the same space as `bounds`. Web content (`AXWebArea` / `AXLink`) clicks the live AX frame center — Chrome often reports AXPress success with no effect. Browser chrome (tabs/toolbar) still uses AXPress, then a click if Press fails. The window is re-raised and the point must sit in a live frame (not a Stage Manager thumbnail). Payment/purchase labels and password nodes are refused (`protected_action`). After a tap, read again.

### `ui_type`

```json
{ "name": "ui_type", "arguments": { "nodeId": "snapshot:2", "text": "hello" } }
{ "name": "ui_type", "arguments": { "text": "hello" } }
```

`text` is required (max 4096). `nodeId` optional: omit to type into the focused field. AX Value is preferred; otherwise Unicode key events in 16-unit chunks after a short focus wait. No clipboard. Password fields and control characters are refused. Contract errors start with `오류: stale_screen` / `오류: protected_action` (not enum case names).

Needs macOS Accessibility (손쉬운 사용) for live calls. Record-focus (`기록 집중`) blocks these tools like `browser_open`.

## Live smoke steps

Leave this to a physical Mac worker after the merge-ready PR. No Google login, device approval, or hub auth.

1. Grant 뽀미 **손쉬운 사용**. Confirm Chrome and/or Safari are installed.
2. Connect MCP or start an in-app text session so `executeTool` is admitted.
3. `browser_open` `{ "url": "https://example.com/" }` → Chrome shows Example Domain. Optional: same URL with `"browser": "safari"`.
4. `screen_read` `{}` or `{ "app": "chrome" }` → JSON includes `Example Domain` (or the Korean/localized equivalent) and at least one clickable or editable node with `bounds`.
5. `ui_type` `{ "text": "ppomi-smoke" }` after focusing the address or a text field, **or** `ui_type` with a fresh editable `nodeId` from step 4. `screen_read` again and confirm the text (or that the field is no longer empty). Do not type passwords or real accounts.
6. `ui_tap` a harmless link/button `nodeId` from a **fresh** `screen_read` (Example Domain's “More information” is enough). Optional: tap the same control with `x,y` at the node center. `screen_read` again and confirm the page or focus changed.
7. Confirm a second `ui_tap` with the old `nodeId` returns `stale_screen`. Confirm `ui_tap` on a 결제/구매 label is `protected_action` if such a node appears — do not complete a payment.

Stop after this loop. Do not add playbook content packs here.

## Out of scope

- Device-approval / Mac-approver / hub login (`beginSignIn`, `completeSignIn`, `configureDevice`, …)
- `playbook-kr-cert` content
- A second `playbook-runtime`
- Package titles `core`, `common`, `engine`, `util`, `shared`, `adapter`, or `runtime`
- Waiting on Windows UIA

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

Swift fixture tests (no live AX):

```sh
swift test --package-path Ppomi --filter MacUIToolsTests
```
