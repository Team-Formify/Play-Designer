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

const root = process.argv[2];
if (!root) {
  console.error("Point me at a checkout of the planner:\n" +
                "  node bridge/build-combined.mjs ../8th-grade-practice-planner");
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

const art = objectAfter(readFileSync(join(root, "src/lib/diagramArt.ts"), "utf8"), "DIAGRAM_SVG");
const meta = objectAfter(readFileSync(join(root, "src/lib/diagrams.ts"), "utf8"), "DIAGRAMS");

/* title and caption live in the metadata, keyed by diagram id inside groups */
const byId = {};
for (const group of Object.values(meta)) {
  for (const d of group) byId[d.id] = d;
}

const his = Object.keys(art)
  .filter((k) => /data-man="D:/.test(art[k]))
  .map((k) => ({ k, routes: (art[k].match(/data-role="route"/g) || []).length }))
  .sort((a, b) => b.routes - a.routes)          // the ones with the most to watch, first
  .slice(0, HOW_MANY)
  .map(({ k }) => ({
    id: k, side: "his", svg: art[k],
    title: byId[k]?.title || k,
    caption: byId[k]?.caption || "",
  }));

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

  for (const m of opponentOf(play).men) {
    const id = `D:${m.q.label || "X"}`;
    const cx = X(m.x), cy = Y(m.y, los);
    men.push(`<g data-man="${id}"><rect x="${cx - 11}" y="${cy - 11}" width="22" height="22" rx="3" fill="#fff" stroke="#c1121f" stroke-width="2.2"/><text x="${cx}" y="${cy + 4}" fill="#c1121f">${m.q.label || ""}</text></g>`);
    if (!m.path || m.path.length < 2) continue;
    const d = `M${cx},${cy} ` + m.path.slice(1).map((t) => `L${X(t.x)},${Y(t.y, los)}`).join(" ");
    lines.push(`<path d="${d}" stroke="#c1121f" stroke-width="2.2" fill="none" marker-end="url(#arR)" data-owner="${id}" data-role="route"/>`);
  }

  for (const p of play.players) {
    const them = p.team === "them";
    const id = them ? `D:${p.label || "X"}` : (p.label || "?");
    const cx = X(p.x), cy = Y(p.y, los);
    men.push(them
      ? `<g data-man="${id}"><rect x="${cx - 11}" y="${cy - 11}" width="22" height="22" rx="3" fill="#fff" stroke="#c1121f" stroke-width="2.2"/><text x="${cx}" y="${cy + 4}" fill="#c1121f">${p.label || ""}</text></g>`
      : `<g data-man="${id}"><circle cx="${cx}" cy="${cy}" r="11" fill="#e8edf7" stroke="#0b2545" stroke-width="2.4"/><text x="${cx}" y="${cy + 4}" fill="#0b2545">${p.label || ""}</text></g>`);
    const r = routes.find((z) => z.playerId === p.id);
    if (!r || !r.points.length) continue;
    const d = `M${cx},${cy} ` + r.points.map((t) => `L${X(t.x)},${Y(t.y, los)}`).join(" ");
    lines.push(`<path d="${d}" stroke="#0b2545" stroke-width="2.6" fill="none" marker-end="url(#arN)" data-owner="${id}" data-role="route"/>`);
  }
  const L = Y(los, los);
  return `<svg viewBox="0 0 920 460" role="img" aria-label="${play.name}" text-anchor="middle" style="font:800 10px system-ui">` +
    `<rect x="0" y="0" width="920" height="460" fill="#fbfcfe"/>` + men.join("") +
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
    ours.push({
      id: play.slug + (look ? ":" + look.id : ""),
      side: "ours",
      title: play.name + (look ? " — " + look.name : ""),
      caption: [play.howItWorks, look?.how, look?.aim?.label].filter(Boolean).join(" "),
      svg: toSvg(play, look),
      jobs,
    });
  }
}

/* ── write it ─────────────────────────────────────────────────────────────── */

const data = JSON.stringify({ plays: [...ours, ...his] });
if (data.includes("</script")) {
  console.error('The play data contains "</script" and would break out of the tag. Refusing.');
  process.exit(1);
}

const shell = readFileSync("bridge/combined-shell.html", "utf8");
const out = shell.replace(
  '<script type="application/json" id="playbook"></script>',
  '<script type="application/json" id="playbook">' + data + "</script>",
);
writeFileSync("bridge/combined.html", out);

console.log(`combined.html — ${ours.length} of ours, ${his.length} of his, ` +
            `${Math.round(out.length / 1024)} KB`);
console.log("NOT committed: it carries his artwork and this repo is public.");
