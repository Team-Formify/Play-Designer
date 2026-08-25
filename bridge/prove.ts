/**
 * PROOF — run the bridge against the planner's real artwork.
 *
 * Before anybody touches the planner's repo, this answers the only question
 * that matters: does a diagram it already ships come out the other side as
 * something you can actually play?
 *
 * The SVG reader here is deliberately minimal and is NOT the thing to ship —
 * the planner's own `sceneFromSvg()` does this properly, with byte-identical
 * round-tripping. This one exists so the pipeline can be proved from outside
 * that repo, on real files, with nothing stubbed.
 *
 *     node --experimental-strip-types bridge/prove.ts
 */

import { readFileSync } from "node:fs";
import { walk } from "./playEngine.ts";
import { sceneToPlay, assignments, type SceneLike, type SceneLineLike, type SceneManLike }
  from "./sceneToPlay.ts";

const NUM = /-?\d*\.?\d+/g;

function segsFromD(d: string): { start: [number, number]; segs: SceneLineLike["segs"] } | null {
  const cmds = d.match(/[MLQC][^MLQCZ]*/g);
  if (!cmds || !cmds[0].startsWith("M")) return null;
  const first = cmds[0].match(NUM)?.map(Number);
  if (!first || first.length < 2) return null;
  const start: [number, number] = [first[0], first[1]];
  const segs: SceneLineLike["segs"] = [];
  for (const c of cmds.slice(1)) {
    const n = c.match(NUM)?.map(Number) ?? [];
    const k = c[0];
    if (k === "L" && n.length >= 2) segs.push({ c: "L", ctrl: [], to: [n[0], n[1]] });
    else if (k === "Q" && n.length >= 4) segs.push({ c: "Q", ctrl: [[n[0], n[1]]], to: [n[2], n[3]] });
    else if (k === "C" && n.length >= 6)
      segs.push({ c: "C", ctrl: [[n[0], n[1]], [n[2], n[3]]], to: [n[4], n[5]] });
    else return null;   // an unexpected command stays read-only rather than being mangled
  }
  return { start, segs };
}

function readScene(svg: string): SceneLike {
  const men: SceneManLike[] = [];
  const seen = new Map<string, number>();
  for (const g of svg.matchAll(/<g data-man="([^"]+)">([\s\S]*?)<\/g>/g)) {
    const base = g[1], inner = g[2];
    // offense is a circle at cx/cy; defense is a rect, so take its middle
    const c = inner.match(/<circle cx="([-\d.]+)" cy="([-\d.]+)"/);
    const r = inner.match(/<rect x="([-\d.]+)" y="([-\d.]+)" width="([-\d.]+)" height="([-\d.]+)"/);
    let at: [number, number] | null = null;
    if (c) at = [Number(c[1]), Number(c[2])];
    else if (r) at = [Number(r[1]) + Number(r[3]) / 2, Number(r[2]) + Number(r[4]) / 2];
    if (!at) continue;
    const n = seen.get(base) ?? 0;
    seen.set(base, n + 1);
    men.push({ id: `${base}#${n}`, at, side: base.startsWith("D:") ? "defense" : "offense" });
  }

  const lines: SceneLineLike[] = [];
  let li = 0;
  for (const p of svg.matchAll(/<(path|line)\s([^>]*)\/>/g)) {
    const attrs = p[2];
    const owner = attrs.match(/data-owner="([^"]+)"/)?.[1] ?? "";
    const role = attrs.match(/data-role="([^"]+)"/)?.[1] ?? "";
    if (!owner) continue;
    const term = attrs.match(/data-term="([^"]+)"/)?.[1] as SceneLineLike["term"] | undefined;
    let start: [number, number], segs: SceneLineLike["segs"];
    if (p[1] === "line") {
      const x1 = Number(attrs.match(/x1="([-\d.]+)"/)?.[1]);
      const y1 = Number(attrs.match(/y1="([-\d.]+)"/)?.[1]);
      const x2 = Number(attrs.match(/x2="([-\d.]+)"/)?.[1]);
      const y2 = Number(attrs.match(/y2="([-\d.]+)"/)?.[1]);
      if ([x1, y1, x2, y2].some(Number.isNaN)) continue;
      start = [x1, y1]; segs = [{ c: "L", ctrl: [], to: [x2, y2] }];
    } else {
      const d = attrs.match(/(?:^|\s)d="([^"]+)"/)?.[1];
      const parsed = d ? segsFromD(d) : null;
      if (!parsed) continue;
      start = parsed.start; segs = parsed.segs;
    }
    lines.push({
      id: `${owner}:${role}#${li++}`, owner, role, start, segs,
      term: term ?? (attrs.includes("marker-end") ? "arrow" : "none"),
    });
  }
  return { men, lines };
}

