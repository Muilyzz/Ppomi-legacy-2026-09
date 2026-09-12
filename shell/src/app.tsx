import { useState } from "react";
import { createRoot } from "react-dom/client";
import { Button } from "../../agent/src/components/ui/button";
import { Bubble, Composer, ErrorBanner, Log, Pane, Shell, ToolCard } from "../../agent/src/ui/shell";
import { approveChat, denyChat, sendChat, type ChatTurn, type PendingApproval } from "./chat";
import type { Line } from "./spine";
import "../../agent/src/index.css";
import "../../agent/src/tokens.css";
import "../../agent/src/style.css";

function App() {
  const [lines, setLines] = useState<Line[]>([]);
  const [status, setStatus] = useState<"ready" | "submitted">("ready");
  const [error, setError] = useState("");
  // The one gate waiting on the person. Only the 실행 button below turns it into a run.
  const [pending, setPending] = useState<PendingApproval | null>(null);

  const settle = async (turn: Promise<ChatTurn> | ChatTurn) => {
    setStatus("submitted");
    setError("");
    try {
      const reply = await turn;
      setLines(old => [...old, ...reply.lines]);
      setPending(reply.pending ?? null);
    } catch (caught) {
      const message = caught instanceof Error ? caught.message : String(caught);
      setError(message);
      setLines(old => [...old, { kind: "bubble", role: "assistant", text: message }]);
      setPending(null);
    } finally {
      setStatus("ready");
    }
  };

  const send = async (text: string) => {
    // A new request drops an unanswered gate: it is never approved by accident.
    setPending(null);
    setLines(old => [...old, { kind: "bubble", role: "user", text }]);
    await settle(sendChat(text));
  };

  const approve = async () => {
    if (pending === null) return;
    const gate = pending;
    setPending(null);
    setLines(old => [...old, { kind: "bubble", role: "user", text: `실행 — ${gate.approval.token}` }]);
    await settle(approveChat(gate));
  };

  const deny = () => {
    if (pending === null) return;
    const gate = pending;
    setPending(null);
    setLines(old => [...old, { kind: "bubble", role: "user", text: `취소 — ${gate.approval.token}` }]);
    void settle(denyChat(gate));
  };

  return (
    <Shell
      platform="macos"
      error={error ? <ErrorBanner onClose={() => setError("")}>{error}</ErrorBanner> : undefined}
      conversation={
        <Pane
          log={
            <Log>
              {lines.map((line, index) =>
                line.kind === "tool"
                  ? <ToolCard key={index} {...line.tool} />
                  : <Bubble key={index} role={line.role} text={line.text} />,
              )}
              {pending !== null && (
                <Bubble
                  role="assistant"
                  text={pending.prompt}
                  actions={
                    <div className="mt-1 flex gap-2" role="group" aria-label="승인">
                      <Button size="sm" onClick={() => { void approve(); }} disabled={status !== "ready"}>실행</Button>
                      <Button size="sm" variant="ghost" onClick={deny} disabled={status !== "ready"}>취소</Button>
                    </div>
                  }
                />
              )}
            </Log>
          }
          composer={
            <Composer
              status={status}
              placeholder="시킬 일을 적어 주세요"
              onSend={send}
              onStop={() => {}}
            />
          }
        />
      }
    />
  );
}

const root = document.getElementById("root");
if (root === null) throw new Error("missing #root");
createRoot(root).render(<App />);
