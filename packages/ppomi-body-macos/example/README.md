# ppomi-body-macos example

One-step `ppomi-body` smoke. Default: fixture `Runtime` click.

Live Safari/Chrome Automation: `PPOMI_BODY_LIVE=1` on a Mac (`PPOMI_MAC_BROWSER=chrome` optional). Off-macOS live skips (exit 0).

```sh
node --experimental-strip-types packages/ppomi-body-macos/example/src/main.ts
PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-macos/example/src/main.ts
```

Deprecated alias (same process):

```sh
PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/adapter-macos/example/src/main.ts
```
