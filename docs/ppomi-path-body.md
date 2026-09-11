# path = JSON catalog, body = ppomi-body*

**FINAL** naming lock (2026-09-11). Canonical packages are `ppomi-body` and `ppomi-body-*` only. Do not revert to `driver-*`. Clerk / MZZ-39 is a separate track.

| Product | Meaning | Code |
| --- | --- | --- |
| **path** | Versioned global JSON recipes (미리 가본 길) | `ppomi-path` (schema + load/validate) + `catalogs/paths/` |
| **body** | Walks a path (observe + act + run) | `ppomi-body` + `ppomi-body-*` |

## Body packages

| Package | Was | Role |
| --- | --- | --- |
| `ppomi-body` | `playbook-runtime` | Execution, `StepResult`, step-type registry, `OsUiDriver` / `BrowserPageDriver` |
| `ppomi-body-windows` | `adapter-windows` / `driver-windows` | Windows UIA (sibling PRs) |
| `ppomi-body-macos` | `adapter-macos` / `driver-macos` | macOS AX (sibling PRs) |
| `ppomi-body-android` | `adapter-android` | Android (sibling PRs) |
| `ppomi-body-iphone-mirroring` | `adapter-iphone-mirroring` | iPhone Mirroring (sibling PRs) |
| `ppomi-body-playwright` | `adapter-playwright` / `driver-playwright` | In-page Playwright |

Native OS boundaries stay separate packages. Do not invent `adapter` / `adaptor` types or package titles. Ports stay `OsUiDriver` and `BrowserPageDriver`.

`playbook-runtime` is a deprecated re-export of `ppomi-body`. Sibling surface packages rename in place to `ppomi-body-*`.

## Path catalog

Do not add new domain `playbook-*` packs. Absorb them into versioned JSON:

```text
catalogs/paths/
  index.json
  kr-cert/0.1.0.json
  kb-star-biz-iphone/0.1.0.json
```

`kr-cert@0.1.0` is the first absorbed fixture (`playbook-kr-cert`). `kb-star-biz-iphone@0.1.0` is the first iPhone Mirroring path (human login, masked account read, no payment). Full pack absorption and app/hub wiring are follow-up slices.

See also [`packages/ppomi-body/docs/glossary.md`](../packages/ppomi-body/docs/glossary.md).
