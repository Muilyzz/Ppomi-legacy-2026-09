# ppomi-body-windows example

One-step `ppomi-body` smoke for this package only. Not the hub.

Default: fixture `Runtime` + `WindowsDriver` runs a single `click` (`effect: "navigate"`). No live UIA.

Live real-control: `PPOMI_BODY_LIVE=1` on Windows with `ppomi-executor` + Edge, or `npm --prefix packages/ppomi-body-windows run smoke:live`.

## Commands

From the repo root (any machine):

```sh
node --experimental-strip-types packages/ppomi-body-windows/example/src/main.ts
```

On Windows (real UIA):

```bat
set PPOMI_BODY_LIVE=1
set PPOMI_EXECUTOR=C:\path\to\ppomi-executor.exe
node --experimental-strip-types packages/ppomi-body-windows/example/src/main.ts
```

No Clerk / hub / payment / submit.
