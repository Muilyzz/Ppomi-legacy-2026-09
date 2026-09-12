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

Same `LOCAL_SIGN_ID` every local Mac build (Swift `make-app.sh`). Quit the old app first — the script does. Do not keep `*-prev.app` or `dist/backup/*.app`; those mixed copies are why TCC listed 「previous」. Do not `tccutil reset` as routine. Ad-hoc is not for permission smoke. `tauri dev` / `target/` are not install paths.

`실행` with intent `다음` (or `browse`) calls `run_path` → `src/host.ts` →
`ppomi-brain` → `path-home-next` → `ppomi-body-macos` fixture click on `Next`.

Live Mac AX (손쉬운 사용 on the terminal or the app):

```sh
PPOMI_BODY_LIVE=1 npm --prefix shell run host -- --intent 다음 --body macos --live
```

Or check **live** in the window. Off-macOS / no grant is a skip, not a crash.

Windows is the same shell, not a second C# chrome. `ppomi-executor` is UIA body.

```sh
npm --prefix shell run host -- --intent 다음 --body windows
npm --prefix shell run dev          # pick body=windows
# packaged (on Windows; needs MSVC + WebView2):
npm --prefix shell run build
```

Live UIA (human UAC / Edge). Off-Windows skips. CI unit uses
`PPOMI_WINDOWS_FAKE_EXECUTOR` against the fake JSONL executor:

```sh
PPOMI_BODY_LIVE=1 npm --prefix shell run host -- --intent 다음 --body windows --live
```

Android fixture uses the same IPC (`--body android`). Live UIAutomator stays
the existing `ppomi-body-android` example (MZZ-55c).

Packaged `npm --prefix shell run build` still needs `node` on `PATH` (or
`PPOMI_NODE`) for the TS host. That is a smoke spine, not a store bundle.
