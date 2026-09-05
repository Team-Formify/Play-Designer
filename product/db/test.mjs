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
  // The hub's data layer is not SQL, but it is the same claim one level up --
  // that a statement reaches Postgres as the caller and no further -- so it
  // builds the same way and runs from the same command. Its assertions live in
  // product/hub/test/api.test.mjs.
  hub:       ["seed.sql"],
  // The boys' page needs no database at all -- it reads the shipped JSON. It
  // runs from here anyway so that "did I break anything" is one command rather
  // than two, and the loop below skips the build for it.
  learn:     [],
};

// What each suite is expected to report. Without this a suite that silently
// shrank to three tests would print "all 3 tests passed" and exit 0, which is
// the shape of a green build that tested nothing.
//
// brand carried `{ failing: 14 }` while those 14 were open. They are fixed, so
// it carries a pass count like the rest. If a suite ever goes knowingly red
// again, put its failure COUNT here rather than deleting the entry -- then a
// fifteenth failure is a regression and a thirteenth is progress, and either
// way the runner says so instead of staying quiet.
const EXPECT = {
  isolation: { pass: 183 },
  auth:      { pass: 243 },
  platform:  { pass: 252 },
  brand:     { pass: 187 },
  consent:   { pass: 187 },
  hub:       { pass: 66 },
  learn:     { pass: 58 },
};

const want = process.argv.slice(2).filter((a) => !a.startsWith("--"));
// A typo'd suite name used to run nothing and exit 0. A CI line with a typo in
// it is a green build that tested nothing, which is worse than a red one.
const unknown = want.filter((w) => !(w in SEEDS));
if (unknown.length) {
  console.error("no such suite: " + unknown.join(", "));
  console.error("known suites: " + Object.keys(SEEDS).join(", "));
  process.exit(1);
}
const suites = Object.keys(SEEDS).filter((s) => !want.length || want.includes(s));

