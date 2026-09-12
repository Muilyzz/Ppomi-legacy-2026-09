import { generateKeyPairSync, sign } from "node:crypto";

export const CLERK_TEST_NOW = Date.parse("2026-09-12T03:00:00Z");
export const CLERK_TEST_ISSUER = "https://foo.clerk.accounts.dev";
export const CLERK_TEST_AZP = "https://ppomi.local";

const pair = generateKeyPairSync("rsa", { modulusLength: 2048 });
export const clerkTestJwtKey = pair.publicKey.export({ type: "spki", format: "pem" }).toString();
export const clerkTestJwk = { ...pair.publicKey.export({ format: "jwk" }), kid: "test-kid", use: "sig", alg: "RS256" };

export const clerkTestEnv: NodeJS.ProcessEnv = {
  CLERK_ISSUER: CLERK_TEST_ISSUER,
  CLERK_AUTHORIZED_PARTIES: CLERK_TEST_AZP,
  CLERK_JWT_KEY: clerkTestJwtKey,
};

function encode(value: object): string {
  return Buffer.from(JSON.stringify(value)).toString("base64url");
}

export function liveClerkSession(overrides: Record<string, unknown> = {}, nowMs = Date.now()): string {
  const header = { alg: "RS256", typ: "JWT", kid: "test-kid" };
  const payload = {
    sub: "user_2AbCdEfGhIjK",
    exp: Math.floor(nowMs / 1000) + 3600,
    iss: CLERK_TEST_ISSUER,
    azp: CLERK_TEST_AZP,
    aud: CLERK_TEST_ISSUER,
    ...overrides,
  };
  const data = `${encode(header)}.${encode(payload)}`;
  return `${data}.${sign("SHA256", Buffer.from(data), pair.privateKey).toString("base64url")}`;
}

export function unsignedClerkSession(overrides: Record<string, unknown> = {}, alg = "none", nowMs = Date.now()): string {
  const payload = {
    sub: "user_2AbCdEfGhIjK",
    exp: Math.floor(nowMs / 1000) + 3600,
    iss: CLERK_TEST_ISSUER,
    azp: CLERK_TEST_AZP,
    ...overrides,
  };
  return `${encode({ alg, typ: "JWT" })}.${encode(payload)}.`;
}
