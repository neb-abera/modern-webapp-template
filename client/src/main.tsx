import { StrictMode } from "react";
import { createRoot, hydrateRoot } from "react-dom/client";
import { App } from "./App";

const root = document.getElementById("root");
if (!root) {
  throw new Error("missing #root element");
}

const app = (
  <StrictMode>
    <App />
  </StrictMode>
);

// Prerendered pages arrive with their markup already in the root, so React
// adopts it instead of rebuilding it; routes that are not prerendered (the
// spa.html fallback) arrive with an empty root and render as before.
if (root.hasChildNodes()) {
  hydrateRoot(root, app);
} else {
  createRoot(root).render(app);
}
