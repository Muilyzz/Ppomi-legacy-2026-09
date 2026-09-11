# playbook-runtime

One package for playbook steps, permissions, stop, and evidence. Content packs and OS drivers stay in other packages.

Product names (**ppomi-path**, **ppomi-body**) are locked in [docs/glossary.md](docs/glossary.md). This package is not a general SDK.

Package titles are domain-specific. Do not add `core`, `common`, `engine`, `util`, `shared`, `runtime`, `adapter`, `playbook-core`, or `playbook-content`.

## Packages

| Package | Count | Role |
| --- | --- | --- |
| `playbook-runtime` | one | Steps, permissions, stop, evidence. No OS or browser calls of its own. |
| `playbook-kr-cert` | later, one of many | Korean certificate content (scenario + fixtures). Not this slice. |
| `driver-windows` | later, one OS | Windows click / type / read-screen / focus. Not this slice. |
| `driver-macos` | later, one OS | macOS click / type / read-screen / focus. Sibling OS package. |
| `driver-playwright` | one page | In-page web `goto` / `click` / `fill` / `waitFor`. Lives in `packages/driver-playwright`. |

This package is `playbook-runtime` only. It ships `OsUiDriver` + `DummyAdapter` and `BrowserPageDriver` + `DummyPageAdapter` so each contract can be tested without UIA, Accessibility, a live browser, or hub login.

`OsUiDriver` is native chrome: `readScreen` / `focus` / `click` / `type`. `BrowserPageDriver` is the in-page port: `readPage` / `goto` / `click` / `fill` / `waitFor`. Do not implement Playwright as `OsUiDriver`. Do not grow a second `playbook-runtime` package. `PagePlaybookRuntime` in this package runs page steps.

A later `driver-windows` package should wrap the existing `executors/windows` tools (`screen_read`, `ui_tap`, `ui_type`, `app_open`). `driver-macos` maps the same OS port onto Mac native names. `driver-playwright` implements `BrowserPageDriver` and exposes those page operations as local Vercel AI SDK tools (`createPlaywrightPageAiTools`). Native / cert UI stays on `OsUiDriver`.

## Playwright vs OS adapter

Pick the port from the **surface**, not the app name. Full rules: [docs/adapter-selection.md](docs/adapter-selection.md).

| Surface | Runner | Port | Package |
| --- | --- | --- | --- |
| In-page web DOM, forms, locator waits | `PagePlaybookRuntime` | `BrowserPageDriver` | `driver-playwright` |
| Native windows, system dialogs, cert UI, non-DOM chrome | `PlaybookRuntime` | `OsUiDriver` | `driver-windows` (UIA), `driver-macos` (AX) |

An in-page "Next" button is Playwright. A Korean certificate window, a native file picker, or a browser OS dialog is UIA/AX. Do not replace the OS adapters with Playwright.

**Hybrid handoff:** page request → watch for the native window → `PlaybookRuntime` → back to `PagePlaybookRuntime` for the page result. Do not leave Playwright blocked in `waitFor` on a locator that only appears after a native modal is dismissed. The modal is not in the DOM. Do not treat that timeout as "the native step never ran" and retry a signing step.

Permanent contracts are page locators / URL and OS accessibility text (`target`). Do **not** store coordinates, pixel boxes, or session node IDs as playbook selectors. Vision, OCR, and VLM are fallbacks when the DOM or accessibility tree is missing — not the default path.

Ppomi onboarding and playbook packages have **no device-approval or Mac-approver gate**. Do not add approved-device checks to `playbook-runtime`, `driver-windows`, `driver-macos`, `driver-playwright`, `playbook-kr-cert`, or their tests.

## Contract

- OS control steps (`focus`, `click`, `type`) need `ui.control`. OS `read` needs `ui.read`. Page control steps (`goto`, `click`, `fill`) need `ui.control`. Page `read` / `waitFor` need `ui.read`. These are UI step permissions, not device approval.
- Before an OS mutation, `PlaybookRuntime` reads the screen and checks declared screen/target/focus preconditions. Before a page mutation, `PagePlaybookRuntime` reads the page and checks declared url/text/locator preconditions (`waitFor` is the wait and is not fail-closed on locator presence).
- Permission denial or a failed precondition **stops the run**. Later steps are not sent to the adapter.
- Evidence records each attempted step and its outcome. `completed` means declared steps finished. It is not a business-result claim and does not write a journal.
- `RunResult.stepResults` is one `StepResult` per declared step (playbook order). Consumers read that list — a timeline iterates it, an LLM can use only `status`, and overlay uses optional `evidence` screenshot paths when present. `dumpStepResults(result.stepResults)` writes the run. `RunResult.evidence` remains the runner log (`StepEvidence`) of evaluated steps only. Later unreached steps are `attempt: "not_executed"` on `stepResults` only. No workbench UI, OCR/CU, or `playbook-kr-cert` in this package yet.

```ts
import { dumpStepResults } from "playbook-runtime";

const result = runtime.run(playbook);
dumpStepResults(result.stepResults);
for (const step of result.stepResults) {
  step.status;
  step.attempt;
}
```

`attempt` is `executed` | `timeout` | `not_executed`. A page `waitFor` timeout is `timeout`, not "the native step never ran". Adapters throw `AdapterTimeoutError` (or an error named `TimeoutError`); runtimes do not import Playwright or UIA. `target` is an observation-bound locator / URL / accessibility name. Coordinates and session node IDs are not a contract. OS `adapter` on each row comes from the injected `OsUiDriver.kind`.

```ts
import { DummyAdapter, FixedPermissionGate, PlaybookRuntime } from "playbook-runtime";

const adapter = new DummyAdapter({ title: "Demo", texts: ["Next"], focused: null });
const runtime = new PlaybookRuntime(adapter, new FixedPermissionGate(["ui.read", "ui.control"]));
const result = runtime.run({
  id: "demo",
  steps: [{ id: "go", kind: "click", target: "Next" }],
});
```

In-page steps use `PagePlaybookRuntime` and a `BrowserPageDriver` (`DummyPageAdapter` here; `driver-playwright` in that package):

```ts
import { DummyPageAdapter, FixedPermissionGate, PagePlaybookRuntime } from "playbook-runtime";

const page = new DummyPageAdapter({
  url: "https://example.test/form",
  title: "Demo",
  texts: ["Next"],
  locators: ["#next"],
});
const pageResult = new PagePlaybookRuntime(page, new FixedPermissionGate(["ui.read", "ui.control"])).run({
  id: "demo-page",
  steps: [{ id: "go", kind: "click", locator: "#next" }],
});
```

## Tests

```sh
npm --prefix packages/playbook-runtime test
```
