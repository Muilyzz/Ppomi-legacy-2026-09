import type { Bootstrap, NativeBridge } from "./bridge";
import { BootstrapReadiness } from "./update-readiness";

export type ChatHostEvents = {
  stop(): void;
  refresh(): void;
  answerCall(reason?: string): void;
  incomingCall(reason: string): void;
  toolProgress(event: { tool?: unknown; kind?: unknown; method?: unknown }): void;
  notice(text: string): void;
};

export type ChatHost = {
  readonly bridge: NativeBridge;
  readonly readiness: BootstrapReadiness;
  applyBootstrap(boot: Bootstrap): void;
  subscribe(events: ChatHostEvents): () => void;
};

type NativeChatWindow = {
  ppomiVoiceStop?: () => void;
  ppomiVoiceRefresh?: () => void;
  ppomiAnswerCall?: (reason: string) => void;
  ppomiIncomingCall?: (reason: string) => void;
  ppomiToolProgress?: (event: { tool?: unknown; kind?: unknown; method?: unknown }) => void;
  ppomiNotice?: (text: string) => void;
  addEventListener(type: "pagehide" | "focus", listener: () => void): void;
  removeEventListener(type: "pagehide" | "focus", listener: () => void): void;
};

export type ChatHostDocument = {
  readonly visibilityState: string;
  readonly documentElement: {
    readonly style: Pick<CSSStyleDeclaration, "setProperty">;
    readonly dataset: { [name: string]: string | undefined };
  };
  addEventListener(type: "visibilitychange", listener: () => void): void;
  removeEventListener(type: "visibilitychange", listener: () => void): void;
};

/** Text size follows the host; the colour scheme changes only when the host names one (otherwise tokens.css follows the system). */
export function applyBootstrapAppearance(document: Pick<ChatHostDocument, "documentElement">, b: Bootstrap) {
  const scale = typeof b.uiScale === "number" && Number.isFinite(b.uiScale) ? Math.min(3, Math.max(0.75, b.uiScale)) : 1;
  document.documentElement.style.setProperty("--ui-scale", String(scale));
  if (typeof b.dark === "boolean") document.documentElement.dataset.theme = b.dark ? "dark" : "light";
}

/** One native document owns its bridge/readiness; the panel owns stopping its controllers. */
export function createNativeChatHost({ bridge, window, document }: {
  bridge: NativeBridge;
  window: NativeChatWindow;
  document: ChatHostDocument;
}): ChatHost {
  const readiness = new BootstrapReadiness(() => bridge.call("updateReady", { bridgeVersion: 1 }, 5_000));

  const applyBootstrap = (b: Bootstrap) => applyBootstrapAppearance(document, b);

  function subscribe(events: ChatHostEvents) {
    const refresh = () => { if (document.visibilityState !== "hidden") events.refresh(); };
    const stop = () => events.stop();
    // Each subscription gets distinct functions, even when its event callbacks are reused.
    // Input checks stay in the panel so native hook behavior remains unchanged.
    const hooks = {
      ppomiVoiceStop: () => events.stop(),
      ppomiVoiceRefresh: refresh,
      ppomiAnswerCall: (reason: string) => events.answerCall(reason),
      ppomiIncomingCall: (reason: string) => events.incomingCall(reason),
      ppomiToolProgress: (event: { tool?: unknown; kind?: unknown; method?: unknown }) => events.toolProgress(event),
      ppomiNotice: (text: string) => events.notice(text),
    };
    Object.assign(window, hooks);
    window.addEventListener("pagehide", stop);
    window.addEventListener("focus", refresh);
    document.addEventListener("visibilitychange", refresh);
    return () => {
      window.removeEventListener("pagehide", stop);
      window.removeEventListener("focus", refresh);
      document.removeEventListener("visibilitychange", refresh);
      for (const name of Object.keys(hooks) as (keyof typeof hooks)[]) {
        if (window[name] === hooks[name]) delete window[name];
      }
    };
  }

  return Object.freeze({ bridge, readiness, applyBootstrap, subscribe });
}
