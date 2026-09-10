import { test } from "node:test";
import assert from "node:assert/strict";
import { NativeBridge } from "./bridge";
import { VoiceController } from "./voice";

test("ending during microphone permission releases late tracks and never requests a credential", async () => {
  let microphoneResolve!: (s: MediaStream) => void;
  const original = Object.getOwnPropertyDescriptor(globalThis, "navigator");
  Object.defineProperty(globalThis, "navigator", {
    configurable: true,
    value: {
      mediaDevices: {
        getUserMedia: () =>
          new Promise<MediaStream>((resolve) => {
            microphoneResolve = resolve;
          }),
      },
    },
  });
  const methods: string[] = [];
  let stopped = 0;
  const bridge = new NativeBridge((raw) => {
    const message = JSON.parse(raw);
    methods.push(message.method);
    queueMicrotask(() =>
      bridge.receive({
        id: message.id,
        result: message.method === "bootstrap" ? {
          platform: "android", deviceLabel: "fixture", configured: true,
          endpoint: "https://example.com", tools: [],
        } : { active: message.args.active },
      }),
    );
  });
  const states: string[] = [];
  const voice = new VoiceController(
    bridge,
    (s) => states.push(s),
    () => assert.fail("cancellation is not an error"),
  );
  try {
    const starting = voice.start({
      platform: "android",
      deviceLabel: "fixture",
      configured: true,
      endpoint: "https://example.com",
      tools: [],
    });
    await new Promise<void>((resolve) => setImmediate(resolve));
    await voice.stop();
    microphoneResolve({
      getTracks: () => [
        {
          stop: () => {
            stopped++;
          },
        },
      ],
    } as unknown as MediaStream);
    await starting;
    assert.equal(stopped, 1);
    assert.deepEqual(methods, ["bootstrap", "sessionState", "sessionState"]);
    assert.equal(states.at(-1), "idle");
    assert.equal(bridge.pendingCount, 0);
  } finally {
    if (original) Object.defineProperty(globalThis, "navigator", original);
    else Reflect.deleteProperty(globalThis, "navigator");
  }
});

