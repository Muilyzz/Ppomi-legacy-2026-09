import assert from "node:assert/strict";
import { test } from "node:test";
import {
  InMemoryDeviceRegistry,
  preferredOsForSurface,
  routeBody,
  routeBodyForSurface,
  type FleetDevice,
} from "../src/index.ts";

const owner = { ownerId: "owner-1", orgId: "org-family" };

function mac(overrides: Partial<FleetDevice> = {}): FleetDevice {
  return {
    id: "mac-1",
    os: "macos",
    online: true,
    lastSeen: "2026-09-11T10:00:00.000Z",
    ...owner,
    ...overrides,
  };
}

function win(overrides: Partial<FleetDevice> = {}): FleetDevice {
  return {
    id: "win-1",
    os: "windows",
    online: true,
    lastSeen: "2026-09-11T10:00:00.000Z",
    ...owner,
    ...overrides,
  };
}

test("empty fleet does not route", () => {
  const missed = routeBody("iphone-mirroring", []);
  assert.equal(missed.ok, false);
  if (!missed.ok) {
    assert.equal(missed.reason, "no macos device in fleet for iphone-mirroring");
  }
});

test("mac-only fleet routes iphone-mirroring to the mac", () => {
  const hit = routeBody("iphone-mirroring", [mac()]);
  assert.equal(hit.ok, true);
  if (hit.ok) {
    assert.equal(hit.device.id, "mac-1");
    assert.equal(hit.device.os, "macos");
  }

  const missed = routeBody("windows", [mac()]);
  assert.equal(missed.ok, false);
  if (!missed.ok) {
    assert.equal(missed.reason, "no windows device in fleet for windows");
  }
});

test("win-only fleet routes windows / edge-cert to the windows body", () => {
  const fleet = [win()];
  const windows = routeBody("windows", fleet);
  const cert = routeBody("edge-cert", fleet);
  assert.equal(windows.ok, true);
  assert.equal(cert.ok, true);
  if (windows.ok) assert.equal(windows.device.id, "win-1");
  if (cert.ok) assert.equal(cert.device.id, "win-1");

  const missed = routeBody("iphone-mirroring", fleet);
  assert.equal(missed.ok, false);
});

test("both online: iphone-mirroring → mac, windows → win", () => {
  const fleet = [mac(), win()];
  const mirror = routeBody("iphone-mirroring", fleet);
  const windows = routeBody("windows", fleet);
  assert.equal(mirror.ok, true);
  assert.equal(windows.ok, true);
  if (mirror.ok) assert.equal(mirror.device.id, "mac-1");
  if (windows.ok) assert.equal(windows.device.id, "win-1");
});

test("offline devices do not route", () => {
  const missed = routeBody("iphone-mirroring", [mac({ online: false })]);
  assert.equal(missed.ok, false);
  if (!missed.ok) {
    assert.equal(missed.reason, "no online macos device for iphone-mirroring");
  }
});

test("unknown surface fails closed", () => {
  const missed = routeBody("page", [mac(), win()]);
  assert.equal(missed.ok, false);
  if (!missed.ok) {
    assert.equal(missed.reason, "unknown body surface: page");
  }
});

test("login/session attach upserts the machine; brain routes from that fleet", async () => {
  const fleet = new InMemoryDeviceRegistry();
  const attached = fleet.attach({
    deviceId: "mac-studio",
    os: "macos",
    ownerId: owner.ownerId,
    orgId: owner.orgId,
    lastSeen: "2026-09-11T12:00:00.000Z",
  });
  assert.equal(attached.online, true);
  assert.equal(attached.id, "mac-studio");
  assert.equal("token" in attached, false);
  assert.equal("password" in attached, false);

  fleet.attach({
    deviceId: "win-tower",
    os: "windows",
    ownerId: owner.ownerId,
    orgId: owner.orgId,
    lastSeen: "2026-09-11T12:01:00.000Z",
  });
  fleet.attach({
    deviceId: "mac-studio",
    os: "macos",
    ownerId: owner.ownerId,
    orgId: owner.orgId,
    lastSeen: "2026-09-11T13:00:00.000Z",
  });

  const listed = fleet.list(owner);
  assert.equal(listed.length, 2);
  assert.equal(listed.find(device => device.id === "mac-studio")?.lastSeen, "2026-09-11T13:00:00.000Z");
  assert.equal(fleet.list({ ownerId: "other-user" }).length, 0);

  const mirror = await routeBodyForSurface(fleet, "iphone-mirroring", owner);
  const windows = await routeBodyForSurface(fleet, "windows", owner);
  assert.equal(mirror.ok, true);
  assert.equal(windows.ok, true);
  if (mirror.ok) assert.equal(mirror.device.id, "mac-studio");
  if (windows.ok) assert.equal(windows.device.id, "win-tower");

  const empty = await routeBodyForSurface(new InMemoryDeviceRegistry(), "iphone-mirroring", owner);
  assert.equal(empty.ok, false);
});

test("surface → OS table matches the product lock", () => {
  assert.equal(preferredOsForSurface("iphone-mirroring"), "macos");
  assert.equal(preferredOsForSurface("windows"), "windows");
  assert.equal(preferredOsForSurface("edge-cert"), "windows");
  assert.equal(preferredOsForSurface("os-windows"), "windows");
  assert.equal(preferredOsForSurface("page"), null);
});
