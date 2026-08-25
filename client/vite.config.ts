/// <reference types="vitest/config" />
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

export default defineConfig({
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
});
