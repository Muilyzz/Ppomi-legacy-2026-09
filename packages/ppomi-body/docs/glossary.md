# Product glossary

**FINAL** locked names (2026-09-11). Canonical packages are `ppomi-body` and `ppomi-body-*` only. Do not revert to `driver-*`.

| Product | Meaning | Code |
| --- | --- | --- |
| **ppomi-path** | domain recipes (미리 가본 길) as a versioned JSON catalog | `ppomi-path` + `catalogs/paths/` |
| **ppomi-body** | runtime + OS/page drivers (길을 걷는 몸) | `ppomi-body` + `ppomi-body-*` |
| eye / hand | modules inside a body package, **not** separate packages | driver implementation internals |
| workbench | execution record UI (작업대) | app |

Ports stay `OsUiDriver` and `BrowserPageDriver`. See [docs/ppomi-path-body.md](../../../docs/ppomi-path-body.md).
