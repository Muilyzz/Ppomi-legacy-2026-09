import { DEVICE_OS, type DeviceListScope, type DeviceOs, type DeviceRegistry, type DeviceSessionAttach, type FleetDevice } from "./ports.ts";

/** Path / body surface names the router understands. Unknown surfaces fail closed. */
export type BodyRouteSurface =
  | "iphone-mirroring"
  | "macos"
  | "os-macos"
  | "windows"
  | "os-windows"
  | "edge-cert"
  | "android"
  | "os-android";

export type BodyRoute =
  | { readonly ok: true; readonly device: FleetDevice }
  | { readonly ok: false; readonly reason: string };

export function isDeviceOs(value: string): value is DeviceOs {
  return (DEVICE_OS as readonly string[]).includes(value);
}

export function preferredOsForSurface(surface: string): DeviceOs | null {
  switch (surface) {
    case "iphone-mirroring":
    case "macos":
    case "os-macos":
      return "macos";
    case "windows":
    case "os-windows":
    case "edge-cert":
      return "windows";
    case "android":
    case "os-android":
      return "android";
    default:
      return null;
  }
}

/**
 * Pick an online device for a path surface. Caller passes an already-scoped fleet
 * (Grok ListMachines analogue: surface → machineId).
 */
export function routeBody(surface: string, fleet: readonly FleetDevice[]): BodyRoute {
  const os = preferredOsForSurface(surface);
  if (os === null) {
    return { ok: false, reason: `unknown body surface: ${surface}` };
  }

  const matches = fleet.filter(device => device.os === os);
  if (matches.length === 0) {
    return { ok: false, reason: `no ${os} device in fleet for ${surface}` };
  }

  const online = matches.filter(device => device.online);
  if (online.length === 0) {
    return { ok: false, reason: `no online ${os} device for ${surface}` };
  }

  // ponytail: newest lastSeen when several share an OS; split by capability later
  return { ok: true, device: newestSeen(online) };
}

export async function routeBodyForSurface(
  registry: DeviceRegistry,
  surface: string,
  scope: DeviceListScope,
): Promise<BodyRoute> {
  return routeBody(surface, await registry.list(scope));
}

/** In-memory fleet. Same attach/list shape a durable upsert will implement later. */
export class InMemoryDeviceRegistry implements DeviceRegistry {
  private readonly devices = new Map<string, FleetDevice>();

  attach(input: DeviceSessionAttach): FleetDevice {
    const deviceId = input.deviceId.trim();
    const ownerId = input.ownerId.trim();
    if (deviceId.length === 0) throw new Error("deviceId is required");
    if (ownerId.length === 0) throw new Error("ownerId is required");
    if (!isDeviceOs(input.os)) throw new Error(`unknown device os: ${input.os}`);

    const record: FleetDevice = {
      id: deviceId,
      os: input.os,
      online: true,
      lastSeen: input.lastSeen ?? new Date().toISOString(),
      ownerId,
      ...(input.orgId !== undefined ? { orgId: input.orgId } : {}),
    };
    this.devices.set(deviceId, record);
    return record;
  }

  list(scope: DeviceListScope): readonly FleetDevice[] {
    return [...this.devices.values()].filter(device => {
      if (device.ownerId !== scope.ownerId) return false;
      if (scope.orgId !== undefined && device.orgId !== scope.orgId) return false;
      return true;
    });
  }
}

function newestSeen(devices: readonly FleetDevice[]): FleetDevice {
  return devices.reduce((best, next) => (next.lastSeen > best.lastSeen ? next : best));
}
