# ppomi-brain example

Mini orchestration: **intent → path → grant → body → memory**. Default body is a mock. Not the hub chat UI (`ppomi-chat` is a different package).

Future library name: `ppomi-brain` (MZZ-41). This example is self-contained and does not import unmerged sibling packages.

## Machine / env

| | |
| --- | --- |
| OS | Any for `--body mock` (default) |
| Node | ≥ 22 |
| Secrets | None. Do not set Clerk keys here. |
| `PPOMI_BODY` | `mock` (default) · `macos` · `windows` |

`macos` / `windows` spawn that OS’s body example. Off-OS the body example prints SKIP and brain still reports the skip.

## Commands

From the **repo root**:

```sh
pnpm --filter ppomi-brain-example start
pnpm --filter ppomi-brain example
node --experimental-strip-types packages/ppomi-brain/example/src/main.ts
```

From this directory:

```sh
npm start
npm test
node --experimental-strip-types src/main.ts
node --experimental-strip-types src/main.ts certificate
node --experimental-strip-types src/main.ts --intent browse
node --experimental-strip-types src/main.ts --deny-control certificate
PPOMI_BODY=macos node --experimental-strip-types src/main.ts browse
PPOMI_BODY=windows node --experimental-strip-types src/main.ts browse
```

On a Mac, after this PR lands, the usual sequence is:

```sh
node --experimental-strip-types packages/ppomi-brain/example/src/main.ts
PPOMI_BODY=macos node --experimental-strip-types packages/ppomi-brain/example/src/main.ts browse
```

## What it checks

- Path selection from a tiny in-example catalog (same IDs as the path fixture).
- Grant denial (`--deny-control`) never reaches the body.
- Mock body completes browse steps and **blocks** `payment` / `submit`.
- Optional real-body switch only runs the sibling example; it does not embed UIA/AX here.
