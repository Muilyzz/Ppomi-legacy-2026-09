# ppomi-shell

Tauri 2 + TypeScript consumer surface. Native Swift / C# / Kotlin stay OS body
(AX, capture, Keychain/CredMan, mirroring) — they do not replace this UI.

Swift `Ppomi/` remains the transitional Mac body host. Do not delete it here.

## Mac install / run

Need Node 22.6+, Rust (1.77+), and on a Mac: Xcode + macOS 26 WebView.

```sh
npm --prefix shell ci
npm --prefix shell test          # brain → path → body fixture (no window)
npm --prefix shell run build:ui
npm --prefix shell run dev       # window + 실행
```

`실행` with intent `다음` (or `browse`) calls `run_path` → `src/host.ts` →
`ppomi-brain` → `path-home-next` → `ppomi-body-macos` fixture click on `Next`.

Live Mac AX (손쉬운 사용 on the terminal or the app):

```sh
PPOMI_BODY_LIVE=1 npm --prefix shell run host -- --intent 다음 --body macos --live
```

Or check **live** in the window. Off-macOS / no grant is a skip, not a crash.

Windows / Android fixtures use the same IPC (`--body windows|android`). Live OS
hooks stay the existing `ppomi-body-*` examples (MZZ-55b / MZZ-55c).

Packaged `npm --prefix shell run build` still needs `node` on `PATH` (or
`PPOMI_NODE`) for the TS host. That is a smoke spine, not a store bundle.
