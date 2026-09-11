# Android executor and Tauri shell

The shared UI talks to the shell's `executor_request` command using a bounded JSON
request `{id, method, args}`. Android routes that request through the local
`tauri-plugin-ppomi-executor` Rust plugin to Kotlin's `AndroidExecutor`. Responses
are `{id, result}` or `{id, error: {code, message}}`; request IDs are canonical UUIDs.
The native dispatcher permits at most 32 pending requests and 180,000 characters
per envelope. Errors do not expose credentials, native exceptions or tool content.

`AndroidExecutor` owns the existing foreground-service session, HTTPS server proxy,
private workspace tools, and accessibility control ownership. It has no WebView or
Tauri dependency. `VoiceSessionHost` is the compatibility adapter for the standalone
Compose app's trusted WebView. `ForegroundHost` supplies the currently visible
activity and native permission request. The Tauri plugin implements the same
interface, so the service, Telecom call UI, app allowlist, stale-node protection,
password redaction, and protected-action checks use one implementation.

The plugin Android library compiles the existing Java/Kotlin sources and resources
through Gradle `sourceSets`; there is no copied second executor. Its manifest
contributes the accessibility service, foreground service, self-managed call service,
call activity, permissions, and a non-exported native settings activity. The shell's
launcher remains the only exported launcher. Native notifications and the control
overlay return through `ExecutorNavigation` to the launcher of the installed APK.
Pending-approval reminders open the native task record and its approval controls directly.

## Protocol

Existing methods remain `bootstrap`, `sessionState`, `request`, `executeTool`,
`heard`, and `declineCall`. Model tool dispatch remains confined to
`AndroidExecutor.TOOLS`; UI management methods cannot be invoked as tools.

Additional trusted UI methods:

| Method | Arguments | Result |
| --- | --- | --- |
| `executorStatus` | `{}` | `platform`, `active`, `mode`, `approval`, `accessibility`, `capabilities` |
| `answerApproval` | `{id, choice}` | `{accepted:true}`; `choice` is `승인` or `취소` |
| `openSettings` | `{}` | Opens the native workbench/settings while idle |
| `openRecords` | `{}` | Opens the existing native records section while idle |
| `openControlApps` | `{}` | Opens the native app allowlist picker while idle |
| `accountingReport` | `{archive}` | Read-only report through the existing canonical Swift JNI engine |

An approval's `id` is the current persisted approval event UUID, not just the task
ID. The executor checks the same event while holding the runner lock, preventing a
response to a previous step from approving a later step. Approval and settings
require a visible unlocked activity. Selecting apps still goes through
native `BridgeAccessPolicy.saveUserPackages`; no model tool can expand its scope.

The Rust plugin forwards Kotlin's `notification` channel as the Tauri
`ppomi-executor` event with `{event, payload}`. Events are `notice`, `incomingCall`,
`answerCall` (string payloads), and `voiceStop` (null). Bootstrap also includes a
pending answered-call reason for a cold launch. Session teardown cancels queued
work, resolves pending requests with `session_ended`, cancels the native proxy,
releases control, restores audio mode and ends the OS call. Uncertain writes are
not retried. Destroying the shell also cancels idle requests.

Foreground attachment and teardown are checked against host identity. A late
`onStop` or `onDestroy` from a replaced host cannot cancel the successor's pending
permission request, active session, or native proxy calls. Permission completion and
foreground-service startup also require the host that initiated that start. The
legacy WebView tracks its current activity separately so delayed disposal cannot
destroy a view already reused by another activity. Native records/settings navigation
uses the records section (1) or the top-bar settings sheet (2). The standalone
workbench keeps top bar, conversation, and content as its three root regions: at
600 dp or wider, records/control are on the left and the retained chat is on the
right; narrower windows show chat until the content sheet is opened. Idle app
selection refreshes bootstrap without replacing that conversation document.
Approval notification timers pause while the native approval controls are visible.
The dispatcher keeps task IDs for speech approval/reminders and event IDs for
`answerApproval` stale-response validation.

