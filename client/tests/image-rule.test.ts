/**
 * The lint rule that requires width and height on every <img>
 * (correctness/useImageSize in biome.json), proven able to fail: a rule that
 * is misspelled, or dropped in a config migration, is silently off, and
 * `npm run lint` stays green either way. This runs the project's own Biome,
 * with the project's own config, on an image without dimensions.
 *
 * @vitest-environment node
 */
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import { expect, test } from "vitest";

// A real file inside the project, so biome.json applies to it exactly as it
// does to src/. Removed again whatever happens.
function lint(source: string) {
  const dir = mkdtempSync(path.join(process.cwd(), ".image-rule-"));
  try {
    const file = path.join(dir, "Probe.tsx");
    writeFileSync(file, source);
    return spawnSync("node_modules/.bin/biome", ["lint", file], {
      encoding: "utf8",
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test("an <img> without width and height fails the lint", () => {
  const result = lint(
    'export const Probe = () => <img src="/a.png" alt="" />;\n',
  );

  expect(result.status).not.toBe(0);
  expect(result.stdout + result.stderr).toContain("useImageSize");
});

test("the same image with its dimensions passes", () => {
  const result = lint(
    'export const Probe = () => <img src="/a.png" alt="" width={1} height={1} />;\n',
  );

  expect(result.stdout + result.stderr).not.toContain("useImageSize");
  expect(result.status).toBe(0);
});
