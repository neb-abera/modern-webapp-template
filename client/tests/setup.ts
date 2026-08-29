import "@testing-library/jest-dom/vitest";
import { cleanup } from "@testing-library/react";
import { afterEach, beforeEach } from "vitest";

afterEach(() => {
  cleanup();
});

// Node 26 predefines an experimental global localStorage (undefined unless
// node gets --localstorage-file), and the jsdom test environment defers to
// that existing global — so window.localStorage is silently undefined in
// tests. Libraries that guard storage access with try/catch degrade without
// a word; tests that assert on what got stored fail confusingly. Every test
// gets a fresh in-memory Storage instead, on both the bare global and window.
function memoryStorage(): Storage {
  const store = new Map<string, string>();
  return {
    get length() {
      return store.size;
    },
    clear: () => store.clear(),
    getItem: (key: string) => store.get(key) ?? null,
    key: (index: number) => [...store.keys()][index] ?? null,
    removeItem: (key: string) => {
      store.delete(key);
    },
    setItem: (key: string, value: string) => {
      store.set(key, String(value));
    },
  };
}

beforeEach(() => {
  const storage = memoryStorage();
  Object.defineProperty(globalThis, "localStorage", {
    value: storage,
    configurable: true,
  });
  if (typeof window !== "undefined") {
    Object.defineProperty(window, "localStorage", {
      value: storage,
      configurable: true,
    });
  }
});
