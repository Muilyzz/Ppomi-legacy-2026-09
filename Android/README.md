# Ppomi Android standalone prototype

A native Kotlin/Compose workbench and an independent test APK demonstrate on-device task execution:

- `app` / `com.ppomi.androidbridge`: local task UI, explicit approvals, persistent records, native screenshot evidence, `AccessibilityService`, and optional authenticated local MCP endpoint.
- `controlfixture` / `com.ppomi.androidtarget`: an independent app with a counter and Unicode text input.

See [the integration guide](../docs/android-control.md) for the Mac Android tab, emulator and mirroring setup. From the repository root, use `python3 scripts/android-bridge.py prepare`, then `python3 scripts/android-bridge.py test`. Run `--help` for device selection and setup options.

## Ephemeral conversation entry

The primary screen hosts shared bundled TypeScript chat (default) and optional voice at
`https://appassets.androidplatform.net/assets/agent/index.html`. Build/copy the shared
assets through `agent/` before assembling the APK. Only that trusted main-frame
origin can call the native bridge; navigation, subframes, remote scripts, file URLs,
Web Storage, console output, and HTTP caching are disabled. The only direct remote
WebView requests allowed are OpenAI's Realtime WebRTC signaling POST and its
OPTIONS preflight at the exact `/v1/realtime/calls` endpoint, plus text WebSocket at `wss://api.openai.com/v1/realtime`; permanent
Supabase credentials stay in the native HTTPS proxy.

Configure an HTTPS agent-server endpoint in the conversation UI and connect the existing
device-specific Supabase configuration under **기록·설정 → 설정**. Debug builds also
accept setup extras through `.DebugProvisioningActivity`, protected by
`android.permission.DUMP` for ADB shell/privileged callers. The ordinary launcher
activity ignores provisioning extras. Setup is rejected while voice or local
work is active. There is no default agent-server endpoint.

From 0.6.2, **채팅** provides a temporary input/response log and safe tool status. Sending starts a text-only WebSocket session without requesting microphone or notification permission, microphone capture, or audio focus. A `specialUse` foreground service retains the host during other-app control. App opening waits for the target foreground to settle before the next screen read, with a bounded deadline and cancellation checks.

**음성 → 음성 시작** requests microphone permission and, on Android 13+, notification
permission. Both are required for the prototype so the ongoing notification's
**음성 종료** action remains available while another app is foreground. The native
microphone foreground service retains the WebView and voice lifetime across app
switches. Ending from the UI/notification, removing the app task, audio-focus loss,
or host destruction closes the session. The service uses `START_NOT_STICKY` and
never starts listening automatically. On Fold configuration changes the host is
retained; live media continuation still needs verification on the target WebView
and device version.

Chat/voice requests, transcripts, model reasoning and audio are not passed to the
persistent `LocalTaskRunner` or `TaskStore`. Pending callbacks and queued operations
are dropped at session end. Only explicit memory/file tools write content. File
tools are confined to app-private `files/AgentWorkspace/`, accept UTF-8 up to
128 KiB, reject absolute/traversal/symlink paths, and verify atomic writes by reading
the SHA-256 back. A request already accepted by a remote server may finish saving
after local cancellation; uncertain writes are never retried automatically.

From 0.6.1, **제어 앱 선택** lets the user add or remove launchable apps from the
device's control scope while conversation sessions and local tasks are idle. Settings, the test
app and Home retain their existing default scope. No model or MCP tool grants
app access, and Ppomi's settings/approval UI remains excluded from control.
`app_list` searches labels/packages and reports each app's authorization;
`app_open` resolves an exact package or unambiguous display name. The shared UI
shows live accessibility state independently from server configuration.

Device tools retain stale-node, password and exclusive-control checks. Known
payment, send, destructive and secret-input targets, including labelled children
of otherwise unlabelled buttons, are rejected for conversation click/type after the
node is refreshed. This label guard is not a complete semantic authorization
system. Stable failure codes distinguish missing accessibility from an unselected
app; raw native errors never enter the model. Existing legacy task records/settings
remain available under **기록·설정** and are not deleted.

Build verification includes `:app:assembleDebug :app:assembleDebugAndroidTest` and
`./tests/run-protocol-tests.sh`. `AgentWorkspaceTest` covers write/readback, size,
traversal and symlinks when run as Android instrumentation. `VoiceHostTest` is
emulator-only and injects an `AudioContext.createMediaStreamDestination()` stream
from instrumentation, without calling real microphone capture or adding production
test hooks. It exercises the bundled UI, live Realtime signaling, mute, foreground
app switching, notification stop, active-only file tools, peer/track/audio teardown,
WebView disposal, repeated stop, and unchanged task records. Diagnostics expose
only fixed stage labels and HTTP status codes, never keys, SDP, or message content.

