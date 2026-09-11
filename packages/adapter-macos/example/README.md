# adapter-macos example (deprecated)

Locked name is `ppomi-body-macos`. This folder only forwards:

```sh
PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/adapter-macos/example/src/main.ts
```

to that package’s live **AX** 1-step (`MacosDriver` + `LiveMacosNativeTools`). Off-macOS / no grant → SKIP.
