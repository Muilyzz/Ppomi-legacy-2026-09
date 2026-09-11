import { MessageChannel, Worker, receiveMessageOnPort, type MessagePort } from "node:worker_threads";
import type {
  WindowsActionResult,
  WindowsExecutorTools,
  WindowsScreenNode,
  WindowsScreenRead,
} from "./windows-executor-tools.ts";
import { WINDOWS_SNAPSHOT_TTL_MS, WindowsAdapterError, snapshotIdOf } from "./windows-executor-tools.ts";

export interface LiveWindowsExecutorOptions {
  /** Path to the real `ppomi-executor.exe` (the same binary the Tauri shell packages). */
  readonly executorPath: string;
  /** Process whose UI the executor must never control; defaults to this process. Must be alive. */
  readonly ownerPid?: number;
  /** Per-request wall-clock budget for a reply from the executor. */
  readonly requestTimeoutMs?: number;
  /** Snapshot lifetime enforced client-side before an addressed action; measured executor value by default. */
  readonly snapshotTtlMs?: number;
  /** Clock for the expiry check; tests inject a fake one. */
  readonly now?: () => number;
  /** How the executor process is started. Defaults to `executorPath --executor --owner-pid <ownerPid>`; tests point it at a fake. */
  readonly launch?: { readonly command: string; readonly args: readonly string[] };
}

export interface WindowsRunningApp {
  readonly label: string;
  readonly packageName: string;
  readonly allowed: boolean;
}

interface RawScreenNode {
  readonly id: string;
  readonly text: string;
  readonly role: string;
  readonly clickable: boolean;
  readonly editable: boolean;
}

interface RawScreenRead {
  readonly snapshotId: string;
  readonly packageName: string;
  readonly appLabel: string;
  readonly nodes: readonly RawScreenNode[];
  readonly truncated: boolean;
}

interface BridgeReply {
  readonly seq: number;
  readonly reply: { readonly result?: unknown; readonly error?: { readonly code?: string; readonly message?: string } };
}

const DEFAULT_REQUEST_TIMEOUT_MS = 20_000;
const START_TIMEOUT_MS = 30_000;
const CLOSE_TIMEOUT_MS = 5_000;

/**
 * `WindowsExecutorTools` over the real `ppomi-executor` JSONL protocol.
 *
 * Measured executor rules this class enforces or mirrors:
 * - `executeTool` needs an active session; `setControlApps` is idle-only (`protected_action` otherwise),
 *   so {@link allowApps} pauses the session, sets the allowlist and resumes it.
 * - `nodeId` is `"<snapshotId>:<index>"`; only the latest snapshot is addressable and it expires after
 *   {@link WINDOWS_SNAPSHOT_TTL_MS}. Both are checked here (`stale_screen`) before a request is sent.
 * - `ui_tap` / `ui_type` return `requiresScreenRead: true`; the snapshot is invalidated locally so the
 *   next addressed action without a fresh `screen_read` fails fast with `stale_screen`.
 * - Every other executor error code (`app_not_allowed`, `protected_action`, `session_ended`, …) is
 *   rethrown unchanged as `WindowsAdapterError`.
 *
 * The `OsAdapter` contract is synchronous, so the async child process lives in a worker thread and each
 * call blocks on `Atomics.wait` until that worker posts the reply.
 */
export class LiveWindowsExecutorTools implements WindowsExecutorTools {
  private readonly worker: Worker;
  private readonly port: MessagePort;
  private readonly flag: Int32Array;
  private readonly requestTimeoutMs: number;
  private readonly snapshotTtlMs: number;
  private readonly now: () => number;
  private seq = 0;
  private active = false;
  private closed = false;
  private latestSnapshotId: string | null = null;
  private latestReadAt = Number.NEGATIVE_INFINITY;
  private addressable = false;
  private childPid: number | undefined = undefined;
  /** Set when the worker thread itself fails; every later call rethrows it instead of hanging. */
  private workerError: WindowsAdapterError | null = null;

  /** PID of the spawned executor process (diagnostics/tests); `undefined` before it starts. */
  get executorPid(): number | undefined {
    return this.childPid;
  }

