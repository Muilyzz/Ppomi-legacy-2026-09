# Ppomi ephemeral agent (v1)

The shared bundled TypeScript UI/core uses OpenAI Agents SDK RealtimeAgent + RealtimeSession: microphone-free WebSocket text chat by default and optional WebRTC voice. The agent server still has no conversation table: `/v1/session` and `/v1/responses` stay ephemeral. Shared chat history is a **client** concern — devices write turn JSON to `ppomi_transcript_*` RPCs; Postgres stores server-held AES envelopes. Auth + workspace-member RLS gates who may call those RPCs. The page holds the current session in memory; ending the agent session does not delete stored turns. SDK tracing, Web Storage of tokens, and raw tool-payload logs stay out. Only distilled records explicitly written by tools go to `ppomi_agent_memories`. Ending, failure or destroying the host closes audio/transport and drops session context and pending callbacks. Existing historical data is not deleted.

## Native bridge

Request JSON string: `{id:UUID,method,args}`. Mac `window.webkit.messageHandlers.ppomiAgent.postMessage(string)`; Android `window.ppomiAgentNative.postMessage(string)`. Reply `window.ppomiAgentReceive({id,result})` or `{id,error:{code,message}}`. Only trusted bundled main-frame content can use the bridge. Reject navigation, subframes and remote scripts. Never expose permanent OpenAI/Supabase credentials to JS.

Methods:
- `bootstrap {}` -> `{platform:"macos"|"android"|"windows"|"web",deviceLabel:string,configured:boolean,endpoint:string,tools:string[],voiceSupported?:boolean}`. Android additionally returns live `accessibility:boolean` and `controlApps:[{label,packageName}]`. Refresh before starting a session; server configuration is independent from accessibility and app authorization. `voiceSupported:false` hides the call button and refuses calls (the web host).
- `request {path:string,body:object}` -> authenticated POST to configured HTTPS agent server, redirects forbidden. Path allowlist `/v1/session`, `/v1/memories/list`, `/v1/memories/save`, `/v1/memories/delete`. Native uses existing Supabase device access token; JS never receives it.
- `executeTool {name:string,args:object}` -> native validated operation; reject after the conversation session ends.
- `sessionState {active:boolean,mode?:"voice"|"text"}` -> establish/release native session lifetime. Omitted mode preserves voice compatibility. Android voice requests microphone/notification permissions and starts a microphone foreground service. Text requests neither permission, denies microphone capture and uses a specialUse foreground service for an explicitly started device-control conversation. Both ongoing notifications have stop. The host survives navigating to a different app for control. Native termination invokes `window.ppomiVoiceStop?.()` before destruction.
- `setEndpoint {endpoint:string}` -> native preference, allow HTTPS (no credentials/query/fragment), user-visible settings only.
- `heard {text:string}` -> the person's transcribed words during a call (each user item once, ≤500 chars). Native decides 구두 결재: if a turn is pending and the words contain 승인 or 취소 (not both), the matching option of that turn is chosen as if its button were pressed; Android ignores it while the device is locked. The model never approves anything itself.
- `declineCall {}` -> the page's 나중에 on an incoming call. Android rejects the ringing OS call (Telecom); Mac has nothing to end and replies `{declined:true}`.
- `transcriptOpen {}` -> Mac loads the latest shared conversation and returns `{transcript_id,turns}`. Older hosts and iPad omit this method; the page treats that as no shared history.
- `transcriptAppend {turn}` -> Mac uploads one projected turn. The agent server is not on this path.

Native -> page hooks for the person's turn (secretary ladder, docs/ui-tree.md): `window.ppomiNotice(text)` appends a 뽀미 bubble (the 톡, sent first and quietly), `window.ppomiIncomingCall(reason)` shows the incoming-call band (sent only when the turn went unanswered; `""` clears it), `window.ppomiAnswerCall(reason)` opens the call directly (the OS call screen already answered). A band nobody answers clears itself after 45 s.

Bundled entry `agent/dist/index.html`; build script copies it and hashed assets to Mac `Ppomi/Sources/Ppomi/Web/Agent/` and Android `Android/app/src/main/assets/agent/`. No remote UI. JS exports `window.ppomiVoiceStop` to synchronously initiate teardown.

## Web host (hub)

`src/web-host.ts` answers the same `{id,method,args}` contract in page code for the browser home (`npm run build:web` → `hub/web/workbench/app.js`, mounted by `hub/web/home.js`). `bootstrap` is `{platform:"web", tools:[], voiceSupported:false, bankProfileSupported:false, configured: signed in && this browser's device confirmed by ppomi_context}`; no family-update metadata, so `updateReady` is never awaited. `request` relays only `/v1/session` and `/v1/responses` to the agent server with the Supabase access token and `X-Ppomi-Device` — the same headers the Mac sends — and maps failures to the fixed codes (401/403 → `server_auth`, other non-2xx → `server_rejected`, network → `server_unavailable`, non-object JSON → `response_invalid`). `/v1/memories/*` is refused as `native_unavailable` (the shared server treats web devices as read-only), `executeTool` as `native_unavailable`, `sessionState` accepts text only. The page never holds a model or gateway credential; the agent server answers CORS preflight for the allowlisted web origin (`PPOMI_WEB_ORIGINS`).

