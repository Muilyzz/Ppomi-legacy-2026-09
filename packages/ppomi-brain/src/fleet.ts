import { PATH_SURFACES } from "../../ppomi-path/src/schema.ts";
import {
  DEVICE_OS,
  type AttachRefusal,
  type AttachResult,
  type DetachRefusal,
  type DetachResult,
  type DeviceListScope,
  type DeviceOs,
  type DeviceRegistry,
  type DeviceSessionAttach,
  type FleetClock,
  type FleetDevice,
  type FleetPresence,
  type FleetSurface,
} from "./ports.ts";

/** Presence window when the registry is not told otherwise: two missed app heartbeats. */
export const DEFAULT_STALE_AFTER_MS = 5 * 60_000;

const OPAQUE_ID = /^[A-Za-z0-9_-]{1,128}$/;
/** Digit groups joined by dashes: 사업자등록번호, 주민등록번호, phone numbers. Never an id here. */
const DIGIT_GROUPS = /^\d+(?:-\d+)+$/;
/** The product's device ids are UUIDs; an all-digit one is still a UUID, not a number. */
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DETAIL_LIMIT = 64;

/** Opaque product ids only: no `@`, dots, quotes or whitespace, and no digit-dash number shapes. */
export function isOpaqueId(value: string): boolean {
  return OPAQUE_ID.test(value) && (UUID.test(value) || !DIGIT_GROUPS.test(value));
}

export function isDeviceOs(value: string): value is DeviceOs {
  return (DEVICE_OS as readonly string[]).includes(value);
}

/** The route keys are exactly the `ppomi-path` surface ids. Aliases belong in path data, not here. */
export function isFleetSurface(value: string): value is FleetSurface {
  return (PATH_SURFACES as readonly string[]).includes(value);
}

/**
 * Surfaces an OS may declare. OS-bound surfaces only by that OS; `os-android` by the host that
 * drives the phone (adb) or the phone's own executor; `page` by whoever runs a page body.
 */
export const ALLOWED_SERVES: Readonly<Record<DeviceOs, readonly FleetSurface[]>> = {
  macos: ["os-macos", "iphone-mirroring", "os-android", "page"],
  windows: ["os-windows", "os-android", "page"],
  android: ["os-android", "page"],
  ios: [],
};

/** What a device serves when it declares nothing: its own screen; a Mac also mirrors an iPhone. */
export const DEFAULT_SERVES: Readonly<Record<DeviceOs, readonly FleetSurface[]>> = {
  macos: ["os-macos", "iphone-mirroring"],
  windows: ["os-windows"],
  android: [],
  ios: [],
};

export type BodyRouteCode = "unknown_surface" | "no_device" | "no_online_device";

export type BodyRoute =
  | { readonly ok: true; readonly device: FleetDevice }
  | { readonly ok: false; readonly code: BodyRouteCode; readonly detail: string };

export function isOnline(device: FleetDevice, presence: FleetPresence): boolean {
  return presence.clock.now() - device.lastSeen <= presence.staleAfterMs;
}

/**
 * Pick an online device that serves a path surface. The caller passes an already-scoped
 * fleet; presence comes from the registry clock, never from a flag on the device.
 */
export function routeBody(surface: string, fleet: readonly FleetDevice[], presence: FleetPresence): BodyRoute {
  if (!isFleetSurface(surface)) {
    return { ok: false, code: "unknown_surface", detail: `not a ppomi-path surface: ${clip(surface)}` };
  }
  const serving = fleet.filter(device => device.serves.includes(surface));
  if (serving.length === 0) {
    return { ok: false, code: "no_device", detail: `no device in fleet serves ${surface}` };
  }
  const online = serving.filter(device => isOnline(device, presence));
  if (online.length === 0) {
    return { ok: false, code: "no_online_device", detail: `no online device serves ${surface}` };
  }
  return { ok: true, device: newestSeen(online) };
}

export async function routeBodyForSurface(
  registry: DeviceRegistry,
  surface: string,
  scope: DeviceListScope,
): Promise<BodyRoute> {
  return routeBody(surface, await registry.list(scope), registry.presence);
}

export interface InMemoryDeviceRegistryOptions {
  readonly clock?: FleetClock;
  readonly staleAfterMs?: number;
}

/** In-memory fleet. A durable store keeps the same refusals and the same presence rule. */
export class InMemoryDeviceRegistry implements DeviceRegistry {
  readonly presence: FleetPresence;
  private readonly devices = new Map<string, FleetDevice>();

