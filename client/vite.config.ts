/// <reference types="vitest/config" />
import path from "node:path";
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
    // In GitHub Actions, add Vitest's built-in github-actions reporter so a
    // failing test becomes an inline annotation on the PR. Vitest would
    // auto-enable it (GITHUB_ACTIONS=true and no reporters configured), but
    // the suite runs in a container against a copy of the tree (/w — see
    // scripts/verify.sh), so the file paths must be rewritten back to the
    // repo's client/ prefix for annotations to land on real files. The job
    // summary is verify.sh's job; the reporter's own stays off.
    reporters:
      process.env.GITHUB_ACTIONS === "true"
        ? [
            "default",
            [
              "github-actions",
              {
                onWritePath: (p: string) =>
                  path.join("client", path.relative(process.cwd(), p)),
                jobSummary: { enabled: false },
              },
            ],
          ]
        : ["default"],
    coverage: {
      // The unit suite renders through App/entry-server, so source coverage
      // is what these tests actually exercise. main.tsx is the browser
      // bootstrap (createRoot/hydrateRoot against a real document) — it only
      // runs in a browser, and the e2e suite covers it end to end.
      include: ["src/**"],
      exclude: ["src/main.tsx"],
      // The first four are Vitest's defaults, kept as-is; json-summary
      // gives verify.sh a machine-readable line-coverage % for the CI job
      // summary, and lcov feeds the (optional, dashboard-only) Codecov
      // upload in the CI verify job.
      reporter: ["text", "html", "clover", "json", "json-summary", "lcov"],
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
