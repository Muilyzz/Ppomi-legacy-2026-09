# Package examples (real smoke) vs unit tests vs hub

Each DI-separated package keeps **two** ways to check it. Do not fold them together.

| Surface | What it is | What it may touch | Where |
| --- | --- | --- | --- |
| **Unit tests** | Mock / fixture only. CI-safe. | No live OS, device, Clerk, or hub login. | `packages/<pkg>/tests/` |
| **Example mini-app** | That package’s real smoke / demo harness. | Real OS, device, or env keys **for that package only**. Other ports stay mocked. | `packages/<pkg>/example/` |
| **Hub** | Catalog + family web (`ppomi-hub`). Full product surface. | Deployed APIs, reviewed catalog copies. | `hub/` |

An `example` is **not** the hub and **not** the Mac/Windows app. It wires **one** package port to a real (or skippable) implementation.

## Layout (locked)

```text
packages/<pkg>/
  src/                 # library (sibling PRs; may be missing on this tip)
  tests/               # mocks / fixtures
  example/             # this convention
    package.json
    README.md
    src/
```

There is no top-level `examples/` tree. Put the mini-app next to the package.

Until [MZZ-40](https://linear.app/muilyzz/issue/MZZ-40) rename PRs merge, examples sit next to **current** names:

| Current package | Example | Future name |
| --- | --- | --- |
| *(none yet — catalog is `Ppomi/Sources/Ppomi/Catalog` + `playbook-*`)* | `packages/ppomi-path/example` | `ppomi-path` |
| *(none yet — orchestration is MZZ-41)* | `packages/ppomi-brain/example` | `ppomi-brain` |
| `adapter-macos` (PR #10 / #12) | `packages/adapter-macos/example` | `ppomi-body-macos` (`driver-macos`) |
| `adapter-windows` (PR #7) / `driver-windows` (PR #15) | `packages/adapter-windows/example` | `ppomi-body-windows` |
| `playbook-runtime` | *(body core — use the OS examples)* | `ppomi-body` |

`playbook-runtime` / `driver-*` / `adapter-*` are legacy names. Do not invent a third product name.

## How to run (exact commands)

Node **≥ 22**. No secrets in git. Examples have **no required npm install** — they use `node --experimental-strip-types`.

From the **repo root** (any machine for path + brain):

```sh
# 1) path catalog CLI — load + validate (bundled fixture; optional live Catalog)
pnpm --filter ppomi-path-example start
# or, zero workspace:
node --experimental-strip-types packages/ppomi-path/example/src/main.ts
# also validate this repo's Catalog:
node --experimental-strip-types packages/ppomi-path/example/src/main.ts --legacy

# 2) brain — orchestration against mocks (default)
pnpm --filter ppomi-brain-example start
node --experimental-strip-types packages/ppomi-brain/example/src/main.ts
# later, point at a real body example (still no Clerk):
PPOMI_BODY=macos node --experimental-strip-types packages/ppomi-brain/example/src/main.ts
PPOMI_BODY=windows node --experimental-strip-types packages/ppomi-brain/example/src/main.ts

# 3) body — macOS / Windows. Off-OS they print SKIP and exit 0.
pnpm --filter adapter-macos-example start
pnpm --filter adapter-windows-example start
node --experimental-strip-types packages/adapter-macos/example/src/main.ts
node --experimental-strip-types packages/adapter-windows/example/src/main.ts
```

On a **Mac**, after this PR lands:

```sh
node --experimental-strip-types packages/ppomi-path/example/src/main.ts --legacy
node --experimental-strip-types packages/ppomi-brain/example/src/main.ts
node --experimental-strip-types packages/adapter-macos/example/src/main.ts
# optional live AX / Safari probe (Automation + Accessibility prompts):
PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/adapter-macos/example/src/main.ts
```

On **Windows** (Parallels), after the driver-windows live PR lands:

```sh
node --experimental-strip-types packages/adapter-windows/example/src/main.ts
# optional Edge + ppomi-executor UIA probe:
set PPOMI_BODY_LIVE=1
set PPOMI_EXECUTOR=C:\path\to\ppomi-executor.exe
node --experimental-strip-types packages/adapter-windows/example/src/main.ts
```

Each example README lists the same commands plus env.

## Rules

- Unit tests stay mock-based. Do not import an example from `tests/`.
- Examples may read `PPOMI_*` env. Never commit `.env` or Clerk keys.
- Off-platform body examples **skip (exit 0)**. They fail (exit 1) only when the live probe was requested and then broke.
- Playwright / Android / iPhone-mirroring examples wait until those drivers stabilize.
