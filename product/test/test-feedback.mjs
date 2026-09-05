/**
 * product/test/test-feedback.mjs -- the lightbulb, both halves.
 *
 *   node product/test/test-feedback.mjs
 *
 * The API half runs in Node against api/feedback.js directly. The browser half
 * drives designer.html and index.html with a fake /api/feedback, because the
 * behaviour that matters most is what happens when the send FAILS.
 *
 * THE CLAIM. A note is never lost and never lied about: a send that does not
 * come back 200 leaves it on the device and says so, and the next load tries
 * again. And nothing a coach types can publish a child's name on a public repo.
 *
 * WHY THOSE TWO. The save badge lying is the bug this project has paid for most
 * (CLAUDE.md rule 5), and a feedback button is a second badge. The redaction is
 * because api/feedback.js files a GitHub issue on a repo that is public, and a
 * coach reporting "Bagley's circle is wrong" is being helpful, not careless.
 *
 * WHAT IT CANNOT CHECK: that GitHub accepts the issue. That needs a token and a
 * network, and the endpoint's own failure path -- keep it locally, say so -- is
 * what this proves instead.
 */
import { createServer } from "node:http";
import { readFileSync, existsSync, statSync } from "node:fs";
import { join, extname, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";
import { Readable } from "node:stream";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const require_ = createRequire(import.meta.url);
const PORT = 8407;

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

// ---------------------------------------------------------------------------
sect("1. Redaction -- the repo is public");
// ---------------------------------------------------------------------------
const api = require_(join(ROOT, "api", "feedback.js"));
const { redact } = api;

ok("an email address never reaches the issue",
   !redact("write to bagley.parent@example.com about it").includes("@example.com"),
   redact("write to bagley.parent@example.com about it"));
ok("nor a phone number",
   !/\d{3}[\s.-]?\d{4}/.test(redact("call me on 801-555-0134")),
   redact("call me on 801-555-0134"));
ok("a surname beside a jersey number is stripped",
   !redact("Bagley #27 is drawn in the wrong place").includes("Bagley"),
   redact("Bagley #27 is drawn in the wrong place"));
ok("and the other way round",
   !redact("#27 Bagley is drawn in the wrong place").includes("Bagley"),
   redact("#27 Bagley is drawn in the wrong place"));

// Football words must survive, or the report becomes unreadable and he stops
// using it. This is the half of redaction that gets forgotten.
const kept = redact("The left gunner on Punt Base ends up outside the sideline");
ok("ordinary football language is left alone", kept.includes("gunner") && kept.includes("Punt Base"), kept);
eq("and an empty message stays empty", redact(""), "");
eq("null does not throw", redact(null), "");

// ---------------------------------------------------------------------------
sect("2. The endpoint refuses what it should");
// ---------------------------------------------------------------------------
function callApi(body, { method = "POST", env = {} } = {}) {
  const keep = { ...process.env };
  Object.assign(process.env, env);
  return new Promise((resolve) => {
    // A REAL readable stream, not a stub with a no-op .on(). readBody() falls
    // back to reading the stream when req.body is absent, and a stub that never
    // emits 'end' leaves the handler waiting forever -- which showed up as an
    // unsettled top-level await rather than as a failing test.
    const req = Object.assign(
      Readable.from(body === undefined ? [] : [JSON.stringify(body)]),
      { method, headers: {}, socket: { remoteAddress: "10.0.0." + Math.floor(Math.random() * 250) } });
    if (body !== null && body !== undefined) req.body = body;
    const res = {
      statusCode: 0, _json: null,
      setHeader() {},
      status(c) { this.statusCode = c; return this; },
      json(j) { this._json = j; Object.assign(process.env, keep); resolve({ status: this.statusCode, json: j }); }
    };
    api(req, res);
  });
}

let r = await callApi({ kind: "idea", message: "hello there" }, { method: "GET" });
eq("GET is refused", r.status, 405);

r = await callApi({ kind: "idea", message: "hello there" }, { env: { GITHUB_TOKEN: "" } });
eq("with no token it returns 501", r.status, 501);
ok("and tells the app to keep the note locally", r.json.keepLocal === true, JSON.stringify(r.json));

r = await callApi({ kind: "nonsense", message: "hello there" }, { env: { GITHUB_TOKEN: "x" } });
eq("an unknown kind is refused", r.status, 400);

r = await callApi({ kind: "idea", message: "hi" }, { env: { GITHUB_TOKEN: "x" } });
eq("a two-character message is refused", r.status, 400);

r = await callApi(undefined, { env: { GITHUB_TOKEN: "x" } });
eq("an empty body is refused", r.status, 400);

// ---------------------------------------------------------------------------
sect("3. In the browser -- and especially when sending fails");
// ---------------------------------------------------------------------------
let chromium;
for (const cand of [process.env.PLAYWRIGHT_PATH, "playwright",
                    join(ROOT, "product", "hub", "node_modules", "playwright")].filter(Boolean)) {
  try { ({ chromium } = require_(cand)); break; } catch { /* keep looking */ }
}

if (!chromium) {
  console.log("  (browser half SKIPPED: playwright is not installed)");
} else {
  const EXE = process.env.CHROME_PATH || "/opt/pw-browsers/chromium-1194/chrome-linux/chrome";
  const MIME = { ".html": "text/html", ".js": "text/javascript", ".json": "application/json",
                 ".css": "text/css", ".svg": "image/svg+xml" };
  let mode = "ok", posted = [];
  const server = createServer((req, res) => {
    const u = new URL(req.url, "http://x");
    if (u.pathname === "/api/feedback") {
      let raw = ""; req.on("data", (c) => { raw += c; });
      req.on("end", () => {
        posted.push(JSON.parse(raw || "{}"));
        if (mode === "ok") { res.writeHead(200, { "content-type": "application/json" });
          return res.end(JSON.stringify({ ok: true, number: 42 })); }
        if (mode === "501") { res.writeHead(501, { "content-type": "application/json" });
          return res.end(JSON.stringify({ error: "not set up", keepLocal: true })); }
        res.writeHead(502, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: "boom", keepLocal: true }));
      });
      return;
    }
    if (u.pathname === "/favicon.ico") { res.writeHead(204); return res.end(); }
    let p = u.pathname === "/" ? "/index.html" : u.pathname;
    let f = join(ROOT, p);
    if (!existsSync(f) && existsSync(f + ".html")) f = f + ".html";
    if (!existsSync(f) || statSync(f).isDirectory()) { res.writeHead(404); return res.end("nf"); }
    res.writeHead(200, { "content-type": MIME[extname(f)] || "application/octet-stream" });
    res.end(readFileSync(f));
  });
  await new Promise((r2) => server.listen(PORT, r2));
  const browser = await chromium.launch({ headless: true, executablePath: EXE, args: ["--no-sandbox"] });

  try {
    for (const path of ["/designer", "/"]) {
      const page = await browser.newPage({ viewport: { width: 390, height: 844 } });
      // Two different things, kept apart. A pageerror is a script that threw
      // and is never acceptable. A console error is often just the browser
      // noting an HTTP status -- and this suite DELIBERATELY makes /api/feedback
      // answer 502 and 501, so counting those as failures marks the test's own
      // scenario as a bug. Requests the page makes that this server does not
      // implement (/api/save-playbook) are the same kind of noise.
      const thrown = [];
      const badUrls = [];
      page.on("pageerror", (e) => thrown.push(e.message));
      page.on("console", (m) => {
        // "Failed to load resource: ... 404" carries no URL, so it cannot be
        // told apart from the 502 this suite causes on purpose. The response
        // event does carry one; that is what gets judged.
        if (m.type() === "error" && !/Failed to load resource/.test(m.text())) thrown.push(m.text());
      });
      page.on("response", (r) => { if (r.status() >= 400) badUrls.push(r.status() + " " + r.url()); });

      mode = "ok"; posted = [];
      await page.goto(`http://localhost:${PORT}${path}`, { waitUntil: "networkidle" });

      ok(`${path}: the lightbulb is on the page`, await page.isVisible("#fbFab"));
      const box = await page.locator("#fbFab").boundingBox();
      const vp = page.viewportSize();
      ok(`${path}: bottom right, and on screen`,
         box.x + box.width <= vp.width && box.y + box.height <= vp.height
         && box.x > vp.width / 2 && box.y > vp.height / 2,
         JSON.stringify(box));
      ok(`${path}: the panel is shut until asked for`, !(await page.isVisible("#fbPanel")));

      await page.click("#fbFab");
      await page.waitForTimeout(200);
      ok(`${path}: clicking opens it`, await page.isVisible("#fbPanel"));

      // A GOOD SEND.
      await page.click("#fbKindProblem");
      await page.fill("#fbText", "The left gunner ends up outside the sideline");
      await page.click("#fbSend");
      await page.waitForTimeout(400);
      ok(`${path}: a successful send says so`, /Sent/i.test(await page.textContent("#fbStatus")),
         (await page.textContent("#fbStatus")).trim());
      eq(`${path}: and it posted exactly once`, posted.length, 1);
      eq(`${path}: with the kind he picked`, posted[0].kind, "problem");
      ok(`${path}: and context naming the page and build`,
         /page /.test(posted[0].context) && /build b/.test(posted[0].context), posted[0].context);
      ok(`${path}: the context carries no roster`,
         !/last|first|roster/i.test(posted[0].context), posted[0].context);
      eq(`${path}: the box is cleared after a send`, await page.inputValue("#fbText"), "");
      eq(`${path}: and nothing is left queued`,
         await page.evaluate(() => JSON.parse(localStorage.getItem("pd-feedback-queue") || "[]").length), 0);

      // THE PART THAT MATTERS. A failed send must keep the note and say so.
      mode = "502"; posted = [];
      await page.fill("#fbText", "Second thought, the aim mark is off");
      await page.click("#fbSend");
      await page.waitForTimeout(400);
      const st = (await page.textContent("#fbStatus")).trim();
      ok(`${path}: a failed send does NOT claim success`, !/^Sent/i.test(st), st);
      ok(`${path}: it says the note is on the device`, /Saved on this device/i.test(st), st);
      eq(`${path}: and the note really is queued`,
         await page.evaluate(() => JSON.parse(localStorage.getItem("pd-feedback-queue") || "[]").length), 1);
      ok(`${path}: the badge shows there is one waiting`, await page.isVisible("#fbDot"));

      // AND IT RETRIES. Reload with the server healthy again.
      mode = "ok"; posted = [];
      await page.reload({ waitUntil: "networkidle" });
      await page.waitForTimeout(2200);
      eq(`${path}: the queued note is sent on the next load`, posted.length, 1);
      eq(`${path}: and the queue is empty afterwards`,
         await page.evaluate(() => JSON.parse(localStorage.getItem("pd-feedback-queue") || "[]").length), 0);
      ok(`${path}: the badge is gone`, !(await page.isVisible("#fbDot")));

      // 501 is a different message: not broken, just not switched on.
      mode = "501";
      await page.click("#fbFab"); await page.waitForTimeout(150);
      await page.fill("#fbText", "A third note while it is switched off");
      await page.click("#fbSend");
      await page.waitForTimeout(400);
      ok(`${path}: when sending is not set up it says that, not "failed"`,
         /not switched on/i.test(await page.textContent("#fbStatus")),
         (await page.textContent("#fbStatus")).trim());
      await page.evaluate(() => localStorage.removeItem("pd-feedback-queue"));

      ok(`${path}: nothing threw through any of it`, thrown.length === 0, thrown.join(" ; "));
      // /api/save-playbook is the coach app asking whether saving to the repo
      // is configured; a static test server has no such function, and the live
      // site answers it. The 502 and 501 are this suite's own doing.
      ok(`${path}: and the only failing requests are ones this test explains`,
         badUrls.every((u) => /\/api\/(save-playbook|feedback)/.test(u)),
         badUrls.join(" ; "));
      await page.close();
    }

    // It must not print, and must not show on game day -- the same list the
    // game-day bar once leaked out of.
    const page = await browser.newPage({ viewport: { width: 390, height: 844 } });
    await page.goto(`http://localhost:${PORT}/designer`, { waitUntil: "networkidle" });
    await page.emulateMedia({ media: "print" });
    ok("it does not print", !(await page.isVisible("#fbFab")));
    await page.emulateMedia({ media: "screen" });
    await page.evaluate(() => document.body.classList.add("gd"));
    await page.waitForTimeout(100);
    ok("and it is hidden on game day", !(await page.isVisible("#fbFab")));
    await page.close();
  } finally {
    await browser.close();
    server.close();
  }
}

// ---------------------------------------------------------------------------
sect("4. One source, inlined -- the copies have not drifted");
// ---------------------------------------------------------------------------
const { execFileSync } = await import("node:child_process");
let synced = true;
try { execFileSync(process.execPath, [join(ROOT, "scripts", "sync-feedback.js"), "--check"], { stdio: "pipe" }); }
catch { synced = false; }
ok("scripts/sync-feedback.js --check passes", synced);
ok("learn.html deliberately does NOT carry it",
   !readFileSync(join(ROOT, "learn.html"), "utf8").includes("fbFab"));

console.log("\n=== RESULTS ===");
rows.forEach(([s, n, okv, d], i) =>
  console.log(`${i + 1}|${s}|${n}|${okv ? "PASS" : "*** FAIL ***"}|${d}`));
console.log(`\n${fail ? `${fail} FEEDBACK TEST(S) FAILED` : `all ${pass} feedback tests passed`}`);
process.exit(fail ? 1 : 0);
