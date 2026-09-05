/**
 * product/test/test-api.mjs -- the Vercel functions, over real HTTP, against a
 * real database.
 *
 *   node product/test/test-api.mjs            builds pd_t_api and runs
 *   node product/test/test-api.mjs --db X     against a database you built
 *
 * WHY THIS EXISTS SEPARATELY FROM product/hub/test/api.test.mjs. That suite
 * attacks the data layer by calling it directly. This one runs the ACTUAL
 * FUNCTIONS Vercel will run, over an actual socket, with cookies -- because
 * everything between the tested library and a working endpoint is new code:
 * the Node-to-Web adapter, the cookie plumbing, the preview sign-in, and the
 * fact that a query string has to stand in for a path parameter.
 *
 * THE CLAIM. A person can sign in, see only their own team, and see nothing of
 * anybody else's -- and every refusal comes from the database rather than from
 * a check in a handler.
 *
 * WHAT IT CANNOT PROVE:
 *   * That Vercel's runtime behaves like this Node server. Same handler
 *     signature and same Node major, but the platform is not under test.
 *   * That the preview sign-in is safe to expose. It is not, and api/signin.js
 *     says so at the top: it stands in for an identity provider that does not
 *     exist yet.
 */
import { createServer } from "node:http";
import { execFileSync } from "node:child_process";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const require_ = createRequire(import.meta.url);
const arg = (f, d) => { const i = process.argv.indexOf(f); return i > -1 ? process.argv[i + 1] : d; };
const DB = arg("--db", "pd_t_api");
const PORT = 8421;

const psql = (sql, db = DB) =>
  execFileSync("psql", ["-h", "/tmp", "-p", "5433", "-U", "app", "-d", db, "-tAq", "-c", sql],
    { encoding: "utf8" }).trim();

// Seed identities, from product/db/seed.sql.
const DOM = "d0000000-0000-4000-8000-000000000001";      // assistant, Lehi 8
const OSTLER = "d0000000-0000-4000-8000-000000000007";   // head, Logan 8, other league
const STRANGER = "d0000000-0000-4000-8000-00000000000a"; // no seat anywhere
const LEHI8 = "c0000000-0000-4000-8000-000000000001";
const LOGAN8 = "c0000000-0000-4000-8000-000000000004";

const SECRET = "preview-passphrase-for-the-suite";
process.env.HUB_SIGNIN_SECRET = SECRET;
process.env.HUB_SESSION_SECRET = "a-test-secret-at-least-sixteen-chars";
process.env.HUB_DATABASE_URL = `postgresql://pd_app@localhost:5433/${DB}?host=/tmp`;

let pass = 0, fail = 0;
const rows = [];
let section = "-";
const sect = (s) => { section = s; console.log("\n=== " + s + " ==="); };
function ok(name, cond, detail = "") {
  if (cond) { pass++; rows.push([section, name, true, detail]); }
  else { fail++; rows.push([section, name, false, detail]); console.log(`  *** FAIL *** ${name}${detail ? "  -- " + detail : ""}`); }
}
const eq = (name, got, want) =>
  ok(name, String(got) === String(want), `got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);

// --- build the database -----------------------------------------------------
function build() {
  try { execFileSync("dropdb", ["-h", "/tmp", "-p", "5433", "-U", "app", "--if-exists", DB], { stdio: "ignore" }); } catch {}
  execFileSync("createdb", ["-h", "/tmp", "-p", "5433", "-U", "app", DB], { stdio: "inherit" });
  execFileSync(process.execPath, [join(ROOT, "product/db/migrate.mjs"), "--db", DB],
    { stdio: ["ignore", "ignore", "inherit"] });
  for (const s of ["seed.sql", "auth-seed.sql", "platform-seed.sql"]) {
    execFileSync("psql", ["-h", "/tmp", "-p", "5433", "-U", "app", "-d", DB, "-tAq", "-v", "ON_ERROR_STOP=1",
      "-f", join(ROOT, "product/db", s)], { stdio: ["ignore", "ignore", "inherit"] });
  }
}
if (!process.argv.includes("--db")) build();

// pd_app is NOLOGIN by design; the suite lends it LOGIN and takes it back.
psql("alter role pd_app login", "postgres");

// --- serve the real functions ----------------------------------------------
const ROUTES = {
  "/api/me": require_(join(ROOT, "api/me.js")),
  "/api/signin": require_(join(ROOT, "api/signin.js")),
  "/api/signout": require_(join(ROOT, "api/signout.js")),
  "/api/roster": require_(join(ROOT, "api/roster.js")),
  "/api/plays": require_(join(ROOT, "api/plays.js")),
  "/api/team": require_(join(ROOT, "api/team.js")),
  "/api/player": require_(join(ROOT, "api/player.js")),
};
const server = createServer((req, res) => {
  const u = new URL(req.url, "http://localhost");
  const fn = ROUTES[u.pathname];
  if (!fn) { res.statusCode = 404; return res.end("no such function"); }
  fn(req, res);
});
await new Promise((r) => server.listen(PORT, r));

let cookie = null;
async function call(path, { method = "GET", body, useCookie = true } = {}) {
  const headers = {};
  if (body !== undefined) headers["content-type"] = "application/json";
  if (useCookie && cookie) headers.cookie = cookie;
  const r = await fetch(`http://localhost:${PORT}${path}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  });
  const set = r.headers.getSetCookie ? r.headers.getSetCookie() : [];
  const text = await r.text();
  let json = null;
  try { json = JSON.parse(text); } catch { /* not json */ }
  return { status: r.status, json, text, setCookie: set };
}

