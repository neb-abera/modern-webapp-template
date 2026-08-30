import { useEffect, useState } from "react";
import type { paths } from "./api-types";

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
      <h1>Modern Web App</h1>
      {error ? (
        <p role="alert">Could not reach the API: {error}</p>
      ) : (
        <p aria-live="polite">{greeting ?? "Loading…"}</p>
      )}
    </main>
  );
}
