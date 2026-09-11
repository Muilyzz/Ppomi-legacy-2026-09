# ppomi-body-windows example

One-step `ppomi-body` smoke for this package only. Not the hub.

Default: fixture `Runtime` + `WindowsDriver` runs a single `click` (`effect: "navigate"`).

Live Edge UIA: `PPOMI_BODY_LIVE=1` on Windows with `ppomi-executor` + Edge. Off-Windows live skips (exit 0). Same path as `npm --prefix packages/ppomi-body-windows run smoke:live`.

```sh
node --experimental-strip-types packages/ppomi-body-windows/example/src/main.ts
PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-windows/example/src/main.ts
```

On Windows (cmd):

```bat
set PPOMI_BODY_LIVE=1
set PPOMI_EXECUTOR=C:\path\to\ppomi-executor.exe
node --experimental-strip-types packages/ppomi-body-windows/example/src/main.ts
```

No Clerk / hub / payment / submit.
