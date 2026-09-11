// Story/test fixtures. Parsed with the playbook-runtime schema. No live run.
import { parseStepResults } from "../../../packages/playbook-runtime/src/step-result";
import type { OverlayBox } from "./highlight-overlay";
import overlayRaw from "./fixtures/overlay-boxes.json";
import stepsRaw from "./fixtures/step-results.json";

export type OverlayFixture = {
  readonly boxes: OverlayBox[];
  readonly selectedBoxId?: string;
  readonly imageSrc?: string;
};

export const fixtureSteps = parseStepResults(stepsRaw);

const overlays = overlayRaw as Record<string, OverlayFixture>;

export function overlayFixture(stepId: string): OverlayFixture | undefined {
  return overlays[stepId];
}
