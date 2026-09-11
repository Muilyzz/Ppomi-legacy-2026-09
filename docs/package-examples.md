# Package examples (real smoke) vs unit tests vs hub

**CEO / product smoke: test in the main app (`뽀미.app` / `Ppomi.app`) chat, not `packages/*/example`.** Type `KB 사업자 계좌 읽어줘`. The agent calls `path_cold_start`. The Home → KB button is smoke only. See [v0.2 Mac 셸](v0.2-mac-shell.md).

Each DI-separated package keeps **two** ways to check it. Do not fold them together.

| Surface | What it is | What it may touch | Where |
| --- | --- | --- | --- |
| **Unit tests** | Mock / fixture only. CI-safe. | No live OS, device, Clerk, or hub login. | `packages/<pkg>/tests/` |
| **Example mini-app** | That package’s real smoke / demo harness. | Real OS, device, or env keys **for that package only**. Other ports stay mocked. | `packages/<pkg>/example/` |
| **Hub** | Catalog + family web. Full product surface. | Deployed APIs, reviewed catalog copies. | `hub/` |

An `example` is **not** the hub and **not** the Mac/Windows app. It wires **one** package port to a real (or skippable) implementation.

## Layout (locked)

```text
packages/<pkg>/
  src/
  tests/
  example/
    package.json
    README.md
    src/
```

There is no top-level `examples/` tree.

| Package | Example |
| --- | --- |
| `ppomi-path` | `packages/ppomi-path/example` |
| `ppomi-brain` | `packages/ppomi-brain/example` |
| `ppomi-body-windows` | `packages/ppomi-body-windows/example` |
| `ppomi-body-macos` | `packages/ppomi-body-macos/example` |
| `ppomi-body-android` | `packages/ppomi-body-android/example` |
| `ppomi-body-iphone-mirroring` | `packages/ppomi-body-iphone-mirroring/example` |
| `ppomi-body` | use the OS examples |

`playbook-runtime` / `driver-*` / `adapter-*` are legacy names only.

## How to run

Node **≥ 22**. No secrets in git. Examples use `node --experimental-strip-types`.

```sh
# path
node --experimental-strip-types packages/ppomi-path/example/src/main.ts
node --experimental-strip-types packages/ppomi-path/example/src/main.ts --legacy

# brain (mocks by default)
node --experimental-strip-types packages/ppomi-brain/example/src/main.ts
PPOMI_BODY=macos node --experimental-strip-types packages/ppomi-brain/example/src/main.ts
PPOMI_BODY=windows node --experimental-strip-types packages/ppomi-brain/example/src/main.ts

# body 1-step fixtures (live UIA/AX skips off-host)
node --experimental-strip-types packages/ppomi-body-windows/example/src/main.ts
node --experimental-strip-types packages/ppomi-body-macos/example/src/main.ts
# Mac live AX (Safari/Chrome System Events). Deprecated alias: packages/adapter-macos/example
PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-macos/example/src/main.ts
PPOMI_BODY_AX=1 node --experimental-strip-types packages/ppomi-body-macos/example/src/main.ts
PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/adapter-macos/example/src/main.ts
node --experimental-strip-types packages/ppomi-body-android/example/src/main.ts
# Android live dump+tap (Settings via AndroidDriver + LiveAndroidNativeTools)
PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-android/example/src/main.ts
node --experimental-strip-types packages/ppomi-body-iphone-mirroring/example/src/main.ts
```

## Rules

- Unit tests stay mock-based. Do not import an example from `tests/`.
- Examples may read `PPOMI_*` env. Never commit `.env` or Clerk keys.
- Off-platform live probes **skip (exit 0)**. Fixture 1-steps still PASS.
- Never invent a third product name.
