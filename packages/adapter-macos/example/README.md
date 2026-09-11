# adapter-macos example

macOS body smoke for **this package only**. Future name: `ppomi-body-macos` (`driver-macos`). Not the hub.

Sibling live tools (unmerged): PR #10 fixture adapter, PR #12 `screen_read` / `ui_tap` / `ui_type`. This example does **not** import those packages — it stays runnable on this tip.

## Machine / env

| | |
| --- | --- |
| OS | macOS for a real probe. Other OS → **SKIP, exit 0**. |
| Node | ≥ 22 |
| Browsers | Safari and/or Google Chrome in `/Applications` |
| Secrets | None |
| `PPOMI_BODY_LIVE` | unset = list browsers only. `1` = open example.com (Automation + Accessibility prompts). |
| `PPOMI_MAC_BROWSER` | `safari` (default) or `chrome` |

## Commands

From the **repo root**:

```sh
pnpm --filter adapter-macos-example start
pnpm --filter adapter-macos example
node --experimental-strip-types packages/adapter-macos/example/src/main.ts
```

From this directory:

```sh
npm start
node --experimental-strip-types src/main.ts
PPOMI_BODY_LIVE=1 node --experimental-strip-types src/main.ts
PPOMI_BODY_LIVE=1 PPOMI_MAC_BROWSER=chrome node --experimental-strip-types src/main.ts
```

On the user’s Mac after this PR lands:

```sh
node --experimental-strip-types packages/adapter-macos/example/src/main.ts
PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/adapter-macos/example/src/main.ts
```

If Automation or Accessibility is denied, the live probe prints SKIP (exit 0), not FAIL.

## What it does not do

- No Clerk / hub login.
- No payment or submit clicks.
- No import of `playbook-runtime` until that PR merges.
