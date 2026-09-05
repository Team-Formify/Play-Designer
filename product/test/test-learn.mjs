/**
 * product/test/test-learn.mjs -- the boys' page, driven in a real browser.
 *
 *   node product/test/test-learn.mjs                 # serves the repo itself
 *   node product/test/test-learn.mjs --url http://…  # or point it somewhere
 *
 * WHY A BROWSER AND NOT A PARSER. CLAUDE.md has the rule and the scar tissue
 * behind it: "Every real bug this project has produced -- the save badge lying,
 * the game-day bar leaking onto the normal screen, names stacked unreadably on
 * a kickoff, lanes crossing each other -- was invisible in the source and
 * obvious in a screenshot or a measurement." learn.html is the one shipped
 * surface that had never been driven at all. It is also the one a twelve-year-old
 * opens on his own phone with nobody next to him, which is the worst possible
 * place for a silent failure.
 *
 * WHAT THIS FILE CHECKS, IN ONE SENTENCE. That the page loads its playbook,
 * draws every play in it without a script error, and that all three modes --
 * Watch it, Line me up, My job -- actually do their thing rather than merely
 * being present in the markup.
 *
 * WHAT IT CANNOT CHECK:
 *   * Whether the plays are good football. That is Dom's, not a test's.
 *   * How it feels on a real phone over a real network. It runs one viewport
 *     at 390px, which catches layout that overflows and nothing about latency.
 *   * That the boys understand it. The quiz can be proved answerable and
 *     scoreable; it cannot be proved teachable.
 *
 * MUTATION RUN. Each behaviour was broken on purpose and the red count taken:
 *
 *   the quiz never marks an answer .................. 14 tests go red
 *   Line me up never scores a tap ................... 12
 *   the clock never advances (men frozen at t=0) ....  4
 *   collision rings are never drawn .................  4
 *   the Them toggle does nothing ....................  4
 *   no browser-tab icon declared ....................  4
 *   no home-screen icon declared ....................  4
 *   scoring always says "that is the spot" ..........  2
 *   Next man does not clear the last verdict ........  2
 *   rings never fill in .............................  2
 *   the play dropdown is left empty .................  2
 *
 * THREE ASSERTIONS IN THE FIRST DRAFT WERE WRONG, and each one is a different
 * way to write a test that cannot fail:
 *
 *   * "answering marks the buttons" checked for a class other than "btn". The
 *     option buttons ship with class "opt", so it was true before anything was
 *     clicked. Making the quiz unanswerable left it green. It checks for the
 *     "right"/"wrong" grade classes now.
 *   * "tapping the field scores in yards" tapped the middle and required the
 *     word "yards". It failed about half the time -- and not randomly: when the
 *     man it asked about was the SNAPPER, who stands in the middle, the tap was
 *     CORRECT and the page says "That is the spot." with no yardage in it. The
 *     suite was flaky because it was wrong about the feature. It now taps
 *     exactly where the man stands, through the SVG's own screen matrix, and
 *     checks both verdicts deliberately.
 *   * "the page declares an icon" accepted rel="icon" OR rel="apple-touch-icon".
 *     Removing either one left it green. They do different jobs and are checked
 *     separately.
 *
 * AND ONE "BUG" THAT WAS NOT ONE. An early probe reported that the collision
 * rings only appear once men reach each other, contradicting CLAUDE.md. They do
 * not: a ring not yet reached is r=9 and dashed, a reached one is r=11 filled
 * plus an r=2.6 dot, and the probe was only counting the dots. The opposing
 * eleven are not circles at all -- they are crossed <line>s. Measuring the
 * wrong element and then trusting the number is how a good page gets "fixed".
 */
