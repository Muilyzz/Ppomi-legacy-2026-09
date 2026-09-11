import { spawnSync } from "node:child_process";
import type { SecretExec, SecretExecResult } from "./store.ts";

const TIMEOUT_MS = 15_000;

export function defaultSecretExec(
  command: string,
  args: readonly string[],
  extraEnv?: Readonly<Record<string, string>>,
): SecretExecResult {
  const result = spawnSync(command, [...args], {
    encoding: "utf8",
    env: extraEnv === undefined ? process.env : { ...process.env, ...extraEnv },
    timeout: TIMEOUT_MS,
    windowsHide: true,
  });
  return {
    status: result.status ?? 1,
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
  };
}

export function scrubDetail(text: string, secret?: string): string {
  const collapsed = text.replace(/\s+/g, " ").trim().slice(0, 160);
  if (secret === undefined || secret.length === 0) return collapsed;
  return collapsed.split(secret).join("");
}

export function requireExec(exec: SecretExec | undefined): SecretExec {
  return exec ?? defaultSecretExec;
}
