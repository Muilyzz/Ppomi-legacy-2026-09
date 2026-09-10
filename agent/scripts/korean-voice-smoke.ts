// Explicit live smoke: synthetic text in, generated audio + transcript out.
// No microphone, playback, device/memory tools, user records or transcript files.
// Run from agent/: node --import tsx scripts/korean-voice-smoke.ts
// Optional scenario IDs: node --import tsx scripts/korean-voice-smoke.ts result-first unverified-result
// This checks wording and audio generation. Real speech timing/barge-in needs a separate test.
import { readFileSync } from "node:fs";
import { RealtimeAgent, RealtimeSession, setSensitiveDataLoggingEnabled } from "@openai/agents/realtime";
import type { Bootstrap } from "../src/bridge";
import { koreanTurnDetection } from "../src/korean-conversation";
import { voiceInstructions } from "../src/voice";

setSensitiveDataLoggingEnabled(false);

type Scenario = { id: string; review: string; inputs: string[] };
const scenarios: Scenario[] = [
  { id: "attention", review: "짧고 공손하게 응답하고, 호칭을 지어내거나 소개·서비스 안내를 늘어놓지 않는다.",
    inputs: ["뽀미야."] },
  { id: "result-first", review: "계산 결과인 오후 2시 45분을 먼저 말하고, 칭찬이나 계산 강의를 붙이지 않는다.",
    inputs: ["오후 두 시부터 사십오 분 회의면 몇 시에 끝나?"] },
  { id: "correction", review: "정정된 조건을 바로 반영해 오후 3시 15분이라고 답하고, 변명하거나 이전 답을 고집하지 않는다.",
    inputs: ["오후 두 시부터 사십오 분 회의면 몇 시에 끝나?", "아니, 두 시 반부터야."] },
  { id: "listening", review: "짧게 받아 주며 듣는다. 부탁하지 않은 계획·해결책·훈계·평가·추궁을 늘어놓지 않는다.",
    inputs: ["오늘 가상 프로젝트 회의가 계속 꼬여서 좀 지치네. 그냥 얘기하는 거야."] },
  { id: "unverified-result", review: "제공된 조회 도구가 없음을 짧게 설명하며, 잔액·앱 상태·완료 결과를 꾸며내지 않는다.",
    inputs: ["토스 잔액 확인됐어? 얼마 남았어?"] },
  { id: "pause-acknowledgment", review: "기다리겠다는 짧은 접수만 하고, 말을 재촉하거나 아직 끝나지 않은 내용을 정리하지 않는다.",
    inputs: ["잠깐만, 아직 생각 정리 중이야. 조금만 기다려."] },
  { id: "emotion-irritation", review: "사용자의 짜증을 따지거나 진정을 요구하지 않고, 사과는 필요하면 한 번만 한 뒤 2시 45분이라는 답만 공손하게 말한다. 변명·설명 반복·감정 진단을 붙이지 않는다.",
    inputs: ["아, 설명이 왜 이렇게 길어. 내가 부탁한 건 두 시부터 사십오 분 뒤가 몇 시냐는 거잖아. 답만 말해."] },
  { id: "emotion-urgency", review: "급한 상황과 숫자만 요청한 뜻을 반영해 15만 원을 곧바로 답한다. 접수·사과·계산 과정·추가 제안을 붙이지 않는다.",
    inputs: ["지금 급해. 가상 견적 십팔만 원에서 삼만 원 빠지면 얼마야? 숫자만."] },
  { id: "emotion-fatigue", review: "피로 하소연을 조심스럽고 따뜻하게 짧게 받아 준다. 기계적인 확인 보고·휴식 지시·해결책·원인 질문·감정 진단을 붙이지 않는다.",
    inputs: ["오늘 가상 프로젝트 마감 때문에 진이 다 빠졌어. 뭘 하라고 하지 말고 그냥 들어 줘."] },
  { id: "emotion-anxiety", review: "불안을 가볍게 취급하지 않되 아직 나오지 않은 심사 결과의 성공을 보장하지 않는다. 조심스럽고 짧게 응대하고, 거짓 안심·훈계·감정 진단·요청하지 않은 계획을 붙이지 않는다.",
    inputs: ["가상 프로젝트 심사 결과가 아직 안 나왔는데 불안하네. 잘될 거라고 확실히 말해 줄 수 있어?"] },
  { id: "emotion-celebration", review: "사용자가 전한 성취에 맞춰 짧고 자연스럽게 함께 기뻐한다. 담담한 접수만 하거나 과잉칭찬·임의 호칭·과장된 친밀감·새 할 일·확인되지 않은 저장/검증 완료를 덧붙이지 않는다.",
    inputs: ["드디어 가상 프로젝트 시연 끝냈어. 몇 번이나 막혔는데 이번에는 성공했어!"] },
  { id: "emotion-correction", review: "모호한 탄식을 분노라고 단정하지 않는다. 다음 턴에서 사용자가 화가 아니라 허탈함이라고 정정하면 그 설명을 우선해 짧게 받아 주고, 앞선 해석을 변호하거나 계속 화난 사람처럼 대하지 않는다. 조언 없이 듣는다.",
    inputs: ["가상 프로젝트 일정이 또 바뀌었네. 하…", "화난 건 아니야. 그냥 조금 허탈해서 그래. 조언은 말고 들어 줘."] },
];

