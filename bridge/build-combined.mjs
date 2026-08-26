#!/usr/bin/env node
/**
 * Build `combined.html` — both playbooks in one app.
 *
 * Reads the practice planner's diagrams and captions off a local checkout, reads
 * this repo's special teams playbook, converts ours into the planner's SVG
 * format so there is ONE data model, and writes a single self-contained page.
 *
 *     node bridge/build-combined.mjs ../8th-grade-practice-planner
 *
 * THE OUTPUT IS NOT COMMITTED. The planner's offense is password-protected and
 * this repo is public, so `combined.html` is gitignored and stays local. This
 * generator is safe to commit because it contains none of his content — it only
 * knows where to look for it.
 */
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createRequire } from "node:module";
const PE = createRequire(import.meta.url)("../play-engine.js");

/* Two builds out of one generator.

   With a path to his checkout: the real thing — his book and ours in his app,
   written to bridge/combined.html, which is gitignored because it carries his
   artwork and this repo is public.

   With --ours-only: the same app carrying only our special teams, written to
   playbook.html at the root so it deploys with the rest of the site. This is
   the REAL BUILD, not a mock-up of one — same shell, same engine, same code
   path; the only thing absent is his half of the book, which cannot be
   published here. When this moves to his repo that half is simply present. */
const OURS_ONLY = process.argv.includes("--ours-only");
const root = OURS_ONLY ? null : process.argv[2];
if (!root && !OURS_ONLY) {
  console.error("Point me at a checkout of the planner, or build the public one:\n" +
                "  node bridge/build-combined.mjs ../8th-grade-practice-planner\n" +
                "  node bridge/build-combined.mjs --ours-only     # writes playbook.html");
  process.exit(1);
}
const HOW_MANY = Number(process.argv[3] || 90);

/* ── his side ─────────────────────────────────────────────────────────────── */

function objectAfter(src, marker) {
  const a = src.indexOf("{", src.indexOf(marker));
  let depth = 0, j = a;
  for (; j < src.length; j++) {
    if (src[j] === "{") depth++;
    else if (src[j] === "}" && --depth === 0) { j++; break; }
  }
  return JSON.parse(src.slice(a, j));
}

const art = OURS_ONLY ? {} : objectAfter(readFileSync(join(root, "src/lib/diagramArt.ts"), "utf8"), "DIAGRAM_SVG");
const meta = OURS_ONLY ? {} : objectAfter(readFileSync(join(root, "src/lib/diagrams.ts"), "utf8"), "DIAGRAMS");

/* title and caption live in the metadata, keyed by diagram id inside groups.
   The group name is his baseKey, which is what CORE_EIGHT matches on. */
const byId = {};
for (const [group, arr] of Object.entries(meta)) {
  for (const d of arr) byId[d.id] = { ...d, baseKey: group };
}

/* His arrowhead markers. Every diagram references them by url(#arN); without
   them the untouched artwork draws its routes with no points on the end. Taken
   from his file rather than redrawn, same as everything else of his. */
let defs = "";
if (!OURS_ONLY) {
  const defsSrc = readFileSync(join(root, "src/lib/diagrams.ts"), "utf8");
  defs = JSON.parse(
    defsSrc.slice(defsSrc.indexOf('"', defsSrc.indexOf("DIAGRAM_DEFS")),
                  defsSrc.indexOf(";", defsSrc.indexOf("DIAGRAM_DEFS"))).trim(),
  );
}

/* THE CORE, straight out of src/lib/playbook.ts. Matched on baseKey + side +
   formation, never on the call string — same rule his own code follows. */
const CORE_EIGHT = [
  ["run-12-13-power", "Right", "trey"],   ["run-12-13-power", "Left", "trey"],
  ["run-14-15-counter", "Right", "denver"], ["run-14-15-counter", "Left", "denver"],
  ["run-20-21-zone", "Right", "denver"],  ["run-20-21-zone", "Left", "denver"],
  ["run-28-29-stretch", "Right", "denver"], ["run-28-29-stretch", "Left", "denver"],
];
const isCore = (d) =>
  CORE_EIGHT.some(([k, side, form]) =>
    d.baseKey === k && d.side === side && d.formation === form);

