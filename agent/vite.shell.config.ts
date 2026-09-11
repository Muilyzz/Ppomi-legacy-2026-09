import { defineConfig } from "vite";
import { fileURLToPath } from "node:url";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  root: fileURLToPath(new URL("./shell", import.meta.url)),
  base: "./",
  publicDir: fileURLToPath(new URL("./public", import.meta.url)),
  plugins: [tailwindcss(), {
    name: "shell-public-font-path",
    generateBundle(_options, bundle) {
      for (const asset of Object.values(bundle)) if (asset.type === "asset" && asset.fileName.endsWith(".css") && typeof asset.source === "string") {
        // Legacy IIFE CSS lives beside fonts; Vite shell CSS lives in assets/.
        asset.source = asset.source.replace(/url\((["']?)\.\/fonts\//g, "url($1../fonts/");
      }
    },
  }],
  resolve: { alias: { "@": fileURLToPath(new URL("./src", import.meta.url)) } },
  build: {
    outDir: fileURLToPath(new URL("./dist-shell", import.meta.url)),
    emptyOutDir: true,
    sourcemap: false,
    target: ["safari16", "chrome105"],
  },
  define: { "process.env.NODE_ENV": '"production"' },
});
