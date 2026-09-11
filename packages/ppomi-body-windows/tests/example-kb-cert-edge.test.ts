import assert from "node:assert/strict";
import { test } from "node:test";
import {
  EDGE_IMAGE_NAME,
  closeDecision,
  edgeArgs,
  openInEdge,
  parseTasklistCsv,
  type EdgeChild,
  type EdgePorts,
} from "../example/src/kb-cert-edge.ts";

const URL = "https://example.test/quics?page=C000000";
const EDGE = "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe";
const TEMP_PROFILE = "C:\\Temp\\ppomi-kb-cert-edge-abc123";

function tasklistRow(imageName: string, pid: number): string {
  return `"${imageName}","${pid}","Console","1","123,456 K"\r\n`;
}

interface FakePorts extends EdgePorts {
  readonly calls: string[];
  readonly spawned: { exe: string; args: readonly string[] }[];
  readonly killed: number[];
}

function fakePorts(options: {
  readonly pid?: number | undefined;
  readonly exited?: boolean;
  readonly tasklist?: string | null;
  readonly taskkillStatus?: number;
  readonly rmFailures?: number;
}): FakePorts {
  const pid = "pid" in options ? options.pid : 4242;
  let rmFailures = options.rmFailures ?? 0;
  const ports: FakePorts = {
    calls: [],
    spawned: [],
    killed: [],
    spawn(exe, args) {
      ports.calls.push("spawn");
      ports.spawned.push({ exe, args });
      const child: EdgeChild = { pid, exited: () => options.exited ?? false };
      return child;
    },
    tasklist(queried) {
      ports.calls.push(`tasklist ${queried}`);
      return options.tasklist === undefined ? tasklistRow(EDGE_IMAGE_NAME, queried) : options.tasklist;
    },
    taskkill(target) {
      ports.calls.push(`taskkill ${target}`);
      ports.killed.push(target);
      return options.taskkillStatus ?? 0;
    },
    mkdtemp() {
      ports.calls.push("mkdtemp");
      return TEMP_PROFILE;
    },
    rm(dir) {
      ports.calls.push(`rm ${dir}`);
      if (rmFailures > 0) {
        rmFailures -= 1;
        throw new Error("EBUSY");
      }
    },
    async sleep(ms) {
      ports.calls.push(`sleep ${ms}`);
    },
  };
  return ports;
}

test("default: one new window in the person's profile, nothing queried, nothing killed", async () => {
  const ports = fakePorts({});
  const result = await openInEdge({ edge: EDGE, url: URL, closeEdge: false, ports });
  assert.equal(result.status, "left-open");
  assert.deepEqual(ports.calls, ["spawn"]);
  assert.deepEqual(ports.spawned, [{ exe: EDGE, args: ["--no-first-run", "--no-default-browser-check", "--new-window", URL] }]);
  assert.equal(result.args.some(arg => arg.startsWith("--user-data-dir=")), false);
  assert.deepEqual(ports.killed, []);
  assert.match(result.lines[0] ?? "", /opened Edge https:\/\/example\.test\/quics \(your profile\)/);
  assert.doesNotMatch(result.lines.join("\n"), /page=C000000/);
  assert.match(result.lines[1] ?? "", /left open for the person — nothing is closed/);
});

test("opt-in close: isolated mkdtemp profile, tasklist confirms msedge.exe on our pid, then that pid only", async () => {
  const ports = fakePorts({ pid: 4242 });
  const result = await openInEdge({ edge: EDGE, url: URL, closeEdge: true, ports });
  assert.equal(result.status, "closed");
  assert.deepEqual(ports.spawned[0]?.args, [
    `--user-data-dir=${TEMP_PROFILE}`,
    "--no-first-run",
    "--no-default-browser-check",
    "--new-window",
    URL,
  ]);
  assert.deepEqual(ports.calls, ["mkdtemp", "spawn", "tasklist 4242", "taskkill 4242", `rm ${TEMP_PROFILE}`]);
  assert.deepEqual(ports.killed, [4242]);
  assert.match(result.lines[1] ?? "", /closed the isolated Edge instance/);
});

