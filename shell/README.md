# ppomi-shell

Tauri 2 + TypeScript consumer surface. Native Swift / C# / Kotlin stay OS body
(AX, capture, Keychain/CredMan, mirroring) — they do not replace this UI.

Swift `Ppomi/` remains the transitional Mac body host. Do not delete it here.

## Mac install / run

Need Node 22.6+, Rust (1.85+), and on a Mac: Xcode + macOS 26 WebView.

```sh
npm --prefix shell ci
npm --prefix shell test          # brain → path → body fixture (no window)
npm --prefix shell run build:ui
npm --prefix shell run dev       # window + 실행 (not the TCC install)
```

Consumer app is **one path**: `/Applications/뽀미.app`, bundle id `com.muilyzz.ppomi`.

```sh
LOCAL_SIGN_ID="Apple Development: …" scripts/install-shell.sh
```

Same `LOCAL_SIGN_ID` every local Mac build (Swift `make-app.sh`). Quit the old app first — the script does. The install path must be an absolute `*.app` (`PPOMI_APP` / `PPOMI_ROOT` are read only by the `--hygiene` / `--check` test modes); any `*-prev.app` or `뽀미*.app` sibling or `dist/backup/` is refused, and the build copy under `target/…/bundle/macos` is deleted after the copy — those mixed copies are why TCC listed 「previous」. Do not `tccutil reset` as routine. Ad-hoc is not for permission smoke. `tauri dev` / `target/` are not install paths. `Info.plist` declares `NSAppleEventsUsageDescription` for the live path's Automation prompt.

The window is a blank log + composer. Placeholder verb only:
`시킬 일을 적어 주세요`. Type `다음` or `browse` and send: `run_path` →
`src/host.ts` → `ppomi-brain` → `path-home-next` → `ppomi-body-macos`
fixture click on `Next`. No IA header, no empty-state chips, no greeting.
The window never arms live: `run_path` refuses `live: true` (`live_refused`)
and strips `PPOMI_BODY_LIVE` / `PPOMI_BODY_AX` / `PPOMI_BODY` from the node
child, so a variable inherited from another probe's shell cannot turn the
fixture run into real control. Each reply shows the brain status plus the core
`run` (`driver`, `status`, `attempt`, `code`).

Live Mac AX is **CLI only** and needs two keys, the `--live` flag **and**
`PPOMI_BODY_LIVE=1` (손쉬운 사용 on the terminal):

```sh
PPOMI_BODY_LIVE=1 npm --prefix shell run host -- --intent 다음 --body macos --live
```

Flag alone → refused (exit 1); variable alone → fixture; `PPOMI_BODY_AX` does
not arm the shell. A stop is never `completed`: Accessibility denied →
`grant_denied`, not a Mac / no Safari or Chrome / no example.com link →
`needs_human`, tool error → `failed` with the driver code (URLs redacted).
`completed` only comes out of `Runtime` after the gated click.

Windows / Android fixtures use the same IPC (`--body windows|android`);
`--live` on them stops as `failed` (not wired, MZZ-55b / MZZ-55c) instead of
running the fixture under a live label. Live OS hooks stay the existing
`ppomi-body-*` examples.

Packaged `npm --prefix shell run build` still needs `node` (or `PPOMI_NODE`)
for the TS host. Apps opened from Finder/Dock only see
`/usr/bin:/bin:/usr/sbin:/sbin`, so Homebrew/nvm node is invisible:
`launchctl setenv PPOMI_NODE "$(command -v node)"`, then reopen the app (lasts
until logout). A miss shows as `host_spawn: node host failed to start (<path>)`.
That is a smoke spine, not a store bundle.

Owner decision pending: `shell/` / `ppomi-shell` is outside the locked
`ppomi-*` names, and "Swift `Ppomi/` is not a UI replacement" diverges from
#61's "test in the main app". Not decided here.
