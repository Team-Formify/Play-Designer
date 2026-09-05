#!/usr/bin/env node
/**
 * Build a database from the migrations and run the adversarial suites on it.
 *
 *   node product/db/test.mjs              all suites
 *   node product/db/test.mjs auth brand   just those
 *
 * WHY THIS EXISTS: until now every suite carried its own FROM EMPTY recipe in a
 * header comment — six -f flags in an order you had to read the comment to
 * know, and four different orders across four files. That is the same failure
 * mode the migration ledger was written to end, one level up. The order lives
 * here now, once, and is executed rather than described.
 *
 * The seeds are NOT migrations and deliberately do not live in migrations/.
 * A migration changes the shape of the schema and runs against a customer's
 * database; a seed invents a fictional league to attack. Shipping the second as
 * the first is how test fixtures end up in production.
 */
import { execFileSync, spawnSync } from "node:child_process";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const DIR = dirname(fileURLToPath(import.meta.url));
const P = (db) => ["-h", "/tmp", "-p", "5433", "-U", "app", "-d", db, "-tAq"];

// Seeds stack: each builds on the one before it. This is the order.
const SEEDS = {
  isolation: ["seed.sql"],
  auth:      ["seed.sql", "auth-seed.sql"],
  platform:  ["seed.sql", "auth-seed.sql", "platform-seed.sql"],
  brand:     ["seed.sql", "auth-seed.sql", "platform-seed.sql", "brand-seed.sql"],
  consent:   ["seed.sql"],
};

const want = process.argv.slice(2).filter((a) => !a.startsWith("--"));
const suites = Object.keys(SEEDS).filter((s) => !want.length || want.includes(s));

let bad = 0;
for (const s of suites) {
  const db = "pd_t_" + s;
  try { execFileSync("dropdb", ["-h", "/tmp", "-p", "5433", "-U", "app", "--if-exists", db], { stdio: "ignore" }); } catch {}
  execFileSync("createdb", ["-h", "/tmp", "-p", "5433", "-U", "app", db], { stdio: "inherit" });

  try {
    execFileSync("node", [join(DIR, "migrate.mjs"), "--db", db], { stdio: ["ignore", "ignore", "inherit"] });
    for (const seed of SEEDS[s]) {
      execFileSync("psql", [...P(db), "-v", "ON_ERROR_STOP=1", "-f", join(DIR, seed)], { stdio: ["ignore", "ignore", "inherit"] });
    }
  } catch {
    console.log(`${s.padEnd(10)} COULD NOT BUILD`);
    bad++;
    continue;
  }

  // psql exits non-zero when a suite RAISEs its failure count, and the output
  // we need is on the throw. Read it off the error rather than losing it.
  // NOTE: match the marker `*** FAIL ***`, never the bare word — several test
  // NAMES contain "fails closed", and grepping for /fail/ counted those as
  // failures. The runner reporting phantom failures is worse than no runner.
  // The count line is a RAISE NOTICE, so it arrives on stderr — on the success
  // path as well as the failure one. Reading stdout alone loses the verdict of
  // every suite that passes, which is the wrong half to lose.
  const r = spawnSync("psql", [...P(db), "-f", join(DIR, `test-${s}.sql`)], { encoding: "utf8" });
  const out = (r.stdout || "") + "\n" + (r.stderr || "");

  const lines = out.split("\n");
  const failed = lines.filter((l) => l.includes("*** FAIL ***"));
  const verdict = lines.filter((l) => /\d+ .*tests? (passed|failed)|TEST\(S\) FAILED/i.test(l)).at(-1);

  if (failed.length) {
    console.log(`${s.padEnd(10)} ${failed.length} FAILING`);
    failed.slice(0, 20).forEach((l) => console.log("           " + l.trim().slice(0, 150)));
    bad++;
  } else if (verdict) {
    console.log(`${s.padEnd(10)} ${verdict.replace(/^.*?(NOTICE|ERROR):\s*/, "").trim()}`);
  } else {
    console.log(`${s.padEnd(10)} NO VERDICT LINE -- the suite did not report a count`);
    bad++;
  }
}
process.exit(bad ? 1 : 0);
