// Fault-injecting stand-in for `ppomi-executor --executor`, for exercising the synchronous bridge's
// failure paths on any platform. Faults are selected through the `app_list` query string:
//   "slow"  – answer this request after 400 ms (long past a short requestTimeoutMs)
//   "wedge" – answer once, then stop reading stdin and stay alive (never exits on EOF)
// Any other query answers immediately. The happy-path protocol lives in `fake-ppomi-executor.mjs`.
import { createInterface } from "node:readline";

let active = false;
const app = { label: "fakeapp", packageName: "win:4242:1" };

function reply(id, result) {
  process.stdout.write(`${JSON.stringify({ id, result })}\n`);
}

const listing = { apps: [{ ...app, allowed: false }], truncated: false };
const rl = createInterface({ input: process.stdin });

rl.on("line", line => {
  let request;
  try { request = JSON.parse(line); } catch { return; }
  const { id, method, args } = request;
  switch (method) {
    case "sessionState":
      active = Boolean(args.active);
      return reply(id, { active, mode: args.mode });
    case "executeTool": {
      if (!active) return process.stdout.write(`${JSON.stringify({ id, error: { code: "session_ended", message: "session_ended" } })}\n`);
      const query = args.name === "app_list" ? String(args.args?.query ?? "") : "";
      if (query === "slow") { setTimeout(() => reply(id, listing), 400); return; }
      if (query === "wedge") {
        reply(id, listing);
        rl.close();
        process.stdin.destroy(); // stop reading: further writes are unanswered, and EOF is never observed
        setInterval(() => {}, 1 << 30);
        return;
      }
      return reply(id, listing);
    }
    default:
      return process.stdout.write(`${JSON.stringify({ id, error: { code: "invalid_request", message: "invalid_request" } })}\n`);
  }
});

process.stdin.on("end", () => process.exit(0));
