// 네이티브 문서의 진입점. 대화 패널 자체는 다른 프레임에서도 같은 컴포넌트를 쓴다.
import React from "react";
import { createRoot } from "react-dom/client";
import { createBridge } from "./bridge";
import { createNativeChatHost } from "./chat-host";
import { ChatPanel, type ChatFrame } from "./chat-panel";
import { ExecutorPanel } from "./executor-panel";
import { isTauriHost } from "./tauri-host";
import "./index.css";
import "./tokens.css";
import "./style.css";
import "./executor-panel.css";

const host = createNativeChatHost({ bridge: createBridge(), window, document });
const frame: ChatFrame | undefined = isTauriHost()
  ? (state, render) => <ExecutorPanel {...state}>{render}</ExecutorPanel>
  : undefined;
createRoot(document.getElementById("root")!).render(<ChatPanel host={host} frame={frame} />);
