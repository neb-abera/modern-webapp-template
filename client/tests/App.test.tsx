import { render, screen } from "@testing-library/react";
import { afterEach, expect, test, vi } from "vitest";
import { App } from "../src/App";

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
  stubFetch(Response.json({ message: "Hello from the API" }));

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
