/**
 * product/hub/test/api.test.mjs -- the desk client's data layer, attacked.
 *
 *   node product/hub/test/api.test.mjs
 *
 * BUILD THE DATABASE FIRST (this suite does not build it, so it can be pointed
 * at any database you like):
 *   node product/db/test.mjs        # or:
 *   createdb pd_hub && node product/db/migrate.mjs --db pd_hub \
 *     && psql -d pd_hub -f product/db/seed.sql
 *
 * WHY THIS FILE EXISTS AT ALL. product/db has 1,052 tests and product/hub had
 * none, and lib/db.ts's own header cited "test/api.test.mjs interleaves two
 * requests over one connection and proves neither sees the other's GUC" -- a
 * test that had never been written. A comment describing a guarantee is not the
 * guarantee. This is that file.
 *
 * THE CLAIM IT TESTS, IN ONE SENTENCE. Every statement the hub runs reaches
 * Postgres as the caller and no further: identity is bound per transaction and
 * cannot survive onto the next request over a reused connection, an anonymous
 * request gets an anonymous role, a failed request leaves nothing behind, and
 * nothing in a request body can become an identity claim.
 *
 * HOUSE RULES, inherited from product/db:
 *   (a) Every refusal is paired with a CONTROL proving the row was really there
 *       to be taken. A refusal whose control returns 0 is a broken test.
 *   (b) Attacks name the other tenant's rows by literal uuid -- a subselect
 *       would return NULL under RLS and the attack would "pass" by asking
 *       about nothing.
 *   (c) Section 9 breaks each guard on purpose and shows the same calls
 *       succeeding, so nobody has to take the zeroes on faith.
 *
 * WHAT THIS FILE CANNOT PROVE:
 *   * That the session secret is well kept. It proves a forged cookie fails.
 *     Where HUB_SESSION_SECRET lives in production is a deployment property.
 *   * That Supabase's JWT verifier behaves like lib/session.ts. The GUC
 *     contract is the same either way; the verifier is not this file's.
 *   * Anything about the React components. This is the data layer only.
 *
 * MUTATION RUN. 66 passes prove nothing on their own, so each guard in
 * lib/db.ts was broken on purpose and the red count recorded:
 *
 *   session verify accepts any signature ............ 30 tests go red
 *   no role switch at all ...........................  6
 *   everybody gets pd_authenticated .................  6
 *   identity bound before the role is set ...........  6
 *   identity bound session-wide (is_local=false) ....  4
 *   no rollback on error ............................  4
 *   the email claim is silently dropped .............  2
 *   no statement timeout ............................  2
 *   the timeout is set session-wide rather than local  2
 *
 * TWO OF THOSE SURVIVED THE FIRST VERSION OF THIS FILE, and they were the two
 * it exists for: is_local=false and the missing rollback both left all 60
 * tests green. Every assertion read the GUC from inside a LATER asCaller(),
 * and asCaller() rebinds all four GUCs on entry -- so the stale value was
 * overwritten a microsecond before anything looked at it. A suite can be
 * pointed straight at the thing it is named after and still not see it.
 *
 * The fix was to observe from OUTSIDE asCaller(), on a raw client from the
 * same pool, which is where the leak actually shows: any statement that
 * reaches that connection without going through asCaller() runs as the last
 * caller. Both mutants die there now.
 */
import { execFileSync } from "node:child_process";
import { createHmac } from "node:crypto";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// Build first, always. A stale test/.build is a suite testing yesterday's code.
execFileSync(process.execPath, [join(dirname(fileURLToPath(import.meta.url)), "build.mjs")], { stdio: "inherit" });

const DB = process.argv.includes("--db")
  ? process.argv[process.argv.indexOf("--db") + 1]
  : "pd_hub_test";
const HOST = "/tmp", PORT = "5433", OWNER = "app";

process.env.HUB_SESSION_SECRET = "a-test-secret-at-least-sixteen-chars";

