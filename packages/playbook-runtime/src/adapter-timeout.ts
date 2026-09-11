/**
 * Drivers throw this when a wait times out.
 * The runtime records `attempt: "timeout"`, not `not_executed`.
 * Do not import Playwright or UIA here — wrap those errors at the driver.
 */
export class DriverTimeoutError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "DriverTimeoutError";
  }
}

export function isDriverTimeout(error: unknown): boolean {
  if (error instanceof DriverTimeoutError) return true;
  return error instanceof Error && error.name === "TimeoutError";
}

/** @deprecated Renamed to `DriverTimeoutError` (#22 glossary). */
export const AdapterTimeoutError = DriverTimeoutError;
/** @deprecated Renamed to `DriverTimeoutError` (#22 glossary). */
export type AdapterTimeoutError = DriverTimeoutError;
/** @deprecated Renamed to `isDriverTimeout` (#22 glossary). */
export const isAdapterTimeout = isDriverTimeout;
