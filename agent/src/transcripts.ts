import type { UIMessage } from "ai";

export type TranscriptPart =
  | { type: "text"; text: string }
  | { type: "reasoning"; text: string }
  | { type: "tool"; name: string; state: string };

export type TranscriptTurn = {
  id: string;
  role: "user" | "assistant";
  parts: TranscriptPart[];
};

export type TranscriptEvent = { type: "turn"; turn: TranscriptTurn } | { type: "deleted" };

export type TranscriptSync = {
  load(): Promise<{ turns: TranscriptTurn[] } | null>;
  append(turn: TranscriptTurn): Promise<void>;
  subscribe(listener: (event: TranscriptEvent) => void): () => void;
};

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SECRET = /\bsk-(?:proj-)?[A-Za-z0-9_-]{12,}\b|\bvck_[A-Za-z0-9_-]{12,}\b|\bsb_(?:publishable|secret)_[A-Za-z0-9_-]{12,}\b|Bearer\s+[A-Za-z0-9._\-+=/]{12,}/gi;

export function redactTranscriptText(text: string): string {
  return text.replace(SECRET, "[redacted]");
}

export function projectTurn(message: UIMessage): TranscriptTurn | null {
  if (message.role !== "user" && message.role !== "assistant") return null;
  if (typeof message.id !== "string" || !message.id || message.id.length > 80) return null;
  const parts: TranscriptPart[] = [];
  for (const part of message.parts) {
    if (part.type === "text") {
      const text = redactTranscriptText(part.text ?? "");
      if (text) parts.push({ type: "text", text });
      continue;
    }
    if (part.type === "reasoning") {
      const text = redactTranscriptText(part.text ?? "");
      if (text) parts.push({ type: "reasoning", text });
      continue;
    }
    const tool = part as { type: string; toolName?: string; state?: string };
    const name = tool.type === "dynamic-tool" ? tool.toolName : tool.type.startsWith("tool-") ? tool.type.slice(5) : "";
    if (name && name.length <= 80) parts.push({ type: "tool", name, state: typeof tool.state === "string" ? tool.state : "done" });
  }
  if (!parts.length) return null;
  return { id: message.id, role: message.role, parts };
}

export function turnToMessage(turn: TranscriptTurn): UIMessage {
  return {
    id: turn.id,
    role: turn.role,
    parts: turn.parts.map((part, index) => {
      if (part.type === "text") return { type: "text", text: part.text };
      if (part.type === "reasoning") return { type: "reasoning", text: part.text, state: "done" as const };
      return {
        type: "dynamic-tool" as const,
        toolCallId: `${turn.id}-${part.name}-${index}`,
        toolName: part.name,
        state: "output-available" as const,
        input: {},
        output: undefined,
      };
    }),
  };
}

export function mergeTranscriptMessages(current: UIMessage[], incoming: TranscriptTurn[]): UIMessage[] {
  const seen = new Set(current.map(message => message.id));
  const extra = incoming.filter(turn => UUID.test(turn.id) && !seen.has(turn.id)).map(turnToMessage);
  return extra.length ? [...current, ...extra] : current;
}

export function completedTurns(messages: UIMessage[], ready: boolean): TranscriptTurn[] {
  if (!ready) return [];
  return messages.flatMap(message => {
    const turn = projectTurn(message);
    return turn ? [turn] : [];
  });
}