  private constructor(worker: Worker, port: MessagePort, flag: Int32Array, options: LiveWindowsExecutorOptions) {
    this.worker = worker;
    this.port = port;
    this.flag = flag;
    this.requestTimeoutMs = options.requestTimeoutMs ?? DEFAULT_REQUEST_TIMEOUT_MS;
    this.snapshotTtlMs = options.snapshotTtlMs ?? WINDOWS_SNAPSHOT_TTL_MS;
    this.now = options.now ?? Date.now;
  }

  /** Spawns the executor (via the worker) and waits until it is running. */
  static start(options: LiveWindowsExecutorOptions): LiveWindowsExecutorTools {
    const signal = new SharedArrayBuffer(Int32Array.BYTES_PER_ELEMENT);
    const flag = new Int32Array(signal);
    const { port1, port2 } = new MessageChannel();
    const launch = options.launch ?? {
      command: options.executorPath,
      args: ["--executor", "--owner-pid", String(options.ownerPid ?? process.pid)],
    };
    const worker = new Worker(new URL("./live-windows-executor-worker.ts", import.meta.url), {
      workerData: { command: launch.command, args: [...launch.args], signal, port: port2 },
      transferList: [port2],
    });
    worker.unref();
    port1.unref();
    const tools = new LiveWindowsExecutorTools(worker, port1, flag, options);
    // A Worker 'error' with no listener is thrown on the main thread and crashes the process; capture
    // it so a blocked wait wakes and every subsequent call fails with native_unavailable instead.
    worker.on("error", error => tools.onWorkerError(error));
    if (Atomics.wait(flag, 0, 0, START_TIMEOUT_MS) === "timed-out") {
      void worker.terminate();
      throw new WindowsAdapterError("native_unavailable", "executor did not start in time");
    }
    if (tools.workerError !== null) {
      void worker.terminate();
      throw tools.workerError;
    }
    const ready = receiveMessageOnPort(port1)?.message as { ready: boolean; pid?: number; error?: { code?: string; message?: string } } | undefined;
    if (ready === undefined || !ready.ready) {
      void worker.terminate();
      throw new WindowsAdapterError(ready?.error?.code ?? "native_unavailable", ready?.error?.message ?? "executor failed to start");
    }
    tools.childPid = ready.pid;
    return tools;
  }

  /** Visible running applications as the executor reports them (`app_list`); needs an active session. */
  listApps(query = ""): { apps: readonly WindowsRunningApp[]; truncated: boolean } {
    this.ensureActive();
    return this.request("executeTool", { name: "app_list", args: { query } }) as { apps: readonly WindowsRunningApp[]; truncated: boolean };
  }

  /** Replaces the executor's control allowlist. Idle-only on the executor side, so the session is paused around it. */
  allowApps(packageNames: readonly string[]): { updated: boolean } {
    const resume = this.active;
    this.ensureIdle();
    const updated = this.request("setControlApps", { packageNames: [...packageNames] }) as { updated: boolean };
    if (resume) this.ensureActive();
    return updated;
  }

  app_open(args: { target: string }): { packageName: string; activated: boolean } {
    this.ensureActive();
    const result = this.request("executeTool", { name: "app_open", args: { target: args.target } }) as { packageName: string; activated: boolean };
    this.addressable = false;
    return result;
  }

  screen_read(): WindowsScreenRead {
    this.ensureActive();
    const raw = this.request("executeTool", { name: "screen_read", args: {} }) as RawScreenRead;
    this.latestSnapshotId = raw.snapshotId;
    this.latestReadAt = this.now();
    this.addressable = true;
    return {
      snapshotId: raw.snapshotId,
      packageName: raw.packageName,
      appLabel: raw.appLabel,
      nodes: raw.nodes.map(toScreenNode),
      truncated: raw.truncated,
    };
  }

  ui_tap(args: { nodeId: string }): WindowsActionResult & { invoked: boolean } {
    this.requireAddressable(args.nodeId);
    const result = this.request("executeTool", { name: "ui_tap", args: { nodeId: args.nodeId } }) as { invoked: boolean; requiresScreenRead?: boolean };
    this.addressable = false;
    return { invoked: result.invoked, requiresScreenRead: result.requiresScreenRead ?? true };
  }

