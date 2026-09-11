# playbook-runtime

One package for playbook steps, permissions, stop, and results. Content packs (the **ppomi-path**, `playbook-*`) and drivers (the **ppomi-body**, `playbook-runtime` + `driver-*`) stay in other packages. A driver is an eye (observation) plus a hand (actuation).

Package titles are domain-specific. Do not add `core`, `common`, `engine`, `util`, `shared`, `runtime`, `adapter`, `playbook-core`, or `playbook-content`.

## One core, two surfaces

There is **one runtime loop**, `Runtime`, and **two surfaces** it can drive through the `UiDriver` contract (`read` / `resolve` / `act`). A surface only reads a snapshot, resolves a declared target against it, and acts on the resolved target; the loop owns permissions, the effect gate, polling, failure handling and results. Do not add a second loop for a new surface or a new OS: add a `UiDriver`, or a driver port behind an existing one.

| Surface (`UiDriver`) | Driver port | Snapshot / target | Drivers |
| --- | --- | --- | --- |
| `OsSurface` | `OsUiDriver` (`readScreen` / `focus` / `click` / `type`, `kind`) | screen texts, accessible-name `target` | `driver-windows` (UIA), `driver-macos` (AX), `driver-android`, `driver-iphone-mirroring`; fixtures via `DummyAdapter` |
| `PageSurface` | `BrowserPageDriver` (`readPage` / `goto` / `click` / `fill` / `waitFor`) | url + page texts + locators, `locator` / `url` | `driver-playwright`; fixtures via `DummyPageAdapter` |

Every driver name is defined in `src/drivers.ts`. `OsAdapter`, `OsAdapterKind`, `BrowserPageAdapter`, `AdapterTimeoutError` and `StepAdapter` remain as deprecated aliases until the sibling packages rename. `PlaybookRuntime` and `PagePlaybookRuntime` remain as thin, deprecated, synchronous wrappers over the core so existing ports keep **compiling**; each sibling needs one line to keep **running** (see *Compatibility*).

```ts
import { DummyAdapter, FixedPermissionGate, OsSurface, Runtime } from "playbook-runtime";

const driver = new DummyAdapter({ title: "Demo", texts: ["Next"], focused: null }, "os-windows");
const runtime = new Runtime(new OsSurface(driver), new FixedPermissionGate(["ui.read", "ui.control"]));
const result = await runtime.run({
  id: "demo",
  steps: [{ id: "go", kind: "click", target: "Next", effect: "navigate" }],
});
```

Ppomi onboarding and playbook packages have **no device-approval or Mac-approver gate**. Do not add approved-device checks to `playbook-runtime`, the drivers, content packs, or their tests. Permissions here are UI step permissions, not device approval.

## Contract

- **Permissions are additive.** Every step needs `ui.read` (it observes the surface); `focus`, `click`, `type`, `goto`, `fill` also need `ui.control`. A step's `require.permission` can add a requirement, never replace one. Denial stops the run before any driver call as `failed` with `code: "permission_denied"`.
- **Mutations declare an effect.** `effect: "navigate" | "input" | "commit"`. A mutation with no declared effect is a `commit`, and a `commit` is never run: the run stops with `handoff` (`StepResult.status: "needs_human"`). Nothing auto-commits; payment, submit and signing buttons are always the person's step.
- **Preconditions are observed before acting.** Declared `screen` / `focused` / `url` / `texts` / `locators` and the step target must hold on a fresh snapshot. `require.wait: ms` polls the surface until they hold or the deadline passes; a deadline is reported as a timeout (`attempt: "timeout"`, `status: "retryable"`), not as a step that never ran.
- **Navigation is bounded.** `goto` refuses non-HTTP(S), credentialed, relative and (when `allowedOrigins` is declared) undeclared origins; a page that leaves the declared origins fails the next step. URLs in results are origin + pathname only.
- **Driver failures are results, not exceptions.** A throwing `read` or `act` becomes `outcome: "failed"` (or `"timeout"` for `DriverTimeoutError` / an error named `TimeoutError`) with the driver's `code`. A timed-out `click` / `fill` / `type` may already have applied, so it is `needs_human`, never `retryable`; `stale_screen` is `retryable`; `protected_action` is `protected` — the only source of that status.
- **Nothing inside a run throws on data.** An empty playbook id, an empty or duplicate step id, a driver with no known kind, or `require.wait` under the synchronous wrappers returns `status: "invalid"` with `invalid.code` before the first step.
- **Results.** `RunResult.evidence` is the runner log (`stepId`, `kind`, `outcome`, bounded `screenTexts`, `note`). `RunResult.stepResults` is one MZZ-34 `StepResult` per declared step in order; steps after a stop are `failed` / `not_executed`. `StepResult.driver` comes from `OsUiDriver.kind` (`os-windows` / `os-macos` / `os-android` / `phone`, or `RuntimeOptions.driver` as fallback) or is `page`; `code` is the structured reason. Neither carries typed text, coordinates or session node ids. `completed` means the declared steps finished; it is not a business-result claim and does not write a journal.

## Loops

`Runtime.run` awaits every driver call and works with sync and async drivers alike; live drivers bind to `Runtime` + a surface, never to a wrapper. `Runtime.runSync` is only the deprecated wrappers' engine: it never sleeps, so a playbook with `require.wait` is `invalid` (`wait_requires_run`) there, and a driver that returns a Promise is a programming error that throws `TypeError`. Poll sleeps are injectable (`RuntimeOptions.sleep` / `now`) so tests use a virtual clock. `runSync` is deleted together with the wrappers in the `driver-*` port slice.

## Compatibility

`PlaybookRuntime(port, gate)` and `PagePlaybookRuntime(port, gate)` call `runSync` with `undeclaredMutations: "run"`: legacy playbooks whose mutations have no `effect` still execute there, while a declared `commit` is handed off. New code uses `Runtime` directly and declares `effect` on every mutation. `waitFor` still works; prefer `read` with `require: { locators: [...], wait }`. `parseStepResult` accepts `adapter` as a deprecated alias of `driver`; dumps emit `driver` only.

Every `StepResult` names its driver, and the runtime never guesses it: an `OsUiDriver` that does not declare `kind` makes each run `invalid` (`unknown_driver`) until one of these one-line changes lands in the sibling package —

| Sibling | One-line change |
| --- | --- |
| `adapter-windows` (#7), `driver-windows` live (#15) | `readonly kind = "os-windows" as const;` on the port class, or `new PlaybookRuntime(port, gate, { driver: "os-windows" })` in the smoke test |
| `adapter-macos` (#10) | `readonly kind = "os-macos" as const;`, or `{ driver: "os-macos" }` |
| `adapter-android` (#20), `adapter-iphone-mirroring` (#21) | `"os-android"` / `"phone"` likewise |
| `adapter-playwright` (#11 / #13) | nothing for `driver` (page runs are always `page`); `tsconfig.json` gains `"extends": "../tsconfig.base.json"` like every package here |

All siblings compile the core through relative imports, so they also need the `extends` line above to typecheck it (node types instead of the DOM lib).

## Tests

```sh
npm --prefix packages/playbook-runtime test
```