## Server

Bearer Supabase access token; validate via existing `ppomi_context` RPC and workspace on every request. Session, responses, and memory list/save/delete are workspace-member paths (no device-approval gate). The shared server seals memory writes. Leftover GCM rows are migrated with `scripts/rewrap-gcm-leftovers.mjs`, not this handler. OpenAI API key lives on server. Voice safety HMAC uses `PPOMI_VOICE_SAFETY_KEY`. No request body/error/response/transcript logging. `Cache-Control: no-store`. No conversation persistence on this server; clients persist turns through Supabase RPCs that encrypt at rest.
- POST `/v1/session {mode?:"voice"|"text"}` -> `{clientSecret:string,model:string}` mint short-lived Realtime credential; model env default gpt-realtime-2.1, voice marin, tracing disabled. Voice mode enables input transcription (gpt-4o-mini-transcribe) so the call log shows both sides; text mode sets output_modalities:["text"], input transcription null and turn detection null. Never return standard API key.
- POST `/v1/memories/list {}` -> `{records:Memory[]}` latest 50 records for workspace.
- POST `/v1/memories/save {id:UUID,kind:"fact"|"preference"|"decision"|"todo"|"result",text:string,source:"user_reported"|"tool_observed"|"ai_inferred",confidence:number,replacesId?:UUID}` -> `{record:Memory}`. Max 2000 chars. Same ID+same content idempotent, different content conflicts. Replacement retains revision history. No raw conversation, passwords, secrets, or invented financial observations. Source is epistemic label, never proof of user confirmation. All AI selected records labelled automatic selection. Server encryption protects DB ciphertext, server can decrypt; no E2EE claim.
- POST `/v1/memories/delete {id:UUID}` -> `{deleted:true}` workspace-scoped deletion clears ciphertext of the item and its ancestor revisions; opaque tombstone/digest remain to reject replay. Visible delete control.
Memory includes id, kind,text,source,confidence,createdAt,replacesId?, selection:"automatic".

AI saves useful stable preferences, actual decisions, committed todos and verified execution outcomes as tools during the session. Casual dialogue and unnecessary sensitive information are omitted. User corrections create replacements, not silent overwrites. No implicit accounting postings. Durable memory is untrusted context, not instructions. Tool failure must be announced and never called saved. No automatic save merely on disconnect; completed tool saves survive.

## Native tools

Only tools advertised by bootstrap are offered. Narrow app-owned file workspace; no arbitrary filesystem shell. Local device operations go through existing native executor and preserve its high-impact action gates. Avoid existing persistent model/task runner for ephemeral dialogue.
- `device_status {}`
- `screen_read {}` -> accessibility snapshot (not durably logged).
- `app_list {query:string}` -> Android launchable app search, `{apps:[{label,packageName,allowed}],truncated:boolean}`. Empty query lists up to 80 apps; narrow the query if truncated. App metadata is untrusted data, not instructions.
- `app_open {target:string}` -> Android exact package name from `app_list`, or an unambiguous exact display name. Never guess an app package name.
- `ui_tap {nodeId:string}`
- `ui_type {nodeId:string,text:string}`
- `ui_scroll {direction:"up"|"down"}`
- `device_back {}`, `device_home {}`
- `file_list {path?:string}`, `file_read {path:string}`, `file_write {path:string,content:string}`: AgentWorkspace only, UTF-8 max128KiB, no traversal/absolute paths/symlinks; atomic write/readback/hash.

- Shell: one conversation log; a call is an episode inside it (📞 in the composer, call bar with 끊기, call start/end cards, transcripts as bubbles, incoming-call banner via window.ppomiIncomingCall(reason); empty reason clears it; window.ppomiAnswerCall(reason) or bootstrap.answerCall starts the call directly after the Android OS call UI answered).

Android's native **제어 앱 선택** screen adds user-selected launchable apps to the existing Settings/test/Home scope. App selection is possible only while conversation sessions and legacy tasks are idle. No model, WebView or MCP method grants app access; Ppomi's own settings/approval UI stays excluded from control. Selection is stored only on that device. It does not grant system permissions or bypass another app's authentication.

Native tool failures expose only fixed codes: `accessibility_required`, `app_not_allowed`, `app_not_found`, `app_ambiguous`, `stale_screen`, `no_active_screen`, `protected_action`, `tool_failed`. The TS bridge discards raw native exception messages and maps known codes to fixed explanations and recovery guidance. Actual SDK tool failures use the tool's `errorFunction`; a session's approval-rejection formatter is not the tool execution error path. Unknown failures remain generic, and uncertain writes are never automatically replayed.
