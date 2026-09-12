import assert from "node:assert/strict";
import { test } from "node:test";
import { PATH_SURFACES } from "../../ppomi-path/src/schema.ts";
import {
  ALLOWED_SERVES,
  DEFAULT_SERVES,
  DEFAULT_STALE_AFTER_MS,
  InMemoryDeviceRegistry,
  isFleetSurface,
  isOpaqueId,
  routeBody,
  routeBodyForSurface,
  type AttachResult,
  type DeviceSessionAttach,
  type FleetDevice,
  type FleetPresence,
} from "../src/index.ts";

const T0 = Date.parse("2026-09-11T10:00:00.000Z");
const personal = { ownerId: "owner_01" };
const family = { ownerId: "owner_01", orgId: "org_01" };

function fixedClock(start: number = T0): { now: () => number; advance: (ms: number) => void } {
  let now = start;
  return { now: () => now, advance: ms => { now += ms; } };
}

function presenceAt(now: number, staleAfterMs: number = DEFAULT_STALE_AFTER_MS): FleetPresence {
  return { clock: { now: () => now }, staleAfterMs };
}

function mac(overrides: Partial<FleetDevice> = {}): FleetDevice {
  return { id: "dev_mac_01", os: "macos", serves: DEFAULT_SERVES.macos, lastSeen: T0, ...family, ...overrides };
}

function win(overrides: Partial<FleetDevice> = {}): FleetDevice {
  return { id: "dev_win_01", os: "windows", serves: DEFAULT_SERVES.windows, lastSeen: T0, ...family, ...overrides };
}

function attached(result: AttachResult): FleetDevice {
  assert.equal(result.ok, true, result.ok ? undefined : `${result.code}: ${result.detail}`);
  if (!result.ok) throw new Error("unreachable");
  return result.device;
}

function refusalOf(result: AttachResult): string | null {
  return result.ok ? null : result.code;
}

test("route keys are exactly the ppomi-path surface ids", () => {
  for (const surface of PATH_SURFACES) assert.equal(isFleetSurface(surface), true);
  for (const alias of ["edge-cert", "windows", "macos", "android", "MACOS", "phone", "web", "device", "app", "parallels-guest"]) {
    assert.equal(isFleetSurface(alias), false, alias);
    const missed = routeBody(alias, [mac(), win()], presenceAt(T0));
    assert.equal(missed.ok, false);
    if (!missed.ok) assert.equal(missed.code, "unknown_surface");
  }
  for (const surfaces of [...Object.values(ALLOWED_SERVES), ...Object.values(DEFAULT_SERVES)]) {
    for (const surface of surfaces) assert.equal(isFleetSurface(surface), true);
  }
});

test("empty fleet does not route", () => {
  const missed = routeBody("iphone-mirroring", [], presenceAt(T0));
  assert.equal(missed.ok, false);
  if (!missed.ok) assert.equal(missed.code, "no_device");
});

test("mac-only fleet serves os-macos and iphone-mirroring, not os-windows", () => {
  const fleet = [mac()];
  for (const surface of ["os-macos", "iphone-mirroring"]) {
    const hit = routeBody(surface, fleet, presenceAt(T0));
    assert.equal(hit.ok, true);
    if (hit.ok) assert.equal(hit.device.id, "dev_mac_01");
  }
  const missed = routeBody("os-windows", fleet, presenceAt(T0));
  assert.equal(missed.ok, false);
  if (!missed.ok) assert.equal(missed.code, "no_device");
});

test("both online: iphone-mirroring → mac, os-windows → win", () => {
  const fleet = [mac(), win()];
  const mirror = routeBody("iphone-mirroring", fleet, presenceAt(T0));
  const windows = routeBody("os-windows", fleet, presenceAt(T0));
  assert.equal(mirror.ok && mirror.device.id, "dev_mac_01");
  assert.equal(windows.ok && windows.device.id, "dev_win_01");
});

