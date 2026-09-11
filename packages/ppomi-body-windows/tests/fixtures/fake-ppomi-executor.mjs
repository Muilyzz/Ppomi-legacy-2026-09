// Stand-in for `ppomi-executor --executor` speaking the measured JSONL protocol, for testing the
// synchronous bridge and session ordering without Windows. Behaviour copied from the real helper:
// `setControlApps` is idle-only (`protected_action` while active), `executeTool` needs an active
// session (`session_ended`), node ids are `<snapshotId>:<index>` and only the latest snapshot is
// addressable (`stale_screen`), and every `ui_tap` / `ui_type` answers `requiresScreenRead: true`.
import { createInterface } from "node:readline";

let active = false;
let allowed = new Set();
let snapshot = 0;
let latest = null;
let typed = "";
let tapped = false;
const app = { label: "fakeapp", packageName: "win:4242:1" };

function reply(id, result) {
  process.stdout.write(`${JSON.stringify({ id, result })}\n`);
}
function fail(id, code) {
  process.stdout.write(`${JSON.stringify({ id, error: { code, message: code } })}\n`);
}

function nodes() {
  snapshot += 1;
  latest = `fake${snapshot}`;
  const row = (index, text, role, clickable, editable) => ({
    id: `${latest}:${index}`, parentId: index === 0 ? null : `${latest}:0`, text, role, clickable, editable,
    visible: true, enabled: true, password: false, bounds: { left: 0, top: 0, right: 10, bottom: 10 },
  });
  return [
    row(0, "Fake App", "ControlType.Window", false, false),
    row(1, `Name ${typed}`.trim(), "ControlType.Edit", false, true),
    row(2, "Go", "ControlType.Button", true, false),
    row(3, tapped ? "tapped" : "idle", "ControlType.Text", false, false),
  ];
}

function tool(id, name, args) {
  if (!active) return fail(id, "session_ended");
  switch (name) {
    case "app_list":
      return reply(id, { apps: [{ ...app, allowed: allowed.has(app.packageName) }], truncated: false });
    case "app_open":
      if (!allowed.has(args.target)) return fail(id, "app_not_allowed");
      return reply(id, { packageName: app.packageName, activated: true });
    case "screen_read":
      if (!allowed.has(app.packageName)) return fail(id, "app_not_allowed");
      return reply(id, { snapshotId: `fake${snapshot + 1}`, packageName: app.packageName, appLabel: app.label, nodes: nodes(), truncated: false });
    case "ui_type":
    case "ui_tap": {
      const [snap, index] = String(args.nodeId).split(":");
      if (snap !== latest) return fail(id, "stale_screen");
      latest = null; // acted upon: the snapshot is spent until the next read
      if (name === "ui_type") {
        if (index !== "1") return fail(id, "protected_action");
        typed = String(args.text);
        return reply(id, { typed: true, requiresScreenRead: true });
      }
      if (index !== "2") return fail(id, "protected_action");
      tapped = true;
      return reply(id, { invoked: true, requiresScreenRead: true });
    }
    default:
      return fail(id, "invalid_request");
  }
}

createInterface({ input: process.stdin }).on("line", line => {
  let request;
  try { request = JSON.parse(line); } catch { return; }
  const { id, method, args } = request;
  switch (method) {
    case "sessionState":
      active = Boolean(args.active);
      if (!active) latest = null;
      return reply(id, { active, mode: args.mode });
    case "setControlApps":
      if (active) return fail(id, "protected_action");
      allowed = new Set(args.packageNames);
      return reply(id, { updated: true });
    case "executeTool":
      return tool(id, args.name, args.args ?? {});
    default:
      return fail(id, "invalid_request");
  }
});
process.stdin.on("end", () => process.exit(0));
