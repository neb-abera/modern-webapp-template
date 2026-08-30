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
    coverage: {
      // The unit suite renders through App/entry-server, so source coverage
      // is what these tests actually exercise. main.tsx is the browser
      // bootstrap (createRoot/hydrateRoot against a real document) — it only
      // runs in a browser, and the e2e suite covers it end to end.
      include: ["src/**"],
      exclude: ["src/main.tsx"],
      // Measured 2026-08: 100% statements/lines/functions, 90% branches.
      // Thresholds sit below that so a reasonable refactor doesn't break
      // the build, while a change landing meaningful untested logic does.
      thresholds: {
        lines: 90,
        statements: 90,
        functions: 90,
        branches: 85,
      },
    },
  },
}));
