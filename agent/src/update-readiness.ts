import { validateBootstrap, UpdateCompatibilityError, type Bootstrap } from "./bridge";

/** A document gets one native readiness acknowledgement. Sessions always enter through wait(). */
export class BootstrapReadiness {
  private current?: Bootstrap;
  private identity?: string;
  private failure?: Error;
  private confirmation?: Promise<void>;
  private resolve!: () => void;
  private reject!: (error: Error) => void;
  private readonly ready = new Promise<void>((resolve, reject) => { this.resolve = resolve; this.reject = reject; });

  constructor(private readonly acknowledge: () => Promise<unknown>) {
    // Failure may precede the first user action. Keep the rejected barrier available without an unhandled rejection.
    void this.ready.catch(() => {});
  }
  get failed() { return this.failure !== undefined; }

  /** Validation can update displayed capabilities; it cannot itself start a session. */
  prepare(value: unknown): Bootstrap {
    if (this.failure) throw this.failure;
    try {
      const boot = validateBootstrap(value);
      const identity = JSON.stringify([boot.platform, boot.nativeBuild, boot.bridgeVersion, boot.webRelease, boot.capabilities?.slice().sort()]);
      // A native release cannot change within one document. Mutable tool lists/configuration can refresh normally.
      if (this.identity !== undefined && identity !== this.identity) throw new UpdateCompatibilityError();
      this.identity = identity;
      this.current = boot;
      return boot;
    } catch (error) { throw this.fail(error); }
  }

  /** Called only from the React commit effect after prepare() succeeded. */
  commit(): Promise<void> {
    if (this.failure) return Promise.reject(this.failure);
    if (this.confirmation) return this.confirmation;
    if (!this.current) return Promise.reject(this.fail(new UpdateCompatibilityError()));
    this.confirmation = (async () => {
      try {
        if (this.current!.bridgeVersion !== undefined) await this.acknowledge();
        // An incompatible refresh could arrive while native acknowledgement was pending.
        if (this.failure) throw this.failure;
        this.resolve();
      } catch (error) { throw this.fail(error); }
    })();
    return this.confirmation;
  }

  /** Both queued text sends and incoming/outgoing calls receive the newest validated bootstrap after the ack. */
  async wait(): Promise<Bootstrap> {
    await this.ready;
    if (this.failure) throw this.failure;
    if (!this.current) throw new UpdateCompatibilityError();
    return this.current;
  }

  private fail(error: unknown): Error {
    if (!this.failure) {
      this.failure = error instanceof UpdateCompatibilityError ? error : new Error("새 화면을 확인하지 못했습니다. 앱을 다시 열어 주세요.");
      this.current = undefined;
      this.reject(this.failure);
    }
    return this.failure;
  }
}
