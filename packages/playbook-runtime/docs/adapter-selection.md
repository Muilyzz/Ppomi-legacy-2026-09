# Playwright vs OS adapter

Pick the port from the **surface**, not the app name or site. One playbook-runtime package; two ports; two runners. Do not fold Playwright into `OsAdapter`. Do not raise a single multi-platform library as the playbook contract.

| Surface | Runner | Port | Package |
| --- | --- | --- | --- |
| In-page web DOM, forms, locator waits | `PagePlaybookRuntime` | `BrowserPageAdapter` (`goto` / `click` / `fill` / `waitFor` / `readPage`) | `adapter-playwright` |
| Native windows, system dialogs, cert UI, non-DOM chrome | `PlaybookRuntime` | `OsAdapter` (`readScreen` / `focus` / `click` / `type`) | `adapter-windows` (UIA), `adapter-macos` (AX), `adapter-android` (accessibility) |

Same `ui.read` / `ui.control`, fail-closed stop, and evidence. Different step shape: page `locator` / `url` vs OS `target`.

## In-page web → Playwright

Use `PagePlaybookRuntime` + `adapter-playwright` when the control lives in the page DOM:

- Navigate (`goto`)
- Click an in-page button or link (`click` + locator)
- Fill a form field (`fill`)
- Wait for a locator (`waitFor`)
- Read url / title / visible text (`readPage`)

An in-page "Next" button is Playwright. Do not drive that button through UIA/AX screen text.

## Native / system chrome → OS adapter

Use `PlaybookRuntime` + `adapter-windows`, `adapter-macos`, or `adapter-android` when the control is outside the page DOM:

- Native application windows
- System dialogs (file picker, permission, print)
- Certificate / security-module UI (including Korean cert helper windows)
- Browser chrome that is not DOM (OS dialogs attached to the browser process)
- Android app chrome via accessibility (`android_screen` / `android_click` / `android_type` / `android_open`). Pixel `android_tap` / `android_swipe` are not playbook selectors.

Those steps use screen text / focus `target`, not CSS locators. Do not replace the OS adapters with Playwright. A cert window, a native file picker, a browser OS dialog, or an Android accessibility tree is still UIA/AX/Android.

## Hybrid handoff

A single user task may cross both surfaces. Sequence the two runtimes; do not merge the ports.

1. In-page: Playwright `goto` / `click` that *requests* a native flow (for example an in-page "인증서 로그인" button).
2. Stop waiting on the page for a DOM result that cannot appear until the native window is dismissed.
3. Watch for the native window with `OsAdapter.readScreen` (UIA/AX).
4. Finish the native steps with `PlaybookRuntime`.
5. Return to `PagePlaybookRuntime` to read the page result.

The handoff is an explicit execution state (page → native → page). There is no combined hybrid runner in this package.

**Do not deadlock.** Do not leave Playwright blocked in `waitFor` on a locator that only appears after a native modal is handled. The native modal is not in the DOM; Playwright cannot dismiss it. Hand off to the OS adapter first, then resume the page wait. Do not treat a Playwright timeout as "the native step never ran" and retry — especially not a signing or certificate step.

## Stable contracts (not coordinates)

Permanent playbook contracts are:

- Page: locators (role / CSS / text) and URL
- OS: accessibility / UIA names and screen text (`target`)

Do **not** store click coordinates, pixel boxes, or session-specific node IDs as playbook selectors. Layout, DPI, and window size change. A VLM coordinate candidate is an observation, not a contract.

Vision, OCR, and VLM (`screen_inspect`) are **fallbacks** when the DOM or accessibility tree is missing or custom-drawn. They are not the default control path. Image/OCR/vision complement UIA/AX and Playwright; they do not replace them.

## Anti-patterns

- Coordinates as a permanent playbook contract
- A large abstraction layer before a real hybrid flow exists (compose the two runtimes; do not invent a third)
- Timeout = "not executed" → automatic retry, especially on signing
- Implementing Playwright as `OsAdapter`, or replacing UIA/AX with Playwright
- Elevating one multi-platform automation library as the playbook contract

## Local AI SDK tools (in-page only)

`adapter-playwright` exposes the page operations as local Vercel AI SDK tools (`createPlaywrightPageAiTools`: `goto` / `click` / `fill` / `waitFor` / `readPage`). Agents pass that tool set to `ToolLoopAgent` / `generateText` on this machine. The tools call Playwright here. They are not a Vercel / cloud browser.

These tools are in-page DOM only. Native windows, cert UI, and system dialogs stay on `OsAdapter` (`readScreen` / `focus` / `click` / `type`). Do not add those OS operations to the Playwright tool set.

## Out of scope here

- Agent session / hub login wiring
- `playbook-kr-cert` content
- Live Mac/Windows UIA changes
- Vercel / cloud browser
