import { createPublicKey, verify as verifySig, type KeyObject } from "node:crypto";
import { existsSync, readFileSync, statSync } from "node:fs";
import { basename, join } from "node:path";

/** Same shape as `web/src/lib/clerk-supabase.ts`. Shell must not import the Next app. */
const CLERK_USER_ID = /^user_[A-Za-z0-9]{8,}$/;
const FILE_MODE_MASK = 0o777;
const WORLD_OR_GROUP = 0o077;

export type ClerkAlg = "RS256" | "ES256";

export type ClerkSessionClaims = {
  readonly sub: string;
  readonly exp: number;
  readonly iss: string;
  readonly aud?: string | readonly string[];
  readonly azp?: string;
  readonly nbf?: number;
};

export type ClerkVerifyConfig = {
  readonly issuer: string;
  readonly parties: readonly string[];
  readonly audiences: readonly string[];
  readonly jwtKey?: string;
};

export type ClerkJwk = {
  readonly kid?: string;
  readonly kty?: string;
  readonly [key: string]: unknown;
};

export type ClerkVerifyDeps = {
  readonly nowMs?: number;
  readonly fetch?: typeof fetch;
  readonly jwks?: { readonly keys: readonly ClerkJwk[] };
};

type ClerkHeader = {
  readonly alg: ClerkAlg;
  readonly kid?: string;
};

type ParsedClerkJwt = {
  readonly header: ClerkHeader;
  readonly claims: ClerkSessionClaims;
  readonly data: string;
  readonly signature: Buffer;
};

const jwksCache = new Map<string, readonly ClerkJwk[]>();

function csv(value: string | undefined): string[] {
  return (value ?? "").split(",").map(item => item.trim()).filter(item => item !== "");
}

export function httpsOrigin(value: string | undefined): string | null {
  if (!value) return null;
  const origin = value.trim().replace(/\/+$/, "");
  if (!/^https:\/\/[^/\s]+$/i.test(origin)) return null;
  return origin;
}

/** Group/other bits must be zero (0600/0400). Missing or unreadable → refuse. */
export function secretFileOk(path: string): boolean {
  try {
    return (statSync(path).mode & FILE_MODE_MASK & WORLD_OR_GROUP) === 0;
  } catch {
    return false;
  }
}

export function clerkVerifyConfig(env: NodeJS.ProcessEnv): ClerkVerifyConfig | null {
  const issuer = httpsOrigin(env.CLERK_ISSUER);
  if (issuer === null) return null;
  const parties = csv(env.CLERK_AUTHORIZED_PARTIES ?? env.CLERK_AZP);
  const audiences = csv(env.CLERK_AUD);
  if (parties.length === 0 && audiences.length === 0) return null;
  const jwtKey = env.CLERK_JWT_KEY?.trim();
  return jwtKey ? { issuer, parties, audiences, jwtKey } : { issuer, parties, audiences };
}

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
    if (!existsSync(file) || !secretFileOk(file)) continue;
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

function asAlg(value: unknown): ClerkAlg | null {
  return value === "RS256" || value === "ES256" ? value : null;
}

function asClaims(payload: unknown): ClerkSessionClaims | null {
  if (payload === null || typeof payload !== "object") return null;
  const { sub, exp, iss, aud, azp, nbf } = payload as {
    sub?: unknown;
    exp?: unknown;
    iss?: unknown;
    aud?: unknown;
    azp?: unknown;
    nbf?: unknown;
  };
  if (typeof sub !== "string" || !CLERK_USER_ID.test(sub)) return null;
  if (typeof exp !== "number" || !Number.isFinite(exp)) return null;
  if (typeof iss !== "string") return null;
  const origin = httpsOrigin(iss);
  if (origin === null) return null;
  const nbfValue = typeof nbf === "number" && Number.isFinite(nbf) ? nbf : undefined;
  const azpValue = typeof azp === "string" && azp !== "" ? azp : undefined;
  const audValue = typeof aud === "string" && aud !== ""
    ? aud
    : Array.isArray(aud) && aud.every(item => typeof item === "string")
      ? aud
      : undefined;
  return {
    sub,
    exp,
    iss: origin,
    ...(nbfValue !== undefined ? { nbf: nbfValue } : {}),
    ...(azpValue !== undefined ? { azp: azpValue } : {}),
    ...(audValue !== undefined ? { aud: audValue } : {}),
  };
}

