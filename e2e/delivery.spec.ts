import { expect, test } from "@playwright/test";

// How the app reaches the browser. Each assertion pins a delivery regression
// that is invisible to unit tests and easy to ship: an uncompressed bundle, a
// hashed asset served with max-age=0 (every return visit re-validates it), or
// a cached document (deploys stop reaching returning visitors).

async function loadApp(page: import("@playwright/test").Page) {
  const responses: import("@playwright/test").Response[] = [];
  page.on("response", (res) => responses.push(res));
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "Modern Web App" })).toBeVisible();
  return responses;
}

const isAsset = (res: import("@playwright/test").Response) =>
  new URL(res.url()).pathname.startsWith("/assets/");

test("the bundle and stylesheet are served compressed", async ({ page }) => {
  const responses = await loadApp(page);

  const compressible = responses.filter(
    (res) => isAsset(res) && /\.(js|css)$/.test(new URL(res.url()).pathname),
  );
  expect(compressible.length).toBeGreaterThan(0);

  for (const res of compressible) {
    const encoding = (await res.headerValue("content-encoding")) ?? "identity";
    expect(encoding, `${res.url()} left the server uncompressed`).toMatch(/gzip|br|zstd/);
  }
});

test("hashed assets are cacheable, the document is not", async ({ page }) => {
  const responses = await loadApp(page);

  // Vite content-hashes everything under /assets, so a change produces a new
  // URL and the old one can be cached forever.
  const assets = responses.filter(isAsset);
  expect(assets.length).toBeGreaterThan(0);
  for (const res of assets) {
    const cache = (await res.headerValue("cache-control")) ?? "";
    expect(cache, `${res.url()} is not cacheable`).toContain("immutable");
  }

  // The document is the one URL that must stay fresh: it is where the hashed
  // names live, so caching it means deploys stop reaching returning visitors.
  const doc = responses.find((res) => new URL(res.url()).pathname === "/");
  expect(doc).toBeDefined();
  const docCache = (await doc?.headerValue("cache-control")) ?? "";
  expect(docCache).toContain("no-cache");
});

test("the home page is readable before any JavaScript runs", async ({ browser }) => {
  // Prerendering's whole promise: first paint is the page, not a blank shell
  // waiting on the bundle. A browser with JS disabled is the strictest proof.
  const context = await browser.newContext({ javaScriptEnabled: false });
  const page = await context.newPage();
  await page.goto("/");

  await expect(page.getByRole("heading", { name: "Modern Web App" })).toBeVisible();

  await context.close();
});

test("a route that is not prerendered still boots the app", async ({ page }) => {
  // Unknown routes fall back to the empty spa.html shell and render
  // client-side; the fallback must not carry the home page's baked markup.
  await page.goto("/definitely-not-prerendered");

  await expect(page.getByRole("heading", { name: "Modern Web App" })).toBeVisible();
});