test("opt-in close refuses when the pid is gone, exited, unknown, or not msedge.exe; taskkill is never reached", async () => {
  const cases: { readonly name: string; readonly ports: FakePorts; readonly reason: RegExp }[] = [
    { name: "no pid", ports: fakePorts({ pid: undefined }), reason: /no pid/ },
    { name: "exited", ports: fakePorts({ exited: true }), reason: /already exited/ },
    { name: "tasklist failed", ports: fakePorts({ tasklist: null }), reason: /tasklist unavailable/ },
    {
      name: "pid not running",
      ports: fakePorts({ tasklist: "INFO: No tasks are running which match the specified criteria.\r\n" }),
      reason: /pid is not running/,
    },
    { name: "pid reused by another image", ports: fakePorts({ tasklist: tasklistRow("notepad.exe", 4242) }), reason: /pid is notepad\.exe, not msedge\.exe/ },
    { name: "row for a different pid", ports: fakePorts({ tasklist: tasklistRow(EDGE_IMAGE_NAME, 4243) }), reason: /pid is not running/ },
  ];
  for (const { name, ports, reason } of cases) {
    const result = await openInEdge({ edge: EDGE, url: URL, closeEdge: true, ports });
    assert.equal(result.status, "not-closed", name);
    assert.deepEqual(ports.killed, [], name);
    assert.equal(ports.calls.some(call => call.startsWith("taskkill")), false, name);
    assert.match(result.lines[1] ?? "", reason, name);
    assert.match(result.lines[1] ?? "", /close the isolated window yourself/, name);
  }
});

test("opt-in close: a failing taskkill is reported, a busy profile dir is retried and never fails the run", async () => {
  const failed = fakePorts({ taskkillStatus: 128 });
  const failedResult = await openInEdge({ edge: EDGE, url: URL, closeEdge: true, ports: failed });
  assert.equal(failedResult.status, "not-closed");
  assert.match(failedResult.lines[1] ?? "", /taskkill exit 128/);
  assert.equal(failed.calls.some(call => call.startsWith("rm")), false);

  const busy = fakePorts({ rmFailures: 2 });
  const busyResult = await openInEdge({ edge: EDGE, url: URL, closeEdge: true, ports: busy });
  assert.equal(busyResult.status, "closed");
  assert.deepEqual(busy.calls.filter(call => call.startsWith("rm")).length, 3);
  assert.deepEqual(busy.calls.filter(call => call.startsWith("sleep")), ["sleep 500", "sleep 500"]);
});

test("closeDecision never closes outside an isolated profile, whatever tasklist says", () => {
  const alive: EdgeChild = { pid: 4242, exited: () => false };
  assert.deepEqual(
    closeDecision({ isolated: false, child: alive, tasklistOutput: tasklistRow(EDGE_IMAGE_NAME, 4242) }),
    { close: false, reason: "not an isolated profile" },
  );
  assert.equal(closeDecision({ isolated: true, child: alive, tasklistOutput: tasklistRow("MSEDGE.EXE", 4242) }).close, true);
});

test("parseTasklistCsv reads the CSV row for the pid only; the memory column's comma is not a separator", () => {
  const output = `INFO: header noise\r\n${tasklistRow("msedge.exe", 4242)}${tasklistRow("msedge.exe", 4300)}`;
  assert.deepEqual(parseTasklistCsv(output, 4242), { imageName: "msedge.exe", pid: 4242 });
  assert.deepEqual(parseTasklistCsv(output, 4300), { imageName: "msedge.exe", pid: 4300 });
  assert.equal(parseTasklistCsv(output, 4301), null);
  assert.equal(parseTasklistCsv("INFO: No tasks are running which match the specified criteria.\r\n", 4242), null);
  assert.equal(parseTasklistCsv("", 4242), null);
  assert.deepEqual(edgeArgs(URL, undefined), ["--no-first-run", "--no-default-browser-check", "--new-window", URL]);
});
