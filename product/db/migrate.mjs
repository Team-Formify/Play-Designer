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

/* WHERE TO CONNECT.
 *
 * This runner was nailed to the dev cluster -- `-h /tmp -p 5433 -U app` -- so
 * it could not apply a single migration to a hosted database. Everything the
 * product has been proved against lives in a container that disappears; the
 * first time that mattered was the first time somebody tried to deploy.
 *
 *   --url postgresql://...        an explicit target
 *   DATABASE_URL / HUB_DATABASE_URL   the same, from the environment
 *   --db pd_dev                   the local cluster, unchanged, still default
 *
 * A URL is passed to psql as the connection string, so sslmode, channel
 * binding and everything else Neon or Supabase puts in it travels with it and
 * this file does not need to know about any of them.
 */
// An EXPLICIT --db beats an ambient env var. Otherwise a DATABASE_URL sitting
// in a shell silently redirects `--db pd_dev` at production, and the only thing
// standing between that and a very bad afternoon is the --yes prompt. A flag
// somebody typed is a stronger statement of intent than a variable they forgot.
const EXPLICIT_DB = process.argv.includes("--db");
const URL_TARGET =
  arg("--url", null) ||
  (EXPLICIT_DB ? null : process.env.DATABASE_URL || process.env.HUB_DATABASE_URL || null);
const REMOTE = Boolean(URL_TARGET);
const PSQL = REMOTE
  ? [URL_TARGET, "-tAq", "-v", "ON_ERROR_STOP=1"]
  : ["-h", "/tmp", "-p", "5433", "-U", "app", "-d", DB, "-tAq", "-v", "ON_ERROR_STOP=1"];

/* A connection string is a credential. Print where we are going, never what
 * gets us there -- this output ends up in terminals, CI logs and screenshots. */
function targetLabel() {
  if (!REMOTE) return "local cluster, database " + DB;
  try {
    const u = new URL(URL_TARGET.replace(/^postgres(ql)?:\/\//, "http://"));
    return u.hostname + (u.pathname && u.pathname !== "/" ? u.pathname : "");
  } catch { return "the URL given"; }
}

/* Applying migrations to somebody's live season is not the same act as
 * rebuilding a scratch database, so it does not get the same default. --yes is
 * how you say you meant it. --status is read-only and needs no such thing. */
if (REMOTE && !STATUS && !process.argv.includes("--yes")) {
  console.error("Target: " + targetLabel() + "  (remote)");
  console.error("Refusing to apply migrations to a remote database without --yes.");
  console.error("  node product/db/migrate.mjs --url <conn> --status     to look first");
  console.error("  node product/db/migrate.mjs --url <conn> --yes        to apply");
  process.exit(1);
}
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

// Strip comments and every kind of quoted body, so what is left is the file's
// actual statements. Needed because plpgsql bodies are full of `begin` and
// `end;`, and a regex run over the raw text either misses real transaction
// control or rejects every function in the schema.
function statementsOf(sql) {
  let out = "", i = 0;
  while (i < sql.length) {
    const two = sql.slice(i, i + 2);
    if (two === "--") { const nl = sql.indexOf("\n", i); i = nl < 0 ? sql.length : nl; continue; }
    if (two === "/*") { const e = sql.indexOf("*/", i + 2); i = e < 0 ? sql.length : e + 2; continue; }
    if (sql[i] === "'") {
      i++;
      while (i < sql.length) { if (sql[i] === "'" && sql[i + 1] === "'") i += 2; else if (sql[i] === "'") { i++; break; } else i++; }
      out += " ''"; continue;
    }
    if (sql[i] === '"') {
      i++;
      while (i < sql.length && sql[i] !== '"') i++;
      i++; out += ' ""'; continue;
    }
    const dollar = /^\$[A-Za-z_0-9]*\$/.exec(sql.slice(i));
    if (dollar) {
      const tag = dollar[0];
      const end = sql.indexOf(tag, i + tag.length);
      i = end < 0 ? sql.length : end + tag.length;
      out += " $$body$$"; continue;
    }
    out += sql[i]; i++;
  }
  return out.split(";").map((x) => x.trim()).filter(Boolean);
}

// A migration that opens or closes its own transaction commits before the
// ledger row is written, and the two can then disagree. Catch it here rather
// than at 2am.
//
// The first version of this check tested /^\s*(begin|commit|rollback)\s*;/ and
// let `begin transaction;`, `start transaction;`, `end;`, `commit work;` and
// `commit transaction;` straight through — so the runner printed "rolled back,
// nothing was applied" while the migration's table sat permanently in the
// schema and no ledger row recorded it. Exactly the divergence the design
// exists to prevent, triggered by words a person writing SQL reaches for
// naturally. Matched on the first word of a real statement now, not on a line.
const TXN = /^(begin|start|commit|end|rollback|abort|savepoint|release|prepare\s+transaction|set\s+transaction|set\s+constraints)\b/i;
for (const f of files) {
  const raw = readFileSync(join(DIR, f), "utf8");
  const bad = statementsOf(raw).filter((st) => TXN.test(st));
  if (bad.length) {
    console.error(`${f} controls its own transaction. The runner supplies it — remove:`);
    bad.slice(0, 5).forEach((st) => console.error("  " + st.replace(/\s+/g, " ").slice(0, 70)));
    process.exit(1);
  }
  if (!/^--\s*WHY/im.test(raw)) {
    console.error(`${f} has no "-- WHY" header. Say why the shape had to change; the SQL already says what it does.`);
    process.exit(1);
  }
}

// The ledger has to exist before it can be consulted; 0001 creates it. The
// ONLY error that means "first run" is the ledger table being absent. Every
// other one -- a misspelled --db, a server that is down, a permission failure
// -- previously came back as an empty map, so the runner reported all seven
// migrations pending and exited 0 against a database it could not read. That
// lies in the worst direction: it says nothing is deployed.
let applied = new Map();
try {
  const rows = psql("select version || '\t' || coalesce(checksum,'') from public._schema_migrations", false, true);
  applied = new Map(rows.trim().split("\n").filter(Boolean).map((r) => r.split("\t")));
} catch (e) {
  const why = String(e.stderr || e.message || "");
  const ledgerAbsent = /relation "public\._schema_migrations" does not exist|relation "_schema_migrations" does not exist/i.test(why);
  if (!ledgerAbsent) {
    console.error("cannot read the migration ledger, and the reason is not that it is missing:");
    console.error("  " + why.trim().split("\n")[0]);
    console.error("Refusing to guess. Check --db and that the server is up.");
    process.exit(1);
  }
}

let ran = 0, drift = 0;
for (const f of files) {
  const version = f.slice(0, 4);
  const body = readFileSync(join(DIR, f), "utf8");
  const sum = createHash("sha256").update(body).digest("hex").slice(0, 16);
  if (applied.has(version)) {
    const ledgerSum = applied.get(version);
    if (!ledgerSum) {
      // A blank checksum used to mean "nothing to compare", which turned drift
      // detection off for that row without saying so. A ledger that lost its
      // checksum is a ledger that can no longer do its one job.
      console.error(`DRIFT  ${f} has no checksum in the ledger, so an edit to it cannot be detected`);
      drift++;
    } else if (ledgerSum !== sum) {
      console.error(`DRIFT  ${f} was edited after it was applied (ledger ${ledgerSum}, file ${sum})`);
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
console.log(STATUS
  ? `\n${ran} pending, ${applied.size} already applied on ${targetLabel()}.`
  : `\n${ran} applied, ${applied.size} were already there on ${targetLabel()}.`);
