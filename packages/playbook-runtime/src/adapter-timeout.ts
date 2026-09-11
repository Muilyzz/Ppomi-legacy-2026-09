/**
 * Adapters throw this when a wait times out.
 * The runtime records `attempt: "timeout"`, not `not_executed`.
 * Do not import Playwright or UIA here — wrap those errors at the adapter.
 */
export class AdapterTimeoutError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AdapterTimeoutError";
  }
}

export function isAdapterTimeout(error: unknown): boolean {
  if (error instanceof AdapterTimeoutError) return true;
  return error instanceof Error && error.name === "TimeoutError";
}
