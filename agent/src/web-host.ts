// 웹 호스트(hub): 같은 대화 패널을 브라우저 탭에서 띄운다. 네이티브 호스트가 하던 일 가운데 서버 중계(request)와 계정 상태(bootstrap)만
// 있고, 기기 도구(executeTool)·통화·가족 업데이트는 없다. 토큰은 request 한 번에만 쓰고 React 상태로 올라가지 않는다.
import { NativeBridge, NativeBridgeError, type Bootstrap } from "./bridge";
import { applyBootstrapAppearance, type ChatHost, type ChatHostDocument, type ChatHostEvents } from "./chat-host";
import type { TranscriptSync } from "./transcripts";
import { BootstrapReadiness } from "./update-readiness";

export type WebAccount = { readonly id: string; readonly name: string | null; readonly email: string | null };
export type WebHostState = {
  /** The signed-in Google account's public profile, or null. Never a token. */
  readonly account: WebAccount | null;
  /** This browser's device ID once ppomi_context confirmed it for the account; the agent server requires the header. */
  readonly deviceID: string | null;
  /** One line about sign-in progress or failure for the top bar; empty when there is nothing to say. */
  readonly notice: string;
  readonly noticeIsError: boolean;
};
/** What the browser layers (Supabase auth, device enrollment) expose to the shared workbench. */
export type WebHostSource = {
  /** The agent server the apps use: https, no credentials, query or fragment. */
  readonly endpoint: string;
  getState(): WebHostState;
  subscribe(listener: () => void): () => void;
  /** The current Supabase access token; refreshes when needed and rejects when signed out. */
  getAccessToken(): Promise<string>;
  signIn(): Promise<void>;
  signOut(): Promise<void>;
};
type WebChatWindow = {
  addEventListener(type: "pagehide" | "focus", listener: () => void): void;
  removeEventListener(type: "pagehide" | "focus", listener: () => void): void;
};

/** The two paths the text conversation needs. Memory paths exist on the server but refuse web devices (read-only browsers). */
export const WEB_REQUEST_PATHS: ReadonlySet<string> = new Set(["/v1/session", "/v1/responses"]);
const JWT = /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const REQUEST_LIMIT = { turn: 4_000_000, other: 16_384 };
const RESPONSE_LIMIT = { turn: 2_000_000, other: 512 * 1024 };
const TIMEOUT = { turn: 120_000, other: 20_000 };

const isPlainObject = (value: unknown): value is Record<string, unknown> => !!value && typeof value === "object" && !Array.isArray(value);

/** Same rule as the Mac's AgentNativePolicy.endpoint: https, host only, nothing that could carry a credential. */
export function webEndpoint(value: string): string {
  let url: URL;
  try { url = new URL(value); } catch { throw new Error("invalid agent endpoint"); }
  // The parser already normalised dot segments; refuse them in the written value, like the Mac does.
  if (url.protocol !== "https:" || !url.host || url.username || url.password || url.search || url.hash || /\s/.test(value)
      || value.split("/").includes("..") || value.includes("%")) throw new Error("invalid agent endpoint");
  return url.origin + url.pathname.replace(/\/+$/, "");
}

/** The browser's bootstrap: configured only after the account's browser device was confirmed by ppomi_context. */
export function webBootstrap(source: Pick<WebHostSource, "endpoint" | "getState">): Bootstrap {
  const { account, deviceID } = source.getState();
  const displayName = account?.name || account?.email || undefined;
  return {
    platform: "web", deviceLabel: "웹 브라우저", configured: account !== null && deviceID !== null, endpoint: source.endpoint,
    tools: [], bankProfileSupported: false, voiceSupported: false,
    executor: { googleSignIn: true, deviceControl: false },
    authentication: { method: "google", signedIn: account !== null, googleSignIn: true, ...(displayName ? { displayName } : {}) },
  };
}

async function boundedJSON(response: Response, limit: number): Promise<Record<string, unknown>> {
  const reader = response.body?.getReader();
  if (!reader) throw new NativeBridgeError("response_invalid");
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > limit) { await reader.cancel(); throw new NativeBridgeError("response_invalid"); }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  let parsed: unknown;
  try { parsed = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)); } catch { throw new NativeBridgeError("response_invalid"); }
  if (!isPlainObject(parsed)) throw new NativeBridgeError("response_invalid");
  return parsed;
}

