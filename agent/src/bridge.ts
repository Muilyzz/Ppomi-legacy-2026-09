export type Bootstrap = {
  platform: "macos" | "android";
  deviceLabel: string;
  configured: boolean;
  endpoint: string;
  tools: string[];
  accessibility?: boolean;
  controlApps?: { label: string; packageName: string }[];
  bankProfileSupported?: boolean;
  /** Mac: every MCP tool (phone/Windows/profile/playbook…) as JSON-schema specs; executeTool returns {text, error}. */
  toolSpecs?: { name: string; description: string; parameters: Record<string, unknown> }[];
  /** Mac: the MCP server's own operating guide (common rules, approval boundaries), appended to the instructions. */
  toolGuide?: string;
  /** System text size (Android font scale, Mac setting). Applied as --ui-scale so the whole UI grows, not just text. */
  uiScale?: number;
  /** Android only: the WebView is reused across activity recreation, so the host says which scheme the page shows. */
  dark?: boolean;
  /** Android only: the OS call UI was answered before the page was ready; start the call about this reason once. */
  answerCall?: string | null;
};

const nativeFailures = {
  accessibility_required: {
    message: "접근성 연결 필요",
    recovery: "사용자에게 Android 접근성 설정에서 뽀미 서비스를 직접 켜도록 안내하세요. 모델이 권한 설정을 조작하지 마세요.",
  },
  app_not_allowed: {
    message: "앱 허용 필요",
    recovery: "접근성 권한 전체가 없다는 뜻은 아닙니다. 사용자에게 뽀미의 앱 제어 설정에서 해당 앱을 직접 허용하도록 안내하세요. 허용 목록을 모델이 바꾸거나 다른 도구로 우회하지 마세요.",
  },
  app_not_found: {
    message: "앱 없음",
    recovery: "app_list로 설치된 앱의 표시명 또는 패키지 이름을 검색하세요. 목록에 없는 패키지를 추측하지 마세요. 사용자가 해당 앱 설치를 명시적으로 요청했다면 제공된 store_search로 허용된 Play 스토어의 검색 결과를 열고 앱 이름·공식 발행자를 확인한 뒤 무료 설치 화면으로 진행할 수 있습니다. 미설치를 접근성 권한 부족으로 단정하지 마세요. 설치 요청이 없으면 임의로 설치하지 말고, 유료 구매·인증·권한 허용은 사용자에게 맡기세요.",
  },
  app_ambiguous: {
    message: "앱 구분 필요",
    recovery: "app_list의 후보를 확인하고 사용자에게 어느 앱인지 물으세요. 정확한 packageName을 사용하세요.",
  },
  playbook_not_found: {
    message: "절차 없음",
    recovery: "list_playbooks로 앱 이름·별칭 또는 작업을 검색한 뒤 결과의 정확한 id로 읽으세요. 절차 문서가 없다는 뜻이며 앱 미설치나 도구 권한 부족으로 단정하지 마세요. 현재 화면과 실제 도구로 가능한 작업은 이어가세요.",
  },
  playbook_ambiguous: {
    message: "절차 구분 필요",
    recovery: "list_playbooks의 후보를 확인해 정확한 id를 선택하세요. 사용자가 원하는 앱이나 작업이 불명확하면 필요한 선택만 물으세요.",
  },
  playbook_read_required: {
    message: "절차 확인 필요",
    recovery: "직전 list_playbooks의 정확한 id로 read_playbook을 먼저 읽으세요. 이 웹 작업은 연결된 Mac 브라우저 도구가 필요하며 Android 앱으로 대체할 수 없습니다. 자동 이관·조회는 실행되지 않았고 사용자 인증 대기도 아닙니다. 대화 승인이나 다른 기기 동작으로 우회하지 마세요.",
  },
  browser_environment_required: {
    message: "Mac 브라우저 연결 필요",
    recovery: "필요한 Mac 브라우저 도구 환경만 짧게 안내하세요. Android 앱 열기·설치·화면 조작으로 웹 절차를 대체하거나 사용자에게 계좌 목록을 준비하라고 하지 마세요. 대화 승인으로 해제되는 제한이 아니며, 새로운 사용자 작업으로 바뀌면 해당 작업의 플레이북을 다시 검색하세요.",
  },
  stale_screen: {
    message: "화면 바뀜",
    recovery: "screen_read로 현재 화면을 다시 읽으세요. 이미 요청 결과가 있으면 동작을 반복하지 말고, 필요한 경우 새 nodes[].id로 이어가세요.",
  },
  no_active_screen: {
    message: "화면 확인 필요",
    recovery: "device_status로 전면 앱과 잠금 상태를 확인하세요. 뽀미 자체 화면이면 요청한 허용 앱을 열거나 홈으로 이동한 뒤 다시 읽으세요. 잠금 해제는 사용자에게 맡기세요.",
  },
  protected_action: {
    message: "직접 처리",
    recovery: "결제·송금·전송·삭제·인증·권한 변경 등 보호 동작은 사용자가 직접 처리해야 합니다. 현재 에이전트에는 이를 허가하는 승인 도구가 없으며, 대화로 승인받거나 좌표 동작으로 우회할 수 없습니다.",
  },
  tool_failed: {
    message: "처리 실패",
    recovery: "도구가 성공했다고 보고하지 마세요. 현재 결과를 확인하고, 원인을 확인할 수 없으면 실패를 설명하세요. 결과가 불확실한 쓰기를 자동으로 반복하지 마세요.",
  },
  bridge_timeout: {
    message: "응답 확인 실패",
    recovery: "완료 여부가 불확실합니다. 조회로 결과를 확인하고 쓰기 요청을 자동 재전송하지 마세요.",
  },
  session_ended: {
    message: "대화 종료",
    recovery: "현재 세션에서 도구 실행을 계속하거나 다음 세션으로 넘기지 마세요.",
  },
  native_unavailable: {
    message: "뽀미 앱에서 열기",
    recovery: "네이티브 연결을 사용할 수 없습니다. 실행했다고 보고하지 마세요.",
  },
  server_unconfigured: {
    message: "설정에서 서버 주소",
    recovery: "사용자가 뽀미의 서버 연결 설정을 확인해야 합니다.",
  },
  invalid_request: {
    message: "요청 형식 오류",
    recovery: "네이티브가 요청을 거부했습니다. 같은 요청을 반복하지 마세요.",
  },
  server_auth: {
    message: "기기 인증 필요",
    recovery: "사용자가 뽀미 서버의 기기 등록을 확인해야 합니다.",
  },
  server_rejected: {
    message: "서버 거부",
    recovery: "앱 서버가 요청을 처리하지 못했습니다. 잠시 후 한 번만 다시 시도하세요.",
  },
  server_unavailable: {
    message: "서버 응답 없음",
    recovery: "앱 서버에 연결하지 못했습니다. 네트워크를 확인한 뒤 한 번만 다시 시도하세요.",
  },
  response_invalid: {
    message: "응답 형식 오류",
    recovery: "앱 서버 응답을 읽지 못했습니다. 같은 요청을 반복하지 마세요.",
  },
} as const;
export type NativeFailureCode = keyof typeof nativeFailures;

