import { defineConfig } from "vite";
import { fileURLToPath } from "node:url";
import tailwindcss from "@tailwindcss/vite";
export default defineConfig({
  base: "./",
  plugins: [tailwindcss()],
  resolve: { alias: { "@": fileURLToPath(new URL("./src", import.meta.url)) } },
  build: {
    lib: {
      entry: "src/main.tsx",
      name: "PpomiVoice",
      formats: ["iife"],
      fileName: () => "app.js",
      cssFileName: "app",
    },
    sourcemap: false,
  },
  define: { "process.env.NODE_ENV": '"production"' },
});
