import { useState } from "react";
import { createRoot } from "react-dom/client";
import { Bubble, Composer, ErrorBanner, Log, Pane, Shell, ToolCard } from "../../agent/src/ui/shell";
import { sendChat } from "./chat";
import type { Line } from "./spine";
import "../../agent/src/index.css";
import "../../agent/src/tokens.css";
import "../../agent/src/style.css";

function App() {
  const [lines, setLines] = useState<Line[]>([]);
  const [status, setStatus] = useState<"ready" | "submitted">("ready");
  const [error, setError] = useState("");

  const send = async (text: string) => {
    setStatus("submitted");
    setError("");
    setLines(old => [...old, { kind: "bubble", role: "user", text }]);
    try {
      const reply = await sendChat(text);
      setLines(old => [...old, ...reply.lines]);
    } catch (caught) {
      const message = caught instanceof Error ? caught.message : String(caught);
      setError(message);
      setLines(old => [...old, { kind: "bubble", role: "assistant", text: message }]);
    } finally {
      setStatus("ready");
    }
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