/** Native messages can contain screen text or secrets. Only an allowlisted code crosses this boundary. */
export class NativeBridgeError extends Error {
  readonly code: NativeFailureCode;
  readonly recovery: string;
  constructor(code: unknown) {
    const safeCode = typeof code === "string" && Object.hasOwn(nativeFailures, code)
      ? code as NativeFailureCode : "tool_failed";
    super(nativeFailures[safeCode].message);
    this.name = "NativeBridgeError";
    this.code = safeCode;
    this.recovery = nativeFailures[safeCode].recovery;
  }
}

export function formatNativeToolError(error: unknown): string {
  const failure = error instanceof NativeBridgeError ? error : new NativeBridgeError("tool_failed");
  return JSON.stringify({ ok: false, error: { code: failure.code, message: failure.message, recovery: failure.recovery } });
}
export type Reply = {
  id: string;
  result?: unknown;
  error?: { code: string; message: string };
};
export type Method =
  | "bootstrap"
  | "declineCall"
  | "heard"
  | "request"
  | "executeTool"
  | "sessionState"
  | "bankProfileRequest"
  | "bankProfileSubmit"
  | "bankProfileCancel"
  | "setEndpoint";
declare global {
  interface Window {
    webkit?: {
      messageHandlers?: { ppomiAgent?: { postMessage(message: string): void } };
    };
    ppomiAgentNative?: { postMessage(message: string): void };
    ppomiAgentReceive?: (reply: Reply) => void;
    ppomiVoiceStop?: () => void;
    /** 비서의 톡: 사람 차례가 오면 네이티브가 먼저 용건을 뽀미 말풍선으로 남긴다. 전화(아래)는 답이 없을 때만 온다. */
    ppomiNotice?: (text: string) => void;
    ppomiToolProgress?: (event: { tool?: unknown; kind?: unknown; method?: unknown }) => void;
    /** 네이티브가 부른다: 사람 차례(승인·질문)나 예약된 일. 셸은 수신 띠를 띄우고, 받으면 용건으로 통화를 연다. */
    ppomiIncomingCall?: (reason: string) => void;
    /** 네이티브(OS 통화 화면)가 이미 받았다: 띠 없이 바로 통화를 연다. */
    ppomiAnswerCall?: (reason: string) => void;
  }
}
// All payloads and callbacks are memory-only. A timeout never retries a mutation.
export class NativeBridge {
  private pending = new Map<
    string,
    {
      resolve(value: unknown): void;
      reject(error: Error): void;
      timer: ReturnType<typeof setTimeout>;
    }
  >();
  constructor(private send: (message: string) => void) {}
  call<T>(method: Method, args: object = {}, timeoutMs = 60_000): Promise<T> {
    const id = crypto.randomUUID();
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new NativeBridgeError("bridge_timeout"));
      }, timeoutMs);
      this.pending.set(id, {
        resolve: resolve as (v: unknown) => void,
        reject,
        timer,
      });
      try {
        this.send(JSON.stringify({ id, method, args }));
      } catch {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(new NativeBridgeError("native_unavailable"));
      }
    });
  }
  receive(reply: Reply) {
    const item = this.pending.get(reply.id);
    if (!item) return;
    this.pending.delete(reply.id);
    clearTimeout(item.timer);
    if (reply.error)
      item.reject(new NativeBridgeError(reply.error.code));
    else item.resolve(reply.result);
  }
  clear() {
    for (const item of this.pending.values()) {
      clearTimeout(item.timer);
      item.reject(new NativeBridgeError("session_ended"));
    }
    this.pending.clear();
  }
  get pendingCount() {
    return this.pending.size;
  }
}
export function createBridge() {
  const bridge = new NativeBridge((message) => {
    const host =
      window.webkit?.messageHandlers?.ppomiAgent ?? window.ppomiAgentNative;
    if (!host) throw new Error("native host unavailable");
    host.postMessage(message);
  });
  window.ppomiAgentReceive = (reply) => bridge.receive(reply);
  return bridge;
}
