# playbook-runtime

One runtime for playbook steps. Content packs and OS adapters stay in other packages.

## Three layers

| Layer | Count | Role |
| --- | --- | --- |
| `playbook-runtime` | one | Steps, permissions, stop, evidence. No OS calls of its own. |
| `playbook-*` | many | Content only (scenario + fixtures). Example later: `playbook-kr-cert`. |
| `adapter-*` | one per OS | Port implementation: click, type, read-screen, focus. Example later: `adapter-windows`. |

This package is the first layer only. It ships `OsAdapter` and a `DummyAdapter` so the contract can be tested without Windows UI Automation, Mac approval, or hub login.

A later Windows adapter should wrap the existing `executors/windows` tools (`screen_read`, `ui_tap`, `ui_type`, `app_open`). Do not grow a second engine next to this runtime.

## Contract

- Control steps (`focus`, `click`, `type`) need `ui.control`. `read` needs `ui.read`.
- Before a mutation, the runtime reads the screen and checks declared screen/target/focus preconditions.
- Permission denial or a failed precondition **stops the run**. Later steps are not sent to the adapter.
- Evidence records each attempted step and its outcome. `completed` means declared steps finished. It is not a business-result claim and does not write a journal.

```ts
import { DummyAdapter, FixedPermissionGate, PlaybookRuntime } from "playbook-runtime";

const adapter = new DummyAdapter({ title: "Demo", texts: ["Next"], focused: null });
const runtime = new PlaybookRuntime(adapter, new FixedPermissionGate(["ui.read", "ui.control"]));
const result = runtime.run({
  id: "demo",
  steps: [{ id: "go", kind: "click", target: "Next" }],
});
```

## Tests

```sh
npm --prefix packages/playbook-runtime test
```
