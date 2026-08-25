import { useEffect, useState } from "react";

type Greeting = {
  message: string;
};

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
