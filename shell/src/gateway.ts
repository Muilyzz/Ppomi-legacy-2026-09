import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { fixtureResponses } from "./chat.ts";

const GATEWAY = "https://ai-gateway.vercel.sh/v1";
const TEXT_MODEL = "openai/gpt-6-astra";
const FILE_KEYS = ["AI_GATEWAY_API_KEY", "AI_GATEWAY_BASE_URL", "AI_TEXT_MODEL"] as const;

export function gatewayEnvFiles(env: NodeJS.ProcessEnv): string[] {
  const files: string[] = [];
  if (env.HOME) files.push(join(env.HOME, ".ppomi", ".env"));
  if (env.PPOMI_ROOT) files.push(join(env.PPOMI_ROOT, "shell", ".env"));
  return files;
}

/** KEY=value lines only. Ignores other secrets (e.g. VERCEL_OIDC_TOKEN). Never logs values. */
export function parseGatewayEnvFile(text: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const raw of text.split(/\r?\n/)) {
    let line = raw.trim();
    if (line === "" || line.startsWith("#")) continue;
    if (line.startsWith("export ")) line = line.slice(7).trim();
    const eq = line.indexOf("=");
    if (eq <= 0) continue;
    const key = line.slice(0, eq).trim();
    let value = line.slice(eq + 1).trim();
    if (
      value.length >= 2
      && ((value.startsWith("\"") && value.endsWith("\"")) || (value.startsWith("'") && value.endsWith("'")))
    ) {
      value = value.slice(1, -1);
    }
    if ((FILE_KEYS as readonly string[]).includes(key) && value !== "") out[key] = value;
  }
  return out;
}

function usableKey(value: string | undefined): boolean {
  return Boolean(value) && !/\s/.test(value ?? "");
}

export function mergeGatewayFileEnv(env: NodeJS.ProcessEnv): NodeJS.ProcessEnv {
  const merged: NodeJS.ProcessEnv = { ...env };
  let needKey = !usableKey(merged.AI_GATEWAY_API_KEY);
  let needBase = !merged.AI_GATEWAY_BASE_URL;
  let needModel = !merged.AI_TEXT_MODEL;
  if (!needKey && !needBase && !needModel) return merged;
  for (const file of gatewayEnvFiles(merged)) {
    if (!existsSync(file)) continue;
    let parsed: Record<string, string>;
    try {
      parsed = parseGatewayEnvFile(readFileSync(file, "utf8"));
    } catch {
      continue;
    }
    if (needKey && usableKey(parsed.AI_GATEWAY_API_KEY)) {
      merged.AI_GATEWAY_API_KEY = parsed.AI_GATEWAY_API_KEY;
      needKey = false;
    }
    if (needBase && parsed.AI_GATEWAY_BASE_URL) {
      merged.AI_GATEWAY_BASE_URL = parsed.AI_GATEWAY_BASE_URL;
      needBase = false;
    }
    if (needModel && parsed.AI_TEXT_MODEL) {
      merged.AI_TEXT_MODEL = parsed.AI_TEXT_MODEL;
      needModel = false;
    }
  }
  return merged;
}

export function gatewayConfig(env: NodeJS.ProcessEnv = process.env): { key: string; base: string; model: string } | null {
  const resolved = mergeGatewayFileEnv(env);
  const key = resolved.AI_GATEWAY_API_KEY ?? "";
  if (!usableKey(key)) return null;
  const base = (resolved.AI_GATEWAY_BASE_URL || GATEWAY).replace(/\/+$/, "");
  const model = resolved.AI_TEXT_MODEL || TEXT_MODEL;
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
  const env = mergeGatewayFileEnv(deps.env ?? process.env);
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
