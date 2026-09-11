import {
  FixedPermissionGate,
  OsSurface,
  Runtime,
  type Playbook,
} from "../../../ppomi-body/src/index.ts";
import {
  FixtureMacosNativeTools,
  MacosDriver,
  type FixtureMacosWindow,
} from "../../src/index.ts";

const window: FixtureMacosWindow = {
  appLabel: "Demo App",
  nodes: [
    { text: "Demo App", clickable: false, editable: false },
    { text: "Next", clickable: true, editable: false },
  ],
};

const oneStep: Playbook = {
  id: "macos-example-1-step",
  steps: [{ id: "open-next", kind: "click", target: "Next", effect: "navigate" }],
};

async function main(): Promise<void> {
  const tools = new FixtureMacosNativeTools(window);
  const result = await new Runtime(
    new OsSurface(new MacosDriver(tools)),
    new FixedPermissionGate(["ui.read", "ui.control"]),
  ).run(oneStep);

  if (result.status !== "completed" || result.stepResults[0]?.status !== "ok") {
    throw new Error(`fixture 1-step status=${result.status} code=${result.stepResults[0]?.code ?? "?"}`);
  }

  process.stdout.write("ppomi-body-macos example: PASS\n");
  process.stdout.write("  step     click Next (effect: navigate) via Runtime + FixtureMacosNativeTools\n");
  process.stdout.write(`  driver   ${result.stepResults[0]?.driver ?? "?"}\n`);
  process.stdout.write(`  status   ${result.status}\n`);
  if (process.platform !== "darwin") {
    process.stdout.write(`  live     SKIP (not macOS; ${process.platform})\n`);
  } else if (process.env.PPOMI_BODY_LIVE !== "1") {
    process.stdout.write("  live     off (set PPOMI_BODY_LIVE=1 for AX / Automation)\n");
  } else {
    process.stdout.write("  live     requested — fixture 1-step is the v0.1 merge proof; live AX is a follow-up\n");
  }
}

main().catch(error => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`ppomi-body-macos example: FAIL\n  ${message}\n`);
  process.exitCode = 1;
});
