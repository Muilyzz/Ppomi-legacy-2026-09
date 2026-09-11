# Windows executor

`executors/windows` is the C# UI Automation helper that `ppomi-body-windows` live smoke talks to. Source lives in this tree (ported from the family-updates / PR #4 executor). The Tauri `shell/` app is **not** required for live smoke.

## Live smoke (`ppomi-executor.exe`)

Needs .NET 10 SDK (`winget install Microsoft.DotNet.SDK.10`). Self-contained publish; the Windows VM does not need the SDK at run time.

```bat
:: Parallels Windows clone, from repo root
node scripts/build-windows-executor.mjs
:: ARM64 VM:
node scripts/build-windows-executor.mjs --rid win-arm64
:: or pull the latest CI artifact (GitHub CLI):
node scripts/build-windows-executor.mjs --download --rid win-arm64

set PPOMI_EXECUTOR=%CD%\shell\src-tauri\resources\executor\ppomi-executor.exe
set PPOMI_BODY_LIVE=1
npm --prefix packages/ppomi-body-windows run smoke:live
node --experimental-strip-types packages/ppomi-body-windows/example/src/main.ts
```

Default stage path (what live smoke already looks for): `shell/src-tauri/resources/executor/ppomi-executor.exe`. Override with `PPOMI_EXECUTOR`. CI uploads `ppomi-executor-win-x64` and `ppomi-executor-win-arm64`.

`dotnet run --project executors/windows/PolicyTests/Ppomi.Executor.PolicyTests.csproj` is the Linux-safe policy suite. UIA itself only runs on Windows.

---

`executors/windows/Executor/Ppomi.Executor.Windows.csproj` builds a .NET 10 console helper for the Tauri shell. It runs locally on Windows and uses Windows UI Automation. There is no Mac host, Parallels guest, remote desktop, PowerShell bridge, or WPF application window. The WindowsDesktop framework reference supplies Microsoft's `UIAutomationClient` assemblies.

The standard agent endpoint is the app constant `https://ppomi-agent.vercel.app`. Missing, empty or unreadable saved endpoint settings fall back to that address. There is no server-address entry in the product UI. Explicit endpoint overrides remain only for CLI/development compatibility.

## Google sign-in and device approval

Windows uses the same product path as the Mac and iPad: Supabase Google sign-in (PKCE), `ppomi_register_device` with this device's X25519 public key, then the owner's approval on the Mac. The executor owns the whole flow; the Tauri shell only opens a URL and relays a deep link.

1. `beginSignIn` creates a PKCE verifier (native memory, 10 minutes) and returns the Supabase authorize URL (`provider=google`, `redirect_to=ppomi://auth`). The shell checks that it is the project's HTTPS authorize endpoint and opens it in the **system browser** (no password is typed into the app's WebView2).
2. The browser returns `ppomi://auth?code=…`. The Windows bundle registers the `ppomi` scheme (tauri-plugin-deep-link; the shell also registers it at start for `tauri dev`), tauri-plugin-single-instance forwards the launch to the running window, and the shell hands the callback to `completeSignIn {callback}` under a request id of its own (`beginSignIn` used another; the executor rejects a reused id for its lifetime). The shell waits five minutes for the browser and then reports `sign_in_timeout` in the account sheet, but a callback that arrives later is still handed over: the executor's ten-minute verifier decides, and a stale code produces one visible notice instead of silence.
3. `completeSignIn` exchanges the code with the verifier (`grant_type=pkce`), then calls `ppomi_register_device(p_platform:"windows", p_public_key)`. The device is now **registered but pending**: `bootstrap.configured` stays `false`, `authentication.pendingApproval` is `true`, and the panel says "Mac에서 이 기기를 승인하면 연결됩니다."
4. The owner opens 나 › 기기 승인 on the Mac and presses 승인. The executor polls `ppomi_context` every 15 seconds; when `device.approved` turns true it reports `configured:true` (the banner clears), fetches the wrapped record key (`ppomi_key_get`) and unwraps it with the device's private key (ppomi-wrap-v1: X25519 → HKDF-SHA256 → AES-GCM, the same format as the Mac's `KeyWrap`). `.NET 10` has no Curve25519, so `Core/KeyWrap.cs` implements RFC 7748 over `System.Numerics`; it is verified with the RFC vectors and a WebCrypto-produced wrapped key. It is not constant-time; the key it protects is a per-user DPAPI secret that the same Windows user can read anyway.
5. 거절 on the Mac revokes the device: the next poll sees a refused context, deletes the record key and registers again as pending. `signOut` deletes the session and record key but keeps the stable device ID, so the same device row is reused after the next sign-in.

