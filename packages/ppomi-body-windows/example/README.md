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

Page `goto` dry-run + human handoffs. Live opens one new Edge window on the official issue URL in the person's profile, then stops — nothing is clicked, typed, or closed. NPKI probe reports file count / newest mtime / `root=default|override` only.

```sh
node --experimental-strip-types packages/ppomi-body-windows/example/src/kb-star-biz-win-cert.ts
PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-windows/example/src/kb-star-biz-win-cert.ts
# VM smoke only: isolated temp profile, closed again after tasklist confirms our own msedge.exe pid
PPOMI_BODY_LIVE=1 PPOMI_KB_CERT_CLOSE_EDGE=1 node --experimental-strip-types packages/ppomi-body-windows/example/src/kb-star-biz-win-cert.ts
```

URLs, the close rule and NPKI verify: [`catalogs/paths/kb-star-biz-win-cert/README.md`](../../../catalogs/paths/kb-star-biz-win-cert/README.md). This example does not use `ppomi-executor`, does not tap UAC, and does not type secrets. The KB glue lives in `example/src/kb-cert-path.ts` / `kb-cert-edge.ts`; the package `src/` only carries the generic `pagePlaybookFromPath` and the NPKI probe.