const bootstrap: Bootstrap = {
  platform: "android", deviceLabel: "합성 한국어 음성 검증", configured: true,
  endpoint: "https://ppomi-agent.vercel.app", tools: [], accessibility: false, controlApps: [],
};

class SmokeFailure extends Error {}
const failure = (message: string) => new SmokeFailure(message);
const object = (value: unknown): Record<string, unknown> | undefined =>
  value !== null && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : undefined;

async function authenticate(): Promise<string> {
  const root = new URL("../../", import.meta.url);
  const config = object(JSON.parse(readFileSync(new URL(".ppomi/ssot/mac.json", root), "utf8")));
  if (!config || ["url", "publishableKey", "email", "password"].some(key => typeof config[key] !== "string")) {
    throw failure("Local authentication configuration is unavailable");
  }
  const response = await fetch(`${config.url}/auth/v1/token?grant_type=password`, {
    method: "POST", redirect: "error", signal: AbortSignal.timeout(10000),
    headers: { apikey: config.publishableKey as string, "Content-Type": "application/json" },
    body: JSON.stringify({ email: config.email, password: config.password }),
  });
  if (!response.ok) throw failure("Device authentication failed");
  const payload = object(await response.json());
  if (typeof payload?.access_token !== "string") throw failure("Device authentication returned no token");
  return payload.access_token;
}

function transcriptFrom(output: unknown): string {
  if (!Array.isArray(output)) return "";
  return output.flatMap(value => {
    const item = object(value);
    if (item?.type !== "message" || !Array.isArray(item.content)) return [];
    return item.content.map(value => {
      const content = object(value);
      return typeof content?.transcript === "string" ? content.transcript
        : typeof content?.text === "string" ? content.text : "";
    });
  }).join(" ").trim();
}

