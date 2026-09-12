import { existsSync } from "node:fs";
import type { IncomingMessage, ServerResponse } from "node:http";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vite";
import { fixtureResponses } from "./src/chat.ts";
import { proxyResponses } from "./src/gateway.ts";

const agentSrc = fileURLToPath(new URL("../agent/src", import.meta.url));
const agentModule = (name: string) => fileURLToPath(new URL(`../agent/node_modules/${name}`, import.meta.url));

if (!existsSync(agentModule("react"))) {
  throw new Error("shell UI reuses agent/src/ui — run: npm --prefix agent ci");
}

const tailwindcss = (await import(agentModule("@tailwindcss/vite/dist/index.mjs"))).default;

function readJson(req: IncomingMessage): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    req.on("data", chunk => { chunks.push(chunk as Buffer); });
    req.on("end", () => {
      const raw = Buffer.concat(chunks).toString("utf8").trim();
      if (raw === "") { resolve({}); return; }
      try { resolve(JSON.parse(raw) as unknown); } catch (error) { reject(error); }
    });
    req.on("error", reject);
  });
}

function json(res: ServerResponse, status: number, body: unknown): void {
  res.statusCode = status;
  res.setHeader("content-type", "application/json");
  res.end(JSON.stringify(body));
}

function previewGateway() {
  const attach = (server: { middlewares: { use: (fn: (req: IncomingMessage, res: ServerResponse, next: () => void) => void) => void } }) => {
    server.middlewares.use((req, res, next) => {
      const url = req.url?.split("?")[0] ?? "";
      if (url !== "/__ppomi/responses" && url !== "/__ppomi/gateway") { next(); return; }
      void (async () => {
        if (url === "/__ppomi/gateway") {
          json(res, 200, await proxyResponses({ probe: true }));
          return;
        }
        if (req.method !== "POST") { json(res, 405, { configured: false }); return; }
        if (process.env.PPOMI_CHAT === "fixture") {
          json(res, 200, fixtureResponses(await readJson(req) as Record<string, unknown>));
          return;
        }
        const result = await proxyResponses(await readJson(req));
        json(res, result.configured && result.response !== undefined ? 200 : result.configured ? 502 : 503, result.configured ? result.response ?? result : result);
      })().catch(() => { json(res, 500, { error: "model_unavailable" }); });
    });
  };
  return { name: "ppomi-gateway-preview", configureServer: attach, configurePreviewServer: attach };
}

export default defineConfig({
  base: "./",
  esbuild: { jsx: "automatic" },
  plugins: [tailwindcss(), previewGateway()],
  resolve: {
    alias: [
      { find: /^@\//, replacement: `${agentSrc}/` },
      { find: /^react$/, replacement: agentModule("react") },
      { find: /^react\/(.*)$/, replacement: `${agentModule("react")}/$1` },
      { find: /^react-dom$/, replacement: agentModule("react-dom") },
      { find: /^react-dom\/(.*)$/, replacement: `${agentModule("react-dom")}/$1` },
    ],
  },
  server: {
    fs: { allow: [fileURLToPath(new URL("..", import.meta.url))] },
  },
  build: {
    outDir: "dist",
    emptyOutDir: true,
  },
});
