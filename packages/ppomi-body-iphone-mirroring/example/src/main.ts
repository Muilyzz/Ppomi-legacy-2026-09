import {
  FixedPermissionGate,
  OsSurface,
  Runtime,
  type Playbook,
} from "../../../ppomi-body/src/index.ts";
import {
  FixtureIphoneMirroringTools,
  IphoneMirroringDriver,
  type FixtureIphoneMirroringScreen,
} from "../../src/index.ts";

const screen: FixtureIphoneMirroringScreen = {
  appLabel: "Demo App",
  rows: [
    { text: "Demo App", tappable: false, editable: false },
    { text: "Next", tappable: true, editable: false },
  ],
};

const oneStep: Playbook = {
  id: "iphone-mirroring-example-1-step",
  steps: [{ id: "open-next", kind: "click", target: "Next", effect: "navigate" }],
};

async function main(): Promise<void> {
  const tools = new FixtureIphoneMirroringTools(screen);
  const result = await new Runtime(
    new OsSurface(new IphoneMirroringDriver(tools)),
    new FixedPermissionGate(["ui.read", "ui.control"]),
  ).run(oneStep);

  if (result.status !== "completed" || result.stepResults[0]?.status !== "ok") {
    throw new Error(`fixture 1-step status=${result.status} code=${result.stepResults[0]?.code ?? "?"}`);
  }

  process.stdout.write("ppomi-body-iphone-mirroring example: PASS\n");
  process.stdout.write("  step     click Next (effect: navigate) via Runtime + FixtureIphoneMirroringTools\n");
  process.stdout.write(`  driver   ${result.stepResults[0]?.driver ?? "?"}\n`);
  process.stdout.write(`  status   ${result.status}\n`);
  if (process.platform !== "darwin") {
    process.stdout.write(`  live     SKIP (not macOS; ${process.platform}) — live phone_* is a Mac follow-up\n`);
  } else {
    process.stdout.write("  live     fixture 1-step is the v0.1 merge proof\n");
  }
}

main().catch(error => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`ppomi-body-iphone-mirroring example: FAIL\n  ${message}\n`);
  process.exitCode = 1;
});
