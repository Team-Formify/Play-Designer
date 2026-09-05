/**
 * Compile lib/*.ts into runnable ESM for the test suite.
 *
 * WHY THIS STEP EXISTS. lib/ is written for Next, whose bundler resolves
 * extensionless relative imports (`from "./db"`). Node's ESM loader does not
 * and never will -- it wants `./db.js`. Running the suite with
 * --experimental-strip-types therefore fails on the first cross-file import,
 * which is exactly the point at which a "lib has no tests" project gives up.
 *
 * So: tsc emits to test/.build, and this script rewrites the relative imports
 * to carry .js. Nothing in lib/ changes -- adding extensions there would be
 * writing around a limitation Next does not have, in the source that ships.
 *
 * It also means the suite runs against TYPE-CHECKED output. A compile error is
 * a test failure before a single assertion runs, which is the right order.
 */
import { execFileSync } from "node:child_process";
import { readdirSync, readFileSync, writeFileSync, rmSync, statSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const HUB = dirname(dirname(fileURLToPath(import.meta.url)));
const OUT = join(HUB, "test", ".build");

rmSync(OUT, { recursive: true, force: true });
execFileSync(join(HUB, "node_modules", ".bin", "tsc"), ["-p", join(HUB, "tsconfig.test.json")], {
  cwd: HUB, stdio: "inherit",
});

// Relative imports only. A bare specifier ("pg", "node:crypto") is resolved by
// Node from node_modules and must not be touched.
const REL = /(from\s+["'])(\.\.?\/[^"']+?)(["'])/g;
function walk(dir) {
  for (const e of readdirSync(dir)) {
    const p = join(dir, e);
    if (statSync(p).isDirectory()) { walk(p); continue; }
    if (!p.endsWith(".js")) continue;
    const src = readFileSync(p, "utf8");
    const out = src.replace(REL, (_m, a, spec, z) => a + (spec.endsWith(".js") ? spec : spec + ".js") + z);
    if (out !== src) writeFileSync(p, out);
  }
}
walk(OUT);
console.log("lib compiled and type-checked -> test/.build");