try {
  // -------------------------------------------------------------------------
  sect("0. CONTROL -- there is something to see, and something to be refused");
  // -------------------------------------------------------------------------
  ok("the database has both leagues' children",
     Number(psql(`select count(*) from public.players where team_id='${LEHI8}'`)) === 21
     && Number(psql(`select count(*) from public.players where team_id='${LOGAN8}'`)) >= 1);
  eq("and pd_app still holds no table privilege",
     psql("select count(*)::text from information_schema.table_privileges where grantee='pd_app'"), "0");

  // -------------------------------------------------------------------------
  sect("1. Signed out");
  // -------------------------------------------------------------------------
  let r = await call("/api/me");
  eq("GET /api/me answers 200 for a visitor", r.status, 200);
  eq("and says it is not signed in", r.json.signed_in, false);
  eq("with no teams", r.json.teams.length, 0);
  eq("and no leagues", r.json.leagues.length, 0);
  eq("running as the anonymous database role", r.json.db_role, "pd_anon");
  eq("and not a platform owner", r.json.is_platform_owner, false);

  r = await call("/api/roster?team=" + LEHI8);
  ok("a visitor asking for a real team's roster gets nothing", r.status === 404 || (r.json && (r.json.players || []).length === 0),
     r.status + " " + r.text.slice(0, 80));

  // -------------------------------------------------------------------------
  sect("2. The preview door refuses before it opens");
  // -------------------------------------------------------------------------
  r = await call("/api/signin", { method: "GET" });
  eq("GET is refused", r.status, 405);

  r = await call("/api/signin", { method: "POST", body: { user_id: DOM } });
  eq("no passphrase is refused", r.status, 401);

  r = await call("/api/signin", { method: "POST", body: { passphrase: "wrong", user_id: DOM } });
  eq("a wrong passphrase is refused", r.status, 401);
  eq("with the same answer as no passphrase at all", r.json.error, "No.");

  r = await call("/api/signin", { method: "POST", body: { passphrase: SECRET, user_id: "not-a-uuid" } });
  eq("a non-uuid account is refused", r.status, 400);

  r = await call("/api/signin", { method: "POST", body: { passphrase: SECRET, user_id: STRANGER } });
  eq("an account with no seat anywhere is refused", r.status, 403);
  ok("and told why", /no seat/i.test(r.json.error), r.json.error);
  eq("no cookie was set by a refusal", r.setCookie.length, 0);

  // -------------------------------------------------------------------------
  sect("3. Signed in as Dom");
  // -------------------------------------------------------------------------
  r = await call("/api/signin", { method: "POST", body: { passphrase: SECRET, user_id: DOM, email: "dom@example.com" } });
  eq("the right passphrase and a real account signs in", r.status, 200);
  ok("and sets a cookie", r.setCookie.length === 1, JSON.stringify(r.setCookie));
  const c = r.setCookie[0] || "";
  ok("HttpOnly", /HttpOnly/i.test(c), c);
  ok("SameSite=Lax", /SameSite=Lax/i.test(c), c);
  ok("Secure", /Secure/i.test(c), c);
  ok("and it says out loud that this is a preview door", r.json.preview === true);
  cookie = c.split(";")[0];

  r = await call("/api/me");
  eq("/api/me now says signed in", r.json.signed_in, true);
  eq("as Dom", r.json.user_id, DOM);
  eq("running as the signed-in database role", r.json.db_role, "pd_authenticated");
  eq("he holds one team", r.json.teams.length, 2);
  ok("both of them Lehi", r.json.teams.every((t) => t.name === "Lehi"), JSON.stringify(r.json.teams.map((t) => t.name)));
  eq("as an assistant", r.json.teams[0].role, "assistant");
  eq("and he is not a platform owner", r.json.is_platform_owner, false);

  r = await call("/api/roster?team=" + LEHI8);
  eq("he can read his own roster", r.status, 200);
  eq("all twenty-one of them", r.json.players.length, 21);
  ok("with names, because he coaches them", r.json.players.some((p) => p.last === "Bagley"),
     JSON.stringify(r.json.players.slice(0, 2)));

  r = await call("/api/plays?team=" + LEHI8);
  eq("and his playbook", r.status, 200);
  ok("with plays in it", r.json.plays.length >= 1, String(r.json.plays.length));

  // -----------------------------------------------------------------------
  sect("4. THE POINT -- he sees nothing of the other league");
  // -----------------------------------------------------------------------
  ok("CONTROL Logan's children really exist",
     Number(psql(`select count(*) from public.players where team_id='${LOGAN8}'`)) >= 1);

  r = await call("/api/roster?team=" + LOGAN8);
  ok("naming the other league's team by uuid returns nothing",
     r.status === 404 || (r.json && (r.json.players || []).length === 0),
     r.status + " " + r.text.slice(0, 100));
  ok("and no surname from it appears in the response",
     !/Ostler|Nielsen/.test(r.text), r.text.slice(0, 120));

  r = await call("/api/plays?team=" + LOGAN8);
  ok("nor its playbook", r.status === 404 || (r.json && (r.json.plays || []).length === 0),
     r.status + " " + r.text.slice(0, 80));

  // -----------------------------------------------------------------------
  sect("5. A forged cookie is nobody");
  // -----------------------------------------------------------------------
  const good = cookie;
  const [k, v] = good.split("=");
  cookie = k + "=" + (v[0] === "A" ? "B" : "A") + v.slice(1);
  r = await call("/api/me");
  eq("a tampered cookie reads as signed out", r.json.signed_in, false);
  eq("and sees no team", r.json.teams.length, 0);
  cookie = good;
  eq("CONTROL the real cookie still works", (await call("/api/me")).json.signed_in, true);

  // -----------------------------------------------------------------------
  sect("6. Another coach, the other way round");
  // -----------------------------------------------------------------------
  cookie = null;
  r = await call("/api/signin", { method: "POST", body: { passphrase: SECRET, user_id: OSTLER, email: "ostler@example.com" } });
  eq("Ostler signs in", r.status, 200);
  cookie = (r.setCookie[0] || "").split(";")[0];

  r = await call("/api/me");
  eq("he holds his own team", r.json.teams.length, 1);
  eq("and it is Logan", r.json.teams[0].name, "Logan");

  r = await call("/api/roster?team=" + LEHI8);
  ok("and Lehi's roster is nothing to him",
     r.status === 404 || (r.json && (r.json.players || []).length === 0), r.status + " " + r.text.slice(0, 80));
  ok("no Lehi surname reaches him", !/Bagley|Archuletta/.test(r.text), r.text.slice(0, 120));

  // -----------------------------------------------------------------------
  sect("6b. The coach hub's one round trip");
  // -----------------------------------------------------------------------
  // Still signed in as Ostler from section 6.
  r = await call("/api/team?team=" + LOGAN8);
  eq("a coach can pull his own team in one request", r.status, 200);
  eq("with the team on it", r.json.team.name, "Logan");
  ok("its staff", r.json.staff.length >= 1, JSON.stringify(r.json.staff));
  ok("its roster", r.json.roster.length >= 1, String(r.json.roster.length));
  ok("and what the database would let him do", typeof r.json.may.staff === "boolean");
  eq("he is head, so he may staff it", r.json.may.staff, true);

  r = await call("/api/team?team=" + LEHI8);
  ok("and the other league's team is 404, not a partial answer",
     r.status === 404, r.status + " " + r.text.slice(0, 90));
  ok("with no Lehi surname anywhere in it", !/Bagley|Archuletta/.test(r.text), r.text.slice(0, 100));

  r = await call("/api/team?team=" + LOGAN8 + "&do=word", { method: "POST" });
  eq("he can rotate his own boys' word", r.status, 200);
  ok("and it is shown exactly once", r.json.shown_once === true && typeof r.json.word === "string"
     && r.json.word.length > 4, JSON.stringify(r.json).slice(0, 80));
  const word1 = r.json.word;
  r = await call("/api/team?team=" + LOGAN8 + "&do=word", { method: "POST" });
  ok("rotating again gives a different word", r.json.word !== word1);

  r = await call("/api/team?team=" + LEHI8 + "&do=word", { method: "POST" });
  ok("but he cannot rotate the other league's", r.status >= 400, String(r.status));

  // A new spot is a jersey and nothing else -- 0007's gate, through the API.
  const before = (await call("/api/team?team=" + LOGAN8)).json.roster.length;
  r = await call("/api/team?team=" + LOGAN8 + "&do=player", { method: "POST", body: { jersey: "88" } });
  eq("he can add a roster spot", r.status, 201);
  eq("and it arrives unnamed", r.json.named, false);
  eq("as a jersey placeholder", r.json.player.last, "#88");
  const after = (await call("/api/team?team=" + LOGAN8)).json.roster;
  eq("the roster grew by one", after.length, before + 1);
  ok("and the new one is not named", after.some((p) => p.jersey === "88" && p.named === false));

  r = await call("/api/team?team=" + LOGAN8 + "&do=staff", { method: "POST", body: { email: "newcoach@example.com", role: "assistant" } });
  eq("a head coach can invite an assistant", r.status, 201);
  ok("and the token is shown once", r.json.shown_once === true && r.json.token.length > 20);

  r = await call("/api/team?team=" + LOGAN8 + "&do=nonsense", { method: "POST" });
  eq("an unknown action is refused", r.status, 400);

  // -----------------------------------------------------------------------
  sect("6c. An assistant coaches. He does not staff.");
  // -----------------------------------------------------------------------
  cookie = null;
  r = await call("/api/signin", { method: "POST", body: { passphrase: SECRET, user_id: DOM, email: "dom@example.com" } });
  cookie = (r.setCookie[0] || "").split(";")[0];

  r = await call("/api/team?team=" + LEHI8);
  eq("Dom pulls his own team", r.status, 200);
  eq("and the screen is told he may not staff it", r.json.may.staff, false);
  eq("but that he may manage its consent", r.json.may.consent, true);
  // NOT a staffing action, and the first draft of this suite got it wrong the
  // same way the screen did. 0004_auth.sql: "Dom's seat is assistant and the
  // boys' page is his ... which is why it is not restricted to the head."
  eq("and that he MAY rotate the boys' word", r.json.may.word, true);

  r = await call("/api/team?team=" + LEHI8 + "&do=staff", { method: "POST", body: { email: "x@example.com", role: "assistant" } });
  ok("and the database refuses the invitation anyway", r.status >= 400, String(r.status));
  r = await call("/api/team?team=" + LEHI8 + "&do=word", { method: "POST" });
  eq("and he can: the word is the assistant's, not the head's", r.status, 200);
  r = await call("/api/team?team=" + LOGAN8 + "&do=word", { method: "POST" });
  ok("though not for a team he does not coach", r.status >= 400, String(r.status));

  // -----------------------------------------------------------------------
  sect("7. Signing out");
  // -----------------------------------------------------------------------
  r = await call("/api/signout", { method: "GET" });
  eq("signout is POST only", r.status, 405);
  r = await call("/api/signout", { method: "POST" });
  eq("signing out succeeds", r.status, 200);
  ok("and clears the cookie", (r.setCookie[0] || "").includes("Max-Age=0")
     || (r.setCookie[0] || "").toLowerCase().includes("expires="), JSON.stringify(r.setCookie));

  // -----------------------------------------------------------------------
  sect("8. With no database configured, it says so rather than breaking");
  // -----------------------------------------------------------------------
  // A fresh child process, because the pool is configured once per process.
  const probe = execFileSync(process.execPath, ["-e", `
    delete process.env.HUB_DATABASE_URL; delete process.env.DATABASE_URL;
    const h = require(${JSON.stringify(join(ROOT, "api/me.js"))});
    const res = { statusCode: 0, body: "", setHeader(){}, end(b){ this.body = b;
      console.log(JSON.stringify({ status: this.statusCode, body: String(b) })); } };
    h({ method: "GET", url: "/api/me", headers: {}, on(){} }, res);
  `], { encoding: "utf8" });
  const p = JSON.parse(probe.trim());
  eq("an unconfigured deployment answers 501", p.status, 501);
  ok("and names the variable that is missing", /HUB_DATABASE_URL/.test(p.body), p.body.slice(0, 120));
} finally {
  server.close();
  try { psql("alter role pd_app nologin", "postgres"); } catch {}
}

console.log("\n=== RESULTS ===");
rows.forEach(([s, n, okv, d], i) =>
  console.log(`${i + 1}|${s}|${n}|${okv ? "PASS" : "*** FAIL ***"}|${d}`));
console.log(`\n${fail ? `${fail} API TEST(S) FAILED` : `all ${pass} api tests passed`}`);
process.exit(fail ? 1 : 0);
