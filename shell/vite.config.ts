import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vite";

const agentSrc = fileURLToPath(new URL("../agent/src", import.meta.url));
const agentModule = (name: string) => fileURLToPath(new URL(`../agent/node_modules/${name}`, import.meta.url));

if (!existsSync(agentModule("react"))) {
  throw new Error("shell UI reuses agent/src/ui — run: npm --prefix agent ci");
}

const tailwindcss = (await import(agentModule("@tailwindcss/vite/dist/index.mjs"))).default;

export default defineConfig({
  base: "./",
  esbuild: { jsx: "automatic" },
  plugins: [tailwindcss()],
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
