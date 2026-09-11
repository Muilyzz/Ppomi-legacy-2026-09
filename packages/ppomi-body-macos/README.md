# ppomi-body-macos

macOS `OsUiDriver` for `ppomi-body`. Maps focus / click / type / read-screen onto Mac native tool names.

`focus` names an already-running app (`browser_open({ app })`). It is never `browser_open({ url })`.

## Tests / 1-step example

```sh
npm --prefix packages/ppomi-body-macos test
node --experimental-strip-types packages/ppomi-body-macos/example/src/main.ts
```

Live AX is out of this slice. Off-macOS the example fixture still PASSes; live probe skips.