const KIND = { run: "RUN", pass: "PASS", screen: "SCREEN", boot: "BOOT",
               formation: "FORMATION", reference: "REFERENCE" };

const withBoth = Object.keys(art).filter((k) => /data-man="D:/.test(art[k]));
const routesIn = (k) => (art[k].match(/data-role="route"/g) || []).length;

/* The core eight always come, whatever else does. The rest fill the quota by
   how much there is to watch — a play with more routes shows more of what the
   engine now does with them. */
const core = withBoth.filter((k) => byId[k] && isCore(byId[k]));
const rest = withBoth.filter((k) => !core.includes(k))
  .sort((a, b) => routesIn(b) - routesIn(a))
  .slice(0, Math.max(0, HOW_MANY - core.length));

const his = [...core, ...rest].map((k) => {
  const d = byId[k] || {};
  return {
    id: k, side: "his", section: core.includes(k) ? "core" : "rest",
    call: d.title || k,
    meta: KIND[d.kind] || (d.kind || "").toUpperCase(),
    caption: d.caption || "",
    svg: art[k],
  };
});

/* ── our side, written out in his format ──────────────────────────────────── */

const book = JSON.parse(readFileSync("special-teams-plays.json", "utf8"));

// ours: 420 wide, 392px = 53.3 yards. his: 16px per yard on a 920 box.
const K = 16 / (392 / 53.3);
const X = (x) => Math.round((460 + (x - 210) * K) * 10) / 10;
const Y = (y, los) => Math.round((300 + (y - los) * K) * 10) / 10;

/* Our special teams plays do not store an opposing eleven — they name the play
   they face and the app reflects it across the ball at draw time. His format has
   both sides in the picture, so the mirror is resolved here, once, at build. */
const bySlug = Object.fromEntries(book.plays.map((p) => [p.slug, p]));
const firstLook = (p) => (p.looks?.length ? p.looks[0] : { routes: p.routes || [] });

function opponentOf(play) {
  const src = bySlug[play.mirrorOf || ""];
  if (!src) return { men: [], routes: [] };
  const ours = play.players.filter((q) => q.team !== "them");
  const theirs = src.players.filter((q) => q.team !== "them");
  if (!ours.length || !theirs.length) return { men: [], routes: [] };
  return PE.mirror(
    { los: play.lineOfScrimmage, ours },
    { los: src.lineOfScrimmage, ours: theirs, routes: firstLook(src).routes },
  );
}

function toSvg(play, look) {
  const los = play.lineOfScrimmage;
  const routes = look ? look.routes : play.routes || [];
  const men = [], lines = [];
  /* His field box is 920x460 — a 2:1 picture, which is the right shape for a
     snap from scrimmage. A punt is not that shape: the punter stands fourteen
     yards back and the coverage runs forty downfield, so the box has to grow to
     the play or the punter is simply cut off the bottom. Width stays his; only
     the vertical extent follows the play. */
  const ys = [];
  const seen = (cy) => { ys.push(cy); return cy; };

  for (const m of opponentOf(play).men) {
    const id = `D:${m.q.label || "X"}`;
    const cx = X(m.x), cy = seen(Y(m.y, los));
    men.push(`<g data-man="${id}"><rect x="${cx - 11}" y="${cy - 11}" width="22" height="22" rx="3" fill="#fff" stroke="#c1121f" stroke-width="2.2"/><text x="${cx}" y="${cy + 4}" fill="#c1121f">${m.q.label || ""}</text></g>`);
    if (!m.path || m.path.length < 2) continue;
    const d = `M${cx},${cy} ` + m.path.slice(1).map((t) => `L${X(t.x)},${seen(Y(t.y, los))}`).join(" ");
    lines.push(`<path d="${d}" stroke="#c1121f" stroke-width="2.2" fill="none" marker-end="url(#arR)" data-owner="${id}" data-role="route"/>`);
  }

  for (const p of play.players) {
    const them = p.team === "them";
    const id = them ? `D:${p.label || "X"}` : (p.label || "?");
    const cx = X(p.x), cy = seen(Y(p.y, los));
    men.push(them
      ? `<g data-man="${id}"><rect x="${cx - 11}" y="${cy - 11}" width="22" height="22" rx="3" fill="#fff" stroke="#c1121f" stroke-width="2.2"/><text x="${cx}" y="${cy + 4}" fill="#c1121f">${p.label || ""}</text></g>`
      : `<g data-man="${id}"><circle cx="${cx}" cy="${cy}" r="11" fill="#e8edf7" stroke="#0b2545" stroke-width="2.4"/><text x="${cx}" y="${cy + 4}" fill="#0b2545">${p.label || ""}</text></g>`);
    const r = routes.find((z) => z.playerId === p.id);
    if (!r || !r.points.length) continue;
    const d = `M${cx},${cy} ` + r.points.map((t) => `L${X(t.x)},${seen(Y(t.y, los))}`).join(" ");
    lines.push(`<path d="${d}" stroke="#0b2545" stroke-width="2.6" fill="none" marker-end="url(#arN)" data-owner="${id}" data-role="route"/>`);
  }
  const L = Y(los, los);
  ys.push(L);
  const PAD = 26;
  const y0 = Math.round(Math.min(0, Math.min(...ys) - PAD));
  const y1 = Math.round(Math.max(460, Math.max(...ys) + PAD));
  const h = y1 - y0;
  /* Our own arrowheads, so a play of ours is a complete picture on its own and
     does not borrow a marker out of his file. Same ids his artwork uses, so the
     two sit in one page without either needing the other. */
  const DEFS = `<defs>` +
    `<marker id="arN" markerWidth="9" markerHeight="9" refX="6.4" refY="3" orient="auto">` +
    `<path d="M0,0 L7,3 L0,6 Z" fill="#0b2545"/></marker>` +
    `<marker id="arR" markerWidth="9" markerHeight="9" refX="6.4" refY="3" orient="auto">` +
    `<path d="M0,0 L7,3 L0,6 Z" fill="#c1121f"/></marker></defs>`;
  return `<svg viewBox="0 ${y0} 920 ${h}" role="img" aria-label="${play.name}" text-anchor="middle" style="font:800 10px system-ui">` + DEFS +
    `<rect x="0" y="${y0}" width="920" height="${h}" fill="#fbfcfe"/>` + men.join("") +
    `<line x1="28" y1="${L}" x2="892" y2="${L}" stroke="#0b2545" stroke-width="2.2"/>` +
    lines.join("") + `</svg>`;
}

const ours = [];
for (const play of book.plays) {
  const looks = play.looks?.length ? play.looks : [null];
  for (const look of looks) {
    const jobs = {};
    for (const p of play.players) {
      if (p.team !== "them" && p.label) jobs[p.label] = { role: p.role || "", job: p.job || "" };
    }
    const svg = toSvg(play, look);
    ours.push({
      id: play.slug + (look ? ":" + look.id : ""),
      side: "ours",
      section: "special",
      call: (play.name + (look ? " \u2014 " + look.name : "")).toUpperCase(),
      meta: (play.phase === "special" || !play.phase) ? "SPECIAL" : play.phase.toUpperCase(),
      caption: [play.howItWorks, look?.how, look?.aim?.label].filter(Boolean).join(" "),
      svg,
      jobs,
    });
  }
}

/* ── write it ─────────────────────────────────────────────────────────────── */

const data = JSON.stringify({ defs, hisBook: !OURS_ONLY, plays: [...his, ...ours] });
if (data.includes("</script")) {
  console.error('The play data contains "</script" and would break out of the tag. Refusing.');
  process.exit(1);
}

const shell = readFileSync("bridge/combined-shell.html", "utf8");
const out = shell.replace(
  '<script type="application/json" id="playbook"></script>',
  '<script type="application/json" id="playbook">' + data + "</script>",
);
const target = OURS_ONLY ? "playbook.html" : "bridge/combined.html";
writeFileSync(target, out);

console.log(`${target} — ${his.length} of his (${core.length} core), ${ours.length} of ours, ` +
            `${Math.round(out.length / 1024)} KB`);
console.log(OURS_ONLY
  ? "Safe to commit: nothing of his is in it."
  : "NOT committed: it carries his artwork and this repo is public.");
