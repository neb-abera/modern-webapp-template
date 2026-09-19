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
//
// Exit codes: 0 = within budget, 1 = over budget (or nothing to measure),
// 2 = an artifact the document names is missing, 3 = the budget file is
// missing or not JSON, 64 = usage. Distinct, so the self-test can tell a
// missing artifact from a passing build: both used to be silent.
import { existsSync, readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { gzipSync } from "node:zlib";

const [dist, budgetPath] = process.argv.slice(2);
if (!dist || !budgetPath) {
  process.stderr.write("usage: check-byte-budget.mjs <dist-dir> <budget.json>\n");
  process.exit(64);
}

let budget;
try {
  budget = JSON.parse(readFileSync(budgetPath, "utf8"));
} catch (cause) {
  process.stderr.write(`budget file ${budgetPath} is missing or not JSON: ${cause.message}\n`);
  process.exit(3);
}

// A file the build should contain but does not is a broken build, not a
// small one: it must never read as "0 bytes, within budget".
const contents = (file) => {
  const full = path.join(dist, file);
  if (!existsSync(full)) {
    process.stderr.write(`artifact missing: ${file} is named by index.html but is not in ${dist}\n`);
    process.exit(2);
  }
  return readFileSync(full);
};
const gz = (file) => gzipSync(contents(file), { level: 9 }).length;
const refs = (html, pattern) => [...html.matchAll(pattern)].map((match) => match[1]);

const home = contents("index.html").toString("utf8");
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