let pass = 0, fail = 0;
const results = [];
let section = "-";
const sect = (s) => { section = s; console.log("\n=== " + s + " ==="); };
function ok(name, cond, detail = "") {
  if (cond) { pass++; results.push([section, name, true, detail]); }
  else { fail++; results.push([section, name, false, detail]); console.log(`  *** FAIL *** ${name}${detail ? "  -- " + detail : ""}`); }
}
const eq = (name, got, want) =>
  ok(name, Object.is(got, want) || String(got) === String(want), `got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);

const psql = (sql, db = DB) =>
  execFileSync("psql", ["-h", HOST, "-p", PORT, "-U", OWNER, "-d", db, "-tAq", "-c", sql], { encoding: "utf8" }).trim();

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------
// pd_app is created NOLOGIN by 0008, deliberately: a migration must not write a
// credential. The suite gives it LOGIN for the duration and takes it back in
// the finally block, because roles are cluster-wide and leaving a login role
// behind on a dev cluster is exactly the kind of thing that is forgotten.
function withLogin(fn) {
  psql("alter role pd_app login", "postgres");
  try { return fn(); } finally { psql("alter role pd_app nologin", "postgres"); }
}

const CONN = (max) => ({ connectionString: `postgresql://pd_app@localhost:${PORT}/${DB}?host=${HOST}`, max });

// Seed identities, from product/db/seed.sql.
const DOM = "d0000000-0000-4000-8000-000000000001";        // assistant, Lehi 8
const STEVE = "d0000000-0000-4000-8000-000000000002";      // head, Lehi 8
const OSTLER = "d0000000-0000-4000-8000-000000000007";     // head, Logan 8 (other league)
const STRANGER = "d0000000-0000-4000-8000-00000000000a";   // no membership at all
const LEHI8 = "c0000000-0000-4000-8000-000000000001";
const LOGAN8 = "c0000000-0000-4000-8000-000000000004";

async function main() {
  // From test/.build, not lib/: see test/build.mjs. Compiled means the suite
  // runs against type-checked output, so a type error is a failure before any
  // assertion runs.
  const db = await import("./.build/db.js");
  const session = await import("./.build/session.js");
  const { ANON, asUser, asCaller, configurePool, closePool } = db;

  // -------------------------------------------------------------------------
  sect("0. CONTROL -- the database really has something to steal");
  // -------------------------------------------------------------------------
  eq("the schema is built to 0008", psql("select count(*)::text from public._schema_migrations"), "8");
  eq("pd_app exists and is NOINHERIT",
     psql("select (not rolinherit)::text from pg_roles where rolname='pd_app'"), "true");
  eq("pd_app holds no table privilege of its own",
     psql("select count(*)::text from information_schema.table_privileges where grantee='pd_app'"), "0");
  ok("there are players to read", Number(psql("select count(*) from public.players")) >= 31,
     psql("select count(*) from public.players") + " players");
  ok("in both leagues", Number(psql(`select count(*) from public.players where team_id='${LOGAN8}'`)) >= 1);

  configurePool(CONN(10));

  // -------------------------------------------------------------------------
  sect("1. Identity reaches the database, and is the caller's");
  // -------------------------------------------------------------------------
  const uid = await asCaller(asUser(DOM, "dom@example.com"), async (tx) =>
    (await tx.query("select auth.uid()::text as u")).rows[0].u);
  eq("auth.uid() is the signed-in user", uid, DOM);

  const em = await asCaller(asUser(DOM, "dom@example.com"), async (tx) =>
    (await tx.query("select auth.email() as e")).rows[0].e);
  eq("auth.email() is his address", em, "dom@example.com");

  const anonUid = await asCaller(ANON, async (tx) =>
    (await tx.query("select auth.uid()::text as u")).rows[0].u);
  eq("an anonymous caller has no uid", anonUid, null);

  const role = await asCaller(asUser(DOM, null), async (tx) =>
    (await tx.query("select current_user as r")).rows[0].r);
  eq("a signed-in caller runs as pd_authenticated", role, "pd_authenticated");

  const anonRole = await asCaller(ANON, async (tx) =>
    (await tx.query("select current_user as r")).rows[0].r);
  eq("an anonymous caller runs as pd_anon", anonRole, "pd_anon");

  const sess = await asCaller(asUser(DOM, null), async (tx) =>
    (await tx.query("select session_user as r")).rows[0].r);
  eq("and the connection itself logged in as pd_app", sess, "pd_app");

  // A request that hangs is a connection the next request cannot have, so the
  // timeout is part of the identity binding rather than a deployment setting.
  const timeout = await asCaller(asUser(DOM, null), async (tx) =>
    (await tx.query("show statement_timeout")).rows[0].statement_timeout);
  eq("every transaction carries a statement timeout", timeout, "10s");
  eq("and it is transaction-local, not left on the connection",
     await (async () => {
       const c = await db.pool().connect();
       try { return (await c.query("show statement_timeout")).rows[0].statement_timeout; }
       finally { c.release(); }
     })(), "0");

  // -------------------------------------------------------------------------
  sect("2. THE CENTRAL CLAIM -- identity cannot survive onto the next request");
  // -------------------------------------------------------------------------
  // max:1 forces every call below onto ONE physical connection, which is the
  // condition the guarantee is about. With a pool of ten the test would pass
  // for the wrong reason: each caller would simply get a different socket.
  await closePool();
  configurePool(CONN(1));

  const seen = [];
  for (const who of [asUser(DOM, "dom@example.com"), ANON, asUser(OSTLER, "ostler@example.com"), ANON]) {
    seen.push(await asCaller(who, async (tx) =>
      (await tx.query("select coalesce(auth.uid()::text,'<none>') as u")).rows[0].u));
  }
  eq("four requests over ONE connection each see their own identity",
     seen.join(","), [DOM, "<none>", OSTLER, "<none>"].join(","));

  // Interleaved rather than sequential: two transactions open at once over a
  // pool of one is not possible, so this proves the second waits and starts
  // clean rather than inheriting.
  await closePool();
  configurePool(CONN(1));
  const [a, b] = await Promise.all([
    asCaller(asUser(DOM, null), async (tx) => (await tx.query("select auth.uid()::text u")).rows[0].u),
    asCaller(asUser(OSTLER, null), async (tx) => (await tx.query("select auth.uid()::text u")).rows[0].u),
  ]);
  ok("two concurrent requests on one connection do not cross", a === DOM && b === OSTLER, `${a} / ${b}`);

  // ---------------------------------------------------------------------
  // OBSERVED FROM OUTSIDE asCaller(), WHICH IS THE ONLY PLACE IT SHOWS.
  //
  // A mutation run found this blind spot and it is worth stating plainly,
  // because the first version of this suite had the bug it is meant to catch.
  // Changing set_config's is_local from true to false -- the exact edit
  // db.ts's header warns about -- left all 60 tests GREEN. Every assertion
  // above reads the GUC from inside a LATER asCaller(), and asCaller() binds
  // all four GUCs on entry, so the stale value is overwritten a microsecond
  // before anything looks at it. The test could not see the leak it was named
  // after.
  //
  // The leak is real all the same: any statement that runs on that connection
  // WITHOUT going through asCaller() -- a health check, a pool validation
  // query, a future code path, an ORM's own bookkeeping -- executes under the
  // last caller's identity. So the observation has to happen there. Taking a
  // raw client from the same pool is precisely that statement.
  //
  // It kills a second mutant too: dropping the rollback in the catch leaves
  // the previous transaction OPEN rather than aborted, so its `set local`
  // values are still live on the connection. Same probe, same failure.
  const rawOnPool = async (sql) => {
    const c = await db.pool().connect();
    try { return (await c.query(sql)).rows[0].v; } finally { c.release(); }
  };
  const RAW_ID = "select coalesce(nullif(current_setting('app.user_id', true),''),'<empty>') v";
  const RAW_ROLE = "select current_user v";

  await asCaller(asUser(DOM, "dom@example.com"), async (tx) => tx.query("select 1"));
  eq("after a request, a RAW statement on that connection has no identity",
     await rawOnPool(RAW_ID), "<empty>");
  eq("and is back to the login role, holding nothing",
     await rawOnPool(RAW_ROLE), "pd_app");

  try {
    await asCaller(asUser(STEVE, null), async (tx) => {
      await tx.query("select 1");
      throw new Error("boom");
    });
  } catch { /* expected */ }
  eq("and after a FAILED request the same is true -- nothing is left open",
     await rawOnPool(RAW_ID), "<empty>");
  eq("nor its role",
     await rawOnPool(RAW_ROLE), "pd_app");

  // The GUC must be gone, not merely overwritten by the next binding.
  await closePool();
  configurePool(CONN(1));
  await asCaller(asUser(DOM, "dom@example.com"), async (tx) => tx.query("select 1"));
  const leaked = await asCaller(ANON, async (tx) =>
    (await tx.query("select coalesce(nullif(current_setting('app.user_id', true),''),'<empty>') v")).rows[0].v);
  eq("the previous caller's GUC is not sitting on the connection", leaked, "<empty>");

  const leakedRole = await asCaller(ANON, async (tx) =>
    (await tx.query("select current_user r")).rows[0].r);
  eq("nor his role", leakedRole, "pd_anon");

  // -------------------------------------------------------------------------
  sect("3. A failed request leaves nothing behind");
  // -------------------------------------------------------------------------
  let threw = false;
  try {
    await asCaller(asUser(STEVE, null), async (tx) => {
      await tx.query("select 1");
      throw new Error("handler exploded");
    });
  } catch (e) { threw = e.message === "handler exploded"; }
  ok("a throwing handler propagates its own error", threw);

  const afterThrow = await asCaller(ANON, async (tx) =>
    (await tx.query("select coalesce(nullif(current_setting('app.user_id', true),''),'<empty>') v")).rows[0].v);
  eq("and the connection it used carries no identity afterwards", afterThrow, "<empty>");

  const stillWorks = await asCaller(asUser(DOM, null), async (tx) =>
    (await tx.query("select auth.uid()::text u")).rows[0].u);
  eq("and the connection is still usable", stillWorks, DOM);

  // A statement error must roll back too, not just a thrown JS error.
  let sqlThrew = false;
  try {
    await asCaller(asUser(STEVE, null), async (tx) => { await tx.query("select 1/0"); });
  } catch { sqlThrew = true; }
  ok("a SQL error propagates", sqlThrew);
  const afterSqlErr = await asCaller(ANON, async (tx) =>
    (await tx.query("select coalesce(nullif(current_setting('app.user_id', true),''),'<empty>') v")).rows[0].v);
  eq("and leaves no identity either", afterSqlErr, "<empty>");

  // -------------------------------------------------------------------------
  sect("4. Isolation, through the library rather than in psql");
  // -------------------------------------------------------------------------
  await closePool();
  configurePool(CONN(10));

  const ownRoster = await asCaller(asUser(DOM, null), async (tx) =>
    (await tx.query("select count(*)::int n from public.players where team_id=$1", [LEHI8])).rows[0].n);
  ok("Dom reads his own roster", ownRoster === 21, `${ownRoster} players`);

  const otherRoster = await asCaller(asUser(DOM, null), async (tx) =>
    (await tx.query("select count(*)::int n from public.players where team_id=$1", [LOGAN8])).rows[0].n);
  eq("and sees nothing of the other league's", otherRoster, 0);

  const anonRoster = await asCaller(ANON, async (tx) =>
    (await tx.query("select count(*)::int n from public.players")).rows[0].n);
  eq("an anonymous caller sees no child at all", anonRoster, 0);

  const strangerRoster = await asCaller(asUser(STRANGER, null), async (tx) =>
    (await tx.query("select count(*)::int n from public.players")).rows[0].n);
  eq("a signed-in stranger with no membership sees none either", strangerRoster, 0);

  // The privilege half: pd_anon holds no EXECUTE on the staff functions, so an
  // anonymous caller is refused by the database before any check inside runs.
  let anonRefused = "";
  try {
    await asCaller(ANON, async (tx) => tx.query("select * from app.platform_leagues()"));
  } catch (e) { anonRefused = e.code || e.message; }
  eq("and cannot even call a staff function", anonRefused, "42501");

  // -------------------------------------------------------------------------
  sect("5. A request body is not an identity");
  // -------------------------------------------------------------------------
  // The whole point of lib/session.ts. Naming a team does not grant it: the
  // Caller is built from the verified session, and the team id is only ever a
  // parameter to a query that RLS then filters.
  const claimed = await asCaller(asUser(OSTLER, null), async (tx) =>
    (await tx.query("select count(*)::int n from public.players where team_id=$1", [LEHI8])).rows[0].n);
  eq("naming another league's team in a parameter yields nothing", claimed, 0);
  ok("CONTROL the rows are really there for the owner to see",
     Number(psql(`select count(*) from public.players where team_id='${LEHI8}'`)) === 21);

  // -------------------------------------------------------------------------
  sect("6. lib/session.ts fails closed");
  // -------------------------------------------------------------------------
  // Through the real entry point: callerFrom() takes a Request, so these are
  // the actual headers a browser would send, not a convenience wrapper.
  const reqWithCookie = (tok) =>
    new Request("https://hub.example/x", { headers: tok === null ? {} : { cookie: `hub_session=${tok}` } });
  const reqWithBearer = (tok) =>
    new Request("https://hub.example/x", { headers: { authorization: "Bearer " + tok } });
  const whoIs = (tok) => session.callerFrom(reqWithCookie(tok)).userId;

  const good = session.mintSession(DOM, "dom@example.com");
  eq("a freshly minted token verifies", session.verifySession(good)?.sub, DOM);
  eq("and a cookie carrying it produces the right caller", whoIs(good), DOM);
  eq("as does the same token as a bearer",
     session.callerFrom(reqWithBearer(good)).userId, DOM);
  eq("the email is folded to lower case on the way in",
     session.verifySession(session.mintSession(DOM, "  Dom@Example.COM "))?.email, "dom@example.com");

  eq("no cookie at all is anonymous", whoIs(null), null);
  eq("an empty cookie is anonymous", whoIs(""), null);
  eq("a garbage cookie is anonymous", whoIs("not.a.token"), null);
  eq("a cookie with no signature at all is anonymous", whoIs(good.split(".")[0]), null);

  const [p0, s0] = good.split(".");
  eq("a flipped signature byte is anonymous",
     whoIs(p0 + "." + (s0[0] === "A" ? "B" : "A") + s0.slice(1)), null);

  // A swapped payload re-signed with the WRONG key must fail -- and with the
  // RIGHT key must succeed, or the test above passes for the wrong reason.
  const b64u = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const forgedPayload = b64u({ sub: STEVE, email: null, exp: Math.floor(Date.now() / 1000) + 600 });
  const sigWith = (key, body) => createHmac("sha256", key).update(body).digest("base64url");
  const forged = forgedPayload + "." + sigWith("some-other-secret-long-enough!!", forgedPayload);
  eq("a payload re-signed with another secret is anonymous", whoIs(forged), null);
  eq("CONTROL the same payload signed with OUR secret does verify",
     whoIs(forgedPayload + "." + sigWith(process.env.HUB_SESSION_SECRET, forgedPayload)), STEVE);

  eq("an expired token is anonymous", whoIs(session.mintSession(DOM, null, -60)), null);
  eq("CONTROL one second of life is enough", whoIs(session.mintSession(DOM, null, 60)), DOM);

  const notUuid = b64u({ sub: "not-a-uuid", email: null, exp: Math.floor(Date.now() / 1000) + 600 });
  eq("a validly signed token whose sub is not a uuid is anonymous",
     whoIs(notUuid + "." + sigWith(process.env.HUB_SESSION_SECRET, notUuid)), null);
  ok("and minting one is refused outright", (() => {
    try { session.mintSession("not-a-uuid", null); return false; } catch { return true; }
  })());

  // The end-to-end consequence: a forged cookie reaches the database as nobody.
  const forgedSees = await asCaller(session.callerFrom(reqWithCookie(forged)),
    async (tx) => (await tx.query("select count(*)::int n from public.players")).rows[0].n);
  eq("so a forged cookie reads no children", forgedSees, 0);

  // -------------------------------------------------------------------------
  sect("7. The boys' word is a read credential, not a session");
  // -------------------------------------------------------------------------
  // Two headers, never stored, re-verified per statement. Naming a team is not
  // a claim to it -- the word is the secret and the database checks the pair.
  const wordReq = (team, word) =>
    new Request("https://hub.example/x", { headers: { "x-player-team": team, "x-player-word": word } });

  const wc = session.callerFrom(wordReq(LEHI8, "whatever"));
  eq("a word request carries no user id", wc.userId, null);
  eq("but does carry the team it names", wc.playerTeam, LEHI8);
  eq("and runs as the anonymous role", await asCaller(wc, async (tx) =>
     (await tx.query("select current_user r")).rows[0].r), "pd_anon");
  eq("a wrong word sees nothing, though it named a real team",
     await asCaller(wc, async (tx) =>
       (await tx.query("select count(*)::int n from public.players where team_id=$1", [LEHI8])).rows[0].n), 0);
  ok("CONTROL that team really has children",
     Number(psql(`select count(*) from public.players where team_id='${LEHI8}'`)) === 21);
  eq("a word with no team is not a word at all",
     session.callerFrom(new Request("https://hub.example/x", { headers: { "x-player-word": "x" } })).playerTeam, null);
  eq("nor is a team with no word",
     session.callerFrom(new Request("https://hub.example/x", { headers: { "x-player-team": LEHI8 } })).playerTeam, null);
  eq("a non-uuid team is ignored rather than passed through",
     session.callerFrom(wordReq("../../etc/passwd", "x")).playerTeam, null);

  // -------------------------------------------------------------------------
  sect("7b. No secret at all fails closed, rather than open");
  // -------------------------------------------------------------------------
  const keep = process.env.HUB_SESSION_SECRET;
  delete process.env.HUB_SESSION_SECRET;
  eq("with no secret configured, a previously valid cookie is anonymous", whoIs(good), null);
  ok("and minting refuses rather than signing with nothing", (() => {
    try { session.mintSession(DOM, null); return false; } catch { return true; }
  })());
  process.env.HUB_SESSION_SECRET = "short";
  eq("a secret under sixteen bytes is treated as no secret", whoIs(good), null);
  process.env.HUB_SESSION_SECRET = keep;
  eq("CONTROL and it verifies again once the real secret is back", whoIs(good), DOM);

  // -------------------------------------------------------------------------
  sect("8. The pool is configured once and says which database it is on");
  // -------------------------------------------------------------------------
  ok("configurePool refuses to reconfigure an open pool", await (async () => {
    try { configurePool(CONN(2)); return false; } catch { return true; }
  })());

  // -------------------------------------------------------------------------
  sect("9. VACUITY CHECK -- with the binding broken, the leak is real");
  // -------------------------------------------------------------------------
  // Everything in section 2 is a list of '<empty>' and a broken binding would
  // produce the same list if the connection happened not to be reused. So:
  // bind identity SESSION-wide (is_local = false), exactly as dropping the
  // `true` in db.ts would, and show the next caller inheriting it.
  await closePool();
  configurePool(CONN(1));
  const pg = (await import("pg")).default;
  const leakPool = new pg.Pool({ ...CONN(1), max: 1 });
  try {
    const c = await leakPool.connect();
    await c.query("begin");
    await c.query("set role pd_authenticated");
    await c.query("select set_config('app.user_id', $1, false)", [DOM]); // <-- false
    await c.query("commit");
    c.release();

    const c2 = await leakPool.connect();          // same physical connection
    const stale = (await c2.query("select coalesce(nullif(current_setting('app.user_id', true),''),'<empty>') v")).rows[0].v;
    const staleRole = (await c2.query("select current_user r")).rows[0].r;
    eq("with is_local=false the next request inherits the last caller's id", stale, DOM);
    eq("and his role", staleRole, "pd_authenticated");
    const stolen = (await c2.query("select count(*)::int n from public.players")).rows[0].n;
    ok("which is a complete tenancy bypass: it reads his children", stolen > 0, `${stolen} children`);
    c2.release();
  } finally {
    await leakPool.end();
  }

  // And with the real function, on the same shape of test, it does not.
  const notStale = await asCaller(ANON, async (tx) =>
    (await tx.query("select coalesce(nullif(current_setting('app.user_id', true),''),'<empty>') v")).rows[0].v);
  eq("put back the right way, nothing is inherited", notStale, "<empty>");

  await closePool();
}

// ---------------------------------------------------------------------------
try {
  withLogin(() => {});                       // fail early if the role is missing
  await withLoginAsync();
} catch (err) {
  console.error("\nSUITE ERROR: " + (err && err.stack ? err.stack : err));
  fail++;
}

async function withLoginAsync() {
  psql("alter role pd_app login", "postgres");
  try { await main(); } finally { psql("alter role pd_app nologin", "postgres"); }
}

console.log("\n=== RESULTS ===");
results.forEach(([s, n, okv, d], i) =>
  console.log(`${i + 1}|${s}|${n}|${okv ? "PASS" : "*** FAIL ***"}|${d}`));
console.log(`\n${fail ? `${fail} HUB TEST(S) FAILED` : `all ${pass} hub tests passed`}`);
process.exit(fail ? 1 : 0);
