// held-majors.mjs — the logic behind scripts/check-held-majors.sh, which
// runs it in the pinned Node image. See that script for what it gates and
// why. No dependencies: node built-ins and the npm CLI only.
//
//   node scripts/held-majors.mjs <dir>...     check these npm manifests
//   node scripts/held-majors.mjs --self-test  prove the check can fail

import { execFile, execFileSync } from "node:child_process";
import {
  cpSync,
  existsSync,
  mkdtempSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";

// A new major often lands before the plugins around it widen their peer
// ranges. That lag is not a silent pin, it is the ecosystem catching up, so
// a major is judged only once it has been out this long.
const GRACE_DAYS = process.env.HELD_MAJORS_GRACE_DAYS
  ? Number(process.env.HELD_MAJORS_GRACE_DAYS)
  : 30;
const EXCEPTIONS_FILE = ".held-majors";

const major = (version) => Number.parseInt(version.split(".")[0], 10);

// A registry call, retried once after a pause. A registry blip is an
// outage, not a finding: it is reported as such and exits 2, distinct from
// the 1 of a held major, so a red run says which it was.
async function registry(call) {
  for (let attempt = 1; ; attempt++) {
    try {
      return await call();
    } catch (error) {
      if (attempt >= 2) {
        console.error(
          `error: registry unreachable after ${attempt} attempts; this is an outage, not a held major`,
        );
        console.error(
          `${error.stderr ?? error.message ?? error}`
            .trim()
            .split("\n")
            .slice(0, 5)
            .join("\n"),
        );
        process.exit(2);
      }
      await new Promise((r) => setTimeout(r, 5000));
    }
  }
}

function npm(args, cwd) {
  return execFileSync("npm", args, {
    cwd,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
}

// Can these specs be installed into a copy of this manifest? Resolution
// only: no scripts run and nothing is written outside the temp copy.
function canInstall(dir, specs) {
  const work = mkdtempSync(join(tmpdir(), "held-majors-"));
  // package.json only, never the lockfile: beside an existing lock npm keeps
  // the tree it has, warns about the broken peer and exits 0. Only a fresh
  // resolve reports ERESOLVE (measured here: typescript 7 "installed" beside
  // openapi-typescript 7 until the lock was left out).
  cpSync(join(dir, "package.json"), join(work, "package.json"));
  try {
    npm(
      [
        "install",
        "--package-lock-only",
        "--ignore-scripts",
        "--no-audit",
        "--no-fund",
        "--save-exact",
        ...specs,
      ],
      work,
    );
    return { ok: true };
  } catch (error) {
    return { ok: false, output: `${error.stderr ?? ""}`.trim() };
  }
}

// `<dir> <package> <reason...>` per line; the reason is mandatory. The
// file is shared with the NuGet check.
function readExceptions() {
  if (!existsSync(EXCEPTIONS_FILE)) return [];
  return readFileSync(EXCEPTIONS_FILE, "utf8")
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith("#"))
    .map((line) => {
      const [dir, name, ...reason] = line.split(/\s+/);
      if (!name || reason.length === 0) {
        throw new Error(
          `${EXCEPTIONS_FILE}: "${line}" needs <dir> <package> <reason>`,
        );
      }
      return { dir: dir.replace(/^\/|\/$/g, "") || ".", name };
    });
}

// Direct dependencies with a newer major published. The registry lookups
// run together; one at a time they were most of the run.
async function candidates(dir) {
  const manifest = JSON.parse(readFileSync(join(dir, "package.json"), "utf8"));
  const lock = JSON.parse(readFileSync(join(dir, "package-lock.json"), "utf8"));
  // Registry dependencies only: a file:, link:, workspace:, git or URL spec
  // has no "next major" for Dependabot to offer.
  const names = Object.entries({
    ...manifest.dependencies,
    ...manifest.devDependencies,
  })
    .filter(
      ([, spec]) => !/^(file:|link:|workspace:|git|github:|https?:)/.test(spec),
    )
    .map(([name]) => name);
  const looked = await Promise.all(
    names.map(async (name) => {
      const current = lock.packages?.[`node_modules/${name}`]?.version;
      if (!current)
        throw new Error(`${dir}: ${name} is not in package-lock.json`);
      // --prefer-online: the answer must be the registry's, not the npm
      // cache's (a local run once saw a major a CI run did not).
      const view = JSON.parse(
        await registry(() =>
          promisify(execFile)(
            "npm",
            [
              "view",
              name,
              "dist-tags.latest",
              "time",
              "--json",
              "--prefer-online",
            ],
            { cwd: tmpdir(), maxBuffer: 64 * 1024 * 1024 },
          ).then((r) => r.stdout),
        ),
      );
      const latest = view["dist-tags.latest"];
      if (major(latest) <= major(current)) return null;
      const ageDays = Math.floor(
        (Date.now() - Date.parse(view.time[latest])) / 86_400_000,
      );
      return { name, current, latest, ageDays };
    }),
  );
  return { names, found: looked.filter(Boolean) };
}

async function check(dirs) {
  const exceptions = readExceptions();
  let failed = false;
  for (const dir of dirs) {
    const { names, found: all } = await candidates(dir);
    // Only entries naming a package this manifest has are this check's
    // business (.held-majors is shared with the NuGet check). A typo here is
    // caught by the real package failing the check.
    const excepted = exceptions
      .filter((e) => e.dir === dir && names.includes(e.name))
      .map((e) => e.name);
    const judged = all.filter(
      (c) => !excepted.includes(c.name) && c.ageDays >= GRACE_DAYS,
    );
    for (const c of all) {
      const note = excepted.includes(c.name)
        ? `excepted in ${EXCEPTIONS_FILE}`
        : c.ageDays < GRACE_DAYS
          ? `out ${c.ageDays}d, judged after ${GRACE_DAYS}d`
          : "judged";
      console.log(`${dir}: ${c.name} ${c.current} -> ${c.latest} (${note})`);
    }

    const specs = judged.map((c) => `${c.name}@${c.latest}`);
    const base = specs.length ? canInstall(dir, specs) : { ok: true };
    if (!base.ok) {
      failed = true;
      console.error(
        `\nerror: ${dir}: ${specs.join(" ")} cannot install beside the rest of the manifest.`,
      );
      console.error(
        "Dependabot cannot open a pull request for a bump that does not install, so this",
      );
      console.error(
        "pin would age in silence. Give the package a manifest of its own (see",
      );
      console.error(
        `tools/api-types), or record it in ${EXCEPTIONS_FILE} with the reason.\n`,
      );
      console.error(base.output.split("\n").slice(0, 25).join("\n"));
      continue;
    }

    // An exception is a debt with an exit condition. Once the bump installs,
    // or there is no newer major at all, the entry must go.
    for (const name of excepted) {
      const c = all.find((x) => x.name === name);
      if (!c) {
        failed = true;
        console.error(
          `error: ${EXCEPTIONS_FILE}: ${dir} ${name} has no newer major; drop the entry.`,
        );
      } else if (canInstall(dir, [...specs, `${name}@${c.latest}`]).ok) {
        failed = true;
        console.error(
          `error: ${EXCEPTIONS_FILE}: ${dir} ${name}@${c.latest} installs now; drop the entry and take the bump.`,
        );
      }
    }
    if (!failed) console.log(`${dir}: ok`);
  }
  return failed ? 1 : 0;
}

// The failure this gate exists for, replayed from published (immutable)
// versions: openapi-typescript 7 peers on typescript ^5.x, so it must be
// refused beside TypeScript 7 and accepted beside TypeScript 5. Fixture
// data, not toolchain versions: they never move.
function selfTest() {
  const fixture = (typescript) => {
    const dir = mkdtempSync(join(tmpdir(), "held-majors-fixture-"));
    writeFileSync(
      join(dir, "package.json"),
      JSON.stringify({
        private: true,
        devDependencies: { "openapi-typescript": "6.7.6", typescript },
      }),
    );
    return dir;
  };
  const refused = canInstall(fixture("7.0.2"), ["openapi-typescript@7.13.0"]);
  const accepted = canInstall(fixture("5.9.3"), ["openapi-typescript@7.13.0"]);
  if (refused.ok || !/ERESOLVE/.test(refused.output)) {
    console.error(
      "self-test: a bump with an unsatisfiable peer was NOT refused with ERESOLVE",
    );
    console.error(refused.output ?? "");
    return 1;
  }
  if (!accepted.ok) {
    console.error("self-test: an installable bump was refused");
    console.error(accepted.output);
    return 1;
  }
  console.log(
    "self-test: refused the uninstallable bump (ERESOLVE), accepted the installable one",
  );
  return 0;
}

const args = process.argv.slice(2);
process.exit(args[0] === "--self-test" ? selfTest() : await check(args));
