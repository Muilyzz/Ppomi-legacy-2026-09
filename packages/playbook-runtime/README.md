# playbook-runtime

One package for playbook steps, permissions, stop, and evidence. Content packs and OS adapters stay in other packages.

Package titles are domain-specific. Do not add `core`, `common`, `engine`, `util`, `shared`, `runtime`, `adapter`, `playbook-core`, or `playbook-content`.

## One core, two surfaces

There is **one runtime loop**, `Runtime`, and **two surfaces** it can drive. A surface only reads a snapshot, resolves a declared target against it, and acts on the resolved target; the loop owns permissions, the effect gate, polling, failure handling and results. Do not add a second loop for a new surface or a new OS: add a `Surface`, or an adapter behind an existing one.

| Surface | Port | Snapshot / target | Adapters |
| --- | --- | --- | --- |
| `OsSurface` | `OsAdapter` (`readScreen` / `focus` / `click` / `type`) | screen texts, accessible-name `target` | `adapter-windows` (UIA), `adapter-macos` (AX), fixtures via `DummyAdapter` |
| `PageSurface` | `BrowserPageAdapter` (`readPage` / `goto` / `click` / `fill` / `waitFor`) | url + page texts + locators, `locator` / `url` | `adapter-playwright`, fixtures via `DummyPageAdapter` |

`PlaybookRuntime` and `PagePlaybookRuntime` remain as thin, deprecated, synchronous wrappers over the core so existing adapters and tests keep working (see *Compatibility*).

```ts
import { DummyAdapter, FixedPermissionGate, OsSurface, Runtime } from "playbook-runtime";

const adapter = new DummyAdapter({ title: "Demo", texts: ["Next"], focused: null }, "os-windows");
const runtime = new Runtime(new OsSurface(adapter), new FixedPermissionGate(["ui.read", "ui.control"]));
const result = await runtime.run({
  id: "demo",
  steps: [{ id: "go", kind: "click", target: "Next", effect: "navigate" }],
});
```

Ppomi onboarding and playbook packages have **no device-approval or Mac-approver gate**. Do not add approved-device checks to `playbook-runtime`, the adapters, content packs, or their tests. Permissions here are UI step permissions, not device approval.

## Contract

- **Permissions are additive.** Every step needs `ui.read` (it observes the surface); `focus`, `click`, `type`, `goto`, `fill` also need `ui.control`. A step's `require.permission` can add a requirement, never replace one. Denial stops the run before any adapter call.
- **Mutations declare an effect.** `effect: "navigate" | "input" | "commit"`. A mutation with no declared effect is a `commit`, and a `commit` is never run: the run stops with `handoff` (`StepResult.status: "needs_human"`). Nothing auto-commits; payment, submit and signing buttons are always the person's step.
- **Preconditions are observed before acting.** Declared `screen` / `focused` / `url` / `texts` / `locators` and the step target must hold on a fresh snapshot. `require.wait: ms` polls the surface until they hold or the deadline passes; a deadline is reported as a timeout (`attempt: "timeout"`, `status: "retryable"`), not as a step that never ran.
- **Navigation is bounded.** `goto` refuses non-HTTP(S), credentialed, relative and (when `allowedOrigins` is declared) undeclared origins; a page that leaves the declared origins fails the next step. URLs in results are origin + pathname only.
- **Adapter failures are results, not exceptions.** A throwing `read` or `act` becomes `outcome: "failed"` (or `"timeout"` for `AdapterTimeoutError` / an error named `TimeoutError`). An executor code `protected_action` reports `protected`; `stale_screen` reports `retryable`.
- **Results.** `RunResult.evidence` is the runner log (`stepId`, `kind`, `outcome`, bounded `screenTexts`, `note`). `RunResult.stepResults` is one MZZ-34 `StepResult` per declared step in order; steps after a stop are `failed` / `not_executed`. `StepResult.adapter` comes from `OsAdapter.kind` (`os-windows` / `os-macos` / `phone`) or is `page`. Neither carries typed text, coordinates or session node ids. `completed` means the declared steps finished; it is not a business-result claim and does not write a journal.

## Drivers

`Runtime.run` awaits every adapter call (sync or async adapters). `Runtime.runSync` serves sync adapters and fixtures and throws if an adapter returns a Promise. Poll sleeps are injectable (`RuntimeOptions.sleep` / `sleepSync` / `now`) so tests use a virtual clock.

## Compatibility

`PlaybookRuntime(adapter, gate)` and `PagePlaybookRuntime(adapter, gate)` call `runSync` with `undeclaredMutations: "run"`: legacy playbooks whose mutations have no `effect` still execute there, while a declared `commit` is handed off. New code uses `Runtime` directly and declares `effect` on every mutation. `waitFor` still works; prefer `read` with `require: { locators: [...], wait }`.

## Tests

```sh
npm --prefix packages/playbook-runtime test
```