import { createServer } from "node:http";
import { readFileSync, existsSync, statSync, readdirSync } from "node:fs";
import { join, extname, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const arg = (f) => { const i = process.argv.indexOf(f); return i > -1 ? process.argv[i + 1] : null; };
const PORT = 8399;

// Playwright is a test-only tool and deliberately not a dependency of this
// repo -- the single-file, no-build property is why the app works on a phone on
// a practice field. It is resolved from wherever it happens to be installed,
// and the suite says so plainly rather than failing with a stack trace.
const require_ = createRequire(import.meta.url);
let chromium;
for (const cand of [
  process.env.PLAYWRIGHT_PATH,            // an explicit answer wins
  "playwright",                           // installed beside this repo
  join(ROOT, "product", "hub", "node_modules", "playwright"),
].filter(Boolean)) {
  try { ({ chromium } = require_(cand)); break; } catch { /* keep looking */ }
}
if (!chromium) {
  // SKIP, not fail. playwright is a test-only tool and a browser download; a
  // contributor on a practice-field laptop should not have a red build because
  // of it. `node product/db/test.mjs` reports this as SKIPPED and moves on.
  console.log("SKIPPED: playwright is not installed.");
  console.log("  PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm i playwright");
  console.log("  or point PLAYWRIGHT_PATH at an existing install.");
  process.exit(0);
}

// Chromium is pre-installed in this environment at a pinned build; the version
// playwright wants and the version present do not always match, so the binary
// is named rather than discovered.
// Chromium may be pre-installed at a pinned build that does not match the one
// playwright expects, in which case launching without an executablePath fails
// with "Executable doesn't exist". Any chromium under PLAYWRIGHT_BROWSERS_PATH
// will do; undefined means "let playwright decide", which is right when its own
// download is present.
const EXE = process.env.CHROME_PATH || (() => {
  const base = process.env.PLAYWRIGHT_BROWSERS_PATH || "/opt/pw-browsers";
  try {
    const dir = readdirSync(base).filter((d) => /^chromium-\d+$/.test(d)).sort().pop();
    const p = dir && join(base, dir, "chrome-linux", "chrome");
    return p && existsSync(p) ? p : undefined;
  } catch { return undefined; }
})();

const MIME = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript",
  ".json": "application/json", ".css": "text/css", ".svg": "image/svg+xml",
  ".png": "image/png", ".ico": "image/x-icon" };

/** Vercel has cleanUrls on, so /learn must serve learn.html. Same here, or the
 *  suite would be testing a URL the site does not have. */
function serve() {
  return new Promise((resolve) => {
    const s = createServer((req, res) => {
      let p = decodeURIComponent(new URL(req.url, "http://x").pathname);
      // The pages carry their icon inline as a data URI, so a request for
      // /favicon.ico means one of them forgot to declare it. Answered 204 here
      // rather than 404 so the assertion below is the thing that catches it,
      // instead of a bare console error nobody reads.
      if (p === "/favicon.ico") { res.writeHead(204); return res.end(); }
      if (p === "/") p = "/index.html";
      let f = join(ROOT, p);
      if (!existsSync(f) && existsSync(f + ".html")) f = f + ".html";
      if (!existsSync(f) || statSync(f).isDirectory()) { res.writeHead(404); return res.end("not found"); }
      res.writeHead(200, { "content-type": MIME[extname(f)] || "application/octet-stream" });
      res.end(readFileSync(f));
    });
    s.listen(PORT, () => resolve(s));
  });
}

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

const URL_BASE = arg("--url") || `http://localhost:${PORT}`;

const server = arg("--url") ? null : await serve();
const browser = await chromium.launch({ headless: true, executablePath: EXE, args: ["--no-sandbox"] });

