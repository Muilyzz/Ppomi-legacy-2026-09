# ppomi-body-windows example

One-step `ppomi-body` smoke for this package only. Not the hub.

Default: fixture `Runtime` + `WindowsDriver` runs a single `click` (`effect: "navigate"`).

Live Edge UIA: `PPOMI_BODY_LIVE=1` on Windows with `ppomi-executor` + Edge. Off-Windows live skips (exit 0); on Windows without the flag it dry-runs. The live branch opens an isolated Edge profile (`--user-data-dir` in a temp dir) on an offline local page, grants and activates that Edge (`allowApps` / `app_open` — session setup), then runs a three-step `Playbook` through `Runtime` + `OsSurface(WindowsDriver(LiveWindowsExecutorTools))`: `type` (`effect: "input"`, after `screen_read` shows the button and the untapped mark), `click` (`effect: "navigate"`), and a `read` that requires the tapped mark. It prints the structured `RunResult` only — run status and per-step `status` / `attempt` / `code` / `driver` — never coordinates, node ids or the typed text. Tools and Edge are closed in `finally`. The tool-level smoke `npm --prefix packages/ppomi-body-windows run smoke:live` still exists for executor debugging.

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

## KB스타기업뱅킹 공동인증서 (`kb-star-biz-win-cert@0.1.0`)

Page `goto` dry-run + human handoffs. Live opens Edge on the official issue URL, then stops. NPKI probe reports file count / newest mtime only.

```sh
node --experimental-strip-types packages/ppomi-body-windows/example/src/kb-star-biz-win-cert.ts
PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-windows/example/src/kb-star-biz-win-cert.ts
```

URLs and NPKI verify: [`catalogs/paths/kb-star-biz-win-cert/README.md`](../../../catalogs/paths/kb-star-biz-win-cert/README.md). Executor install follows [PR #48](https://github.com/Muilyzz/Ppomi/pull/48) (`node scripts/build-windows-executor.mjs --download`). This path does not tap UAC or type secrets.
