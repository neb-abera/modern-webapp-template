import { renderToString } from "react-dom/server";
import { prerenderToNodeStream } from "react-dom/static";
import { App } from "./App";

export { prerenderedRoutes } from "./prerenderedRoutes";

function page(_url: string) {
  // No router yet, so every route renders the same tree. The day a router
  // arrives, wrap App in its static router here (and in a browser router in
  // main.tsx) — both entries must compose the exact same tree, because
  // hydration compares the prerendered markup against it.
  return <App />;
}

/**
 * One route rendered to the HTML the browser entry will hydrate. Runs in
 * Node at build time, never in production.
 *
 * Two passes with two APIs, each covering the other's blind spot — a lesson
 * paid for on aberaTech. prerenderToNodeStream waits for suspended
 * components (React.lazy chunks), but emits a resolved Suspense boundary as
 * its fallback plus a hidden deferred segment and a swap script —
 * streaming-shaped output, wrong for a static file. renderToString emits
 * markup inline but cannot wait: a chunk still loading would come out as the
 * fallback. Warm-up pass first, then the real one; with nothing suspended
 * today the warm-up is nearly free, and the day someone adds a lazy route it
 * is what keeps "Loading…" out of the baked HTML.
 */
export async function render(url: string): Promise<string> {
  const warmup = await prerenderToNodeStream(page(url));
  warmup.prelude.resume(); // drain; the output is not used

  return renderToString(page(url));
}
