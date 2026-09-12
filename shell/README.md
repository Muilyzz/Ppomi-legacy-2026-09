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

Same `LOCAL_SIGN_ID` every local Mac build (Swift `make-app.sh`). Quit the old app first — the script does. The install path must be an absolute `*.app` (`PPOMI_APP` / `PPOMI_ROOT` are read only by the `--hygiene` / `--check` test modes); any `*-prev.app` or `뽀미*.app` sibling or `dist/backup/` is refused, and the build copy under `target/…/bundle/macos` is deleted after the copy — those mixed copies are why TCC listed 「previous」. Do not `tccutil reset` as routine. Ad-hoc is not for permission smoke. `tauri dev` / `target/` are not install paths. `Info.plist` declares `NSAppleEventsUsageDescription` for the live path's Automation prompt.

Reinstall after the host JSON hotfix (quit the running app first):

```sh
LOCAL_SIGN_ID="Apple Development: …" scripts/install-shell.sh
open --env PPOMI_CHAT=fixture /Applications/뽀미.app
```

Prefixing `PPOMI_CHAT=fixture open …` does **not** pass env into the GUI app. `지금 데이터 뭐 있어?` should be the Korean path-not-found bubble (or fixture tool + that text), never `node host returned invalid JSON`. Node spawn clears inherited `NODE_PATH` / Grok Electron injects.

The window is the **agent conversation shell** (`agent/src/ui/shell.tsx`)
inside Tauri — same visual family as Storybook 「대화 셸」. Placeholder verb
only: `시킬 일을 적어 주세요`. Send goes through a Vercel AI Gateway
Responses loop when configured (`AI_GATEWAY_API_KEY` or `PPOMI_CHAT=fixture`).
The model may call one host tool, `run_path`, which reuses the existing
spine (`src/host.ts` → `ppomi-brain` → body / `ppomi-secrets`). The ToolCard
is painted from that **model function_call** (`via: "gateway"`), not from a
local regex on the composer text. No key / no fixture: same local matcher as
before (offline, no crash). Chat never prints a plaintext account —
masked `****last4` only.

Type `다음` or `browse`: `run_path` → `path-home-next` → `ppomi-body-macos`
fixture click on `Next`. `내 사업자 KB계좌번호 알아?` still matches locally.
`KB스타비즈에 넣어둔 번호 마지막만 보여줘` does **not** match the local regex
— that prompt is how you prove the Gateway/fixture tool loop.

No IA header, no empty-state chips, no greeting — composer-only empty
inside the real shell chrome.
The window never arms live: `run_path` refuses `live: true` (`live_refused`)
and never forwards `PPOMI_BODY_LIVE`, `PPOMI_BODY_AX`, `PPOMI_BODY`,
`PPOMI_SECRETS_LIVE` to the node child, so a variable inherited from another
probe's shell cannot turn the fixture run into real control or a real
Keychain/CredMan read. The JSON reply carries the core `run` (`driver`,
`status`, `attempt`, `code`) next to the brain status.

### Vercel AI Gateway

The webview never holds the key (Tauri CSP is IPC-only). Packaged app:
`ai_gateway` IPC → `host.ts --proxy-responses` → `https://ai-gateway.vercel.sh/v1/responses`
(env `AI_GATEWAY_API_KEY`, optional `AI_GATEWAY_BASE_URL`, `AI_TEXT_MODEL`).
Vite preview: same proxy at `/__ppomi/responses`, or `?chat=fixture` for an
offline model-shaped function_call.

```sh
# real Gateway (Mac install / host)
AI_GATEWAY_API_KEY=… PPOMI_CHAT=  npm --prefix shell run host -- --proxy-responses
# offline model-shaped loop (no key)
PPOMI_CHAT=fixture npm --prefix shell run dev:ui
# then open /?chat=fixture — or set PPOMI_CHAT=fixture for the Vite middleware
```

Missing key: composer still works; ToolCards come from `linesFromSpine` only
when the local matcher hits. Do not put account digits in chat.

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