`bootstrap.authentication` reports `method:"google"`, `signedIn`, `approved`, `pendingApproval` and a display name only; `executorStatus.account` carries the same presentation state plus `recordKey`. Tokens, the account email and keys never cross the protocol. Until the owner approves, `request` refuses with `server_auth` and the agent server refuses the device with `device_unapproved`.

The email/password device-file import remains **only as a developer compatibility path** behind the environment variable `PPOMI_DEVELOPER_DEVICE_IMPORT=1` on the shell process. Without it, `configureDevice` is rejected, a stored `device.dpapi` is ignored and the settings sheet shows no import button. With it, `authentication.method` is `deviceConfigImport` and `developerOnly:true` while no Google session exists.

## Build and package

```sh
node scripts/build-windows-executor.mjs --rid win-x64
node scripts/build-windows-executor.mjs --rid win-arm64
```

That is `dotnet publish` (Release, self-contained, single-file) into `executors/windows/artifacts/<rid>/` and a copy at the smoke default path. Cross-publish works on Linux with the .NET 10 SDK; macOS also needs the WindowsDesktop reference packs. Use `win-arm64` on a Windows ARM64 VM (Parallels on Apple silicon). Package the helper as a Tauri resource and invoke its absolute installed resource path:

```text
ppomi-executor.exe --executor --owner-pid <Tauri-process-id>
```

`--owner-pid` is mandatory and identifies the shell whose UI must never be controlled. Launch without elevation; the helper refuses an elevated token. The shell must own its stdin/stdout pipes and terminate the process at shutdown. No network port or named pipe is exposed.

## Protocol

One UTF-8 JSON object per line:

```json
{"id":"unique-request-id","method":"executeTool","args":{"name":"file_list","args":{"path":""}}}
{"id":"unique-request-id","result":{"path":"","entries":[],"truncated":false}}
```

Failures return `{"id":"...","error":{"code":"...","message":"same-safe-code"}}`. Exceptions, credential values, full paths and HTTP error bodies are not logged. Lines are bounded, at most 32 operations are in flight, and duplicate request IDs are rejected for the process lifetime (50,000-ID ceiling). The transport must never replay a mutation after timeout/restart.

Management methods are **trusted local UI operations**, not model tools. The Tauri shell must keep this route separate from `executeTool` and serve only its bundled frontend:

| Method | Arguments | Result / behavior |
| --- | --- | --- |
| `bootstrap` | `{}` | `platform:"windows"`, device label, `configured` (= signed in and approved, or a developer import), `authentication`, `executor.googleSignIn:true`, endpoint, actual tools, tool guide, allowed-app discovery |
| `executorStatus` | `{}` | `platform`, `active`, `mode`, `approval:null`, `configured`, `account:{signedIn,registered,approved,pendingApproval,recordKey,displayName}`, capability flags, `availableApps:[{label,packageName,allowed}]`; works while idle |
| `sessionState` | `{active:boolean,mode:"text"\|"voice"}` | Starts or ends native tool admission; duplicate start is rejected |
| `beginSignIn` | `{}` | Idle only. New PKCE verifier; returns `{url}` of the Supabase Google authorize endpoint for the system browser |
| `completeSignIn` | `{callback:string}` | Idle only. `ppomi://auth?code=…` → token exchange → `ppomi_register_device`; returns `{configured, account}`; `sign_in_failed` for a foreign or stale callback |
| `signOut` | `{}` | Idle only. Deletes the session and record key; the device ID and device key stay |
| `refreshAccount` | `{}` | Idle only. `ppomi_context` (+ `ppomi_key_get` once approved); the same poll runs every 15 s in the background while pending |
| `configureDevice` | `{path:string}` | Only with `PPOMI_DEVELOPER_DEVICE_IMPORT=1`: imports an existing device-registration JSON file; idle only; returns no secret; not Google sign-in |
| `setEndpoint` | `{endpoint:string}` | CLI/development override only, not advertised as a product UI capability; idle only; an empty value restores the standard endpoint |
| `setControlApps` | `{packageNames:string[]}` | Replaces the control allowlist with currently discoverable app IDs; idle only |
| `request` | `{path:string,body:object}` | Authenticated server proxy, requires active native session |
| `executeTool` | `{name:string,args:object}` | One of the tools below, requires active native session |
| `heard` | `{...}` | Acknowledges an active-session transcript without storing it or treating it as approval |
| `declineCall` | `{}` | Acknowledgement; no Windows call integration is advertised |