The legacy WebView adapter also owns signed family-web release loading, the
`updateReady` handshake, and startup-failure recovery. It adds native build and web
release metadata to executor bootstrap responses and prevents an unconfirmed trial
page from starting a session. These checks remain at the document adapter boundary;
the Tauri shell packages and owns its own document.

A Tauri WebChromeClient permission gate preserves the original active voice-session,
local origin, audio-only and Android runtime permission checks. Text sessions do not
request microphone access. A destroyed shell ends its session; changing to another
app leaves a user-started foreground service active as before. Device-specific
background WebView/audio behavior still requires explicit device verification.

The product uses `https://ppomi-agent.vercel.app`, matching the canonical
`PpomiServer.agentEndpoint` in `Shared/SupabaseAuth.swift`. Neither the common shell
nor native settings collect server URLs, connection JSON, or model API credentials;
`setEndpoint` is no longer a native UI method. Old user-entered endpoint preferences
are ignored. Only debug builds accept an HTTPS `endpoint_override` through the
existing `android.permission.DUMP`-protected `DebugProvisioningActivity`; release
always uses the constant. The Tauri debug manifest includes this activity with its
fully qualified native class name and the same permission guard.

Android authentication is still the previous encrypted device email/password
configuration consumed by `SupabaseSettings`/`SupabaseClient`. Google OAuth/PKCE,
the `ppomi://auth` callback, and Google account/device registration are not implemented
on Android. A fixed server address therefore does not complete new-user onboarding.
This refactor neither presents a nonfunctional login button nor converts existing
device credentials into Google sessions. Debug provisioning remains a development
path, not the product's account setup flow.

## Build

From `shell/`, install the npm dependencies and run:

```sh
node scripts/android-init.mjs
rustup target add aarch64-linux-android
npm run frontend
npm run tauri -- android build --debug --target aarch64 --apk --ci
```

Set `JAVA_HOME`, `ANDROID_HOME`, and `NDK_HOME` for the installed JDK/Android SDK/NDK.
The init script regenerates ignored Tauri Android files when absent and applies
reproducible settings: API 35, minimum API 28, Gradle 8.11.1, AGP 8.7.3,
Kotlin/Compose compiler 2.2.21, and backup exclusion. Pass `--regenerate` to recreate
the generated project. It configures the downloaded Tauri Android dependency's SDK
through Gradle rather than modifying cached dependency sources.

The native plugin's `preBuild` invokes `Android/swift-core/build.sh android` and
packages the resulting Swift/JNI libraries and synthetic example assets. The
existing bridge currently builds **arm64-v8a only**; use `--target aarch64`. Windows,
x86 Android, and ARMv7 cannot substitute for that library. `LifeJSON.swift` is staged
byte-for-byte with the accounting files, preserving timestamp encoding/validation.
No accounting arithmetic is implemented in Kotlin or Rust.

## Verification and limits

`Android/tests/run-protocol-tests.sh` checks existing access/protected-action/error
policies off-device. `:app:assembleDebug` checks the compatibility host. The native
`AndroidExecutorTest` instrumentation source exercises bootstrap and rejection
responses without creating a WebView or starting accessibility actions. Building an
instrumentation APK does not execute those tests; device execution must be requested
separately.

The refactor was checked with the off-device protocol suite, the standalone debug
APK build, and `tauri android build --debug --target aarch64 --apk --ci`. The Tauri
APK contains the shared executor and Swift accounting JNI libraries. After integrating the common workbench and family-web changes, the standalone
Kotlin, Java, and instrumentation Java compilation passed. The off-device suite
also passed, including family package verification/rollback and 14 lifecycle-owner
assertions. Existing instrumentation sources were not changed as part of this
integration and were not executed; the earlier combined frame/IME teardown failure
has not been revalidated against the extracted owner guards. No APK was installed
during integration, and this compile check does not verify microphone, call,
accessibility, or approval behavior on a device.

The Tauri app has a separate application ID and sandbox from the standalone APK.
Existing preferences, keys, files, and accessibility grants are not silently copied.
The user must configure/enable the new installation. Release accessibility control
remains disabled by the existing `BridgeSession.supported()` policy. This refactor
does not claim Play distribution approval or production support for automatic
financial actions. The older settings/workbench UI remains available for native
capabilities not yet presented by the shared shell.
