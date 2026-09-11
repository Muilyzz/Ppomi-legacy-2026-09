import assert from "node:assert/strict";
import { test } from "node:test";
import {
  LiveMacosNativeTools,
  MacosAdapterError,
  pickLiveAxClickTarget,
  type LiveAxNode,
  type LiveMacosCommand,
  type LiveMacosReply,
} from "../src/index.ts";

const link: LiveAxNode = {
  text: "More information...",
  role: "link",
  clickable: true,
  editable: false,
  password: false,
  web: true,
  bounds: { left: 20, top: 80, right: 180, bottom: 104 },
};

const field: LiveAxNode = {
  text: "Search",
  role: "edit",
  clickable: false,
  editable: true,
  password: false,
  web: true,
  bounds: { left: 20, top: 120, right: 300, bottom: 150 },
};

function toolsOver(handler: (command: LiveMacosCommand) => LiveMacosReply): { tools: LiveMacosNativeTools; commands: LiveMacosCommand[] } {
  const commands: LiveMacosCommand[] = [];
  const tools = new LiveMacosNativeTools({
    app: "Safari",
    exec: command => {
      commands.push(command);
      return handler(command);
    },
  });
  return { tools, commands };
}

const readReply: LiveMacosReply = {
  ok: true,
  result: { appLabel: "Safari", packageName: "com.apple.Safari", truncated: false, nodes: [link, field] },
};

function code(error: unknown): string | undefined {
  return error instanceof MacosAdapterError ? error.code : undefined;
}

// The checked node's identity travels with the action; the script re-resolves the element live and
// refuses when it no longer matches. Stored coordinates are never sent, so a stale point cannot be clicked.
test("gate: tap and type carry the read-time role/label, never coordinates", () => {
  const { tools, commands } = toolsOver(command => {
    if (command.op === "read") return readReply;
    if (command.op === "tap") return { ok: true, result: { invoked: true } };
    if (command.op === "type") return { ok: true, result: { typed: true } };
    return { ok: false, code: "failed", message: command.op };
  });
  const screen = tools.screen_read();
  tools.ui_tap({ nodeId: screen.nodes[0]!.id });
  const tap = commands.find(command => command.op === "tap");
  assert.deepEqual(tap, { op: "tap", app: "Safari", index: 0, web: true, role: "link", label: "More information..." });
  assert.equal("x" in (tap as object), false);

  const fresh = tools.screen_read();
  tools.ui_type({ nodeId: fresh.nodes[1]!.id, text: "hello\tworld" });
  const type = commands.find(command => command.op === "type");
  assert.deepEqual(type, { op: "type", app: "Safari", index: 1, role: "edit", label: "Search", text: "hello\tworld" });
});

// MacUI.parseType allows no control character but `\t`; through the System Events keystroke fallback a
// `\n` is Return, i.e. a form submit the gate never saw.
test("gate: ui_type refuses newline and other control characters before anything is sent", () => {
  const { tools, commands } = toolsOver(command => {
    if (command.op === "read") return readReply;
    return { ok: true, result: { typed: true } };
  });
  const screen = tools.screen_read();
  for (const text of ["submit\n", "submit\r", "a\u0000b", "del\u007f", "c1\u0085"]) {
    assert.equal(code(assertThrows(() => tools.ui_type({ nodeId: screen.nodes[1]!.id, text }))), "protected_action", JSON.stringify(text));
  }
  assert.equal(commands.some(command => command.op === "type"), false);
});

// The live 1-step must click only the known example.com link; a different tab or window yields no
// target at all instead of "any link" / "any button".
test("gate: pickLiveAxClickTarget never falls back to an arbitrary link or button", () => {
  const otherPage = [
    { id: "a", text: "Log out", clickable: true, editable: false, role: "link" },
    { id: "b", text: "Delete", clickable: true, editable: false, role: "button" },
    { id: "c", text: "More information...", clickable: true, editable: false, role: "link" },
  ];
  assert.equal(pickLiveAxClickTarget(otherPage), undefined, "link present but not the example.com page");
  assert.equal(pickLiveAxClickTarget(otherPage.slice(0, 2)), undefined, "no fallback to Log out / Delete");
  const examplePage = [
    { id: "h", text: "Example Domain", clickable: false, editable: false, role: "heading" },
    { id: "b", text: "Delete", clickable: true, editable: false, role: "button" },
    { id: "c", text: "More information...", clickable: true, editable: false, role: "link" },
  ];
  assert.equal(pickLiveAxClickTarget(examplePage)?.id, "c");
  assert.equal(pickLiveAxClickTarget(examplePage.filter(node => node.id !== "c")), undefined, "example page without the link");
});

function assertThrows(block: () => unknown): unknown {
  try {
    block();
  } catch (error) {
    return error;
  }
  assert.fail("expected an error");
}
