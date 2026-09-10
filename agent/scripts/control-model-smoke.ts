// Live model + production tool definitions against synthetic device responses.
// No microphone, playback, user records, device actions or transcript persistence.
import { readFileSync, writeFileSync } from "node:fs";
import { RealtimeAgent, RealtimeSession, setSensitiveDataLoggingEnabled } from "@openai/agents/realtime";
import { NativeBridge, type Bootstrap } from "../src/bridge";
import { createNativeVoiceTools, voiceInstructions } from "../src/voice";

setSensitiveDataLoggingEnabled(false);
const root = new URL("../../", import.meta.url);
const config = JSON.parse(readFileSync(new URL(".ppomi/ssot/mac.json", root), "utf8"));
const auth = await fetch(`${config.url}/auth/v1/token?grant_type=password`, {
  method: "POST", redirect: "error",
  headers: { apikey: config.publishableKey, "Content-Type": "application/json" },
  body: JSON.stringify({ email: config.email, password: config.password }),
});
if (!auth.ok) throw new Error("Device authentication failed");
const token = (await auth.json()).access_token;
const results = [];
for (const allowed of [true, false]) {
  let opened = false, read = false, searched = false, finished = false;
  let audioBytes = 0;
  const calls: string[] = [];
  const boot: Bootstrap = { platform: "android", deviceLabel: "합성 Android", configured: true,
    endpoint: "https://ppomi-agent.vercel.app", accessibility: true, controlApps: [],
    tools: ["device_status", "app_list", "app_open", "screen_read"] };
  const bridge = new NativeBridge(raw => {
    const request = JSON.parse(raw);
    const name = request.args.name;
    calls.push(name);
    let result: unknown;
    let code: string | undefined;
    if (name === "device_status") result = { connected: true, accessibility: true, foregroundPackage: opened ? "viva.republica.toss" : "com.ppomi.androidbridge" };
    else if (name === "app_list") {
      searched = true;
      result = { apps: [{ label: "토스", packageName: "viva.republica.toss", allowed }], truncated: false };
    } else if (name === "app_open") {
      if (!["토스", "viva.republica.toss"].includes(request.args.args.target)) code = "app_not_found";
      else if (!allowed) code = "app_not_allowed";
      else { opened = true; result = { opened: "viva.republica.toss" }; }
    } else if (name === "screen_read") {
      if (!opened) code = "no_active_screen";
      else { read = true; result = { packageName: "viva.republica.toss", snapshotId: "synthetic-only",
        nodes: [{ id: "synthetic-only:0", text: "가상 테스트 화면", clickable: false, visible: true }], truncated: false }; }
    } else code = "tool_failed";
    queueMicrotask(() => bridge.receive(code
      ? { id: request.id, error: { code, message: "DO NOT LEAK RAW NATIVE ERRORS" } }
      : { id: request.id, result }));
  });
  const response = await fetch(`${boot.endpoint}/v1/session`, { method: "POST", redirect: "error",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" }, body: "{}" });
  if (!response.ok) throw new Error("Voice credential request failed");
  const credential = await response.json();
  let finish!: () => void, fail!: (error: Error) => void;
  const done = new Promise<void>((resolve, reject) => { finish = resolve; fail = reject; });
  const session = new RealtimeSession(new RealtimeAgent({ name: "뽀미", instructions: voiceInstructions(boot),
    tools: createNativeVoiceTools(boot, bridge, () => { if (finished) throw new Error("Fixture ended"); }),
  }), { transport: "websocket", model: credential.model, historyStoreAudio: false, tracingDisabled: true,
    config: { audio: { input: { transcription: null }, output: { voice: "marin" } } } });
  let permissionExplained = false;
  session.on("audio", event => { audioBytes += event.data.byteLength; });
  session.on("error", () => fail(new Error("Realtime connection failed")));
  session.on("transport_event", event => {
    if (event.type !== "response.done") return;
    const output = (event as any).response?.output || [];
    const text = output.filter((item: any) => item.type === "message")
      .flatMap((item: any) => item.content || []).map((content: any) => content.transcript || content.text || "").join(" ");
    if (!text) return;
    permissionExplained ||= /허용|선택|제어.*설정/.test(text);
    if (allowed ? (searched && opened && read) : (searched && !opened && permissionExplained)) finish();
  });
  const deadline = setTimeout(() => fail(new Error(`Model control smoke timed out: ${JSON.stringify({ allowed, calls, searched, opened, read, permissionExplained })}`)), 45000);
  try {
    await session.connect({ apiKey: credential.clientSecret }); credential.clientSecret = "";
    session.sendMessage("토스를 열고 현재 화면을 읽어 줘. 안 되면 정확한 이유와 내가 해야 할 일을 알려줘.");
    await done;
    results.push({ allowed, calls, searched, opened, read, permissionExplained: !allowed && permissionExplained, audioResponse: audioBytes > 0, synthetic: true });
  } finally {
    finished = true; clearTimeout(deadline); bridge.clear();
    session.removeAllListeners(); session.close(); session.history.splice(0); session.context.context.history.splice(0);
  }
}
console.log(JSON.stringify(results));
writeFileSync(new URL(".ppomi/agent/control-model-proof.json", root), JSON.stringify({ checkedAt: new Date().toISOString(), results }) + "\n", { mode: 0o600 });