Verified on Android 15/API 35 with System WebView 124.0.6367.219: both voice runtime
tests passed against the deployed server, along with two workspace tests and four
existing task-persistence tests. Real microphone capture, Fold folding/unfolding,
task removal and process restart still require separate device verification.

## Build and checks

Requires Android SDK platform 35, build tools 34.0.0 and JDK 17 or newer. Android Studio includes a compatible JDK. Gradle 8.11.1 and AGP 8.7.3 are pinned; Kotlin/Compose UI dependencies are pinned in Gradle. The shared Swift accounting library builds from the canonical Mac source; see [shared-core setup](../docs/android-shared-core.md).

```sh
cd Android
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export ANDROID_HOME="$HOME/Library/Android/sdk"
./gradlew :app:assembleDebug :controlfixture:assembleDebug
./tests/run-protocol-tests.sh
```

Outputs are `app/build/outputs/apk/debug/app-debug.apk` and `controlfixture/build/outputs/apk/debug/controlfixture-debug.apk`. The protocol test runs off-device and checks authentication, package/emulator policy, Unicode framing and invalid HTTP request rejection. The repository's emulator smoke test exercises the real APKs and verifies UI changes.

## Enable and pair

The server runs only while `com.ppomi.androidbridge/.BridgeAccessibilityService` is enabled in Android Accessibility settings. The app's settings button explains the capability and opens the system settings screen. Disabling the service stops the server. The prototype accepts development/debug builds. On a physical phone, the user enables accessibility in Android settings; release builds cannot enable control. Use `scripts/android-device.py prepare --serial <phone-serial>` for an explicitly selected physical phone (Android 11+, ARM64), as described in [physical setup](../docs/android-physical-control.md). The emulator scripts remain emulator-only.

For a clean test emulator, the setup helper installs the APKs, passes a freshly generated session token to the shell-protected `.DebugProvisioningActivity` using the `bridge_token` intent extra, enables the service while preserving other enabled accessibility services, and creates an `adb forward` tunnel. Provisioned tokens must have 32–128 URL-safe characters. They remain in private app preferences and are never returned by MCP. Reprovisioning replaces the token used for subsequent requests.

`adb` is used for installation, pairing, emulator setup, port forwarding and screen mirroring. Screen taps, swipes, text entry, node clicks and navigation are executed inside the companion's Android `AccessibilityService`; the bridge does not use `adb shell input` for control.

## Standalone device workflow

The **작업** tab accepts text for an explicitly labelled built-in test procedure. It opens the separate fixture app, observes the screen, and returns to Ppomi for approval **before** entering text or applying it. Once the user approves, Ppomi finds fresh nodes, enters the text, clicks Apply, verifies `Applied: <text>`, and captures the real screen into its own private storage. A small accessibility overlay offers stop/return while another app is open. **기록** shows task events and the actual evidence image.

Task records are atomic JSON files under Android app-private `files/tasks/`; screenshots and observed trees sit beside each task. These are operational records, not financial journal postings. Process death or accessibility disconnection marks unfinished work interrupted; uncertain actions are never replayed automatically. A task owns the control channel, and every non-status external MCP call is rejected while it runs or waits for approval. Approval/settings UI is user-only, including for the local agent.

The built-in procedure is **not an AI model** and makes no network request. **설정** optionally accepts an HTTPS chat-completions-compatible endpoint/model/key; the key is encrypted with Android Keystore and excluded from task records and screenshots. Model mode sends the user's request and current allowed app's accessibility text to that configured provider, proposes one action per approval, and stops at 24 decisions. No provider is configured by default, no Mac key is imported, and the initial standalone proof does not require or exercise a paid model request.

Run the real UI tests from the repository root:

```sh
python3 scripts/android-standalone-test.py
```

This uses instrumentation only to represent the user entering a request and clicking approval/cancel. Target app actions and PNG creation run through Ppomi's own Android service. The test removes this emulator's MCP port forwarding for the whole run and restores the prior mappings afterwards. It checks approval exclusion, cross-app Unicode input and observed output, private native evidence, cancellation, and actual force-stop/relaunch recovery. It preserves other accessibility services and never selects a physical device. Results are under `.ppomi/android-standalone/`.

**기록 → 공통 분개장 → 가상 예시 열기** explicitly opens synthetic, read-only sample reports through the same Swift accounting engine. Original and adjusted results and owner/book/unit scopes stay distinct; this is not a migrated ledger or new financial entry.

