import { existsSync } from "node:fs";
import { spawnSync } from "node:child_process";

const BROWSERS = [
  { id: "safari", app: "/Applications/Safari.app" },
  { id: "chrome", app: "/Applications/Google Chrome.app" },
] as const;

interface Probe {
  readonly status: "ok" | "skip" | "fail";
  readonly lines: readonly string[];
}

function detectBrowsers(): string[] {
  return BROWSERS.filter(browser => existsSync(browser.app)).map(browser => browser.id);
}

function runOsascript(source: string): { ok: boolean; text: string } {
  const result = spawnSync("osascript", ["-e", source], { encoding: "utf8" });
  const text = `${result.stdout ?? ""}${result.stderr ?? ""}`.trim();
  return { ok: result.status === 0, text };
}

function probeDarwin(): Probe {
  const browsers = detectBrowsers();
  const live = process.env.PPOMI_BODY_LIVE === "1";
  const lines = [
    `platform  ${process.platform}`,
    `browsers  ${browsers.length > 0 ? browsers.join(",") : "(none in /Applications)"}`,
    `live      ${live ? "PPOMI_BODY_LIVE=1" : "off (set PPOMI_BODY_LIVE=1 to open Safari/Chrome)"}`,
  ];

  if (!live) {
    return {
      status: "ok",
      lines: [...lines, "probe     dry-run — browsers listed, no AX / Automation"],
    };
  }

  const preferred = process.env.PPOMI_MAC_BROWSER === "chrome" ? "chrome" : "safari";
  if (!browsers.includes(preferred) && browsers[0] === undefined) {
    return { status: "skip", lines: [...lines, "probe     SKIP — no Safari/Chrome"] };
  }

  const app = preferred === "chrome" && browsers.includes("chrome") ? "Google Chrome" : "Safari";
  const opened = runOsascript(`
tell application "${app}"
  activate
  open location "https://example.com/"
  delay 2
  if (count of windows) is 0 then error "no window"
  return name of front window
end tell
`);
  if (!opened.ok) {
    return {
      status: "skip",
      lines: [...lines, `probe     SKIP — ${app} Automation/Accessibility denied or failed`, `          ${opened.text}`],
    };
  }
  return { status: "ok", lines: [...lines, `probe     ${app} window: ${opened.text}`] };
}

function main(): void {
  if (process.platform !== "darwin") {
    process.stdout.write("adapter-macos example: SKIP\n");
    process.stdout.write(`  reason   not macOS (${process.platform})\n`);
    process.stdout.write("  future   ppomi-body-macos (driver-macos). Sibling live tools: PR #10 / #12.\n");
    return;
  }

  const probe = probeDarwin();
  const label = probe.status === "fail" ? "FAIL" : probe.status === "skip" ? "SKIP" : "PASS";
  process.stdout.write(`adapter-macos example: ${label}\n`);
  for (const line of probe.lines) {
    process.stdout.write(`  ${line}\n`);
  }
  if (probe.status === "fail") process.exitCode = 1;
}

main();
