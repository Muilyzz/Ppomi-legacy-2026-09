# adapter-windows example

Windows body smoke for **this package only**. Future name: `ppomi-body-windows`. Current live UIA package on sibling PR #15 is `driver-windows`. Not the hub.

This example does **not** import `LiveWindowsExecutorTools` (that code is not on `main`). It stays independently runnable.

## Machine / env

| | |
| --- | --- |
| OS | Windows for a real probe. Other OS → **SKIP, exit 0**. |
| Node | ≥ 22 |
| Browser | Microsoft Edge (`PPOMI_EDGE` if not in Program Files) |
| Executor | optional `PPOMI_EXECUTOR` → `ppomi-executor.exe` (PR #15 / `shell/…/ppomi-executor.exe`) |
| Secrets | None. No Google / Clerk login. |
| `PPOMI_BODY_LIVE` | unset = list Edge/executor paths. `1` = isolated Edge on a local HTML page. |

## Commands

From the **repo root**:

```sh
pnpm --filter adapter-windows-example start
pnpm --filter adapter-windows example
node --experimental-strip-types packages/adapter-windows/example/src/main.ts
```

From this directory:

```sh
npm start
node --experimental-strip-types src/main.ts
```

On Windows (Parallels) after this PR lands:

```bat
node --experimental-strip-types packages/adapter-windows/example/src/main.ts
set PPOMI_BODY_LIVE=1
node --experimental-strip-types packages/adapter-windows/example/src/main.ts
```

When PR #15 is on the same checkout, the measured UIA smoke is still:

```bat
cd packages/driver-windows
set PPOMI_EXECUTOR=C:\path\to\ppomi-executor.exe
npm run smoke:live
```

## What it does not do

- No Clerk / hub / Mac-approver gate.
- No payment or submit clicks.
- No reuse of the user’s Edge profile (live mode uses a temp `--user-data-dir`).
