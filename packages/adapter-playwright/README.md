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

Runs on the user's machine (or a device-local VM). This is **not** a Vercel / cloud browser. Do not add a hosted browser service here.

`npm test` is fixture-only and does not download browsers, start Chrome, or call a cloud browser. Live Chromium is a separate script.

## Mapping

| `BrowserPageAdapter` | Live Playwright (`LivePlaywrightPage`) | Fixture (`FixturePlaywrightPage`) |
| --- | --- | --- |
| `goto(url)` | `page.goto(url)` | switch in-memory document |
| `click(locator)` | `page.locator(locator).click()` | click a fixture node |
| `fill(locator, text)` | `page.locator(locator).fill(text)` | fill a fixture node |
| `waitFor(locator)` | `page.locator(locator).waitFor()` | require a visible fixture node |
| `readPage()` | url / title / visible `h1` text | in-memory snapshot |

`PlaywrightPageAdapter` stays a sync `BrowserPageAdapter` for fixtures and `PagePlaybookRuntime`. Live callers `await` `LivePlaywrightPage` (Playwright's `Page` is async).

## Out of scope

- AI SDK tool wrapping
- `playbook-kr-cert` content
- Replacing `adapter-windows` / `adapter-macos`
- Device-approval / Mac-approver / hub login
- OS vs Playwright playbook selection rules (later slice)
- Package titles `core`, `common`, `engine`, `util`, `shared`, `adapter`, `runtime`, or `browser-util`

```ts
import { chromium } from "playwright";
import { LivePlaywrightPage } from "adapter-playwright";

const browser = await chromium.launch();
const tools = new LivePlaywrightPage(await browser.newPage());
await tools.goto({ url: "https://example.com/" });
await tools.waitFor({ locator: "h1" });
const page = await tools.readPage();
await browser.close();
```

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

Hermetic unit tests (no browser):

```sh
npm --prefix packages/adapter-playwright test
```

Live Chromium smoke on this machine (`https://example.com` → `waitFor(h1)` → read title). Installs Playwright's Chromium if it is missing. Not a Vercel browser.

```sh
npm --prefix packages/adapter-playwright install
npx --prefix packages/adapter-playwright playwright install chromium
npm --prefix packages/adapter-playwright run test:live
# or
PLAYWRIGHT_LIVE=1 npm --prefix packages/adapter-playwright run test:live
```
