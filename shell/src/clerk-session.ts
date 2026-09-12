import { existsSync, readFileSync } from "node:fs";
import { basename, join } from "node:path";

/** Same shape as `web/src/lib/clerk-supabase.ts`. Shell must not import the Next app. */
const CLERK_USER_ID = /^user_[A-Za-z0-9]{8,}$/;

export type ClerkSessionClaims = {
  readonly sub: string;
  readonly exp: number;
  readonly iss: string;
};

function parseEnvValue(text: string, key: string): string | undefined {
  for (const raw of text.split(/\r?\n/)) {
    let line = raw.trim();
    if (line === "" || line.startsWith("#")) continue;
    if (line.startsWith("export ")) line = line.slice(7).trim();
    const eq = line.indexOf("=");
    if (eq <= 0) continue;
    if (line.slice(0, eq).trim() !== key) continue;
    let value = line.slice(eq + 1).trim();
    if (
      value.length >= 2
      && ((value.startsWith("\"") && value.endsWith("\"")) || (value.startsWith("'") && value.endsWith("'")))
    ) {
      value = value.slice(1, -1);
    }
    if (value !== "") return value;
  }
  return undefined;
}

export function clerkSessionFiles(env: NodeJS.ProcessEnv): string[] {
  const files: string[] = [];
  if (env.HOME) {
    files.push(join(env.HOME, ".ppomi", "clerk-session"));
    files.push(join(env.HOME, ".ppomi", ".env"));
  }
  if (env.PPOMI_ROOT) files.push(join(env.PPOMI_ROOT, "shell", ".env"));
  return files;
}

export function readStoredClerkSession(env: NodeJS.ProcessEnv): string | undefined {
  for (const file of clerkSessionFiles(env)) {
    if (!existsSync(file)) continue;
    let text: string;
    try {
      text = readFileSync(file, "utf8");
    } catch {
      continue;
    }
    const token = basename(file) === "clerk-session"
      ? (parseEnvValue(text, "CLERK_SESSION") ?? text.trim().split(/\r?\n/).find(line => line.trim() !== "" && !line.trim().startsWith("#")))
      : parseEnvValue(text, "CLERK_SESSION");
    if (token !== undefined && token.trim() !== "") return token.trim();
  }
  return undefined;
}

export function decodeClerkSession(token: string): ClerkSessionClaims | null {
  const parts = token.split(".");
  if (parts.length !== 3 || parts[0] === "" || parts[1] === "") return null;
  let payload: unknown;
  try {
    payload = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8"));
  } catch {
    return null;
  }
  if (payload === null || typeof payload !== "object") return null;
  const { sub, exp, iss } = payload as { sub?: unknown; exp?: unknown; iss?: unknown };
  if (typeof sub !== "string" || !CLERK_USER_ID.test(sub)) return null;
  if (typeof exp !== "number" || !Number.isFinite(exp)) return null;
  if (typeof iss !== "string") return null;
  const origin = iss.replace(/\/+$/, "");
  if (!/^https:\/\/[^/\s]+$/i.test(origin)) return null;
  return { sub, exp, iss: origin };
}

export function clerkSessionActive(claims: ClerkSessionClaims, nowMs = Date.now()): boolean {
  return claims.exp * 1000 > nowMs;
}

// ponytail: claims-only (sub/exp/iss). JWKS when a remote Clerk-gated proxy exists.
export function verifyClerkSession(token: string | undefined, nowMs = Date.now()): boolean {
  if (!token) return false;
  const claims = decodeClerkSession(token);
  return claims !== null && clerkSessionActive(claims, nowMs);
}

export function clerkSessionToken(body: unknown, env: NodeJS.ProcessEnv = process.env): string | undefined {
  if (body !== null && typeof body === "object" && !Array.isArray(body)) {
    const token = (body as { clerkSession?: unknown }).clerkSession;
    if (typeof token === "string" && token.trim() !== "") return token.trim();
  }
  if (typeof env.CLERK_SESSION === "string" && env.CLERK_SESSION.trim() !== "") {
    return env.CLERK_SESSION.trim();
  }
  return readStoredClerkSession(env);
}
