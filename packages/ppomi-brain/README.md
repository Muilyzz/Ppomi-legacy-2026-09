# ppomi-brain

Orchestration use-cases for Ppomi: **choose path → check grant → run body → emit/record**. Ports are injected. Unit tests use mocks only — no OS drivers, Clerk, or network.

This is not the chat UI, not Clerk UI, and not a second body/runtime.

## Layers

| Product | Role | Code today |
| --- | --- | --- |
| **ppomi-brain** | Orchestration (this package) | `packages/ppomi-brain` |
| **ppomi-chat** | Conversation UI | not this package |
| **ppomi-path** | Versioned path JSON catalog (미리 가본 길) | Catalog / `playbook-*` until MZZ-40 rename |
| **ppomi-body** | Observation + actuation + run (길을 걷는 몸) | `playbook-runtime` + `driver-*` / `ppomi-body-*` |
| **ppomi-account** | Org / seat session | injected port; Clerk UI stays out |

`ppomi-brain` talks to those neighbors through ports defined here. Concrete package names may still be `playbook-runtime` while MZZ-40 lands. Thin wiring to the current runtime lives in `src/wiring/` and tests only. Do not add an `adapter-*` product package.

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