try {
  // A phone, because that is what the boys have. 390px is an iPhone 14.
  const page = await browser.newPage({ viewport: { width: 390, height: 844 } });
  const errors = [];
  page.on("pageerror", (e) => errors.push("pageerror: " + e.message));
  page.on("console", (m) => { if (m.type() === "error") errors.push("console: " + m.text()); });

  // -------------------------------------------------------------------------
  sect("1. It loads, and it loads the playbook");
  // -------------------------------------------------------------------------
  await page.goto(URL_BASE + "/learn", { waitUntil: "networkidle" });
  ok("the page loads with no script error", errors.length === 0, errors.join(" ; "));
  ok("the title names the team", (await page.title()).includes("Lehi"), await page.title());

  const plays = await page.$$eval("#playSel option", (o) => o.map((x) => x.value || x.textContent.trim()));
  ok("the play dropdown is populated from the JSON", plays.length >= 10, `${plays.length} plays`);

  const shipped = JSON.parse(readFileSync(join(ROOT, "special-teams-plays.json"), "utf8"));
  eq("and holds exactly what the shipped playbook holds", plays.length, shipped.plays.length);

  ok("a build chip is on the page, so 'is it updating' is readable",
     (await page.locator("text=/b\\d+/").count()) > 0);

  // Declared inline as a data URI, so it costs no request -- same rule as the
  // absent webfonts. Without it the browser asks for /favicon.ico on every
  // load, gets a 404 from the real site, and a boy who adds the page to his
  // home screen gets a blank square. designer.html had one; learn.html and
  // index.html did not.
  // Two separate links, checked separately, because they do different jobs and
  // an assertion that accepts "either one" passes with the tab icon missing.
  const href = (sel) => page.$$eval(sel, (ls) => (ls[0] && ls[0].getAttribute("href")) || "");
  const tabIcon = await href("link[rel='icon']");
  const homeIcon = await href("link[rel='apple-touch-icon']");
  ok("it declares a browser-tab icon, so /favicon.ico is never requested",
     tabIcon.startsWith("data:image/"), tabIcon.slice(0, 30) || "(none)");
  ok("and a home-screen icon, so a bookmarked page is not a blank square",
     homeIcon.startsWith("data:image/"), homeIcon.slice(0, 30) || "(none)");
  ok("both inline as data URIs, so nothing blocks on the network",
     tabIcon.startsWith("data:") && homeIcon.startsWith("data:"));

  // -------------------------------------------------------------------------
  sect("2. It draws -- every play, not just the first");
  // -------------------------------------------------------------------------
  // WHAT IS A CIRCLE ON THIS FIELD. Worked out by measuring, after a first
  // draft of this suite counted them all together and produced nonsense:
  //   r=12          our eleven
  //   r=9  dashed   a collision ring not yet reached
  //   r=11 + r=2.6  a collision ring reached, and its centre dot
  //   r=9.5, r=2.4  the target mark
  // The opposing eleven are NOT circles at all -- they are drawn as a pair of
  // crossed <line>s each. Counting "#field circle" therefore measures our men,
  // the collisions and the aim together, and changes as the clock runs, which
  // is exactly the sort of thing that makes a suite report a bug that is not
  // there.
  const OURS = "#field circle[r='12']";
  const ourCount = () => page.$$eval(OURS, (c) => c.length);
  // The AIM MARK is drawn in the same warm colour as a collision ring (r=9.5),
  // so "warm circle" alone counts it as a twelfth ring and then reports it as a
  // leak when Them is turned off -- which it is not: the target belongs to the
  // play, not to the opposition. Rings are r=9 (not yet reached) or r=11
  // (reached). Measured, not assumed.
  const RING_R = ["9", "11"];
  const isRing = (c) => (c.getAttribute("stroke") || "").toUpperCase() === "#E58A6B"
                     && ["9", "11"].includes(c.getAttribute("r"));
  const ringCount = () => page.$$eval("#field circle", (cs, rr) =>
    cs.filter((c) => (c.getAttribute("stroke") || "").toUpperCase() === "#E58A6B"
                  && rr.includes(c.getAttribute("r"))).length, RING_R);
  const ringsDashed = () => page.$$eval("#field circle", (cs, rr) =>
    cs.filter((c) => (c.getAttribute("stroke") || "").toUpperCase() === "#E58A6B"
                  && rr.includes(c.getAttribute("r"))
                  && c.getAttribute("stroke-dasharray")).length, RING_R);
  const aimMarks = () => page.$$eval("#field circle", (cs) =>
    cs.filter((c) => (c.getAttribute("stroke") || "").toUpperCase() === "#E58A6B"
                  && c.getAttribute("r") === "9.5").length);

  const drew = [];
  for (const v of plays) {
    await page.selectOption("#playSel", v);
    await page.waitForTimeout(120);
    const n = await ourCount();
    const labels = await page.$$eval("#field text", (t) => t.length);
    drew.push({ v, n, labels });
  }
  const empty = drew.filter((d) => d.n === 0);
  ok("every play draws at least one player", empty.length === 0,
     empty.map((d) => d.v).join(", "));
  const unlabelled = drew.filter((d) => d.labels === 0);
  ok("and every play draws its labels", unlabelled.length === 0,
     unlabelled.map((d) => d.v).join(", "));
  ok("no play threw while drawing", errors.length === 0, errors.join(" ; "));

  // A man drawn outside the field is a man the boy cannot see. The viewBox is
  // 420x500 and the sidelines are at x=14 and x=406.
  const outside = await page.$$eval("#field circle", (cs) =>
    cs.filter((c) => {
      const x = +c.getAttribute("cx"), y = +c.getAttribute("cy");
      return !(x >= 0 && x <= 420 && y >= 0 && y <= 500);
    }).length);
  eq("nobody is drawn outside the viewBox", outside, 0);

  // -------------------------------------------------------------------------
  sect("3. Watch it -- the clock actually moves men");
  // -------------------------------------------------------------------------
  await page.selectOption("#playSel", plays[0]);
  await page.click('.tab[data-m="watch"]');
  await page.waitForTimeout(200);
  ok("the watch controls are shown", await page.isVisible("#watchUI"));
  ok("and the scrub bar with them", await page.isVisible("#scrub"));

  const posAt = () => page.$$eval(OURS, (cs) =>
    cs.map((c) => c.getAttribute("cx") + "," + c.getAttribute("cy")).join("|"));

  await page.fill("#scrub", "0");
  await page.dispatchEvent("#scrub", "input");
  await page.waitForTimeout(120);
  const t0 = await posAt();

  await page.fill("#scrub", "1000");
  await page.dispatchEvent("#scrub", "input");
  await page.waitForTimeout(120);
  const t1 = await posAt();

  ok("scrubbing to the end moves the men", t0 !== t1);
  ok("and there are the same number of them at both ends",
     t0.split("|").length === t1.split("|").length,
     `${t0.split("|").length} vs ${t1.split("|").length}`);

  await page.fill("#scrub", "0");
  await page.dispatchEvent("#scrub", "input");
  await page.waitForTimeout(120);
  eq("scrubbing back puts them exactly where they started", await posAt(), t0);

  // Pressing Play must animate and must not write the halfway picture anywhere.
  await page.click("#playBtn");
  await page.waitForTimeout(500);
  const mid = await posAt();
  ok("pressing Play moves them", mid !== t0);
  await page.waitForTimeout(4000);
  ok("no error during the run", errors.length === 0, errors.join(" ; "));

  // Them: the opposing eleven is derived, and toggling it changes the count.
  // -------------------------------------------------------------------------
  sect("3b. The collision marks, which are the point of Watch it");
  // -------------------------------------------------------------------------
  // CLAUDE.md: "The spot is ringed from the first frame, dashed until they reach
  // it and filled once they do, so a boy sees where his collision is supposed to
  // happen before it does." A boy who only sees the ring appear at the moment of
  // contact learns nothing he could have acted on.
  await page.fill("#scrub", "0");
  await page.dispatchEvent("#scrub", "input");
  await page.waitForTimeout(150);
  const ringsAtStart = await ringCount();
  ok("collision rings are on the field at the very first frame", ringsAtStart > 0, `${ringsAtStart} rings`);
  eq("and every one of them is dashed, because nobody has arrived yet",
     await ringsDashed(), ringsAtStart);

  await page.fill("#scrub", "1000");
  await page.dispatchEvent("#scrub", "input");
  await page.waitForTimeout(150);
  eq("the same rings are still there at the end", await ringCount(), ringsAtStart);
  eq("and by then every one has filled in", await ringsDashed(), 0);

  await page.fill("#scrub", "0");
  await page.dispatchEvent("#scrub", "input");
  await page.waitForTimeout(150);

  const themCross = () => page.$$eval("#field line", (ls) => ls.length);
  const withThem = await themCross();
  const oursWithThem = await ourCount();
  await page.click("#themBtn");
  await page.waitForTimeout(250);
  const withoutThem = await themCross();
  ok("turning Them off removes their crosses from the field", withoutThem < withThem,
     `${withThem} lines with, ${withoutThem} without`);
  eq("and takes the collision rings with them -- there is nobody to collide with",
     await ringCount(), 0);
  eq("but NOT the target mark, which belongs to the play and not the opposition",
     await aimMarks(), 1);
  eq("but leaves our own eleven exactly as they were", await ourCount(), oursWithThem);
  await page.click("#themBtn");
  await page.waitForTimeout(250);
  eq("turning them back on restores them", await themCross(), withThem);
  ok("and the rings come back", (await ringCount()) > 0);

  // -------------------------------------------------------------------------
  sect("4. Line me up -- it asks, it scores, it moves on");
  // -------------------------------------------------------------------------
  await page.click('.tab[data-m="lineup"]');
  await page.waitForTimeout(250);
  ok("the lineup controls are shown", await page.isVisible("#lineupUI"));

  const prompt1 = (await page.textContent("#lineAsk")).trim();
  ok("it asks about somebody", /Tap where/i.test(prompt1), prompt1.slice(0, 60));

  // DETERMINISTIC, both ways. The first version of this tapped the middle of
  // the field and required the words "yards off" -- which failed roughly half
  // the time, and not randomly: when the man it happened to ask about was the
  // SNAPPER, who stands in the middle, the tap was CORRECT and the page said
  // "That is the spot." with no yardage in it at all. A flaky suite is worse
  // than no suite, and this one was flaky because it was wrong about the
  // feature rather than because the browser was slow.
  //
  // So: tap exactly where the asked man stands, then tap a corner, and check
  // both verdicts. The exact spot is computed through the SVG's own screen
  // matrix rather than guessed from the bounding box, because the viewBox is
  // cropped per play and the two are not the same mapping.
  const tapExactly = async () => {
    const at = await page.evaluate(() => {
      const svg = document.getElementById("field");
      const pt = svg.createSVGPoint();
      pt.x = lineCur.x; pt.y = lineCur.y;
      const s = pt.matrixTransform(svg.getScreenCTM());
      return { x: s.x, y: s.y, label: lineCur.label };
    });
    await page.mouse.click(at.x, at.y);
    await page.waitForTimeout(400);
    return at.label;
  };

  const who = await tapExactly();
  eq(`tapping exactly where ${who} stands is scored as correct`,
     (await page.textContent("#lineVerdict")).trim(), "That is the spot.");

  await page.click("#lineNext");
  await page.waitForTimeout(300);
  const box = await page.locator("#field").boundingBox();
  await page.mouse.click(box.x + 6, box.y + 6);
  await page.waitForTimeout(400);
  const far = (await page.textContent("#lineVerdict")).trim();
  ok("and tapping a corner is scored as wrong, in yards",
     /^Not quite/.test(far) && /\d+\s*yards off/.test(far), far.slice(0, 70));

  ok("the score line counts the attempts",
     /\d+\s*of\s*\d+/.test((await page.textContent("#lineScore")) || ""),
     (await page.textContent("#lineScore")) || "");

  const beforeNext = (await page.textContent("#lineAsk")).trim();
  await page.click("#lineNext");
  await page.waitForTimeout(300);
  ok("Next man moves to another spot", (await page.textContent("#lineAsk")).trim() !== beforeNext);
  eq("and clears the last verdict", (await page.textContent("#lineVerdict")).trim(), "");

  await page.click("#lineRestart");
  await page.waitForTimeout(300);
  ok("Start over does not throw", errors.length === 0, errors.join(" ; "));

  // -------------------------------------------------------------------------
  sect("5. My job -- multiple choice, built from the written jobs");
  // -------------------------------------------------------------------------
  await page.click('.tab[data-m="quiz"]');
  await page.waitForTimeout(250);
  ok("the quiz controls are shown", await page.isVisible("#quizUI"));

  const opts = await page.$$eval("#quizOpts button", (b) => b.map((x) => x.textContent.trim()));
  ok("it offers more than one answer", opts.length >= 2, `${opts.length} options`);
  ok("and the options are not all the same", new Set(opts).size === opts.length,
     opts.join(" | ").slice(0, 120));

  // The buttons ship with class "opt", so "has a class other than btn" was true
  // before anything was clicked -- a vacuous assertion that survived a mutation
  // making the quiz unanswerable. What answering actually does is add "right"
  // or "wrong", so that is what gets checked.
  const graded = () => page.$$eval("#quizOpts button",
    (b) => b.filter((x) => /\b(right|wrong)\b/.test(x.className)).length);
  eq("before answering, nothing is graded", await graded(), 0);

  await page.click("#quizOpts button");
  await page.waitForTimeout(400);
  ok("answering grades the buttons", (await graded()) > 0, `${await graded()} graded`);
  ok("the correct answer is always shown, right or wrong",
     (await page.$$eval("#quizOpts button", (b) => b.filter((x) => /\bright\b/.test(x.className)).length)) === 1);
  ok("and a verdict is written", ((await page.textContent("#quizVerdict")) || "").trim().length > 0,
     ((await page.textContent("#quizVerdict")) || "").trim().slice(0, 50));
  ok("the score line updates", /\d+\s*of\s*\d+/.test((await page.textContent("#quizScore")) || ""),
     (await page.textContent("#quizScore")) || "");

  // The documented payoff: after he answers he is told who he is across from,
  // what that man will try, and how he beats him -- all read off the coach's
  // own opposing play rather than invented.
  const beat = (await page.textContent("#quizBeat")) || "";
  ok("and he is told who he is across from", /Across from you/i.test(beat), beat.slice(0, 70));
  ok("what that man will try", /He will try to/i.test(beat), beat.slice(0, 70));
  ok("and how to beat him", /You beat him by/i.test(beat), beat.slice(0, 70));

  // A second click must not re-score: quizLocked exists for exactly this.
  const scoreAfterOne = await page.textContent("#quizScore");
  await page.click("#quizOpts button");
  await page.waitForTimeout(250);
  eq("clicking again does not score twice", await page.textContent("#quizScore"), scoreAfterOne);

  await page.click("#quizNext");
  await page.waitForTimeout(250);
  const opts2 = await page.$$eval("#quizOpts button", (b) => b.map((x) => x.textContent.trim()));
  ok("Next question asks another one", opts2.length >= 2 && opts2.join("|") !== opts.join("|"));

  await page.click("#quizRestart");
  await page.waitForTimeout(250);
  ok("Start over does not throw", errors.length === 0, errors.join(" ; "));

  // The page says so when a play has no written jobs, rather than showing an
  // empty quiz -- offence and defence are drafts with no per-man jobs.
  const phases = shipped.plays.map((p) => p.phase || "special");
  if (phases.some((x) => x !== "special")) {
    const nonSpecial = shipped.plays.find((p) => (p.phase || "special") !== "special");
    await page.selectOption("#playSel", nonSpecial.slug);
    await page.waitForTimeout(300);
    const noJobs = await page.isVisible("#noJobs");
    const someOpts = await page.$$eval("#quizOpts button", (b) => b.length);
    ok("a play with no written jobs says so instead of showing an empty quiz",
       noJobs || someOpts >= 2, `noJobs=${noJobs}, options=${someOpts}`);
  }

  // -------------------------------------------------------------------------
  sect("6. It fits a phone, and nothing leaks");
  // -------------------------------------------------------------------------
  await page.selectOption("#playSel", plays[0]);
  await page.waitForTimeout(200);
  const overflow = await page.evaluate(() =>
    document.documentElement.scrollWidth - document.documentElement.clientWidth);
  ok("the page does not scroll sideways on a 390px phone", overflow <= 0, `${overflow}px over`);

  // Only one mode's controls may be on screen at a time. This is the same class
  // of bug as the game-day bar leaking onto the normal screen.
  for (const [m, shown] of [["watch", "#watchUI"], ["lineup", "#lineupUI"], ["quiz", "#quizUI"]]) {
    await page.click(`.tab[data-m="${m}"]`);
    await page.waitForTimeout(200);
    const others = ["#watchUI", "#lineupUI", "#quizUI"].filter((s) => s !== shown);
    const leaked = [];
    for (const o of others) if (await page.isVisible(o)) leaked.push(o);
    ok(`in ${m} mode, no other mode's controls are visible`, leaked.length === 0, leaked.join(", "));
  }

  ok("there is a way back to the coach's app", (await page.locator("a[href]").count()) > 0);

  // -------------------------------------------------------------------------
  sect("7. The whole run produced no error at all");
  // -------------------------------------------------------------------------
  ok("no page error, no failed request, no console error across every check",
     errors.length === 0, errors.join(" ; "));
} finally {
  await browser.close();
  if (server) server.close();
}

console.log("\n=== RESULTS ===");
rows.forEach(([s, n, okv, d], i) =>
  console.log(`${i + 1}|${s}|${n}|${okv ? "PASS" : "*** FAIL ***"}|${d}`));
console.log(`\n${fail ? `${fail} LEARN TEST(S) FAILED` : `all ${pass} learn tests passed`}`);
process.exit(fail ? 1 : 0);
