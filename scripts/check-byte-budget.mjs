// Measures a production client build (the image's wwwroot) against a byte
// budget. Driven by check-byte-budget.sh, which also proves this can fail.
//
//   node check-byte-budget.mjs <dist-dir> <budget.json>
//
// Everything is gzip -9 bytes of the file on disk: deterministic for a given
// build, independent of the network and of which encoding a browser
// negotiates. It is a yardstick, not a prediction of the wire size.
//
//   entryJs       the <script type="module"> the document names
//   entryCss      every <link rel="stylesheet"> the document names
//   initialTotal  the home document + entryJs + entryCss + modulepreloads:
//                 what a first visit to / must download before it is whole
//   htmlPerRoute  each prerendered <route>/index.html, individually
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { gzipSync } from "node:zlib";

const [dist, budgetPath] = process.argv.slice(2);
if (!dist || !budgetPath) {
  process.stderr.write("usage: check-byte-budget.mjs <dist-dir> <budget.json>\n");
  process.exit(2);
}

const budget = JSON.parse(readFileSync(budgetPath, "utf8"));
const gz = (file) => gzipSync(readFileSync(path.join(dist, file)), { level: 9 }).length;
const refs = (html, pattern) => [...html.matchAll(pattern)].map((match) => match[1]);

const home = readFileSync(path.join(dist, "index.html"), "utf8");
const scripts = refs(home, /<script[^>]*type="module"[^>]*src="([^"]+)"/g);
const styles = refs(home, /<link[^>]*rel="stylesheet"[^>]*href="([^"]+)"/g);
const preloads = refs(home, /<link[^>]*rel="modulepreload"[^>]*href="([^"]+)"/g);
if (scripts.length === 0) {
  process.stderr.write("no <script type=\"module\" src> in index.html: nothing was measured\n");
  process.exit(1);
}

const sum = (files) => files.reduce((total, file) => total + gz(file), 0);
const measured = {
  entryJs: sum(scripts),
  entryCss: sum(styles),
};
measured.initialTotal = gz("index.html") + measured.entryJs + measured.entryCss + sum(preloads);

const rows = Object.entries(measured).map(([name, bytes]) => [name, bytes, budget[name]]);
const pages = readdirSync(dist, { recursive: true })
  .map(String)
  .filter((file) => path.basename(file) === "index.html")
  .sort();
for (const page of pages) {
  const route = `/${path.dirname(page)}`.replace(/^\/\.$/, "/");
  rows.push([`html ${route}`, gz(page), budget.htmlPerRoute]);
}

let over = 0;
for (const [name, bytes, limit] of rows) {
  const verdict = typeof limit !== "number" ? "NO BUDGET" : bytes > limit ? "OVER" : "ok";
  if (verdict !== "ok") over += 1;
  process.stdout.write(`${name.padEnd(24)} ${String(bytes).padStart(8)} B gz   budget ${String(limit).padStart(8)}   ${verdict}\n`);
}
if (over > 0) {
  process.stderr.write(
    `${over} measurement(s) over budget. Find what grew before raising anything; ` +
      "CONTRIBUTING.md says how a budget is raised on purpose.\n",
  );
  process.exit(1);
}
