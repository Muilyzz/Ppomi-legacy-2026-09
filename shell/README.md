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

Reinstall after the host JSON hotfix (quit the running app first):

```sh
LOCAL_SIGN_ID="Apple Development: …" scripts/install-shell.sh
open --env PPOMI_CHAT=fixture /Applications/뽀미.app
```

Prefixing `PPOMI_CHAT=fixture open …` does **not** pass env into the GUI app. `open --env` lasts for that launch only: quit, then Dock/Finder starts a new process without it. `open --env AI_GATEWAY_API_KEY=…` is **HITL only**, not the product path. Clerk is who (Google lands on `web/` `/account`). The Gateway key stays host-side (`~/.ppomi/.env` must be mode 600 or the host refuses it; optional `$PPOMI_ROOT/shell/.env`). A file-held key is posted only after a Clerk session JWT verifies with JWKS + aud/azp — this is **not** an auth gate: the same OS user can read the file, and process env still wins (HITL). No Keychain, no Tauri Clerk UI, no deep link. `PPOMI_CHAT=fixture` still forces fixture. 「안녕」 / thanks / 뭐해 / 「너 모델 뭐야?」 in fixture or unset Gateway is a short secretary reply, never the path-not-found bubble. Live Gateway may answer that chat in text with no tool. The key is never printed and never given to the webview. A true miss (`지금 데이터 뭐 있어?`) is the Korean path-not-found bubble when Gateway is unset. If Gateway/`complete()` throws, the bubble is `모델 연결에 실패했습니다. 게이트웨이 오류: <code>` — local `run_path` is not a disguise. `run_path` IPC failure is `실행에 실패했습니다.` — never `node host returned invalid JSON` and never disguised as path-not-found. Node spawn clears inherited `NODE_PATH` / Grok Electron injects. `PPOMI_CHAT=fixture` is an IPC ack; the webview fills the fixture Responses body (no node proxy required). The composer footer shows `Gateway` when the live proxy is on, and `fixture` only when `PPOMI_CHAT=fixture`.

The window is the **agent conversation shell** (`agent/src/ui/shell.tsx`)
inside Tauri — same visual family as Storybook 「대화 셸」. Placeholder verb
only: `시킬 일을 적어 주세요`. Send goes through a Vercel AI Gateway
Responses loop when configured (Clerk-gated host key, HITL process `AI_GATEWAY_API_KEY`, or `PPOMI_CHAT=fixture`).
The model may call one host tool, `run_path`, which reuses the existing
spine (`src/host.ts` → `ppomi-brain` → body / `ppomi-secrets` / `ppomi-path`
catalog). The ToolCard is painted from that **model function_call**
(`via: "gateway"`), not from a local regex on the composer text. No key /
no fixture: same local matcher as before (offline, no crash). Chat never
prints a plaintext account — masked `****last4` only.

Type `다음` or `browse`: `run_path` → `path-home-next` → `ppomi-body-macos`
fixture click on `Next`. `내 사업자 KB계좌번호 알아?` and
`KB스타비즈에 넣어둔 번호 마지막만 보여줘` both hit `path-secrets-account`
(local aliases + fixture/Gateway `run_path(사업자 계좌번호)`).
`KB스타기업뱅킹 열어` / `KB 사업자 홈` / `path_cold_start` load
`kb-star-biz-iphone` from the `ppomi-path` catalog (Home → KB, Face ID).
`지금 데이터 뭐 있어?` has no catalog path yet. Casual chat (`안녕`, `뭐해`, `thanks`, `너 모델 뭐야?`) is a secretary reply, not `run_path`.

No IA header, no empty-state chips, no greeting — composer-only empty
inside the real shell chrome.

### Vercel AI Gateway

The webview never holds the key (Tauri CSP is IPC-only). Packaged app:
`ai_gateway` IPC → `host.ts --proxy-responses` → `https://ai-gateway.vercel.sh/v1/responses`.
Who: Clerk session (Google → `web/` `/account`). Host key: `~/.ppomi/.env` only
after that session verifies (interim). HITL escape: process `AI_GATEWAY_API_KEY`
(`open --env`, not Dock). Else `$PPOMI_ROOT/shell/.env` with the same Clerk gate
(optional `AI_GATEWAY_BASE_URL`, `AI_TEXT_MODEL` in the same file). `VERCEL_OIDC_TOKEN` is ignored.
Vite preview: same proxy at `/__ppomi/responses`, or `?chat=fixture` for an
offline model-shaped function_call.

```sh
# packaged Mac — Dock / open, no --env
# ~/.ppomi/.env          AI_GATEWAY_API_KEY=…   (host secret)
# ~/.ppomi/clerk-session  Clerk session JWT     (after web /account)
open /Applications/뽀미.app
# HITL only — not the product path
open --env AI_GATEWAY_API_KEY=… /Applications/뽀미.app
# real Gateway (CLI host, HITL)
AI_GATEWAY_API_KEY=… PPOMI_CHAT=  npm --prefix shell run host -- --proxy-responses
# offline model-shaped loop (no key)
PPOMI_CHAT=fixture npm --prefix shell run dev:ui
# then open /?chat=fixture — or set PPOMI_CHAT=fixture for the Vite middleware
```

Missing key: composer still works; ToolCards come from `linesFromSpine` only
when the local matcher hits. Do not put account digits in chat.

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

KB스타기업뱅킹 live is fixture-default; the host documents the iPhone
Mirroring body hook (MZZ-46 / MZZ-52). Face ID / login stay HITL:

```sh
npm --prefix shell run host -- --intent 'KB스타기업뱅킹 열어'
PPOMI_BODY_LIVE=1 npm --prefix shell run host -- --intent 'KB스타기업뱅킹 열어' --live
PPOMI_BODY_LIVE=1 node --experimental-strip-types packages/ppomi-body-iphone-mirroring/example/src/main.ts
```

Windows / Android fixtures use the same IPC (`--body windows|android`). Live OS
hooks stay the existing `ppomi-body-*` examples (MZZ-55b / MZZ-55c).

Packaged `npm --prefix shell run build` still needs `node` on `PATH` (or
`PPOMI_NODE`) for the TS host. That is a smoke spine, not a store bundle.

Failures stay failures. `run_path` / `ai_gateway` pipe the node child's
stdout and stderr (60 s / 120 s timeout, then kill) and use the last JSON
object; anything else is `{ code, message }` — `run_path_host_failed` /
`gateway_host_failed` — never an empty or invented result. In the window an
IPC failure is `실행에 실패했습니다.` plus an `output-error` card
(`run_path_ipc_failed: <code>`), a Gateway failure is
`모델 연결에 실패했습니다. 게이트웨이 오류: <code>`; neither is disguised as
path-not-found or downgraded to the regex matcher. Only "no key and no
fixture" falls back locally, and that card says `via: "local"`. The browser
`previewSpine` runs only under `vite dev` or `?chat=fixture` and is labelled
`(미리보기)`. The node child gets an allow-listed environment (`PATH`, `HOME`,
`TMPDIR`, `LANG`/`LC_*`, `PPOMI_CHAT`, `PPOMI_NODE`, `PPOMI_MAC_BROWSER`,
`AI_GATEWAY_API_KEY`, `AI_GATEWAY_BASE_URL`, `AI_TEXT_MODEL`); the live-arming
variables, `NODE_*` and `DYLD_*`/`LD_*` never reach it from the window. The
window's `live` refusal (`live_refused`) lands with #79.
