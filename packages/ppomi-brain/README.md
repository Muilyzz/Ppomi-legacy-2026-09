# ppomi-brain

Orchestration use-cases for Ppomi: **choose path → check grant → run body → emit/record**. Ports are injected. Unit tests use mocks only — no OS drivers, Clerk, or network.

This is not the chat UI, not Clerk UI, and not a second body/runtime.

## Layers

| Product | Role | Code today |
| --- | --- | --- |
| **ppomi-brain** | Orchestration (this package) | `packages/ppomi-brain` |
| **ppomi-chat** | Conversation UI | not this package |
| **ppomi-path** | Versioned path JSON catalog (미리 가본 길) | `packages/ppomi-path` + `catalogs/paths/` |
| **ppomi-body** | Observation + actuation + run (길을 걷는 몸) | `ppomi-body` + `ppomi-body-*` |
| **ppomi-account** | Org / seat session | injected port; Clerk UI stays out |

`ppomi-brain` talks to those neighbors through ports defined here. Thin wiring to `ppomi-body` lives in `src/wiring/` and tests only. Do not add an `adapter-*` / `driver-*` product package.

## Device fleet (MZZ-50)

Clerk is who. Each Mac/Windows app login/session attach is where. Brain maps a path surface to an online device that serves it.

| Layer | Role |
| --- | --- |
| Clerk | **who** |
| App login / `DeviceRegistry.attach` | **where** (Mac and Windows must each attach) |
| `routeBody` / `routeBodyForSurface` | `ppomi-path` surface → online device that declares it |

Account-only is not a fleet. No serving device, or none online → `ok: false` with a `code` (`unknown_surface` · `no_device` · `no_online_device`). No Mac-approval gate.

**Surfaces** are the `ppomi-path` ids only — `os-macos`, `os-windows`, `os-android`, `iphone-mirroring`, `page` — no aliases (`edge-cert`, bare OS names) in the brain; an alias is path data. Devices declare what they serve (`serves`), limited by OS:

| Surface | Served by |
| --- | --- |
| `os-macos`, `iphone-mirroring` | a macOS device (both are its defaults) |
| `os-windows` | a Windows device (default) |
| `os-android` | the host that drives the phone over adb, or the phone's own executor — only if declared |
| `page` | any device that declares a page body |

**Presence** is derived, never stored: `online = clock.now() − lastSeen ≤ staleAfterMs` (default `DEFAULT_STALE_AFTER_MS`, 5 min) on the registry's injected clock. `lastSeen` is epoch ms; a device-reported ISO stamp is parsed, refused if unparsable, and never ahead of the clock.

**Attach refuses** (`ok: false`, `code`): a `deviceId` already attached to another owner/org (`owner_mismatch`) or another OS (`os_mismatch`); ids that are not opaque (`invalid_*`: no `@`, dots, whitespace, display names or digit-dash 사업자등록번호 shapes); surfaces the OS cannot serve. Same-owner re-attach refreshes `lastSeen` and `serves`. `detach(deviceId, scope)` removes a device from its own scope; a foreign id is `not_found`.

**Scopes:** `{ ownerId }` is personal and lists personal devices only; `{ ownerId, orgId }` lists that org only. Never both.

`InMemoryDeviceRegistry` is the test fake; a durable store keeps the same refusals and presence rule. The port carries device id, OS, owner/org, capabilities and a timestamp — no tokens — and nothing here logs.

## Grant and payment HITL (MZZ-38)

- Path match is not a permission. A **narrow grant** is fixed before `BodyRuntime.run`.
- Brain must not widen a grant or honor `financial_submit` on an agent grant.
- `confirm_payment` is a **human handoff**. It does not unlock automatic final submit.
- Payment-like body steps stop as `needs_human` / `protected`. Brain will not treat a mocked auto-submit as success.

## Tests

```sh
npm --prefix packages/ppomi-brain test
npm --prefix packages/ppomi-brain run typecheck
```
