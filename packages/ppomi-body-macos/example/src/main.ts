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
import { probeMacLive, writeLiveProbe } from "./live-probe.ts";

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

async function runFixtureStep(): Promise<void> {
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
}

async function main(): Promise<void> {
  await runFixtureStep();
  await writeLiveProbe(probeMacLive());
}

main().catch(error => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`ppomi-body-macos example: FAIL\n  ${message}\n`);
  process.exitCode = 1;
});
