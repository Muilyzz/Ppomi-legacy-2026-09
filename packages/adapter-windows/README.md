# adapter-windows

Windows `OsAdapter` for `playbook-runtime`. Maps focus / click / type / read-screen onto the existing `executors/windows` tools.

This is not a second playbook runner, and it is not a generic `adapter` package.

## Mapping

| `OsAdapter` | `executors/windows` tool |
| --- | --- |
| `focus(target)` | `app_open` `{ target }` |
| `readScreen()` | `screen_read` |
| `click(target)` | fresh `screen_read`, then `ui_tap` `{ nodeId }` |
| `type(target, text)` | fresh `screen_read`, then `ui_type` `{ nodeId, text }` |

Live UI Automation stays in `executors/windows`. This package talks to that tool surface. Tests use `FixtureWindowsExecutorTools` (in-memory window + nodes). They do not start the C# helper or drive a real desktop.

## Out of scope

- Device-approval / Mac-approver / hub login (`beginSignIn`, `completeSignIn`, `configureDevice`, …)
- Live `playbook-kr-cert` issuance (content + fixtures live in that package)
- A second `playbook-runtime`
- Package titles `core`, `common`, `engine`, `util`, `shared`, `adapter`, or `runtime`

```ts
import { FixedPermissionGate, PlaybookRuntime } from "../playbook-runtime/src/index.ts";
import { FixtureWindowsExecutorTools, WindowsAdapter } from "adapter-windows";

const tools = new FixtureWindowsExecutorTools({
  appLabel: "Demo App",
  packageName: "win:1:1",
  nodes: [{ text: "Next", clickable: true, editable: false }],
});
const result = new PlaybookRuntime(
  new WindowsAdapter(tools),
  new FixedPermissionGate(["ui.read", "ui.control"]),
).run({
  id: "demo",
  steps: [{ id: "go", kind: "click", target: "Next" }],
});
```

## Tests

```sh
npm --prefix packages/adapter-windows test
```
