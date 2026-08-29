/// <reference types="vitest/config" />
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

// A function because the build runs twice: once for the browser bundle and
// once (--ssr) for the build-time renderer, whose single output file must
// land at a fixed name for tools/prerender.mjs to import.
export default defineConfig(({ isSsrBuild }) => ({
  build: isSsrBuild
    ? {
        outDir: "dist-server",
        rollupOptions: { output: { entryFileNames: "[name].js" } },
      }
    : {},
  plugins: [react()],
  server: {
    host: true,
    // In dev the API runs in its own container; compose sets the proxy
    // target to the server service (see `make dev`).
    proxy: {
      "/api": process.env.VITE_API_PROXY ?? "http://localhost:8080",
      "/healthz": process.env.VITE_API_PROXY ?? "http://localhost:8080",
    },
  },
  test: {
    environment: "jsdom",
    setupFiles: ["./tests/setup.ts"],
    globals: false,
  },
}));
