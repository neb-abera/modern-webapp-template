/**
 * The prerender contract: a route rendered at build time is real HTML, not
 * an empty shell — and not a Suspense fallback. These run in node on
 * purpose: the build-time renderer has no browser, and anything that
 * reaches for one at render time (rather than in an effect) should fail
 * here rather than in the Docker build.
 *
 * @vitest-environment node
 */
import { describe, expect, it } from "vitest";
import { prerenderedRoutes, render } from "../src/entry-server";

describe("build-time rendering", () => {
  it("renders the home page with its content", async () => {
    const html = await render("/");

    expect(html).toContain("Modern Web App");
  });

  it("renders every prerendered route to something", async () => {
    for (const route of prerenderedRoutes) {
      expect((await render(route)).trim()).not.toBe("");
    }
  });

  it("shows the loading state for live data, not the data", async () => {
    // The greeting comes from the API at runtime; a build-time snapshot of
    // it would be a lie. The prerendered page carries the loading state and
    // hydration fills in the real answer.
    const html = await render("/");

    expect(html).toContain("Loading…");
  });
});
