/**
 * Bake the static routes to HTML, after `vite build` has produced both the
 * client bundle (dist/) and the build-time renderer (dist-server/).
 *
 * Each route's markup is injected into the built index.html — the file that
 * already names the hashed assets — and written where the route's URL maps
 * in wwwroot: / fills dist/index.html, /about becomes dist/about/index.html.
 *
 * The untouched template is kept as dist/spa.html for the server's fallback.
 * It cannot share dist/index.html: that file now carries the home page's
 * markup, and a client-rendered route served over it would flash the wrong
 * page and then hydrate against DOM that contradicts it.
 */
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { prerenderedRoutes, render } from "../dist-server/entry-server.js";

const MARK = '<div id="root"></div>';

const template = await readFile("dist/index.html", "utf8");
if (!template.includes(MARK)) {
  throw new Error(
    `dist/index.html has no ${MARK} to fill; did the shell change?`,
  );
}

await writeFile("dist/spa.html", template);
process.stdout.write("kept empty shell -> dist/spa.html\n");

for (const route of prerenderedRoutes) {
  const html = await render(route);
  if (html.trim() === "") {
    throw new Error(`route ${route} rendered to nothing`);
  }

  const file =
    route === "/" ? "dist/index.html" : path.join("dist", route, "index.html");
  await mkdir(path.dirname(file), { recursive: true });
  await writeFile(file, template.replace(MARK, `<div id="root">${html}</div>`));
  process.stdout.write(`prerendered ${route} -> ${file}\n`);
}
