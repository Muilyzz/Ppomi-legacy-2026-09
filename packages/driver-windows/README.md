# driver-windows

Windows `OsAdapter` for `playbook-runtime`. Maps focus / click / type / read-screen onto the existing `executors/windows` tools.

This is not a second playbook runner, and it is not a generic `adapter` package.

## Mapping

| `OsAdapter` | `executors/windows` tool | measured reply |
| --- | --- | --- |
| `focus(target)` | `app_open` `{ target }` | `{ packageName, activated: true }` |
| `readScreen()` | `screen_read` | `{ snapshotId, packageName, appLabel, nodes[], truncated }` |
| `click(target)` | fresh `screen_read`, then `ui_tap` `{ nodeId }` | `{ invoked: true, requiresScreenRead: true }` |
| `type(target, text)` | fresh `screen_read`, then `ui_type` `{ nodeId, text }` | `{ typed: true, requiresScreenRead: true }` |

`target` for `focus` is the executor app id `win:<pid>:<startTicks>` from `app_list`; `click`/`type` targets are node texts on the current screen.

## Two implementations of `WindowsExecutorTools`

| | `FixtureWindowsExecutorTools` | `LiveWindowsExecutorTools` |
| --- | --- | --- |
| Backend | in-memory window + nodes | the real `ppomi-executor.exe` over its JSONL protocol |
| Use | unit tests, playbook-runtime smoke | live runs and the Edge smoke below |
| Process | none | spawns `ppomi-executor --executor --owner-pid <pid>` (default owner: the Node process) in a worker thread; the sync `OsAdapter` contract is kept by blocking on `Atomics.wait` per request |
| Extra API | `calls` log | `listApps(query)`, `allowApps(packageNames)`, `close()` |

Both follow the semantics measured against the real executor (Windows 11 ARM64, Edge):

| Measured rule | Behaviour in this package |
| --- | --- |
| `nodeId` = `"<snapshotId>:<index>"`; every `screen_read` yields a new `snapshotId` | `snapshotIdOf()`; a node from an older snapshot → `stale_screen` before any request is sent |
| Only the latest snapshot is addressable; it expires after 15 s (`WINDOWS_SNAPSHOT_TTL_MS`) | client-side expiry check → `stale_screen` |
| `ui_tap` / `ui_type` return `requiresScreenRead: true` and spend the snapshot | both implementations invalidate after an action; the next addressed action without a fresh read → `stale_screen`. `WindowsAdapter` already re-reads before each action |
| `executeTool` needs an active session; `setControlApps` is **idle-only** (`protected_action` while active) | `allowApps()` pauses the session, sets the allowlist, resumes. Order matters: active → `app_list` → idle → `setControlApps` → active → tools |
| Allowlist and snapshots are per executor **process** (memory only) | one `LiveWindowsExecutorTools` = one process; restarting the executor requires `allowApps()` again |
| Non-invokable / non-editable node → `protected_action`; unknown app → `app_not_allowed` | error codes are rethrown unchanged as `WindowsAdapterError.code` |
| Chromium exposes web-page fields to UIA only with `--force-renderer-accessibility` | without it `screen_read` on Edge shows just the browser chrome (address bar, tabs) |

Live UI Automation stays in `executors/windows`. This package talks to that tool surface and never calls `beginSignIn`, `completeSignIn`, `configureDevice`, or any approval RPC.

## What PR #7 should absorb

The base branch's `WindowsAdapter` and fixture predate the measured semantics encoded here. When #7 folds them in it must:

- Re-read before every addressed action: `FixtureWindowsExecutorTools` no longer keeps a spent snapshot addressable, so any consumer that re-used a `nodeId` after an action now gets `stale_screen`, matching the real executor. `WindowsAdapter` already re-reads.
- Update hand-written `WindowsExecutorTools` implementations for `ui_tap`/`ui_type` now returning `requiresScreenRead`.
- Call `allowApps` only while the session is idle; never `setControlApps` during an active session.
- Honour `app_open`'s `activated` flag in `focus()`: treat `activated: false` as a failed focus (throw) instead of silently continuing, since the executor reports `activated` as `GetForegroundWindow() == window`, which can be `false`.

## Live smoke (real executor, Edge)

`tests/live-edge-uia-smoke.test.ts` launches an isolated Edge profile (`--user-data-dir` in a temp dir, `--force-renderer-accessibility`) on an offline local page with a text input and a button, then runs `app_list → allowApps → app_open → screen_read → ui_type → (stale_screen check) → screen_read → ui_tap → screen_read` through `LiveWindowsExecutorTools`. It skips when not on Windows or when the executor / Edge is missing.

```sh
# on the Windows machine, from packages/driver-windows (Node ≥ 22)
set PPOMI_EXECUTOR=<path>\ppomi-executor.exe      # default: ..\..\shell\src-tauri\resources\executor\ppomi-executor.exe
set PPOMI_SMOKE_SHOT=<path>\live-smoke-windows.png  # optional full-screen capture after the final read
npm run smoke:live
```

## Out of scope

- Device-approval / Mac-approver / hub login (`beginSignIn`, `completeSignIn`, `configureDevice`, …)
- `playbook-kr-cert` content
- A second `playbook-runtime`
- Package titles `core`, `common`, `engine`, `util`, `shared`, `adapter`, or `runtime`

```ts
import { FixedPermissionGate, PlaybookRuntime } from "../playbook-runtime/src/index.ts";
import { LiveWindowsExecutorTools, WindowsAdapter } from "driver-windows";

const tools = LiveWindowsExecutorTools.start({ executorPath: "C:/path/to/ppomi-executor.exe" });
const edge = tools.listApps("").apps.find(app => app.label === "msedge")!;
tools.allowApps([edge.packageName]);            // idle-only on the executor; handled here
const result = new PlaybookRuntime(
  new WindowsAdapter(tools),
  new FixedPermissionGate(["ui.read", "ui.control"]),
).run({
  id: "demo",
  steps: [
    { id: "go", kind: "focus", target: edge.packageName },
    { id: "type", kind: "type", target: "입력 상자:", text: "hello" },
  ],
});
tools.close();
```

## Tests

```sh
npm --prefix packages/driver-windows install   # dev-only: typescript + @types/node
npm --prefix packages/driver-windows test       # fixture + fake-executor bridge tests; live smoke skips off Windows
npm --prefix packages/driver-windows run typecheck
```
