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

Grok Bot `ListMachines` analogue **inside the product**. Clerk is who. Each Mac/Windows app login/session attach is where. Brain maps a path surface to an online body.

| Layer | Role |
| --- | --- |
| Clerk | **who** |
| App login / `DeviceRegistry.attach` | **where** (Mac and Windows must each attach) |
| `routeBody` / `routeBodyForSurface` | surface → online device |

Account-only is not a fleet. Empty or offline fleet → no route (`ok: false` + reason). No Mac-approval gate.

| Surface | Preferred OS |
| --- | --- |
| `iphone-mirroring` | macos |
| `windows` / `edge-cert` | windows |

`InMemoryDeviceRegistry` is the test fake. A later store implements the same attach upsert. Attach takes device id, OS, owner/org — no tokens, and nothing here logs secrets.

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
