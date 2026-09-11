import { defineConfig } from "vite";
import { fileURLToPath } from "node:url";
import tailwindcss from "@tailwindcss/vite";

// hub(ppomi.muilyzz.com)용 번들: 전역 PpomiWebWorkbench를 두는 스크립트 하나 + CSS 하나(IIFE라 네이티브 번들처럼 완전히 압축된다).
// hub는 빌드 단계가 없으므로 산출물을 hub/web/workbench/에 커밋한다(copy-web-assets.mjs).
export default defineConfig({
  base: "./",
  publicDir: false,
  plugins: [tailwindcss(), {
    name: "web-vendor-font-path",
    enforce: "post",   // lib-mode CSS is emitted by Vite's own post plugin; rewrite after it
    generateBundle(_options, bundle) {
      for (const asset of Object.values(bundle)) if (asset.type === "asset" && asset.fileName.endsWith(".css")) {
        // hub already serves the shared font for its record frames; the workbench CSS points at that copy.
        const css = typeof asset.source === "string" ? asset.source : new TextDecoder().decode(asset.source);
        asset.source = css.replace(/url\((["']?)\.\/fonts\//g, "url($1../vendor/Agent/fonts/");
      }
    },
  }],
  resolve: { alias: { "@": fileURLToPath(new URL("./src", import.meta.url)) } },
  build: {
    outDir: fileURLToPath(new URL("./dist-web", import.meta.url)),
    emptyOutDir: true,
    sourcemap: false,
    target: ["safari16", "chrome105"],
    lib: {
      entry: fileURLToPath(new URL("./src/web-main.tsx", import.meta.url)),
      name: "PpomiWebWorkbench",
      formats: ["iife"],
      fileName: () => "app.js",
      cssFileName: "app",
    },
  },
  define: { "process.env.NODE_ENV": '"production"' },
});
