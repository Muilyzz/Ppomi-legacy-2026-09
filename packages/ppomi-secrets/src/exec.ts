import { spawnSync } from "node:child_process";
import type { SecretExec, SecretExecOptions, SecretExecResult } from "./store.ts";

const TIMEOUT_MS = 15_000;

export function defaultSecretExec(
  command: string,
  args: readonly string[],
  options?: SecretExecOptions,
): SecretExecResult {
  const result = spawnSync(command, [...args], {
    encoding: "utf8",
    env: options?.extraEnv === undefined ? process.env : { ...process.env, ...options.extraEnv },
    ...(options?.input === undefined ? {} : { input: options.input }),
    timeout: TIMEOUT_MS,
    windowsHide: true,
  });
  return {
    status: result.status ?? 1,
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
  };
}

/** Error detail for a thrown `SecretStoreError`: secrets removed first, then collapsed and capped. */
export function scrubDetail(text: string, ...secrets: readonly string[]): string {
  let scrubbed = text;
  for (const secret of secrets) {
    if (secret.length > 0) scrubbed = scrubbed.split(secret).join("");
  }
  return scrubbed.replace(/\s+/g, " ").trim().slice(0, 160);
}

export function requireExec(exec: SecretExec | undefined): SecretExec {
  return exec ?? defaultSecretExec;
}