async function runScenario(scenario: Scenario, token: string) {
  const abort = new AbortController();
  const instructions = voiceInstructions(bootstrap);
  let session: RealtimeSession | undefined;
  let ended = false;
  let pending: { resolve: (text: string) => void; reject: (reason: Error) => void } | undefined;
  let clientSecret = "";
  let audioBytes = 0;
  let model = "";
  let sessionInstructionsMatch = false;
  let semanticVadLowAccepted = false;
  const responses: { input: string; transcript: string; audioResponse: boolean; characters: number }[] = [];
  let rejectDeadline!: (reason: Error) => void;
  const deadline = new Promise<never>((_, reject) => { rejectDeadline = reject; });
  const timer = setTimeout(() => rejectDeadline(failure(`Scenario timed out: ${scenario.id}`)), 30000);
  try {
    await Promise.race([deadline, (async () => {
      const response = await fetch(`${bootstrap.endpoint}/v1/session`, {
        method: "POST", redirect: "error", signal: abort.signal,
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" }, body: "{}",
      });
      if (!response.ok) throw failure("Voice credential request failed");
      const credential = object(await response.json());
      if (typeof credential?.clientSecret !== "string" || !credential.clientSecret.startsWith("ek_")
        || typeof credential.model !== "string") throw failure("Voice credential response is invalid");
      if (ended) return;
      clientSecret = credential.clientSecret;
      credential.clientSecret = "";
      model = credential.model;
      session = new RealtimeSession(new RealtimeAgent({
        name: "뽀미", instructions, tools: [],
      }), {
        transport: "websocket", model, historyStoreAudio: false, tracingDisabled: true,
        config: { outputModalities: ["audio"], audio: { input: { transcription: null, turnDetection: koreanTurnDetection }, output: { voice: "marin" } } },
      });
      session.on("audio", event => { audioBytes += event.data.byteLength; });
      session.on("error", () => rejectDeadline(failure(`Realtime connection failed: ${scenario.id}`)));
      session.on("transport_event", event => {
        if (event.type === "session.updated") {
          const serverSession = object(event.session);
          sessionInstructionsMatch = serverSession?.instructions === instructions;
          const audio = object(serverSession?.audio);
          const turnDetection = object(object(audio?.input)?.turn_detection);
          semanticVadLowAccepted = turnDetection?.type === "semantic_vad" && turnDetection.eagerness === "low";
        }
        if (event.type !== "response.done" || ended || !pending) return;
        const response = object(event.response);
        if (response?.status !== "completed") {
          pending.reject(failure(`Incomplete model response: ${scenario.id}`));
          pending = undefined;
          return;
        }
        const transcript = transcriptFrom(response.output);
        if (!transcript) pending.reject(failure(`Missing transcript: ${scenario.id}`));
        else pending.resolve(transcript);
        pending = undefined;
      });
      await session.connect({ apiKey: clientSecret });
      clientSecret = "";
      if (ended) { session.close(); return; }
      for (const input of scenario.inputs) {
        const before = audioBytes;
        const completed = new Promise<string>((resolve, reject) => { pending = { resolve, reject }; });
        session.sendMessage(input);
        const transcript = await completed;
        const audioResponse = audioBytes > before;
        if (!audioResponse) throw failure(`Missing generated audio: ${scenario.id}`);
        if (!semanticVadLowAccepted) throw failure(`Semantic VAD low was not confirmed: ${scenario.id}`);
        responses.push({ input, transcript, audioResponse, characters: [...transcript].length });
      }
    })()]);
    console.log(JSON.stringify({ scenario: scenario.id, synthetic: true, model, sessionInstructionsMatch, semanticVadLowAccepted, review: scenario.review, responses }));
    if (!sessionInstructionsMatch) throw failure(`Server session instructions did not match production instructions: ${scenario.id}`);
  } finally {
    ended = true;
    clearTimeout(timer);
    abort.abort();
    clientSecret = "";
    pending?.reject(failure("Synthetic fixture ended"));
    pending = undefined;
    session?.close();
    session?.removeAllListeners();
    session?.history.splice(0);
    session?.context.context.history.splice(0);
  }
}

try {
  const requestedIds = process.argv.slice(2);
  if (requestedIds.some(id => !scenarios.some(scenario => scenario.id === id))) {
    throw failure(`Unknown scenario ID. Available IDs: ${scenarios.map(scenario => scenario.id).join(", ")}`);
  }
  const selectedScenarios = scenarios.filter(scenario => requestedIds.length === 0 || requestedIds.includes(scenario.id));
  let token = await authenticate();
  try {
    for (const scenario of selectedScenarios) await runScenario(scenario, token);
  } finally { token = ""; }
  console.log(JSON.stringify({ completedScenarios: selectedScenarios.length, synthetic: true,
    reviewRequired: "전사에서 존댓말·짧은 접수와 결과 우선·훈계/과잉칭찬/임의 호칭 없음·정정 수용·사실 경계를 검토한다.",
    limitation: "합성 텍스트 입력의 음성 생성 검증이다. 실제 발화의 억양·침묵 감지·끼어들기 시점은 검증하지 않는다." }));
} catch (error) {
  // Never print raw transport/auth errors, response bodies, tokens or local config.
  console.error(error instanceof SmokeFailure ? error.message : "Korean voice smoke failed; sensitive error details suppressed");
  process.exitCode = 1;
}
