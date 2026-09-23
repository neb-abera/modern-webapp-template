import os from "node:os";
import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: ".",
  fullyParallel: true,
  // Half the cores, at most eight: three engines at 24 workers put Firefox
  // at 15 s a test on a 48-core box.
  workers: Math.min(8, Math.max(1, Math.floor(os.cpus().length / 2))),
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  // In GitHub Actions, Playwright's built-in github reporter turns failures
  // into inline PR annotations; the list reporter keeps the log readable.
  // verify.sh runs this suite in a container laid out so the reporter's
  // GITHUB_WORKSPACE-relative paths match the repo (e2e/<file>).
  reporter: process.env.GITHUB_ACTIONS ? [["list"], ["github"]] : "list",
  // Every browser engine, every run. A fix verified in Chromium alone
  // (aberaTech #191, 2026-09-22) was no fix in Firefox. The Playwright image
  // this suite runs in ships all three.
  projects: [
    { name: "chromium", use: { ...devices["Desktop Chrome"] } },
    { name: "firefox", use: { ...devices["Desktop Firefox"] } },
    { name: "webkit", use: { ...devices["Desktop Safari"] } },
  ],
  use: {
    baseURL: process.env.E2E_BASE_URL ?? "http://localhost:8080",
    trace: "on-first-retry",
  },
});