There is no Windows bank-profile form or approval resolver. Known protected actions return `protected_action`; a spoken “yes” cannot release this restriction.

## Supported local tools

* `device_status`: interactive desktop, foreground discovered app, allow state and own-window state.
* `app_list {query}`: visible **running** applications, grouped by process. These are not installed-package identifiers. One visible top-level window per process is selected. Command/system hosts, elevated processes, Ppomi, WebView2 hosts and unsupported process identities are excluded.
* `app_open {target}`: brings an allowed running application's window to the foreground. It never starts an executable. A foreground-lock refusal is a failure. The user opens an absent application themselves.
* `screen_read`: bounded UI Automation tree of the foreground allowed app; up to 500 nodes, 20 levels, 5 seconds between provider calls. It returns fresh opaque node IDs, text, roles, flags and bounds. Password nodes are redacted. Unsupported/custom-drawn content has no OCR fallback.
* `ui_tap {nodeId}`: UIA `InvokePattern` only.
* `ui_type {nodeId,text}`: UIA `ValuePattern.SetValue` only, up to 4096 characters. No keystroke injection, Enter, password input or clipboard use.
* `ui_scroll {direction}`: a single unambiguous vertically scrollable node from the current snapshot; returns a fresh read. Multiple scroll targets are rejected.
* `file_list {path}`, `file_read {path}`, `file_write {path,content}`: UTF-8 text under `%LOCALAPPDATA%\Ppomi\Executor\workspace`. Existing subdirectories can be used; these tools do not create directories. Read/write maximum 128 KiB; replies include byte size and SHA-256; writes require a matching readback.

App grants are memory-only IDs containing PID and process-start time. Closing/restarting an application or the executor requires a new user selection. Before a UI action, the executor rechecks foreground window, current process identity, allowlist, default input desktop, element ancestry and the selected element's runtime ID, text/value, role, bounds and flags. Snapshots expire after 15 seconds and are invalidated after every action and session transition. There is no coordinate, shell, browser-debugging, arbitrary process-launch or global keyboard tool.

The protected-label deny rule covers common Korean/English payment, send, delete, authentication and permission labels, including AutomationId and ancestors of the selected element. It is a conservative filter, **not a complete understanding of application transactions**. An innocuous label may perform a consequential action; a malicious UI provider may lie about its content. Allow only applications the user trusts. This helper is not a sandbox against another process running as the same Windows user, and an application allow grant does not authorize every possible business transaction. Other languages and unfamiliar applications need their own product policy and validation before release.

## Credentials and filesystem boundary

