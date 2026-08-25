import { expect, test } from "@playwright/test";

// End-to-end smoke against the real production image: client served, API
// reachable, the two wired together.

test("serves the client and shows the API greeting", async ({ page }) => {
  await page.goto("/");

  await expect(page.getByRole("heading", { name: "Modern Web App" })).toBeVisible();
  await expect(page.getByText("Hello from the API")).toBeVisible();
});

test("health endpoint responds", async ({ request }) => {
  const response = await request.get("/healthz");

  expect(response.status()).toBe(200);
});

test("security headers are served to browsers", async ({ request }) => {
  const response = await request.get("/");

  expect(response.headers()["content-security-policy"]).toContain("default-src 'self'");
  expect(response.headers()["x-content-type-options"]).toBe("nosniff");
});
