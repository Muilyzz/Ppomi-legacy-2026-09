/**
 * Deprecated path. Locked name is `ppomi-body-macos`.
 * Forwards to that example so existing Mac smoke commands keep working.
 */
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const target = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
  "..",
  "..",
  "ppomi-body-macos",
  "example",
  "src",
  "main.ts",
);

process.stdout.write("adapter-macos example: deprecated → ppomi-body-macos\n");

const result = spawnSync(process.execPath, ["--experimental-strip-types", target], {
  stdio: "inherit",
  env: process.env,
});

process.exit(result.status ?? 1);
