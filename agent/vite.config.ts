import { defineConfig } from "vite";
export default defineConfig({
  base: "./",
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
