import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { chromium, type Browser } from "playwright";
import { LivePlaywrightPage } from "../src/playwright-live-page.ts";

const EXAMPLE_URL = "https://example.com/";
const packageRoot = join(dirname(fileURLToPath(import.meta.url)), "..");

/**
 * Device-local Chromium smoke. Not a Vercel / cloud browser.
 * `npm test` stays fixture-only; run this via `npm run test:live`.
 */
async function main(): Promise<void> {
  const browser = await launchLocalChromium();
  try {
    const page = await browser.newPage();
    const tools = new LivePlaywrightPage(page);

    await tools.goto({ url: EXAMPLE_URL });
    await tools.waitFor({ locator: "h1" });
    const snapshot = await tools.readPage();

    if (!/example\.com/i.test(snapshot.url)) {
      throw new Error(`expected example.com url, got ${snapshot.url}`);
    }
    if (!/example domain/i.test(snapshot.title)) {
      throw new Error(`expected Example Domain title, got ${JSON.stringify(snapshot.title)}`);
    }

    console.log("adapter-playwright live smoke: PASS");
    console.log(`  goto ${EXAMPLE_URL}`);
    console.log("  waitFor h1");
    console.log(`  title ${snapshot.title}`);
    console.log(`  url ${snapshot.url}`);
  } finally {
    await browser.close();
  }
}

async function launchLocalChromium(): Promise<Browser> {
  try {
    return await chromium.launch(launchOptions());
  } catch (error) {
    if (!isMissingBrowser(error)) throw error;
    installChromium();
    return await chromium.launch(launchOptions());
  }
}

function launchOptions(): { headless: true; args: string[] } {
  return {
    headless: true,
    args: ["--no-sandbox", "--disable-dev-shm-usage"],
  };
}

function isMissingBrowser(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error);
  return /executable doesn't exist|browserType\.launch/i.test(message);
}

function installChromium(): void {
  console.log("Chromium missing; running npx playwright install chromium");
  const install = spawnSync(
    process.execPath,
    [join(packageRoot, "node_modules/playwright/cli.js"), "install", "chromium"],
    { cwd: packageRoot, stdio: "inherit" },
  );
  if (install.status !== 0) {
    throw new Error("playwright install chromium failed");
  }
}

main().catch(error => {
  const message = error instanceof Error ? error.message : String(error);
  console.error("adapter-playwright live smoke: FAIL");
  console.error(`  ${message}`);
  process.exitCode = 1;
});