## Local MCP contract

The device listens on **127.0.0.1:8765**. Forward a host loopback port to device `tcp:8765`, then send `POST /mcp`, `Content-Type: application/json` and `Authorization: Bearer <session-token>`. The server accepts JSON-RPC 2.0 `initialize`, `ping`, `tools/list`, `tools/call` and notifications. HTTP notifications receive 202 without a body and never execute actions. This is a JSON response MCP subset, without SSE, sessions or subscriptions; initialization advertises protocol `2024-11-05`.

Successful `tools/call` responses contain the same JSON object in `structuredContent` and in `content[0].text`; tool failures set `isError: true`. HTTP authentication failures return 401. Requests carrying an Origin header are rejected because this is a native loopback client endpoint. HTTP headers and bodies are bounded at 16 KiB and 64 KiB, respectively; chunked requests are unsupported.

| Tool | Arguments | Behavior |
| --- | --- | --- |
| `status` | `{}` | Connection, emulator, allowed packages, foreground package, last gesture status |
| `ui_tree` | `{}` | Active allowed app nodes and snapshot ID, screen pixel dimensions |
| `screen` | `{}` | Actual native screenshot returned as an MCP image; respects protected windows |
| `long_press` | `{nodeId,holdMs?}` | Hold a fresh visible node, then release |
| `long_press_drag` | `{nodeId,x2,y2,holdMs?,dragMs?,hoverMs?}` | Hold and drag the same pointer, hover, then release |
| `gesture_status` | `{gestureId?}` | Retained delivery state; verify placement in a fresh screen |
| `cancel_gesture` | `{gestureId}` | Request pointer release; does not undo earlier motion |
| `tap` | `{x,y}` | `dispatchGesture` tap, using screen pixels |
| `swipe` | `{x1,y1,x2,y2,durationMs?}` | `dispatchGesture` swipe, 50–2000 ms (default 300) |
| `click` | `{nodeId}` | `AccessibilityNodeInfo.ACTION_CLICK` on a clickable node |
| `type_text` | `{nodeId,text}` | `ACTION_SET_TEXT`, replaces content and supports Unicode |
| `back`, `home`, `recents` | `{}` | `performGlobalAction` navigation |
| `open_app` | `{packageName}` | Launch an explicitly allowlisted installed app |

`ui_tree` returns flat `nodes` with `id`, `parentId`, text, description, class/resource IDs, click/long-click/edit/enabled/visible/password flags, exposed accessibility actions and bounds (`left`, `top`, `right`, `bottom`). Node IDs belong to one snapshot and expire on subscribed UI events, a new snapshot, or after 30 seconds. Fetch a fresh tree after every action. A successful gesture response indicates dispatch acceptance; poll `gesture_status` with its exact `gestureId`, then read a fresh tree or screenshot to verify the effect. Node actions report Android's action result, which still requires observing the expected UI change.

Held drags keep one pointer down through hold, movement, hover and release. They serialize control and stop continuation when task ownership, foreground package, display size or rotation changes. Cancellation releases where the pointer currently is and does not undo movement. If Android cannot confirm release, the retained result is `release_unconfirmed` with `controlBlocked: true`; inspect the device and reconnect its accessibility service before further control. Neither the client nor the executor automatically repeats an uncertain mutation.

Run the native gesture fixture test against an explicitly prepared device:

```sh
python3 scripts/android-gesture-test.py --config .ppomi/android-bridge.json --serial emulator-5554
# Physical phones: supply their dedicated pairing file and exact serial instead.
```

## Prototype boundaries

Android Settings, the separate test app and the device’s selected default Home launcher expose controllable UI. Ppomi can be opened for the user, but its approval/settings UI cannot be read or manipulated by the bridge or agent. The service checks the foreground package again at action time; global navigation remains available to leave a screen. UI reads from other packages are rejected. Password text and descriptions are redacted, and password field actions are excluded. Snapshots stop at 300 nodes and depth 32, and text input is limited to 4096 characters.

This does not make every Android UI controllable: apps may omit accessibility nodes, Android can reject gestures, and secure content can be hidden. Native task evidence uses Android AccessibilityService screenshots (Android 11+); screen mirroring is supplied separately by the Mac integration. Physical-phone pairing and user-enabled service setup are explicit; broader package access and release distribution are not enabled.

Official Android references: [AccessibilityService](https://developer.android.com/reference/android/accessibilityservice/AccessibilityService), [create an accessibility service](https://developer.android.com/guide/topics/ui/accessibility/service), and [AGP 8.7 compatibility](https://developer.android.com/build/releases/agp-8-7-0-release-notes).