test("os-android and page route only to a device that declares them", () => {
  const presence = presenceAt(T0);
  assert.equal(refusalCode(routeBody("os-android", [mac(), win()], presence)), "no_device");
  assert.equal(refusalCode(routeBody("page", [mac(), win()], presence)), "no_device");

  const adbHost = mac({ serves: ["os-macos", "os-android"] });
  const pageHost = win({ serves: ["os-windows", "page"] });
  const android = routeBody("os-android", [adbHost, pageHost], presence);
  const page = routeBody("page", [adbHost, pageHost], presence);
  assert.equal(android.ok && android.device.id, "dev_mac_01");
  assert.equal(page.ok && page.device.id, "dev_win_01");
});

test("online is derived from the clock and the staleness threshold", () => {
  const fleet = [mac({ lastSeen: T0 })];
  assert.equal(routeBody("os-macos", fleet, presenceAt(T0 + DEFAULT_STALE_AFTER_MS)).ok, true);
  const stale = routeBody("os-macos", fleet, presenceAt(T0 + DEFAULT_STALE_AFTER_MS + 1));
  assert.equal(refusalCode(stale), "no_online_device");
  assert.equal(routeBody("os-macos", fleet, presenceAt(T0 + 60_000, 30_000)).ok, false);
  assert.equal(routeBody("os-macos", fleet, presenceAt(T0 + 20_000, 30_000)).ok, true);
  assert.equal(DEFAULT_STALE_AFTER_MS, 5 * 60_000);
});

test("several serving devices: the most recently seen wins, compared as numbers", () => {
  // "09:00+09:00" is 00:00Z: lexicographically later than "01:00Z", older by the clock.
  const older = mac({ id: "dev_mac_01", lastSeen: Date.parse("2026-09-11T09:00:00+09:00") });
  const newer = mac({ id: "dev_mac_02", lastSeen: Date.parse("2026-09-11T01:00:00.000Z") });
  assert.equal(older.lastSeen < newer.lastSeen, true);
  const picked = routeBody("os-macos", [older, newer], presenceAt(newer.lastSeen, 2 * 60 * 60_000));
  assert.equal(picked.ok && picked.device.id, "dev_mac_02");
});

test("opaque ids only", () => {
  for (const id of ["dev_01", "owner_01", "org_01", "00000000-0000-4000-8000-000000000001", "user_2abc", "a"]) {
    assert.equal(isOpaqueId(id), true, id);
  }
  for (const id of [
    "user@example.com",
    "123-45-67890",
    "900101-1234567",
    "010-1234-5678",
    "Someone's MacBook Pro",
    "mac-studio.local",
    " padded ",
    "",
    "a".repeat(129),
  ]) {
    assert.equal(isOpaqueId(id), false, id);
  }
});

test("attach refuses malformed input with a code and stores nothing", () => {
  const fleet = new InMemoryDeviceRegistry({ clock: fixedClock() });
  const base: DeviceSessionAttach = { deviceId: "dev_01", os: "macos", ownerId: "owner_01" };
  const cases: readonly [Partial<DeviceSessionAttach> | { readonly os: string }, string][] = [
    [{ deviceId: "user@example.com" }, "invalid_device_id"],
    [{ deviceId: "123-45-67890" }, "invalid_device_id"],
    [{ deviceId: "Someone's MacBook Pro" }, "invalid_device_id"],
    [{ ownerId: "owner@example.com" }, "invalid_owner_id"],
    [{ orgId: "" }, "invalid_org_id"],
    [{ os: "linux" }, "invalid_os"],
    [{ os: "windows", serves: ["os-macos"] }, "invalid_surface"],
    [{ os: "ios", serves: ["page"] }, "invalid_surface"],
    [{ serves: ["edge-cert" as never] }, "invalid_surface"],
    [{ lastSeen: "not-a-date" }, "invalid_last_seen"],
  ];
  for (const [patch, code] of cases) {
    const result = fleet.attach({ ...base, ...patch } as DeviceSessionAttach);
    assert.equal(refusalOf(result), code, JSON.stringify(patch));
  }
  assert.deepEqual(fleet.list(personal), []);
});