Everything secret lives in `%LOCALAPPDATA%\Ppomi\Executor\` as current-user DPAPI blobs inside a directory whose ACL admits only that user: `session.dpapi` (Supabase access/refresh token, subject, display name, registered/approved flags), `device-key.dpapi` (the X25519 private scalar created on first use), `record-key.dpapi` (the unwrapped record key once the Mac delivered it) and, for the developer import only, `device.dpapi`. `device-id.txt` holds the stable device ID in plain text; it is an identifier, not a secret, and becomes the `X-Ppomi-Device` header and the server row. Nothing is written into the repository, journals or exports. Plaintext still exists in native process memory while a request needs it.

The developer import uses the existing shared-server fields `url`, `publishableKey`, `email`, `password`, `deviceId`. Import validates size, regular-file identity, the exact HTTPS `<project>.supabase.co` host, an anon/publishable key, password length and UUID. It does not delete the user's source file. Endpoint settings contain no password or token.

The proxy prefers the Google session: it refreshes the access token 30 seconds before expiry (`grant_type=refresh_token`, persisted), sends `Authorization: Bearer` plus `X-Ppomi-Device` to the agent server, and refuses to send anything while the device is not approved. A dead refresh token signs the installation out instead of retrying. Only with the developer flag and no Google session does it fall back to the password grant and the `ppomi_context` device check of the imported account. Only `/v1/session`, `/v1/responses`, `/v1/memories/list`, `/v1/memories/save` and `/v1/memories/delete` can be sent to the standard agent service or an explicit development override; the Supabase RPCs the executor itself calls are `ppomi_register_device`, `ppomi_context` and `ppomi_key_get`. HTTPS is mandatory; redirects, cookies and automatic mutation/authentication retries are disabled. Payloads/responses are bounded. Long-lived credentials and Supabase access tokens are never returned to JavaScript. A server-provided short-lived voice session credential may be returned by `/v1/session`, as required by the frontend's voice transport. A development override is a trusted credential recipient; the path allowlist does not vouch for its operator.

Workspace traversal, alternate data streams, device names, hidden temporary-write names, trailing Windows path aliases, UNC paths, reparse points and multi-link regular files are rejected. The helper opens directories without delete sharing, keeps them open across child operations, opens files with `FILE_FLAG_OPEN_REPARSE_POINT`, rejects their reparse attributes and checks the final handle path. Writes use a same-directory temporary file followed by replacement and readback; they never write through an existing destination link. These controls restrict model file tools. They do not establish isolation from an attacker already running as the same OS user.

## Cancellation and recovery

Session leases are captured at request admission; stopping cancels HTTP and invalidates queued tools. A new session never inherits an old lease or snapshot. Stop remains admitted even when operation slots are full. An OS action already handed to another application cannot be undone by cancellation; an uncertain result must be inspected without automatically repeating it.

UI Automation runs on a single MTA worker. A provider taking over 20 seconds terminates the executor with exit 70, preventing its queued work from running later. The shell must mark pending requests failed, leave the conversation stopped, and restart the helper only as a fresh process with empty grants. EOF also ends the process/session. No background service, automatic session resumption or durable mutation queue is implemented.

## Verification boundary

`PolicyTests` uses only synthetic configuration and an in-memory HTTP handler. It checks path and URL bypasses, service-key rejection, session generations, registration binding, token isolation, bounded routes, redirect-error behavior and cancellation, plus the sign-in path: RFC 7748 X25519 vectors, a wrapped key produced by WebCrypto, PKCE and callback parsing, sign-in → pending → approval → wrapped key → revocation, token refresh persistence and a dead refresh token. It requires no account, API key, network, UI or live financial application.

A macOS or Linux build validates C# and the Windows reference assemblies and produces the self-contained `win-x64` executable; it does **not** prove Windows UIA, DPAPI, NTFS handle semantics, the `ppomi://` scheme registration or packaging behavior. Before Windows release, run on a disposable Windows desktop with a harmless fixture app: sign in with a test Google account and confirm the browser returns to the running window, that the device appears in the Mac's 기기 승인 list and that approval clears the banner within 15 seconds; sign out, restart and sign in again with the same device ID; allow/deny a running app; verify screen IDs and stale rejection after edits/focus changes; check password controls, protected buttons, elevated/own windows, session stop and process restart; exercise regular files, junctions, symlinks, hard links, ADS and a temporary-file write race; test helper EOF/hung-provider recovery. Never use a real purchase, transfer, destructive command or production account for these checks.

References: [Microsoft UI Automation elements](https://learn.microsoft.com/en-us/dotnet/api/system.windows.automation.automationelement?view=windowsdesktop-10.0), [CreateFileW flags and sharing](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew).
