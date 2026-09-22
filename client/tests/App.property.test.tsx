import { cleanup, render, screen } from "@testing-library/react";
import fc from "fast-check";
import { afterEach, expect, test, vi } from "vitest";
import { App, type Greeting } from "../src/App";

// A property, not an example: whatever text the API answers with, the page
// shows it as text and nothing else happens. Markup in the message stays
// markup on the screen (React escapes it), and no length or character
// breaks the render. fast-check generates the messages, shrinks a failing
// one to its smallest form, and prints the seed to replay it.
//
// The harness is the point of this file as much as the property: a
// downstream project has fast-check installed, wired into the same vitest
// run as every other test, and a shape to copy for its own parsers.

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

test("any message from the API is shown verbatim, as text", async () => {
  await fc.assert(
    fc.asyncProperty(
      // Testing Library matches text with collapsed whitespace, so the
      // property is stated over messages that survive that unchanged.
      fc
        .string({ minLength: 1, maxLength: 200 })
        .filter((s) => s.trim() === s && !/\s\s/.test(s)),
      async (message) => {
        const payload = { message } satisfies Greeting;
        vi.stubGlobal(
          "fetch",
          vi.fn(() => Promise.resolve(Response.json(payload))),
        );

        render(<App />);

        const shown = await screen.findByText(message, { exact: true });
        expect(shown.textContent).toBe(message);
        expect(shown.querySelector("*")).toBeNull();
        cleanup();
      },
    ),
    { numRuns: 100 },
  );
});