/* ─────────────────────────────────────────────────────────────────── run it ── */

/* By default this runs on a fixture built from our own Offense — Base and
   Defense — Purple, written out in the planner's SVG format. His artwork is
   password-protected and this repo is public, so none of it lives here.

   To run against the real book, point at his diagramArt.ts locally:

     node --experimental-strip-types bridge/prove.ts <path-to>/src/lib/diagramArt.ts

   Nothing is written; it reads and reports. */
const arg = process.argv[2];
let book: Record<string, string>;
if (arg) {
  const src = readFileSync(arg, "utf8");
  const a = src.indexOf("{", src.indexOf("DIAGRAM_SVG"));
  let depth = 0, j = a;
  for (; j < src.length; j++) {
    if (src[j] === "{") depth++;
    else if (src[j] === "}" && --depth === 0) { j++; break; }
  }
  const all: Record<string, string> = JSON.parse(src.slice(a, j));
  const keys = Object.keys(all).filter((k) => /data-man="D:/.test(all[k]));
  console.log(`reading ${arg}\n${Object.keys(all).length} diagrams, ${keys.length} with both sides — sampling 4\n`);
  book = Object.fromEntries(keys.slice(0, 4).map((k) => [k, all[k]]));
} else {
  book = JSON.parse(readFileSync(new URL("./fixtures/diagrams.json", import.meta.url), "utf8"));
}

let bad = 0;
const say = (ok: boolean, m: string) => { console.log((ok ? "PASS  " : "FAIL  ") + m); if (!ok) bad++; };

for (const [id, svg] of Object.entries(book)) {
  console.log(`\n── ${id}`);
  const scene = readScene(svg);
  const play = sceneToPlay(scene);
  const movers = [...play.offense, ...play.defense].filter((m) => m.path.length > 1);

  say(play.offense.length >= 9 && play.defense.length >= 9,
      `both sides come across — ${play.offense.length} on offense, ${play.defense.length} on defense`);
  say(movers.length > 0, `${movers.length} men have a route to run`);

  // the play actually moves on the clock
  const mover = movers[0];
  if (mover) {
    const a = walk(mover.path, 0), b = walk(mover.path, 1);
    say(Math.hypot(b.x - a.x, b.y - a.y) > 5,
        `${mover.label} runs from ${a.x.toFixed(0)},${a.y.toFixed(0)} to ${b.x.toFixed(0)},${b.y.toFixed(0)}`);
  }

  const drawn = Object.keys(
    Object.fromEntries([...play.offense].filter((o) => o.covers).map((o) => [o.id, o.covers])),
  ).length;
  const { pairs, contacts } = assignments(play);
  say(Object.keys(pairs).length > 0,
      `${Object.keys(pairs).length} men matched up — ${drawn} of them read straight off the block tees`);
  say(contacts.length > 0, `${contacts.length} pairs come together, first at t=${
    contacts.length ? Math.min(...contacts.map((c) => c.t)).toFixed(2) : "-"}`);

  const sample = contacts.slice(0, 3).map((c) => {
    const o = play.offense.find((m) => m.id === c.id)!;
    const d = play.defense[c.bi!];
    return `${o.label} ↔ ${d.label} @ ${c.x.toFixed(0)},${c.y.toFixed(0)}`;
  });
  if (sample.length) console.log("        " + sample.join("   "));
}

console.log(bad ? `\nFAILURES: ${bad}` : "\nparsed, matched up and collided \u2014 the bridge holds");
process.exit(bad ? 1 : 0);
