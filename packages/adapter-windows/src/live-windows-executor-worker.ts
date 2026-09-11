/**
 * Worker thread that owns one real `ppomi-executor --executor --owner-pid <pid>` process and speaks
 * its JSONL protocol (one `{id,method,args}` request per line, one `{id,result|error}` reply per line).
 *
 * `LiveWindowsExecutorTools` runs on the main thread with a synchronous `WindowsExecutorTools`
 * contract, so it blocks on a shared flag (`Atomics.wait`) while this worker does the async I/O and
 * posts each reply back through a `MessagePort`. Notifications without an `id` are dropped here.
 */
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { workerData, type MessagePort } from "node:worker_threads";

interface WorkerInit {
  readonly command: string;
  readonly args: readonly string[];
  readonly signal: SharedArrayBuffer;
  readonly port: MessagePort;
}

interface WorkerRequest {
  readonly seq: number;
  readonly id: string;
  readonly method: string;
  readonly args: unknown;
}

interface ExecutorReply {
  readonly id?: string;
  readonly result?: unknown;
  readonly error?: { readonly code?: string; readonly message?: string };
}

const { command, args, signal, port } = workerData as WorkerInit;
const flag = new Int32Array(signal);
const pending = new Map<string, (reply: ExecutorReply) => void>();
let alive = false;

function wake(): void {
  Atomics.store(flag, 0, 1);
  Atomics.notify(flag, 0);
}

function failAll(code: string, message: string): void {
  for (const [id, resolve] of pending) resolve({ id, error: { code, message } });
  pending.clear();
}

const child = spawn(command, [...args], {
  stdio: ["pipe", "pipe", "ignore"],
  windowsHide: true,
});

child.once("spawn", () => {
  alive = true;
  port.postMessage({ ready: true });
  wake();
});

child.once("error", error => {
  alive = false;
  port.postMessage({ ready: false, error: { code: "native_unavailable", message: String(error.message) } });
  failAll("native_unavailable", "executor failed to start");
  wake();
});

child.on("exit", (code, signalName) => {
  alive = false;
  failAll("native_unavailable", `executor exited (${code ?? signalName ?? "unknown"})`);
});

createInterface({ input: child.stdout }).on("line", line => {
  let reply: ExecutorReply;
  try {
    reply = JSON.parse(line) as ExecutorReply;
  } catch {
    return;
  }
  if (typeof reply.id !== "string") return;
  const resolve = pending.get(reply.id);
  if (resolve === undefined) return;
  pending.delete(reply.id);
  resolve(reply);
});

port.on("message", (message: WorkerRequest | { readonly close: true }) => {
  if ("close" in message) {
    child.stdin.end();
    child.kill();
    return;
  }
  const answer = (reply: ExecutorReply): void => {
    port.postMessage({ seq: message.seq, reply });
    wake();
  };
  if (!alive) {
    answer({ id: message.id, error: { code: "native_unavailable", message: "executor is not running" } });
    return;
  }
  pending.set(message.id, answer);
  child.stdin.write(`${JSON.stringify({ id: message.id, method: message.method, args: message.args })}\n`);
});