  ui_type(args: { nodeId: string; text: string }): WindowsActionResult & { typed: boolean } {
    this.requireAddressable(args.nodeId);
    const result = this.request("executeTool", { name: "ui_type", args: { nodeId: args.nodeId, text: args.text } }) as { typed: boolean; requiresScreenRead?: boolean };
    this.addressable = false;
    return { typed: result.typed, requiresScreenRead: result.requiresScreenRead ?? true };
  }

  /** Stops the executor process, then drops the worker thread. Idempotent and never throws. */
  close(): void {
    if (this.closed) return;
    this.closed = true;
    if (this.workerError === null) {
      // Have the worker close the child's stdin and, if it will not exit, kill it; wait for the ack so
      // a wedged executor is reaped before the worker thread (which owns the child) is terminated.
      const deadline = Date.now() + CLOSE_TIMEOUT_MS;
      let seen = Atomics.load(this.flag, 0);
      this.port.postMessage({ close: true });
      for (;;) {
        let message = receiveMessageOnPort(this.port)?.message as { readonly closed?: boolean } | undefined;
        while (message !== undefined && message.closed !== true) {
          message = receiveMessageOnPort(this.port)?.message as { readonly closed?: boolean } | undefined;
        }
        if (message?.closed === true) break;
        const remaining = deadline - Date.now();
        if (remaining <= 0 || Atomics.wait(this.flag, 0, seen, remaining) === "timed-out") break;
        seen = Atomics.load(this.flag, 0);
      }
    }
    void this.worker.terminate();
  }

  private ensureActive(): void {
    if (this.active) return;
    this.request("sessionState", { active: true, mode: "text" });
    this.active = true;
  }

  private ensureIdle(): void {
    if (!this.active) return;
    this.request("sessionState", { active: false, mode: "text" });
    this.active = false;
    this.addressable = false;
  }

  private requireAddressable(nodeId: string): void {
    if (!this.addressable || this.latestSnapshotId === null) {
      throw new WindowsAdapterError("stale_screen", "screen_read is required before an addressed action");
    }
    if (snapshotIdOf(nodeId) !== this.latestSnapshotId) {
      throw new WindowsAdapterError("stale_screen", "nodeId does not belong to the latest snapshot");
    }
    if (this.now() - this.latestReadAt > this.snapshotTtlMs) {
      this.addressable = false;
      throw new WindowsAdapterError("stale_screen", "snapshot expired");
    }
  }

  /** One synchronous round trip: post the request, block until the worker signals, read this seq's reply. */
  private request(method: string, args: unknown): unknown {
    if (this.workerError !== null) throw this.workerError;
    if (this.closed) throw new WindowsAdapterError("native_unavailable", "executor tools are closed");
    this.seq += 1;
    const seq = this.seq;
    const deadline = Date.now() + this.requestTimeoutMs;
    let seen = Atomics.load(this.flag, 0);
    this.port.postMessage({ seq, id: `live-${seq}`, method, args });
    for (;;) {
      // Drop replies to earlier requests that already timed out; only the one tagged with this seq counts.
      let message = receiveMessageOnPort(this.port)?.message as BridgeReply | undefined;
      while (message !== undefined && message.seq !== seq) {
        message = receiveMessageOnPort(this.port)?.message as BridgeReply | undefined;
      }
      if (message !== undefined) {
        const { error, result } = message.reply;
        if (error !== undefined) throw new WindowsAdapterError(error.code ?? "tool_failed", error.message);
        return result;
      }
      if (this.workerError !== null) throw this.workerError;
      const remaining = deadline - Date.now();
      if (remaining <= 0 || Atomics.wait(this.flag, 0, seen, remaining) === "timed-out") {
        throw new WindowsAdapterError("bridge_timeout", `${method} did not answer within ${this.requestTimeoutMs} ms`);
      }
      seen = Atomics.load(this.flag, 0);
    }
  }

  private onWorkerError(error: Error): void {
    if (this.workerError === null) this.workerError = new WindowsAdapterError("native_unavailable", `executor worker failed: ${error.message}`);
    Atomics.add(this.flag, 0, 1);
    Atomics.notify(this.flag, 0);
  }
}

function toScreenNode(node: RawScreenNode): WindowsScreenNode {
  return { id: node.id, text: node.text, clickable: node.clickable, editable: node.editable, role: node.role };
}
