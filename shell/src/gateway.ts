import { fixtureResponses } from "./chat.ts";

const GATEWAY = "https://ai-gateway.vercel.sh/v1";
const TEXT_MODEL = "openai/gpt-6-astra";

export function gatewayConfig(env: NodeJS.ProcessEnv = process.env): { key: string; base: string; model: string } | null {
  const key = env.AI_GATEWAY_API_KEY ?? "";
  if (!key || /\s/.test(key)) return null;
  const base = (env.AI_GATEWAY_BASE_URL || GATEWAY).replace(/\/+$/, "");
  const model = env.AI_TEXT_MODEL || TEXT_MODEL;
  return { key, base, model };
}

function isProbe(body: unknown): boolean {
  return Boolean(body && typeof body === "object" && !Array.isArray(body) && (body as { probe?: unknown }).probe === true);
}

function asRecord(body: unknown): Record<string, unknown> {
  return body && typeof body === "object" && !Array.isArray(body) ? body as Record<string, unknown> : {};
}

export async function proxyResponses(
  body: unknown,
  deps: { env?: NodeJS.ProcessEnv; fetch?: typeof fetch } = {},
): Promise<Record<string, unknown>> {
  const env = deps.env ?? process.env;
  const fixture = env.PPOMI_CHAT === "fixture";
  const config = gatewayConfig(env);
  if (isProbe(body)) return { configured: fixture || config !== null, fixture };
  if (fixture) return { configured: true, fixture: true, response: fixtureResponses(asRecord(body)) };
  if (config === null) return { configured: false, fixture: false };
  const payload = asRecord(body);
  const { model: _model, stream: _stream, store: _store, ...rest } = payload;
  let response: Response;
  try {
    response = await (deps.fetch ?? fetch)(`${config.base}/responses`, {
      method: "POST",
      redirect: "error",
      headers: { Authorization: `Bearer ${config.key}`, "Content-Type": "application/json" },
      body: JSON.stringify({ ...rest, model: config.model, stream: false, store: false }),
    });
  } catch {
    return { configured: true, fixture: false, error: "model_unavailable" };
  }
  if (!response.ok) {
    await response.body?.cancel();
    return { configured: true, fixture: false, error: "model_unavailable" };
  }
  return { configured: true, fixture: false, response: await response.json() as Record<string, unknown> };
}
