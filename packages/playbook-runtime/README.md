# playbook-runtime

One package for playbook steps, permissions, stop, and evidence. Content packs and OS adapters stay in other packages.

Package titles are domain-specific. Do not add `core`, `common`, `engine`, `util`, `shared`, `runtime`, `adapter`, `playbook-core`, or `playbook-content`.

## Packages

| Package | Count | Role |
| --- | --- | --- |
| `playbook-runtime` | one | Steps, permissions, stop, evidence. No OS or browser calls of its own. |
| `playbook-kr-cert` | later, one of many | Korean certificate content (scenario + fixtures). Not this slice. |
| `adapter-windows` | later, one OS | Windows click / type / read-screen / focus. Not this slice. |
| `adapter-macos` | later, one OS | macOS click / type / read-screen / focus. Sibling OS package. |
| `adapter-playwright` | one page | In-page web `goto` / `click` / `fill` / `waitFor`. Lives in `packages/adapter-playwright`. |

This package is `playbook-runtime` only. It ships `OsAdapter` + `DummyAdapter` and `BrowserPageAdapter` + `DummyPageAdapter` so each contract can be tested without UIA, Accessibility, a live browser, or hub login.

`OsAdapter` is native chrome: `readScreen` / `focus` / `click` / `type`. `BrowserPageAdapter` is the in-page port: `readPage` / `goto` / `click` / `fill` / `waitFor`. Do not implement Playwright as `OsAdapter`. Do not grow a second `playbook-runtime` package. `PagePlaybookRuntime` in this package runs page steps.

A later `adapter-windows` package should wrap the existing `executors/windows` tools (`screen_read`, `ui_tap`, `ui_type`, `app_open`). `adapter-macos` maps the same OS port onto Mac native names. `adapter-playwright` implements `BrowserPageAdapter` only.

## Playwright vs OS adapter

Pick the port from the **surface**, not the app name. Full rules: [docs/adapter-selection.md](docs/adapter-selection.md).

| Surface | Runner | Port | Package |
| --- | --- | --- | --- |
| In-page web DOM, forms, locator waits | `PagePlaybookRuntime` | `BrowserPageAdapter` | `adapter-playwright` |
| Native windows, system dialogs, cert UI, non-DOM chrome | `PlaybookRuntime` | `OsAdapter` | `adapter-windows` (UIA), `adapter-macos` (AX) |

An in-page "Next" button is Playwright. A Korean certificate window, a native file picker, or a browser OS dialog is UIA/AX. Do not replace the OS adapters with Playwright.

**Hybrid handoff:** page request → watch for the native window → `PlaybookRuntime` → back to `PagePlaybookRuntime` for the page result. Do not leave Playwright blocked in `waitFor` on a locator that only appears after a native modal is dismissed. The modal is not in the DOM. Do not treat that timeout as "the native step never ran" and retry a signing step.

Permanent contracts are page locators / URL and OS accessibility text (`target`). Do **not** store coordinates, pixel boxes, or session node IDs as playbook selectors. Vision, OCR, and VLM are fallbacks when the DOM or accessibility tree is missing — not the default path.

Ppomi onboarding and playbook packages have **no device-approval or Mac-approver gate**. Do not add approved-device checks to `playbook-runtime`, `adapter-windows`, `adapter-macos`, `adapter-playwright`, `playbook-kr-cert`, or their tests.

## Contract

- OS control steps (`focus`, `click`, `type`) need `ui.control`. OS `read` needs `ui.read`. Page control steps (`goto`, `click`, `fill`) need `ui.control`. Page `read` / `waitFor` need `ui.read`. These are UI step permissions, not device approval.
- Before an OS mutation, `PlaybookRuntime` reads the screen and checks declared screen/target/focus preconditions. Before a page mutation, `PagePlaybookRuntime` reads the page and checks declared url/text/locator preconditions (`waitFor` is the wait and is not fail-closed on locator presence).
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

In-page steps use `PagePlaybookRuntime` and a `BrowserPageAdapter` (`DummyPageAdapter` here; `adapter-playwright` in that package):

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
