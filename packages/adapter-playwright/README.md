# adapter-playwright

In-page `BrowserPageAdapter` for `playbook-runtime`. Maps `goto` / `click` / `fill` / `waitFor` onto Playwright page methods.

This is not `OsAdapter`, not a second playbook-runtime package, and not a generic `adapter` / `browser-util` package.

## When to use Playwright vs an OS adapter

Hybrid agent automation. Pick the port from the surface, not from the app name.

| Surface | Port | Package |
| --- | --- | --- |
| Web page DOM (URL, locators, forms, in-page buttons) | `BrowserPageAdapter` | **this package** |
| OS / native chrome, cert/security dialogs, UIA or Accessibility trees | `OsAdapter` (`readScreen` / `focus` / `click` / `type`) | `adapter-windows`, `adapter-macos` |

Do **not** replace the OS adapters with Playwright. A Korean certificate window, a native file picker, or a browser OS dialog is still UIA/AX. An in-page "Next" button is Playwright.

`PlaybookRuntime` drives `OsAdapter`. `PagePlaybookRuntime` drives `BrowserPageAdapter`. Same permissions, stop, and evidence. Different step shape (`target` vs `locator` / `url`).

## Device-local execution

Runs on the user's machine (or a device-local VM). This is **not** a Vercel / cloud browser. Slice 1 does not launch Chromium; tests use `FixturePlaywrightPage`. Slice 2 may start a local Chrome/Edge. Do not add a hosted browser service here.

## Mapping

| `BrowserPageAdapter` | Playwright page (slice 2) | Slice 1 fixture |
| --- | --- | --- |
| `goto(url)` | `page.goto(url)` | switch in-memory document |
| `click(locator)` | `page.locator(locator).click()` | click a fixture node |
| `fill(locator, text)` | `page.locator(locator).fill(text)` | fill a fixture node |
| `waitFor(locator)` | `page.locator(locator).waitFor()` | require a visible fixture node |
| `readPage()` | url / title / visible locator texts | in-memory snapshot |

Live Playwright stays out of this slice. Tests use `FixturePlaywrightPage` (in-memory documents + locators). They do not download browsers, start Chrome, or call a cloud browser.

## Out of scope

- Live Chrome / Edge smoke (slice 2)
- AI SDK tool wrapping
- `playbook-kr-cert` content
- Replacing `adapter-windows` / `adapter-macos`
- Device-approval / Mac-approver / hub login
- Package titles `core`, `common`, `engine`, `util`, `shared`, `adapter`, `runtime`, or `browser-util`

```ts
import { FixedPermissionGate, PagePlaybookRuntime } from "../playbook-runtime/src/index.ts";
import { FixturePlaywrightPage, PlaywrightPageAdapter } from "adapter-playwright";

const tools = new FixturePlaywrightPage([
  {
    url: "https://example.test/form",
    title: "Demo Page",
    nodes: [{ locator: "#next", text: "Next", clickable: true, fillable: false }],
  },
]);
const result = new PagePlaybookRuntime(
  new PlaywrightPageAdapter(tools),
  new FixedPermissionGate(["ui.read", "ui.control"]),
).run({
  id: "demo",
  steps: [{ id: "go", kind: "click", locator: "#next" }],
});
```

## Tests

```sh
npm --prefix packages/adapter-playwright test
```
