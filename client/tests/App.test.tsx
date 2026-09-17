import { render, screen } from "@testing-library/react";
import { afterEach, expect, test, vi } from "vitest";
import { App, type Greeting } from "../src/App";

afterEach(() => {
  vi.unstubAllGlobals();
});

function stubFetch(response: Response | Promise<Response>) {
  vi.stubGlobal(
    "fetch",
    vi.fn(() => Promise.resolve(response)),
  );
}

test("shows the greeting from the API", async () => {
  // `satisfies Greeting` pins this mock to the generated OpenAPI contract
  // type: if the server's response shape drifts, this stops compiling
  // before the runtime drift gate even runs.
  const payload = { message: "Hello from the API" } satisfies Greeting;
  stubFetch(Response.json(payload));

  render(<App />);

  expect(await screen.findByText("Hello from the API")).toBeInTheDocument();
});

test("shows a loading state before the API answers", () => {
  stubFetch(new Promise<Response>(() => {}));

  render(<App />);

  expect(screen.getByText("Loading…")).toBeInTheDocument();
});

test("surfaces API failures to the user", async () => {
  stubFetch(new Response(null, { status: 500 }));

  render(<App />);

  expect(await screen.findByRole("alert")).toHaveTextContent(
    "API responded 500",
  );
});

test("an unmount mid-request aborts quietly instead of surfacing an error", async () => {
  // A fetch that honors its AbortSignal: never resolves, rejects on abort —
  // exactly what unmounting during the request produces.
  const fetchMock = vi.fn(
    (_input: string, init?: RequestInit) =>
      new Promise<Response>((_resolve, reject) => {
        init?.signal?.addEventListener("abort", () => {
          reject(new DOMException("The operation was aborted.", "AbortError"));
        });
      }),
  );
  vi.stubGlobal("fetch", fetchMock);

  const { unmount } = render(<App />);
  unmount();

  // The cleanup aborted the in-flight request; the rejection must be
  // swallowed by the abort guard, not turned into a state update on an
  // unmounted component or an unhandled rejection (either fails the run).
  expect(fetchMock.mock.calls[0]?.[1]?.signal?.aborted).toBe(true);
  await Promise.resolve();
});

test("every image reserves its box and decodes off the main thread", async () => {
  stubFetch(Response.json({ message: "hi" } satisfies Greeting));

  const { container } = render(<App />);
  await screen.findByText("hi");

  const images = [...container.querySelectorAll("img")];
  expect(images.length).toBeGreaterThan(0);
  for (const image of images) {
    expect(image).toHaveAttribute("width");
    expect(image).toHaveAttribute("height");
    expect(image).toHaveAttribute("decoding", "async");
    // Lazy and high priority contradict each other.
    if (image.getAttribute("loading") === "lazy") {
      expect(image).not.toHaveAttribute("fetchpriority", "high");
    }
  }
});
