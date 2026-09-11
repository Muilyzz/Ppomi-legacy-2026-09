import { invoke, isTauri } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { NativeBridgeError, type Reply } from "./bridge";
import { receiveExecutorNotification, type ExecutorNotification } from "./executor-events";

export const isTauriHost = () => typeof window !== "undefined" && isTauri();

export function tauriTransport(receive: (reply: Reply) => void): (message: string) => void {
  const ready = listen<ExecutorNotification>("ppomi-executor", ({ payload }) => receiveExecutorNotification(payload, window));
  window.addEventListener("pagehide", () => { void ready.then((unlisten) => unlisten()).catch(() => {}); }, { once: true });
  return (message) => {
    const request = JSON.parse(message) as { id: string };
    void ready.then(() => invoke<Reply>("executor_request", { request }))
      .then(receive)
      .catch(() => receive({ id: request.id, error: { code: "native_unavailable", message: "" } }));
  };
}

export type ExecutorStatus = {
  platform: "macos" | "windows" | "android";
  active: boolean;
  mode?: "voice" | "text";
  approval?: { id: string; text: string; options: string[] } | null;
  availableApps?: { label: string; packageName: string; allowed: boolean }[];
  capabilities?: Record<string, unknown>;
};
export type ManagementAction = "status" | "answerApproval" | "setControlApps" | "openSettings" | "openAccount" | "openRecords" | "configureDevice";

/** This API is used by app settings and human approval controls, never by createAgentTools. */
export async function manageExecutor<T>(action: ManagementAction, args: object = {}): Promise<T> {
  let reply: Reply;
  try { reply = await invoke<Reply>("executor_manage", { action, args }); }
  catch { throw new NativeBridgeError("native_unavailable"); }
  if (reply.error) throw new NativeBridgeError(reply.error.code);
  return reply.result as T;
}