export function parseClerkJwt(token: string): ParsedClerkJwt | null {
  const parts = token.split(".");
  if (parts.length !== 3 || parts[0] === "" || parts[1] === "" || parts[2] === "") return null;
  let headerRaw: unknown;
  let payload: unknown;
  try {
    headerRaw = JSON.parse(Buffer.from(parts[0], "base64url").toString("utf8"));
    payload = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8"));
  } catch {
    return null;
  }
  if (headerRaw === null || typeof headerRaw !== "object") return null;
  const { alg: rawAlg, kid } = headerRaw as { alg?: unknown; kid?: unknown };
  const alg = asAlg(rawAlg);
  if (alg === null) return null;
  const claims = asClaims(payload);
  if (claims === null) return null;
  const header: ClerkHeader = typeof kid === "string" && kid !== "" ? { alg, kid } : { alg };
  return {
    header,
    claims,
    data: `${parts[0]}.${parts[1]}`,
    signature: Buffer.from(parts[2], "base64url"),
  };
}

function audienceOk(claims: ClerkSessionClaims, config: ClerkVerifyConfig): boolean {
  const azpOk = config.parties.length === 0
    || (typeof claims.azp === "string" && config.parties.includes(claims.azp));
  const audValues = claims.aud === undefined ? [] : Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  const audOk = config.audiences.length === 0
    || audValues.some(value => config.audiences.includes(value));
  return azpOk && audOk;
}

function verifyWithKey(alg: ClerkAlg, data: string, signature: Buffer, key: KeyObject): boolean {
  switch (alg) {
    case "RS256":
      return verifySig("SHA256", Buffer.from(data), key, signature);
    case "ES256":
      return verifySig("SHA256", Buffer.from(data), { key, dsaEncoding: "ieee-p1363" }, signature);
    default: {
      const exhaustive: never = alg;
      return exhaustive;
    }
  }
}

function jwkOf(keys: readonly ClerkJwk[], kid: string | undefined): ClerkJwk | null {
  if (keys.length === 0) return null;
  if (kid === undefined) return keys.length === 1 ? keys[0] ?? null : null;
  return keys.find(key => key.kid === kid) ?? null;
}

async function publicKeyFor(
  parsed: ParsedClerkJwt,
  config: ClerkVerifyConfig,
  deps: ClerkVerifyDeps,
): Promise<KeyObject | null> {
  if (config.jwtKey) {
    try {
      return createPublicKey(config.jwtKey);
    } catch {
      return null;
    }
  }
  let keys = deps.jwks?.keys ?? jwksCache.get(config.issuer);
  if (keys === undefined || (parsed.header.kid !== undefined && jwkOf(keys, parsed.header.kid) === null)) {
    const fetchFn = deps.fetch ?? fetch;
    let body: unknown;
    try {
      const response = await fetchFn(`${config.issuer}/.well-known/jwks.json`, { redirect: "error" });
      if (!response.ok) return null;
      body = await response.json();
    } catch {
      return null;
    }
    if (body === null || typeof body !== "object" || !("keys" in body) || !Array.isArray(body.keys)) return null;
    keys = body.keys.filter(key => key && typeof key === "object") as ClerkJwk[];
    jwksCache.set(config.issuer, keys);
  }
  const jwk = jwkOf(keys, parsed.header.kid);
  if (jwk === null) return null;
  try {
    return createPublicKey({ format: "jwk", key: { ...jwk } });
  } catch {
    return null;
  }
}

export function clerkSessionActive(claims: ClerkSessionClaims, nowMs = Date.now()): boolean {
  const now = Math.floor(nowMs / 1000);
  if (claims.exp <= now) return false;
  if (claims.nbf !== undefined && claims.nbf > now) return false;
  return true;
}

export async function verifyClerkSession(
  token: string | undefined,
  env: NodeJS.ProcessEnv = process.env,
  deps: ClerkVerifyDeps = {},
): Promise<boolean> {
  if (!token) return false;
  const config = clerkVerifyConfig(env);
  if (config === null) return false;
  const parsed = parseClerkJwt(token);
  if (parsed === null) return false;
  if (parsed.claims.iss !== config.issuer) return false;
  if (!clerkSessionActive(parsed.claims, deps.nowMs ?? Date.now())) return false;
  if (!audienceOk(parsed.claims, config)) return false;
  const key = await publicKeyFor(parsed, config, deps);
  if (key === null) return false;
  try {
    return verifyWithKey(parsed.header.alg, parsed.data, parsed.signature, key);
  } catch {
    return false;
  }
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
