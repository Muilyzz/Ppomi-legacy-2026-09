import { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { Bubble, Composer, ErrorBanner, Log, Pane, Shell, ToolCard } from "../../agent/src/ui/shell";
import { probeChatMode, sendChat, type ChatMode } from "./chat";
import type { Line } from "./spine";
import "../../agent/src/index.css";
import "../../agent/src/tokens.css";
import "../../agent/src/style.css";

function modeCaption(mode: ChatMode): string {
  switch (mode) {
    case "fixture":
      return "fixture";
    case "gateway":
      return "Gateway";
    case "local":
      return "";
    default: {
      const exhaustive: never = mode;
      return exhaustive;
    }
  }
}

function tauriInvoke(): ((cmd: string) => Promise<unknown>) | null {
  return (globalThis as { __TAURI__?: { core?: { invoke: (cmd: string) => Promise<unknown> } } }).__TAURI__?.core?.invoke ?? null;
}

function App() {
  const [lines, setLines] = useState<Line[]>([]);
  const [status, setStatus] = useState<"ready" | "submitted">("ready");
  const [error, setError] = useState("");
  const [mode, setMode] = useState<ChatMode>("local");
  const [signingIn, setSigningIn] = useState(false);

  useEffect(() => {
    void probeChatMode().then(setMode);
  }, []);

  const login = async () => {
    const invoke = tauriInvoke();
    if (invoke === null) return;
    setSigningIn(true);
    try {
      await invoke("open_clerk_account");
      const deadline = Date.now() + 5 * 60 * 1000;
      while (Date.now() < deadline) {
        const next = await probeChatMode();
        setMode(next);
        if (next === "gateway") break;
        await new Promise(resolve => setTimeout(resolve, 1000));
      }
    } finally {
      setSigningIn(false);
    }
  };

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
            <>
              <div className="flex items-center justify-between gap-2 px-1 pb-1">
                {modeCaption(mode) !== "" && (
                  <p className="text-muted-foreground text-xs" aria-label="chat mode">{modeCaption(mode)}</p>
                )}
                {mode === "local" && tauriInvoke() !== null && (
                  <button
                    type="button"
                    className="text-muted-foreground text-xs underline-offset-2 hover:underline"
                    onClick={() => void login()}
                    disabled={signingIn}
                  >
                    {signingIn ? "로그인 중" : "로그인"}
                  </button>
                )}
              </div>
              <Composer
                status={status}
                placeholder="시킬 일을 적어 주세요"
                onSend={send}
                onStop={() => {}}
              />
            </>
          }
        />
      }
    />
  );
}

const root = document.getElementById("root");
if (root === null) throw new Error("missing #root");
createRoot(root).render(<App />);
