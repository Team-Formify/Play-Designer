#!/usr/bin/env node
/**
 * Apply pending migrations, in order, once each.
 *
 * The practice-planner org has the same discipline and it is the right one; the
 * runner here is ours because theirs applies through a service-role key against
 * PostgREST, and this one is a plain psql invocation as the database owner.
 *
 *   node product/db/migrate.mjs --db pd_dev            apply what is pending
 *   node product/db/migrate.mjs --db pd_dev --status   say what would run
 *
 * Rules, deliberately strict:
 *   - files are NNNN_name.sql, four digits, monotonic, no gaps
 *   - an applied migration is never edited; the checksum catches it if it is
 *   - each file applies inside its own transaction, so a failure leaves the
 *     ledger and the schema agreeing with each other
 */
import { readdirSync, readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const DIR = join(dirname(fileURLToPath(import.meta.url)), "migrations");
const arg = (f, d) => { const i = process.argv.indexOf(f); return i > -1 ? process.argv[i + 1] : d; };
const DB = arg("--db", "pd_dev");
const STATUS = process.argv.includes("--status");
const PSQL = ["-h", "/tmp", "-p", "5433", "-U", "app", "-d", DB, "-tAq", "-v", "ON_ERROR_STOP=1"];
// quiet:true swallows psql's own stderr. Only the ledger probe below uses it —
// on a first run the ledger genuinely does not exist yet, and psql shouting
// ERROR about it looked like a failure when it is the expected path.
const psql = (sqlOrFile, isFile = false, quiet = false) =>
  execFileSync("psql", [...PSQL, isFile ? "-f" : "-c", sqlOrFile], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", quiet ? "pipe" : "inherit"],
  });

const psqlStdin = (sql) =>
  execFileSync("psql", [...PSQL], { encoding: "utf8", input: sql, stdio: ["pipe", "pipe", "inherit"] });

// psql is the whole runner. Say so plainly rather than letting the first
// migration fail with a stack trace that looks like bad SQL.
try {
  execFileSync("psql", ["--version"], { stdio: "ignore" });
} catch {
  console.error("psql is not on PATH. This runner shells out to it; there is no driver.");
  process.exit(1);
}

// NNNN_lower_snake_case.sql, and nothing else. The narrow pattern is the
// security boundary, not the quoting below it: the file name is interpolated
// into a psql \i line and into the ledger's description, and a name carrying a
// quote or a semicolon is a name aimed at that insert. Rejecting the name is a
// smaller thing to get right than escaping it.
const NAME = /^\d{4}_[a-z0-9_]+\.sql$/;
const all = readdirSync(DIR).filter((f) => f.endsWith(".sql") && !f.endsWith(".down.sql"));
const rejected = all.filter((f) => !NAME.test(f));
if (rejected.length) {
  console.error("migration file names must be NNNN_lower_snake_case.sql:");
  rejected.forEach((f) => console.error("  " + JSON.stringify(f)));
  process.exit(1);
}
const files = all.sort();
if (!files.length) { console.error("no migrations found in " + DIR); process.exit(1); }

// gap check — a missing number means a file was lost or never committed
const nums = files.map((f) => Number(f.slice(0, 4)));
for (let i = 0; i < nums.length; i++) {
  if (nums[i] !== i + 1) {
    console.error(`migration numbering has a gap or duplicate at ${files[i]} (expected ${String(i + 1).padStart(4, "0")})`);
    process.exit(1);
  }
}

// A migration that opens its own transaction commits before the ledger row is
// written, and the two can then disagree. Catch it here rather than at 2am.
for (const f of files) {
  const body = readFileSync(join(DIR, f), "utf8");
  if (/^\s*(begin|commit|rollback)\s*;/im.test(body)) {
    console.error(`${f} controls its own transaction. The runner supplies it — remove the begin/commit.`);
    process.exit(1);
  }
}

// the ledger has to exist before it can be consulted; 0001 creates it
let applied = new Map();
try {
  const rows = psql("select version || '\t' || coalesce(checksum,'') from public._schema_migrations", false, true);
  applied = new Map(rows.trim().split("\n").filter(Boolean).map((r) => r.split("\t")));
} catch { /* first run: the ledger does not exist yet */ }

let ran = 0, drift = 0;
for (const f of files) {
  const version = f.slice(0, 4);
  const body = readFileSync(join(DIR, f), "utf8");
  const sum = createHash("sha256").update(body).digest("hex").slice(0, 16);
  if (applied.has(version)) {
    if (applied.get(version) && applied.get(version) !== sum) {
      console.error(`DRIFT  ${f} was edited after it was applied (ledger ${applied.get(version)}, file ${sum})`);
      drift++;
    } else if (STATUS) console.log(`  applied  ${f}`);
    continue;
  }
  if (STATUS) { console.log(`  PENDING  ${f}`); ran++; continue; }

  // The file and its ledger row go in together or not at all. Feeding psql on
  // stdin lets \i pull the migration in between our own begin and commit, so a
  // file that half-applies leaves no ledger row and no schema change either.
  const desc = f.slice(5, -4).replace(/'/g, "''");
  try {
    psqlStdin(`begin;
\\i ${join(DIR, f)}
insert into public._schema_migrations(version, description, checksum)
values ('${version}', '${desc}', '${sum}')
on conflict (version) do update set checksum = excluded.checksum;
commit;`);
  } catch {
    // psql has already printed the real error to stderr; a Node stack trace on
    // top of it buries the one line that says what actually went wrong.
    console.error(`\n  FAILED   ${f} — rolled back. Nothing was applied and no ledger row was written.`);
    process.exit(1);
  }
  console.log(`  applied  ${f}`);
  ran++;
}
if (drift) { console.error(`\n${drift} migration(s) edited after being applied. They are meant to be written once.`); process.exit(1); }
console.log(STATUS ? `\n${ran} pending, ${applied.size} already applied.` : `\n${ran} applied, ${applied.size} were already there.`);