  constructor(options: InMemoryDeviceRegistryOptions = {}) {
    this.presence = {
      clock: options.clock ?? { now: () => Date.now() },
      staleAfterMs: options.staleAfterMs ?? DEFAULT_STALE_AFTER_MS,
    };
  }

  attach(input: DeviceSessionAttach): AttachResult {
    if (!isOpaqueId(input.deviceId)) return refuseAttach("invalid_device_id", "deviceId must be an opaque device id");
    if (!isOpaqueId(input.ownerId)) return refuseAttach("invalid_owner_id", "ownerId must be an opaque auth subject");
    if (input.orgId !== undefined && !isOpaqueId(input.orgId)) return refuseAttach("invalid_org_id", "orgId must be an opaque org id");
    if (!isDeviceOs(input.os)) return refuseAttach("invalid_os", `unknown device os: ${clip(String(input.os))}`);

    const serves = input.serves ?? DEFAULT_SERVES[input.os];
    const allowed = ALLOWED_SERVES[input.os];
    const unserved = serves.find(surface => !isFleetSurface(surface) || !allowed.includes(surface));
    if (unserved !== undefined) return refuseAttach("invalid_surface", `${input.os} cannot serve ${clip(String(unserved))}`);

    const now = this.presence.clock.now();
    let lastSeen = now;
    if (input.lastSeen !== undefined) {
      const reported = Date.parse(input.lastSeen);
      if (!Number.isFinite(reported)) return refuseAttach("invalid_last_seen", "lastSeen must be an ISO 8601 timestamp");
      lastSeen = Math.min(reported, now);
    }

    const existing = this.devices.get(input.deviceId);
    if (existing !== undefined) {
      if (existing.ownerId !== input.ownerId || existing.orgId !== input.orgId) {
        return refuseAttach("owner_mismatch", "device is attached to another owner or org");
      }
      if (existing.os !== input.os) return refuseAttach("os_mismatch", `device is registered as ${existing.os}`);
      lastSeen = Math.max(existing.lastSeen, lastSeen);
    }

    const record: FleetDevice = {
      id: input.deviceId,
      os: input.os,
      serves: [...new Set(serves)],
      lastSeen,
      ownerId: input.ownerId,
      ...(input.orgId !== undefined ? { orgId: input.orgId } : {}),
    };
    this.devices.set(input.deviceId, record);
    return { ok: true, device: record };
  }

  /** Removes a device from its own scope. A foreign or missing id is `not_found`: no existence oracle. */
  detach(deviceId: string, scope: DeviceListScope): DetachResult {
    if (!isOpaqueId(deviceId)) return refuseDetach("invalid_device_id", "deviceId must be an opaque device id");
    const invalidScope = scopeRefusal(scope);
    if (invalidScope !== null) return refuseDetach(invalidScope, "scope ids must be opaque ids");
    const existing = this.devices.get(deviceId);
    if (existing === undefined || !inScope(existing, scope)) return refuseDetach("not_found", "no such device in this scope");
    this.devices.delete(deviceId);
    return { ok: true };
  }

  /** An invalid scope lists nothing. */
  list(scope: DeviceListScope): readonly FleetDevice[] {
    if (scopeRefusal(scope) !== null) return [];
    return [...this.devices.values()].filter(device => inScope(device, scope));
  }
}

function inScope(device: FleetDevice, scope: DeviceListScope): boolean {
  return device.ownerId === scope.ownerId && device.orgId === scope.orgId;
}

function scopeRefusal(scope: DeviceListScope): Extract<DetachRefusal, "invalid_owner_id" | "invalid_org_id"> | null {
  if (!isOpaqueId(scope.ownerId)) return "invalid_owner_id";
  if (scope.orgId !== undefined && !isOpaqueId(scope.orgId)) return "invalid_org_id";
  return null;
}

function refuseAttach(code: AttachRefusal, detail: string): AttachResult {
  return { ok: false, code, detail };
}

function refuseDetach(code: DetachRefusal, detail: string): DetachResult {
  return { ok: false, code, detail };
}

function newestSeen(devices: readonly FleetDevice[]): FleetDevice {
  return devices.reduce((best, next) => (next.lastSeen > best.lastSeen ? next : best));
}

function clip(text: string): string {
  return text.length > DETAIL_LIMIT ? `${text.slice(0, DETAIL_LIMIT)}…` : text;
}