test("attach stamps lastSeen from the registry clock, parses ISO, never in the future", () => {
  const clock = fixedClock();
  const fleet = new InMemoryDeviceRegistry({ clock });
  const stamped = attached(fleet.attach({ deviceId: "dev_01", os: "macos", ownerId: "owner_01" }));
  assert.equal(stamped.lastSeen, T0);
  assert.equal("online" in stamped, false);

  const reported = attached(fleet.attach({ deviceId: "dev_02", os: "windows", ownerId: "owner_01", lastSeen: "2026-09-11T18:30:00+09:00" }));
  assert.equal(reported.lastSeen, Date.parse("2026-09-11T09:30:00.000Z"));

  const future = attached(fleet.attach({ deviceId: "dev_03", os: "windows", ownerId: "owner_01", lastSeen: "2999-01-01T00:00:00.000Z" }));
  assert.equal(future.lastSeen, T0);
});

test("attach defaults capabilities by OS and accepts a narrower or wider declaration the OS allows", () => {
  const fleet = new InMemoryDeviceRegistry({ clock: fixedClock() });
  assert.deepEqual(attached(fleet.attach({ deviceId: "dev_mac_01", os: "macos", ownerId: "owner_01" })).serves, ["os-macos", "iphone-mirroring"]);
  assert.deepEqual(attached(fleet.attach({ deviceId: "dev_win_01", os: "windows", ownerId: "owner_01" })).serves, ["os-windows"]);
  assert.deepEqual(attached(fleet.attach({ deviceId: "dev_and_01", os: "android", ownerId: "owner_01" })).serves, []);
  assert.deepEqual(attached(fleet.attach({ deviceId: "dev_ios_01", os: "ios", ownerId: "owner_01" })).serves, []);
  assert.deepEqual(
    attached(fleet.attach({ deviceId: "dev_mac_02", os: "macos", ownerId: "owner_01", serves: ["os-macos", "os-android", "os-android"] })).serves,
    ["os-macos", "os-android"],
  );
  assert.deepEqual(attached(fleet.attach({ deviceId: "dev_and_02", os: "android", ownerId: "owner_01", serves: ["os-android"] })).serves, ["os-android"]);
});

test("attach never re-owns a device: another owner or org is owner_mismatch and the original stays", async () => {
  const fleet = new InMemoryDeviceRegistry({ clock: fixedClock() });
  attached(fleet.attach({ deviceId: "dev_01", os: "macos", ...family }));

  const otherOwner = fleet.attach({ deviceId: "dev_01", os: "windows", ownerId: "owner_02" });
  assert.equal(refusalOf(otherOwner), "owner_mismatch");
  const otherOrg = fleet.attach({ deviceId: "dev_01", os: "macos", ownerId: "owner_01", orgId: "org_02" });
  assert.equal(refusalOf(otherOrg), "owner_mismatch");
  const personalClaim = fleet.attach({ deviceId: "dev_01", os: "macos", ownerId: "owner_01" });
  assert.equal(refusalOf(personalClaim), "owner_mismatch");

  const kept = fleet.list(family);
  assert.equal(kept.length, 1);
  assert.equal(kept[0]?.os, "macos");
  assert.equal(kept[0]?.ownerId, "owner_01");
  assert.deepEqual(fleet.list({ ownerId: "owner_02" }), []);
  const route = await routeBodyForSurface(fleet, "os-windows", { ownerId: "owner_02" });
  assert.equal(refusalCode(route), "no_device");
});

test("same-owner re-attach refreshes lastSeen and serves; an OS change is os_mismatch", () => {
  const clock = fixedClock();
  const fleet = new InMemoryDeviceRegistry({ clock });
  attached(fleet.attach({ deviceId: "dev_01", os: "macos", ...family }));

  clock.advance(60_000);
  const again = attached(fleet.attach({ deviceId: "dev_01", os: "macos", ...family, serves: ["os-macos", "os-android"] }));
  assert.equal(again.lastSeen, T0 + 60_000);
  assert.deepEqual(again.serves, ["os-macos", "os-android"]);

  const older = attached(fleet.attach({ deviceId: "dev_01", os: "macos", ...family, lastSeen: "2026-09-11T09:00:00.000Z" }));
  assert.equal(older.lastSeen, T0 + 60_000);

  assert.equal(refusalOf(fleet.attach({ deviceId: "dev_01", os: "windows", ...family })), "os_mismatch");
  assert.equal(fleet.list(family)[0]?.os, "macos");
});

