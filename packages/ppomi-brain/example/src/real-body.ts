import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { BodyKind, BodyPort, BodyRunResult, PathDefinition } from "./ports.ts";

const exampleRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const repoRoot = path.resolve(exampleRoot, "..", "..", "..");

export class RealBodyBridge implements BodyPort {
  readonly kind: BodyKind;

  constructor(kind: Exclude<BodyKind, "mock">) {
    this.kind = kind;
  }

  async run(selected: PathDefinition): Promise<BodyRunResult> {
    const script = this.kind === "macos"
      ? path.join(repoRoot, "packages", "ppomi-body-macos", "example", "src", "main.ts")
      : path.join(repoRoot, "packages", "ppomi-body-windows", "example", "src", "main.ts");
    const result = await runNodeScript(script);
    const skipped = /SKIP/.test(result.stdout);
    const failed = result.status !== 0;
    return {
      body: this.kind,
      status: failed ? "stopped" : "completed",
      steps: [
        {
          stepId: selected.steps[0]?.id ?? "body",
          outcome: failed ? "failed" : "ok",
          note: skipped
            ? `${this.kind} body example skipped (wrong OS or missing live tools)`
            : failed
              ? result.stderr.trim() || result.stdout.trim() || "body example failed"
              : `${this.kind} body example ran (exit ${result.status})`,
        },
      ],
    };
  }
}

function runNodeScript(script: string): Promise<{ status: number; stdout: string; stderr: string }> {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ["--experimental-strip-types", script], {
      cwd: path.dirname(script),
      env: { ...process.env, PPOMI_BODY_FROM_BRAIN: "1" },
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", chunk => { stdout += String(chunk); });
    child.stderr.on("data", chunk => { stderr += String(chunk); });
    child.on("error", reject);
    child.on("close", status => {
      resolve({ status: status ?? 1, stdout, stderr });
    });
  });
}

export function parseBodyKind(value: string | undefined): BodyKind {
  switch (value) {
    case undefined:
    case "":
    case "mock":
      return "mock";
    case "macos":
    case "windows":
      return value;
    default:
      throw new Error(`PPOMI_BODY / --body must be mock | macos | windows (got ${value})`);
  }
}
