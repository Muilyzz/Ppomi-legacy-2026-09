// Fixture workbench feed: DummyPageAdapter + DummyAdapter emit RunResult.stepResults.
// Screenshot captions are attached after the run (dummies do not capture). No live AX / Playwright / OCR.
import {
  AdapterTimeoutError,
  DummyAdapter,
  DummyPageAdapter,
  FixedPermissionGate,
  PagePlaybookRuntime,
  PlaybookRuntime,
  type Evidence,
  type OsAdapter,
  type ScreenSnapshot,
  type StepResult,
} from "../../../packages/playbook-runtime/src/index";

const page = {
  url: "https://example.test/start",
  title: "Demo Page",
  texts: ["Demo Page", "Next", "Name"],
  locators: ["#next", "#name"],
};

const osScreen: ScreenSnapshot = {
  title: "Demo App",
  texts: ["Demo App", "Next", "Name", "인증서", "서명"],
  focused: null,
};

const EVIDENCE: Record<string, Evidence> = {
  "open-next": {
    screenshotBefore: "runs/fixture/open-next.before.png",
    screenshotAfter: "runs/fixture/open-next.after.png",
  },
  confirm: {
    screenshotAfter: "runs/fixture/confirm.after.png",
  },
};

class TimeoutClickAdapter implements OsAdapter {
  readonly kind = "os-windows" as const;

  readScreen(): ScreenSnapshot {
    return osScreen;
  }

  focus(): void {
    throw new Error("unused");
  }

  click(target: string): void {
    throw new AdapterTimeoutError(`click timed out waiting for ${target}`);
  }

  type(): void {
    throw new Error("unused");
  }
}

function runPageHappy(): StepResult[] {
  return new PagePlaybookRuntime(
    new DummyPageAdapter(page),
    new FixedPermissionGate(["ui.read", "ui.control"]),
  ).run({
    id: "fixture-page-happy",
    steps: [
      { id: "open-form", kind: "goto", url: "https://example.test/form" },
      { id: "open-next", kind: "click", locator: "#next" },
      { id: "fill-name", kind: "fill", locator: "#name", text: "fixture" },
    ],
  }).stepResults;
}

function runOsTimeout(): StepResult[] {
  return new PlaybookRuntime(
    new TimeoutClickAdapter(),
    new FixedPermissionGate(["ui.read", "ui.control"]),
  ).run({
    id: "fixture-hybrid",
    steps: [
      { id: "wait-cert", kind: "click", target: "인증서" },
      { id: "sign", kind: "click", target: "서명" },
    ],
  }).stepResults;
}

function runOsDenied(): StepResult[] {
  return new PlaybookRuntime(
    new DummyAdapter(osScreen),
    new FixedPermissionGate(["ui.read"]),
  ).run({
    id: "fixture-denied",
    steps: [{ id: "type-name", kind: "type", target: "Name", text: "fixture" }],
  }).stepResults;
}

function runMacConfirm(): StepResult[] {
  return new PlaybookRuntime(
    new DummyAdapter({ title: "Cert", texts: ["인증서 PIN"], focused: null }, "os-macos"),
    new FixedPermissionGate(["ui.read", "ui.control"]),
  ).run({
    id: "fixture-macos",
    steps: [{ id: "confirm", kind: "focus", target: "인증서 PIN" }],
  }).stepResults;
}

function runPhoneTap(): StepResult[] {
  return new PlaybookRuntime(
    new DummyAdapter({ title: "Phone", texts: ["다음"], focused: null }, "phone"),
    new FixedPermissionGate(["ui.read", "ui.control"]),
  ).run({
    id: "fixture-phone",
    steps: [{ id: "tap-next", kind: "click", target: "다음" }],
  }).stepResults;
}

export function attachFixtureEvidence(steps: readonly StepResult[]): StepResult[] {
  return steps.map(step => {
    const evidence = EVIDENCE[step.stepId];
    return evidence ? { ...step, evidence } : step;
  });
}

/** One fixture workbench run: page + OS timeout + permission stop + macOS + phone. */
export function runFixtureStepRecord(): StepResult[] {
  return attachFixtureEvidence([
    ...runPageHappy(),
    ...runOsTimeout(),
    ...runOsDenied(),
    ...runMacConfirm(),
    ...runPhoneTap(),
  ]);
}
