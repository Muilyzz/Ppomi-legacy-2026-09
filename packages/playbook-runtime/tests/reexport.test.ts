import assert from "node:assert/strict";
import { test } from "node:test";
import { DummyAdapter, FixedPermissionGate, OsSurface, Runtime } from "../src/index.ts";

test("deprecated playbook-runtime re-exports ppomi-body", async () => {
  const runtime = new Runtime(
    new OsSurface(new DummyAdapter({ title: "Demo", texts: ["Next"], focused: null }, "os-windows")),
    new FixedPermissionGate(["ui.read", "ui.control"]),
  );
  const result = await runtime.run({
    id: "demo",
    steps: [{ id: "go", kind: "click", target: "Next", effect: "navigate" }],
  });
  assert.equal(result.status, "completed");
});
