# playbook-runtime

One package for playbook steps, permissions, stop, and evidence. Content packs and OS adapters stay in other packages.

Package titles are domain-specific. Do not add `core`, `common`, `engine`, `util`, `shared`, `runtime`, `adapter`, `playbook-core`, or `playbook-content`.

## Three layers

| Package | Count | Role |
| --- | --- | --- |
| `playbook-runtime` | one | Steps, permissions, stop, evidence. No OS calls of its own. |
| `playbook-kr-cert` | later, one of many | Korean certificate content (scenario + fixtures). Not this slice. |
| `adapter-windows` | one OS | Windows click / type / read-screen / focus. Lives in `packages/adapter-windows`. |

This package is `playbook-runtime` only. It ships `OsAdapter` and a `DummyAdapter` so the contract can be tested without Windows UI Automation or hub login.

A later `adapter-windows` package should wrap the existing `executors/windows` tools (`screen_read`, `ui_tap`, `ui_type`, `app_open`). Do not grow a second `playbook-runtime`.

Ppomi onboarding and playbook packages have **no device-approval or Mac-approver gate**. Do not add approved-device checks to `playbook-runtime`, `adapter-windows`, `playbook-kr-cert`, or their tests.

## Contract

- Control steps (`focus`, `click`, `type`) need `ui.control`. `read` needs `ui.read`. These are UI step permissions, not device approval.
- Before a mutation, `playbook-runtime` reads the screen and checks declared screen/target/focus preconditions.
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
