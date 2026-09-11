import {
  FixedPermissionGate,
  OsSurface,
  Runtime,
  type Playbook,
} from "../../../ppomi-body/src/index.ts";
import {
  AndroidDriver,
  FixtureAndroidNativeTools,
  type FixtureAndroidWindow,
} from "../../src/index.ts";
import { probeAndroidLive, writeLiveProbe } from "./live-probe.ts";

const window: FixtureAndroidWindow = {
  appLabel: "Demo App",
  packageName: "com.ppomi.androidtarget",
  nodes: [
    { text: "Demo App", clickable: false, editable: false },
    { text: "Next", clickable: true, editable: false },
  ],
};

const oneStep: Playbook = {
  id: "android-example-1-step",
  steps: [{ id: "open-next", kind: "click", target: "Next", effect: "navigate" }],
};

async function main(): Promise<void> {
  const tools = new FixtureAndroidNativeTools(window);
  const result = await new Runtime(
    new OsSurface(new AndroidDriver(tools)),
    new FixedPermissionGate(["ui.read", "ui.control"]),
  ).run(oneStep);

  if (result.status !== "completed" || result.stepResults[0]?.status !== "ok") {
    throw new Error(`fixture 1-step status=${result.status} code=${result.stepResults[0]?.code ?? "?"}`);
  }

  process.stdout.write("ppomi-body-android example: PASS\n");
  process.stdout.write("  step     click Next (effect: navigate) via Runtime + FixtureAndroidNativeTools\n");
  process.stdout.write(`  driver   ${result.stepResults[0]?.driver ?? "?"}\n`);
  process.stdout.write(`  status   ${result.status}\n`);
  await writeLiveProbe(probeAndroidLive());
}

main().catch(error => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`ppomi-body-android example: FAIL\n  ${message}\n`);
  process.exitCode = 1;
});
