// 웹(hub) 진입점. 브라우저 전용 계층은 hub/web/home.js가 만들고, 여기는 공통 대화 패널을 웹 프레임에 마운트만 한다.
import React from "react";
import { createRoot } from "react-dom/client";
import { ChatPanel, type ChatFrame } from "./chat-panel";
import { createWebChatHost } from "./web-host";
import { WebPanel, type WebWorkbenchHost } from "./web-panel";
import "./index.css";
import "./tokens.css";
import "./style.css";
import "./executor-panel.css";
import "./web-panel.css";

export type { WebWorkbenchHost, WebRecords, WebRecordsState, WebRecordView, WebRecordConnection } from "./web-panel";
export type { WebHostSource, WebHostState, WebAccount } from "./web-host";

/** Mounts the shared workbench into the page. Returns the unmount function. */
export function mountWebWorkbench(root: HTMLElement, host: WebWorkbenchHost): () => void {
  const chatHost = createWebChatHost({ source: host.source, window, document });
  const frame: ChatFrame = (state, render) => <WebPanel {...state} host={host}>{render}</WebPanel>;
  const reactRoot = createRoot(root);
  reactRoot.render(<ChatPanel host={chatHost} frame={frame} />);
  return () => reactRoot.unmount();
}
