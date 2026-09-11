import { NativeBridge, NativeBridgeError, type Bootstrap, type NativeFailureCode } from "../agent/src/bridge";
import type { ChatHost } from "../agent/src/chat-host";
import { BootstrapReadiness } from "../agent/src/update-readiness";

/** Offline preview of the actual chat panel. No native hooks, credentials or network transport. */
export function createStoryChatHost(patch: Partial<Bootstrap> = {}): ChatHost {
  let active = false, responses = 0;
  const bootstrap = (): Bootstrap => ({
    platform: "macos", deviceLabel: "오프라인 미리보기", configured: true,
    endpoint: "https://preview.invalid", tools: [], ...patch,
  });
  const bridge = new NativeBridge(raw => {
    const request = JSON.parse(raw) as { id: string; method: string; args: Record<string, unknown> };
    const reply = (result: unknown) => queueMicrotask(() => bridge.receive({ id: request.id, result }));
    const refuse = (code: NativeFailureCode) => {
      const error = new NativeBridgeError(code);
      queueMicrotask(() => bridge.receive({ id: request.id, error: { code: error.code, message: error.message } }));
    };
    const args = request.args;
    if (request.method === "bootstrap") return reply(bootstrap());
    if (request.method === "updateReady") return reply({ ready: true });
    if (request.method === "sessionState") {
      // Refuse voice before VoiceController can request microphone access.
      if (args.mode !== "text") return refuse("native_unavailable");
      if (typeof args.active !== "boolean") return refuse("invalid_request");
      active = args.active;
      return reply({ active });
    }
    if (request.method !== "request") return refuse("invalid_request");
    const body = args.body;
    if (!body || typeof body !== "object" || Array.isArray(body)) return refuse("invalid_request");
    if (args.path === "/v1/session") {
      if ((body as Record<string, unknown>).mode !== "text") return refuse("native_unavailable");
      if (!active) return refuse("session_ended");
      return reply({ model: "synthetic-model" });
    }
    if (args.path !== "/v1/responses") return refuse("invalid_request");
    if (!active) return refuse("session_ended");
    const sequence = ++responses;
    return reply({
      id: `resp_preview_${sequence}`, object: "response", created_at: 1, status: "completed", model: "synthetic-model",
      output: [{
        type: "message", id: `msg_preview_${sequence}`, role: "assistant", status: "completed",
        content: [{ type: "output_text", text: "미리보기 응답입니다. 실제 기기나 서버에는 연결하지 않습니다.", annotations: [] }],
      }],
      usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2,
        input_tokens_details: { cached_tokens: 0 }, output_tokens_details: { reasoning_tokens: 0 } },
    });
  });
  return {
    bridge,
    readiness: new BootstrapReadiness(() => bridge.call("updateReady")),
    applyBootstrap() { /* Preview appearance belongs to the Storybook toolbar. */ },
    subscribe() { return () => {}; },
  };
}
