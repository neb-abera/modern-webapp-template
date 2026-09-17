import { useEffect, useState } from "react";
import type { paths } from "./api-types";
import mark from "./assets/mark.svg";

// The API contract, not a hand-written mirror of it: api-types.d.ts is
// generated (npm run generate:api-types) from the OpenAPI document the
// server emits at build time, and verify.sh regenerates both and fails on
// drift. If the server's Greeting record changes shape, this type changes
// with it and the compiler flags every stale usage.
export type Greeting =
  paths["/api/hello"]["get"]["responses"]["200"]["content"]["application/json"];

export function App() {
  const [greeting, setGreeting] = useState<string>();
  const [error, setError] = useState<string>();

  useEffect(() => {
    const controller = new AbortController();
    fetch("/api/hello", { signal: controller.signal })
      .then((response) => {
        if (!response.ok) {
          throw new Error(`API responded ${response.status}`);
        }
        return response.json() as Promise<Greeting>;
      })
      .then((data) => setGreeting(data.message))
      .catch((cause: unknown) => {
        if (!controller.signal.aborted) {
          setError(cause instanceof Error ? cause.message : "unknown error");
        }
      });
    return () => controller.abort();
  }, []);

  return (
    <main>
      {/*
        The image conventions, on the one image the template has. width and
        height always (Biome's useImageSize fails the lint without them): the
        browser reserves the box before the file arrives, so nothing jumps.
        decoding="async" always. Then one of three, by position: nothing for
        a small image above the fold, like this one; loading="lazy" for
        anything below it; fetchPriority="high" for the single largest image
        of the first screen, and never together with lazy.
      */}
      <img src={mark} alt="" width={48} height={48} decoding="async" />
      <h1>Modern Web App</h1>
      {error ? (
        <p role="alert">Could not reach the API: {error}</p>
      ) : (
        <p aria-live="polite">{greeting ?? "Loading…"}</p>
      )}
    </main>
  );
}