/** The {id, method, args} contract answered by page code. Every failure is an allowlisted NativeBridgeError code, like the native hosts. */
export function createWebBridge(source: WebHostSource, options: { fetch?: typeof fetch } = {}): NativeBridge {
  const fetcher = options.fetch ?? globalThis.fetch.bind(globalThis);
  const endpoint = webEndpoint(source.endpoint);

  async function relay(args: Record<string, unknown>): Promise<unknown> {
    const keys = Object.keys(args);
    if (keys.length !== 2 || typeof args.path !== "string" || !isPlainObject(args.body)) throw new NativeBridgeError("invalid_request");
    const path = args.path;
    if (!WEB_REQUEST_PATHS.has(path)) throw new NativeBridgeError(path.startsWith("/v1/memories/") ? "native_unavailable" : "invalid_request");
    const { account, deviceID } = source.getState();
    if (!account || !deviceID || !UUID.test(deviceID)) throw new NativeBridgeError("server_unconfigured");
    let token: string;
    try { token = await source.getAccessToken(); } catch { throw new NativeBridgeError("server_auth"); }
    if (typeof token !== "string" || token.length > 8192 || !JWT.test(token)) throw new NativeBridgeError("server_auth");
    const turn = path === "/v1/responses";
    const body = JSON.stringify(args.body);
    if (body.length > (turn ? REQUEST_LIMIT.turn : REQUEST_LIMIT.other)) throw new NativeBridgeError("invalid_request");
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), turn ? TIMEOUT.turn : TIMEOUT.other);
    try {
      let response: Response;
      try {
        response = await fetcher(`${endpoint}${path}`, {
          method: "POST", body, mode: "cors", credentials: "omit", redirect: "error", cache: "no-store", referrerPolicy: "no-referrer", signal: controller.signal,
          headers: { "Content-Type": "application/json", Accept: "application/json", Authorization: `Bearer ${token}`, "X-Ppomi-Device": deviceID.toLowerCase() },
        });
      } catch { throw new NativeBridgeError("server_unavailable"); }
      if (!response.ok) {
        await response.body?.cancel().catch(() => {});
        throw new NativeBridgeError(response.status === 401 || response.status === 403 ? "server_auth" : "server_rejected");
      }
      return await boundedJSON(response, turn ? RESPONSE_LIMIT.turn : RESPONSE_LIMIT.other);
    } finally { clearTimeout(timer); }
  }

  async function dispatch(method: string, args: Record<string, unknown>): Promise<unknown> {
    switch (method) {
      case "bootstrap": return webBootstrap(source);
      case "updateReady": return { ready: true };
      case "sessionState":
        if (typeof args.active !== "boolean") throw new NativeBridgeError("invalid_request");
        // No microphone session exists here; a call attempt fails before getUserMedia.
        if (args.mode !== undefined && args.mode !== "text") throw new NativeBridgeError("native_unavailable");
        return { active: args.active };
      case "request": return relay(args);
      case "executeTool":
      case "transcriptOpen":
      case "transcriptAppend":
        throw new NativeBridgeError("native_unavailable");
      case "declineCall": return { declined: true };
      case "heard": return {};
      default: throw new NativeBridgeError("invalid_request");
    }
  }

  const bridge = new NativeBridge(raw => {
    const request = JSON.parse(raw) as { id: string; method: string; args?: unknown };
    const args = isPlainObject(request.args) ? request.args : {};
    void dispatch(request.method, args).then(
      result => bridge.receive({ id: request.id, result }),
      error => {
        const failure = error instanceof NativeBridgeError ? error : new NativeBridgeError("tool_failed");
        bridge.receive({ id: request.id, error: { code: failure.code, message: failure.message } });
      });
  });
  return bridge;
}

/** One browser document owns its bridge/readiness. Account changes end the conversation and refresh the bootstrap, like native hosts. */
export function createWebChatHost({ source, transcripts, window, document, fetch }: {
  source: WebHostSource;
  transcripts?: TranscriptSync;
  window: WebChatWindow;
  document: ChatHostDocument;
  fetch?: typeof globalThis.fetch;
}): ChatHost {
  const bridge = createWebBridge(source, { fetch });
  const readiness = new BootstrapReadiness(() => bridge.call("updateReady", { bridgeVersion: 1 }, 5_000));

  function subscribe(events: ChatHostEvents) {
    let account = source.getState().account?.id ?? null;
    const refresh = () => { if (document.visibilityState !== "hidden") events.refresh(); };
    const stop = () => events.stop();
    const changed = () => {
      const next = source.getState().account?.id ?? null;
      if (next !== account) { account = next; events.stop(); }
      refresh();
    };
    const unsubscribe = source.subscribe(changed);
    window.addEventListener("pagehide", stop);
    window.addEventListener("focus", refresh);
    document.addEventListener("visibilitychange", refresh);
    return () => {
      unsubscribe();
      window.removeEventListener("pagehide", stop);
      window.removeEventListener("focus", refresh);
      document.removeEventListener("visibilitychange", refresh);
    };
  }

  return Object.freeze({
    bridge, readiness, transcripts,
    applyBootstrap: (b: Bootstrap) => applyBootstrapAppearance(document, b), subscribe,
  });
}
