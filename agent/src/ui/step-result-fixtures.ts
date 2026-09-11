// Story/test fixtures. Parsed with the ppomi-body StepResult schema. No live run.
import { parseStepResults } from "../../../packages/ppomi-body/src/step-result";
import type { OverlayBox } from "./highlight-overlay";
import type { StepScreenshotResolver } from "./step-record-panel";
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

/** Panel resolver backed by the overlay fixture: a data-URL picture and session boxes per step id. */
export const fixtureScreenshots: StepScreenshotResolver = step => {
  const overlay = overlayFixture(step.stepId);
  if (!overlay) return undefined;
  return { src: overlay.imageSrc, boxes: overlay.boxes, selectedBoxId: overlay.selectedBoxId };
};
