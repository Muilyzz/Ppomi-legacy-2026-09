# Windows executor

`executors/windows/Executor/Ppomi.Executor.Windows.csproj` builds a .NET 10 console helper for the Tauri shell. It runs locally on Windows and uses Windows UI Automation. There is no Mac host, Parallels guest, remote desktop, PowerShell bridge, or WPF application window. The WindowsDesktop framework reference supplies Microsoft's `UIAutomationClient` assemblies.

The standard agent endpoint is the app constant `https://ppomi-agent.vercel.app`. Missing, empty or unreadable saved endpoint settings fall back to that address. There is no server-address entry in the product UI. Explicit endpoint overrides remain only for CLI/development compatibility.

**Windows Google sign-in has not been ported.** `configureDevice` imports the existing JSON device registration only as a developer compatibility path; it is not Google OAuth or production sign-in. `bootstrap.authentication` reports `method:"deviceConfigImport"`, `developerOnly:true`, `googleSignIn:false`; `executorStatus.capabilities` reports `developmentDeviceImport:true` and `googleSignIn:false`. `configured` means that device configuration is present, not that the user has completed Google sign-in. The frontend must not display a Google login success from that flag.

## Build and package

```sh
dotnet run --project executors/windows/PolicyTests/Ppomi.Executor.PolicyTests.csproj
dotnet build executors/windows/Executor/Ppomi.Executor.Windows.csproj
dotnet publish executors/windows/Executor/Ppomi.Executor.Windows.csproj \
  -c Release -r win-x64 --self-contained true \
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
  -o executors/windows/artifacts/win-x64
```

Use `win-arm64` for a native Windows ARM64 build. Cross compilation on macOS needs the Microsoft WindowsDesktop reference/runtime packs from NuGet. The self-contained publish bundles .NET; end users do not install its SDK. Preserve the published files, or use the single executable when publishing with the flags above. Package the helper as a Tauri resource and invoke its absolute installed resource path:

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
| `bootstrap` | `{}` | `platform:"windows"`, device label, configuration status, endpoint, actual tools, tool guide, allowed-app discovery |
| `executorStatus` | `{}` | `platform`, `active`, `mode`, `approval:null`, capability flags, `availableApps:[{label,packageName,allowed}]`; works while idle |
| `sessionState` | `{active:boolean,mode:"text"\|"voice"}` | Starts or ends native tool admission; duplicate start is rejected |
| `configureDevice` | `{path:string}` | Development compatibility: imports an existing device-registration JSON file; idle only; returns no secret; not Google sign-in |
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

The selected configuration uses the existing shared-server fields `url`, `publishableKey`, `email`, `password`, `deviceId`. Import validates size, regular-file identity, the exact HTTPS `<project>.supabase.co` host, an anon/publishable key, password length and UUID. It does not delete the user's source file. Stored bytes are encrypted with Windows current-user DPAPI in `device.dpapi`; the executor directory has a protected ACL for that user. Endpoint settings contain no password or token. Plaintext still exists in native process memory while authentication is needed.

The proxy authenticates the imported development device credentials natively, checks `ppomi_context` against the registered device and workspace, and caches the bearer only in native memory. Only `/v1/session`, `/v1/responses`, `/v1/memories/list`, `/v1/memories/save` and `/v1/memories/delete` can be sent to the standard agent service or an explicit development override. HTTPS is mandatory; redirects, cookies and automatic mutation/authentication retries are disabled. Payloads/responses are bounded. Long-lived credentials and Supabase access tokens are never returned to JavaScript. A server-provided short-lived voice session credential may be returned by `/v1/session`, as required by the frontend's voice transport. A development override is a trusted credential recipient; the path allowlist does not vouch for its operator.

Workspace traversal, alternate data streams, device names, hidden temporary-write names, trailing Windows path aliases, UNC paths, reparse points and multi-link regular files are rejected. The helper opens directories without delete sharing, keeps them open across child operations, opens files with `FILE_FLAG_OPEN_REPARSE_POINT`, rejects their reparse attributes and checks the final handle path. Writes use a same-directory temporary file followed by replacement and readback; they never write through an existing destination link. These controls restrict model file tools. They do not establish isolation from an attacker already running as the same OS user.

## Cancellation and recovery

Session leases are captured at request admission; stopping cancels HTTP and invalidates queued tools. A new session never inherits an old lease or snapshot. Stop remains admitted even when operation slots are full. An OS action already handed to another application cannot be undone by cancellation; an uncertain result must be inspected without automatically repeating it.

UI Automation runs on a single MTA worker. A provider taking over 20 seconds terminates the executor with exit 70, preventing its queued work from running later. The shell must mark pending requests failed, leave the conversation stopped, and restart the helper only as a fresh process with empty grants. EOF also ends the process/session. No background service, automatic session resumption or durable mutation queue is implemented.

## Verification boundary

`PolicyTests` uses only synthetic configuration and an in-memory HTTP handler. It checks path and URL bypasses, service-key rejection, session generations, registration binding, token isolation, bounded routes, redirect-error behavior and cancellation. It requires no account, API key, network, UI or live financial application.

A macOS build validates C# and the Windows reference assemblies; it does **not** prove Windows UIA, DPAPI, NTFS handle semantics or packaging behavior. Before Windows release, run on a disposable Windows desktop with a harmless fixture app: allow/deny a running app; verify screen IDs and stale rejection after edits/focus changes; check password controls, protected buttons, elevated/own windows, session stop and process restart; exercise regular files, junctions, symlinks, hard links, ADS and a temporary-file write race; test configuration import/restart and helper EOF/hung-provider recovery. Never use a real purchase, transfer, destructive command or production account for these checks.

References: [Microsoft UI Automation elements](https://learn.microsoft.com/en-us/dotnet/api/system.windows.automation.automationelement?view=windowsdesktop-10.0), [CreateFileW flags and sharing](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew).