let bad = 0;
for (const s of suites) {
  const db = "pd_t_" + s;

  if (s === "learn") {
    // A browser suite. No database, and it SKIPS rather than fails when
    // playwright is absent, because playwright is deliberately not a dependency
    // of this repo -- the no-build property is why the app works on a phone on
    // a practice field.
    const r = spawnSync(process.execPath, [join(DIR, "..", "test", "test-learn.mjs")], { encoding: "utf8" });
    const out = (r.stdout || "") + "\n" + (r.stderr || "");
    if (/^SKIPPED:/m.test(out)) { console.log(`${s.padEnd(10)} SKIPPED (playwright not installed)`); continue; }
    const failed = out.split("\n").filter((l) => l.includes("*** FAIL ***"));
    const verdict = out.split("\n").filter((l) => /all \d+ learn tests passed|LEARN TEST\(S\) FAILED/.test(l)).at(-1);
    const exp = EXPECT[s] || {};
    if (failed.length || !verdict || /FAILED/.test(verdict)) {
      console.log(`${s.padEnd(10)} ${failed.length || "?"} FAILING`);
      failed.slice(0, 20).forEach((l) => console.log("           " + l.trim().slice(0, 150)));
      if (!verdict) console.log("           " + out.trim().split("\n").slice(-6).join("\n           "));
      bad++;
    } else {
      const n = Number((verdict.match(/all (\d+) learn tests passed/) || [])[1]);
      if (exp.pass !== undefined && n !== exp.pass) {
        console.log(`${s.padEnd(10)} ${verdict.trim()}   <== EXPECTED ${exp.pass}. Update EXPECT if you added tests.`);
        bad++;
      } else console.log(`${s.padEnd(10)} ${verdict.trim()}`);
    }
    continue;
  }

  try { execFileSync("dropdb", ["-h", "/tmp", "-p", "5433", "-U", "app", "--if-exists", db], { stdio: "ignore" }); } catch {}

  try {
    // createdb was outside this try, so a failure to create the database came
    // out as an uncaught stack trace instead of "COULD NOT BUILD".
    execFileSync("createdb", ["-h", "/tmp", "-p", "5433", "-U", "app", db], { stdio: ["ignore", "ignore", "inherit"] });
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
  if (s === "hub") {
    // Not a psql suite: it is Node, it compiles lib/ first, and it needs the
    // database this loop just built.
    const r = spawnSync(process.execPath, [join(DIR, "..", "hub", "test", "api.test.mjs"), "--db", db],
      { encoding: "utf8" });
    const out = (r.stdout || "") + "\n" + (r.stderr || "");
    const failed = out.split("\n").filter((l) => l.includes("*** FAIL ***"));
    const verdict = out.split("\n").filter((l) => /all \d+ hub tests passed|HUB TEST\(S\) FAILED/.test(l)).at(-1);
    const exp = EXPECT[s] || {};
    if (failed.length || !verdict || /FAILED/.test(verdict)) {
      console.log(`${s.padEnd(10)} ${failed.length || "?"} FAILING`);
      failed.slice(0, 20).forEach((l) => console.log("           " + l.trim().slice(0, 150)));
      if (!verdict) console.log("           " + out.trim().split("\n").slice(-6).join("\n           "));
      bad++;
    } else {
      const n = Number((verdict.match(/all (\d+) hub tests passed/) || [])[1]);
      if (exp.pass !== undefined && n !== exp.pass) {
        console.log(`${s.padEnd(10)} ${verdict.trim()}   <== EXPECTED ${exp.pass}. Update EXPECT if you added tests.`);
        bad++;
      } else console.log(`${s.padEnd(10)} ${verdict.trim()}`);
    }
    continue;
  }

  // The count line is a RAISE NOTICE, so it arrives on stderr — on the success
  // path as well as the failure one. Reading stdout alone loses the verdict of
  // every suite that passes, which is the wrong half to lose.
  const r = spawnSync("psql", [...P(db), "-f", join(DIR, `test-${s}.sql`)], { encoding: "utf8" });
  const out = (r.stdout || "") + "\n" + (r.stderr || "");

  const lines = out.split("\n");
  const failed = lines.filter((l) => l.includes("*** FAIL ***"));
  const verdict = lines.filter((l) => /\d+ .*tests? (passed|failed)|TEST\(S\) FAILED/i.test(l)).at(-1);

  const exp = EXPECT[s] || {};
  if (failed.length) {
    const expected = exp.failing === failed.length;
    console.log(`${s.padEnd(10)} ${failed.length} FAILING${expected ? " (the known " + exp.failing + ", unchanged)" : ""}`);
    failed.slice(0, 20).forEach((l) => console.log("           " + l.trim().slice(0, 150)));
    if (!expected) {
      if (exp.failing !== undefined) console.log(`           EXPECTED ${exp.failing} FAILING, GOT ${failed.length}`);
      bad++;
    }
  } else if (verdict) {
    const line = verdict.replace(/^.*?(NOTICE|ERROR):\s*/, "").trim();
    const n = Number((line.match(/(\d+)\s+\S+\s+tests?\s+passed/) || [])[1]);
    if (exp.failing !== undefined) {
      console.log(`${s.padEnd(10)} ${line}   <== EXPECTED ${exp.failing} FAILING, NONE FAILED`);
      bad++;                        // a known-red suite going green is news, not silence
    } else if (exp.pass !== undefined && n !== exp.pass) {
      // A shrinking suite still reports "all N tests passed" and exits 0. The
      // count is the only thing that notices tests going missing.
      console.log(`${s.padEnd(10)} ${line}   <== EXPECTED ${exp.pass}. Update EXPECT if you added tests.`);
      bad++;
    } else {
      console.log(`${s.padEnd(10)} ${line}`);
    }
  } else {
    console.log(`${s.padEnd(10)} NO VERDICT LINE -- the suite did not report a count`);
    bad++;
  }
}
process.exit(bad ? 1 : 0);
