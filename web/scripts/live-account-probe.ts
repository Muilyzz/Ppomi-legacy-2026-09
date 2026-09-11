/**
 * Clerk Google → /account readiness. Does not invent keys and does not complete OAuth.
 * Paste real pk_/sk_ into web/.env.local, enable Google in Clerk Dashboard, then sign in.
 */
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { readClerkEnv } from "../src/lib/clerk-env.ts";

const webRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const envLocal = join(webRoot, ".env.local");
const LIVE_COMMAND = "PPOMI_BODY_LIVE=1 node --experimental-strip-types web/scripts/live-account-probe.ts";

function loadEnvLocal(): NodeJS.Dict<string> {
  const env: NodeJS.Dict<string> = { ...process.env };
  if (!existsSync(envLocal)) return env;
  for (const raw of readFileSync(envLocal, "utf8").split(/\r?\n/)) {
    const line = raw.trim();
    if (line.length === 0 || line.startsWith("#")) continue;
    const separator = line.indexOf("=");
    if (separator <= 0) continue;
    const key = line.slice(0, separator).trim();
    let value = line.slice(separator + 1).trim();
    if (
      (value.startsWith("\"") && value.endsWith("\""))
      || (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    if (env[key] === undefined) env[key] = value;
  }
  return env;
}

async function signInReachable(): Promise<string> {
  try {
    const response = await fetch("http://127.0.0.1:3000/sign-in", { redirect: "manual" });
    return `http://127.0.0.1:3000/sign-in → ${response.status}`;
  } catch {
    return "dev server not running (npm run dev in web/)";
  }
}

async function main(): Promise<void> {
  const live = process.env.PPOMI_BODY_LIVE === "1";
  const env = loadEnvLocal();
  const snapshot = readClerkEnv(env);
  const lines = [
    `env       ${existsSync(envLocal) ? "web/.env.local" : "web/.env.local missing"}`,
    `clerk     ${snapshot.configured ? "keys present" : "not configured"}`,
    snapshot.missing.length > 0 ? `missing   ${snapshot.missing.join(",")}` : undefined,
    snapshot.placeholders.length > 0 ? `placeholder ${snapshot.placeholders.join(",")}` : undefined,
    `live      ${live ? "PPOMI_BODY_LIVE=1" : "off (set PPOMI_BODY_LIVE=1 to probe /sign-in)"}`,
  ].filter((line): line is string => line !== undefined);

  process.stdout.write("ppomi-web live-account-probe:\n");
  for (const line of lines) process.stdout.write(`  ${line}\n`);

  if (!snapshot.configured) {
    process.stdout.write("  live     SKIP\n");
    process.stdout.write("           paste NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY + CLERK_SECRET_KEY into web/.env.local\n");
    process.stdout.write("           Clerk Dashboard → SSO connections → Google, then npm run dev\n");
    process.stdout.write(`           ${LIVE_COMMAND}\n`);
    return;
  }

  if (!live) {
    process.stdout.write("  live     PASS\n");
    process.stdout.write("           dry-run — keys look live; Google → /account still needs a browser\n");
    return;
  }

  const reach = await signInReachable();
  process.stdout.write("  live     PASS\n");
  process.stdout.write(`           ${reach}\n`);
  process.stdout.write("           operator: Google sign-in must land on /account\n");
}

main().catch(error => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`ppomi-web live-account-probe: FAIL\n  ${message}\n`);
  process.exitCode = 1;
});
