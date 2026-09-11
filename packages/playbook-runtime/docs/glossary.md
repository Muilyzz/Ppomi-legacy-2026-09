# Product glossary

Locked names for Ppomi. This is **not** a general SDK — package and port hygiene for Ppomi.

| Product | Meaning | Code |
| --- | --- | --- |
| **ppomi-path** | domain recipes (미리 가본 길) | `playbook-*` |
| **ppomi-body** | runtime + drivers (observation+actuation+run) (길을 걷는 몸) | `playbook-runtime` + `driver-*` |
| eye / hand | modules inside a driver, **not** separate packages | driver implementation internals |
| workbench | execution record UI (작업대) | app |

- **ppomi-path** / **ppomi-body** are the product terms. Do not invent a third product name for recipes or the runtime.
- eye and hand live inside a `driver-*` package. Do not publish `eye-*` or `hand-*` packages.
- `executors/windows` is the native host. It is not a driver package and is not renamed.

On this tip, the OS port is `OsUiDriver` (was `OsAdapter`) and the page port is `BrowserPageDriver` (was `BrowserPageAdapter`).

## Sibling PR rename follow-up

This tip (`cursor/playbook-emit-step-result-ce13`, PR #18) only has `packages/adapter-playwright`, renamed here to `packages/driver-playwright`.

These `adapter-*` packages live only on unmerged sibling PRs. They are **not** renamed in this slice — do not merge the stacked PRs just to finish the rename.

| Sibling path (unmerged) | PR | Target path |
| --- | --- | --- |
| `packages/adapter-windows` | #7 (live follow-up #15) | `packages/driver-windows` |
| `packages/adapter-macos` | #10 | `packages/driver-macos` |
| `packages/adapter-android` | #20 | `packages/driver-android` |
| `packages/adapter-iphone-mirroring` | #21 | `packages/driver-iphone-mirroring` |

When those PRs land or rebase onto this tip, rename the package directory, `package.json` name, and `OsUiDriver` / `BrowserPageDriver` imports there.
