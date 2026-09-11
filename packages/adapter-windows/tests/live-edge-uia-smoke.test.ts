/**
 * Live smoke against the real `ppomi-executor`: an isolated Edge profile on an offline local page,
 * read → type → tap → re-read through `LiveWindowsExecutorTools`. Skips unless on Windows with the
 * executor and Edge present.
 *
 *   PPOMI_EXECUTOR   path to ppomi-executor.exe (default: the shell's staged executor in this repo)
 *   PPOMI_EDGE       path to msedge.exe (default: the usual Program Files locations)
 *   PPOMI_SMOKE_SHOT optional PNG path; a full-screen capture is written after the final read
 */
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { test } from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";
import { LiveWindowsExecutorTools, WindowsAdapterError } from "../src/index.ts";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..", "..");
const executorPath = process.env.PPOMI_EXECUTOR
  ?? join(repoRoot, "shell", "src-tauri", "resources", "executor", "ppomi-executor.exe");
const edgeCandidates = [
  process.env.PPOMI_EDGE,
  process.env["ProgramFiles(x86)"] && join(process.env["ProgramFiles(x86)"], "Microsoft", "Edge", "Application", "msedge.exe"),
  process.env.ProgramFiles && join(process.env.ProgramFiles, "Microsoft", "Edge", "Application", "msedge.exe"),
].filter((candidate): candidate is string => typeof candidate === "string");
const edgePath = edgeCandidates.find(candidate => existsSync(candidate));

const skip = process.platform !== "win32"
  ? "live Windows UIA smoke runs only on Windows"
  : !existsSync(executorPath)
    ? `ppomi-executor not found at ${executorPath} (set PPOMI_EXECUTOR)`
    : edgePath === undefined
      ? "Microsoft Edge not found (set PPOMI_EDGE)"
      : false;

const page = `<!doctype html><html lang="ko"><head><meta charset="utf-8"><title>Ppomi UIA Smoke</title></head>
<body style="font-family:Segoe UI,sans-serif;padding:48px;font-size:22px">
<h1>Ppomi UIA smoke</h1>
<p><label>입력 상자: <input id="box" type="text" style="width:520px;font-size:24px;padding:8px"></label></p>
<p><button id="btn" type="button" style="font-size:22px;padding:10px 20px"
  onclick="document.getElementById('mark').textContent='탭됨 OK ' + new Date().toLocaleTimeString()">여기를 탭</button></p>
<p id="mark" style="font-size:24px">아직 탭 안 됨</p>
</body></html>`;

const sleep = (ms: number): Promise<void> => new Promise(done => setTimeout(done, ms));

test("live: Edge read → type → tap → re-read through the real executor", { skip, timeout: 120_000 }, async () => {
  const workDir = mkdtempSync(join(tmpdir(), "ppomi-uia-smoke-"));
  const pagePath = join(workDir, "smoke.html");
  writeFileSync(pagePath, page, "utf8");
  // Own profile: never the user's tabs or sessions. Renderer accessibility must be forced, otherwise
  // Chromium exposes only the browser chrome (address bar, tabs) to UIA and not the page's fields.
  const edge = spawn(edgePath!, [
    `--user-data-dir=${join(workDir, "edge-profile")}`,
    "--no-first-run",
    "--no-default-browser-check",
    "--force-renderer-accessibility",
    "--new-window",
    pathToFileURL(pagePath).href,
  ], { stdio: "ignore" });
  await sleep(9_000);

  const tools = LiveWindowsExecutorTools.start({ executorPath });
  try {
    const running = tools.listApps("");
    const browser = running.apps.find(app => app.label === "msedge");
    assert.ok(browser, `Edge not in app_list: ${JSON.stringify(running.apps.map(app => app.label))}`);

    assert.deepEqual(tools.allowApps([browser.packageName]), { updated: true });
    assert.equal(tools.app_open({ target: browser.packageName }).activated, true);

    const before = tools.screen_read();
    assert.equal(before.appLabel, "msedge");
    assert.ok(before.nodes.some(node => node.role === "ControlType.Edit" && node.text.includes("주소")), "address bar node missing");
    const input = before.nodes.find(node => node.editable && !node.text.includes("주소"));
    assert.ok(input, "page text input missing from screen_read (renderer accessibility?)");

    const unique = `ppomiuiasmoke${Date.now()}`;
    assert.deepEqual(tools.ui_type({ nodeId: input.id, text: unique }), { typed: true, requiresScreenRead: true });
    // The snapshot the type was addressed against is gone; the adapter must read again first.
    assert.throws(() => tools.ui_tap({ nodeId: input.id }), error => error instanceof WindowsAdapterError && error.code === "stale_screen");

    const afterType = tools.screen_read();
    assert.ok(afterType.nodes.some(node => node.editable && node.text.includes(unique)), "typed text not visible after re-read");
    const button = afterType.nodes.find(node => node.text.includes("여기를 탭"));
    assert.ok(button, "tap target missing");
    console.log(`tap target: role=${button.role} clickable=${button.clickable}`);

    assert.deepEqual(tools.ui_tap({ nodeId: button.id }), { invoked: true, requiresScreenRead: true });

    const afterTap = tools.screen_read();
    assert.ok(afterTap.nodes.some(node => node.text.includes("탭됨")), "tap effect not visible after re-read");
    assert.ok(afterTap.nodes.some(node => node.editable && node.text.includes(unique)), "typed text lost after tap");
    console.log(`nodes: before=${before.nodes.length} afterType=${afterType.nodes.length} afterTap=${afterTap.nodes.length}; snapshot ids differ: ${before.snapshotId !== afterTap.snapshotId}`);

    if (process.env.PPOMI_SMOKE_SHOT) captureScreen(process.env.PPOMI_SMOKE_SHOT);
  } finally {
    tools.close();
    if (edge.pid !== undefined) spawnSync("taskkill", ["/PID", String(edge.pid), "/T", "/F"], { stdio: "ignore" });
    rmSync(workDir, { recursive: true, force: true });
  }
});

function captureScreen(target: string): void {
  const script = [
    "Add-Type -AssemblyName System.Windows.Forms,System.Drawing",
    "$b=[System.Windows.Forms.SystemInformation]::VirtualScreen",
    "$bmp=New-Object System.Drawing.Bitmap $b.Width,$b.Height",
    "$g=[System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($b.X,$b.Y,0,0,$bmp.Size); $g.Dispose()",
    `$bmp.Save('${target.replace(/'/g, "''")}',[System.Drawing.Imaging.ImageFormat]::Png)`,
  ].join("; ");
  spawnSync("powershell", ["-NoProfile", "-Command", script], { stdio: "ignore" });
}