test("detach removes a device from its own scope only", () => {
  const fleet = new InMemoryDeviceRegistry({ clock: fixedClock() });
  attached(fleet.attach({ deviceId: "dev_01", os: "macos", ...family }));

  const foreign = fleet.detach("dev_01", { ownerId: "owner_02" });
  assert.equal(!foreign.ok && foreign.code, "not_found");
  const wrongScope = fleet.detach("dev_01", personal);
  assert.equal(!wrongScope.ok && wrongScope.code, "not_found");
  const badId = fleet.detach("someone@example.com", family);
  assert.equal(!badId.ok && badId.code, "invalid_device_id");
  assert.equal(fleet.list(family).length, 1);

  assert.deepEqual(fleet.detach("dev_01", family), { ok: true });
  assert.deepEqual(fleet.list(family), []);
  const gone = fleet.detach("dev_01", family);
  assert.equal(!gone.ok && gone.code, "not_found");
});

test("personal scope lists personal devices only; an org scope lists that org only", async () => {
  const fleet = new InMemoryDeviceRegistry({ clock: fixedClock() });
  attached(fleet.attach({ deviceId: "dev_personal", os: "macos", ownerId: "owner_01" }));
  attached(fleet.attach({ deviceId: "dev_org_a", os: "windows", ownerId: "owner_01", orgId: "org_a" }));
  attached(fleet.attach({ deviceId: "dev_org_b", os: "windows", ownerId: "owner_01", orgId: "org_b" }));

  assert.deepEqual(fleet.list(personal).map(device => device.id), ["dev_personal"]);
  assert.deepEqual(fleet.list({ ownerId: "owner_01", orgId: "org_a" }).map(device => device.id), ["dev_org_a"]);
  assert.deepEqual(fleet.list({ ownerId: "owner_01", orgId: "org_c" }), []);
  assert.deepEqual(fleet.list({ ownerId: "owner@example.com" }), []);

  assert.equal(refusalCode(await routeBodyForSurface(fleet, "os-windows", personal)), "no_device");
  const orgRoute = await routeBodyForSurface(fleet, "os-windows", { ownerId: "owner_01", orgId: "org_a" });
  assert.equal(orgRoute.ok && orgRoute.device.id, "dev_org_a");
});

test("login/session attach builds the fleet the brain routes from; a stale device drops out", async () => {
  const clock = fixedClock();
  const fleet = new InMemoryDeviceRegistry({ clock });
  attached(fleet.attach({ deviceId: "dev_mac_01", os: "macos", ...family }));
  clock.advance(60_000);
  attached(fleet.attach({ deviceId: "dev_win_01", os: "windows", ...family }));

  const mirror = await routeBodyForSurface(fleet, "iphone-mirroring", family);
  const windows = await routeBodyForSurface(fleet, "os-windows", family);
  assert.equal(mirror.ok && mirror.device.id, "dev_mac_01");
  assert.equal(windows.ok && windows.device.id, "dev_win_01");

  clock.advance(DEFAULT_STALE_AFTER_MS);
  assert.equal(refusalCode(await routeBodyForSurface(fleet, "iphone-mirroring", family)), "no_online_device");
  const stillWindows = await routeBodyForSurface(fleet, "os-windows", family);
  assert.equal(stillWindows.ok && stillWindows.device.id, "dev_win_01");

  const empty = await routeBodyForSurface(new InMemoryDeviceRegistry({ clock }), "iphone-mirroring", family);
  assert.equal(refusalCode(empty), "no_device");
});

function refusalCode(route: ReturnType<typeof routeBody>): string | null {
  return route.ok ? null : route.code;
}
