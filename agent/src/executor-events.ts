export type ExecutorNotification = { event: string; payload?: unknown };
type Hooks = {
  ppomiVoiceStop?: () => void;
  ppomiNotice?: (text: string) => void;
  ppomiIncomingCall?: (reason: string) => void;
  ppomiAnswerCall?: (reason: string) => void;
  ppomiToolProgress?: (event: { tool?: unknown; kind?: unknown; method?: unknown }) => void;
};

/** Only data is forwarded; an executor cannot ask the shell to evaluate JavaScript. */
export function receiveExecutorNotification(value: ExecutorNotification, hooks: Hooks) {
  const payload = value?.payload;
  const object = payload && typeof payload === "object" ? payload as Record<string, unknown> : {};
  const text = typeof payload === "string" ? payload : typeof object.text === "string" ? object.text : "";
  const reason = typeof payload === "string" ? payload : typeof object.reason === "string" ? object.reason : "";
  switch (value?.event) {
    case "stop": case "voiceStop": hooks.ppomiVoiceStop?.(); break;
    case "notice": if (text) hooks.ppomiNotice?.(text); break;
    case "incomingCall": hooks.ppomiIncomingCall?.(reason); break;
    case "answerCall": hooks.ppomiAnswerCall?.(reason); break;
    case "toolProgress": hooks.ppomiToolProgress?.(object); break;
  }
}
