import { NativeBridgeError, type Bootstrap } from "../agent/src/bridge";
import type { ExecutorAccount, ExecutorStatus, ManagementAction } from "../agent/src/tauri-host";
import { createStoryChatHost } from "./chat-host.fixture";

/** The three states of a Windows installation: before Google sign-in, registered but waiting for the Mac, connected. */
export type WindowsAccountState = "signed-out" | "pending-approval" | "connected";

/** Offline stand-in for the Windows executor's management route (`executor_manage`). No browser, network or token. */
export function createWindowsExecutorStory(initial: WindowsAccountState) {
  let state = initial;
  const account = (): ExecutorAccount => ({
    signedIn: state !== "signed-out", registered: state !== "signed-out", approved: state === "connected",
    pendingApproval: state === "pending-approval", recordKey: state === "connected",
    displayName: state === "signed-out" ? null : "합성 사용자",
  });
  const bootstrap = (): Bootstrap => {
    const a = account();
    return {
      platform: "windows", deviceLabel: "Windows", configured: state === "connected", endpoint: "https://preview.invalid",
      tools: ["device_status"], accessibility: true, bankProfileSupported: false,
      executor: { googleSignIn: true, developmentDeviceImport: false, nativeAutomation: true },
      authentication: { method: "google", googleSignIn: true, developerOnly: false, signedIn: a.signedIn, approved: a.approved,
        pendingApproval: a.pendingApproval, displayName: a.displayName },
    };
  };
  const status = (): ExecutorStatus => ({
    platform: "windows", active: false, mode: "text", approval: null, configured: state === "connected", account: account(),
    capabilities: { configureDevice: false, developmentDeviceImport: false, googleSignIn: true, controlApps: true, nativeAutomation: true, fileWorkspace: true, bankProfile: false, approval: false },
    availableApps: [
      { label: "msedge", packageName: "win:4120:133700001", allowed: false },
      { label: "notepad", packageName: "win:5208:133700002", allowed: true },
      { label: "excel", packageName: "win:6316:133700003", allowed: false },
    ],
  });
  const delay = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));
  const manage = async <T,>(action: ManagementAction, args: object = {}): Promise<T> => {
    switch (action) {
      case "status": return status() as T;
      case "signIn":
        await delay(900);   // the system browser round trip, compressed
        state = "pending-approval";
        return { configured: false, account: account() } as T;
      case "refreshAccount": return { configured: state === "connected", account: account() } as T;
      case "signOut": state = "signed-out"; return { signedOut: true, account: account() } as T;
      case "setControlApps": return { updated: true, ...args } as T;
      case "answerApproval":
      case "openSettings":
      case "openAccount":
      case "openRecords":
      case "configureDevice":
        throw new NativeBridgeError("invalid_request");
      default: {
        const exhaustive: never = action;
        throw new NativeBridgeError(exhaustive);
      }
    }
  };
  return {
    host: createStoryChatHost(bootstrap),
    manage,
    /** What the owner does on the Mac (나 › 기기 승인 › 승인): the next status poll sees it and the banner clears. */
    approve() { state = "connected"; },
    get state() { return state; },
  };
}
