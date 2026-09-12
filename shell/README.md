# ppomi-shell

Tauri 2 + TypeScript consumer surface. Native Swift / C# / Kotlin stay OS body
(AX, capture, Keychain/CredMan, mirroring) — they do not replace this UI.

Swift `Ppomi/` remains the transitional Mac body host. Do not delete it here.

## Mac install / run

Need Node 22.6+, Rust (1.85+), and on a Mac: Xcode + macOS 26 WebView.

```sh
npm --prefix agent ci            # 대화 셸 UI (agent/src/ui)
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

The window is the **agent conversation shell** (`agent/src/ui/shell.tsx`)
inside Tauri — same visual family as Storybook 「대화 셸」. Placeholder verb
only: `시킬 일을 적어 주세요`. Type `다음` or `browse` and send: `run_path` →
`src/host.ts` → `ppomi-brain` → `path-home-next` → `ppomi-body-macos`
fixture click on `Next`. `내 사업자 KB계좌번호 알아?` (and 계좌번호 / KB 계좌 /
account number) selects `path-secrets-account` and reads `ppomi-secrets`
(`ppomi/kb-star-biz/account`). Chat shows a tool card plus masked `****last4`
only — never the plaintext account. Fixture is the default. Path results land
in chat bubbles / tool cards. Handled outcomes (`path_not_found` included)
return JSON and exit 0.
No IA header, no empty-state chips, no greeting — composer-only empty
inside the real shell chrome.

Live Mac AX (손쉬운 사용 on the terminal or the app):

```sh
PPOMI_BODY_LIVE=1 npm --prefix shell run host -- --intent 다음 --body macos --live
```

Off-macOS / no grant is a skip, not a crash.

Live Keychain / Credential Manager read (empty key → "저장된 사업자 계좌가 없습니다"):

```sh
PPOMI_SECRETS_LIVE=1 npm --prefix shell run host -- --intent '내 사업자 KB계좌번호 알아?' --live
PPOMI_BODY_LIVE=1 npm --prefix shell run host -- --intent '내 사업자 KB계좌번호 알아?' --live
PPOMI_SECRETS_LIVE=1 node --experimental-strip-types packages/ppomi-secrets/example/src/main.ts
```

Mac window install is still the one signed path:

```sh
LOCAL_SIGN_ID="Apple Development: …" scripts/install-shell.sh
```

Windows / Android fixtures use the same IPC (`--body windows|android`). Live OS
hooks stay the existing `ppomi-body-*` examples (MZZ-55b / MZZ-55c).

Packaged `npm --prefix shell run build` still needs `node` on `PATH` (or
`PPOMI_NODE`) for the TS host. That is a smoke spine, not a store bundle.
