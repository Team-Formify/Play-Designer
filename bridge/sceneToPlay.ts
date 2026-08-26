/**
 * SCENE → PLAY — the bridge.
 *
 * The planner's diagrams are generated SVG, and `playScene.ts` already reads
 * them back into men and lines so a coach can edit them. That parse is doing
 * almost all the work needed here: a `SceneMan` is a player with a position and
 * a side, and `pointsOf(line)` is a route as a polyline.
 *
 * So this file is small on purpose. It is a shape change, not a conversion —
 * nothing is redrawn, nothing is stored, and the SVG stays the source of truth.
 * Feed a scene in, get back what `playEngine` needs to run the play.
 *
 * Two things worth knowing about the artwork it reads:
 *
 *   · Defenders are the men whose id starts `D:`. Both sides are already in the
 *     same picture, so unlike the special teams tool there is nothing to mirror.
 *
 *   · A line with `term: "tee"` is a block, and a tee ends ON the man being
 *     blocked. That is an assignment the artist already drew, so it is read
 *     straight off rather than guessed at — `coversFromBlocks` turns those into
 *     the `covers` the engine honours before it starts pairing by distance.
 */

import { matchups, meets, smoothPts, type EngineMan, type Meet, type Pt } from "./playEngine";

/* The parts of the planner's own types this depends on. Kept structural so the
   bridge does not have to import from playScene.ts and cannot drift with it. */
export interface SceneManLike {
  id: string;
  at: [number, number];
  side: "offense" | "defense";
}
export interface SceneLineLike {
  id: string;
  owner: string;
  role: string;
  start: [number, number];
  segs: { c: string; ctrl: [number, number][]; to: [number, number] }[];
  term: "arrow" | "tee" | "none";
}
export interface SceneLike {
  men: SceneManLike[];
  lines: SceneLineLike[];
}

export interface PlayMan extends EngineMan {
  label: string;
  side: "offense" | "defense";
  /** The route he runs, already sampled along its curve. */
  path: Pt[];
  /** The stored points, untouched — what a curve is DRAWN from. Kept apart from
      `path` because sampling is for walking a man, not for drawing his line. */
  raw: Pt[];
}

/** A nudge a coach has made, per man. The artwork is never rewritten; a move is
    a delta held by the caller — the same shape playScene.ts keeps its edits. */
export type Moves = Record<string, { dx: number; dy: number }>;

export interface Play {
  offense: PlayMan[];
  defense: PlayMan[];
}

const pt = ([x, y]: [number, number]): Pt => ({ x, y });

/** A line's on-path points: where it starts, then the end of each leg. */
export function linePoints(l: SceneLineLike): Pt[] {
  return [pt(l.start), ...l.segs.map((s) => pt(s.to))];
}

/**
 * The man a block line lands on, if it lands on anybody.
 *
 * A tee is drawn at the point of contact, so the defender nearest its end —
 * within a man's width — is the one being blocked. Anything further away was
 * not aimed at a man and is left alone rather than guessed at.
 */
const BLOCK_REACH = 26;

export function coversFromBlocks(scene: SceneLike): Record<string, string> {
  const out: Record<string, string> = {};
  const defs = scene.men.filter((m) => m.side === "defense");
  if (!defs.length) return out;
  for (const l of scene.lines) {
    if (l.term !== "tee" || !l.owner) continue;
    const end = linePoints(l).at(-1);
    if (!end) continue;
    let best: { id: string; d: number } | null = null;
    for (const d of defs) {
      const dist = Math.hypot(end.x - d.at[0], end.y - d.at[1]);
      if (!best || dist < best.d) best = { id: d.id, d: dist };
    }
    if (best && best.d <= BLOCK_REACH) out[l.owner] = best.id;
  }
  return out;
}

/**
 * Turn a parsed scene into two sides the engine can run.
 *
 * A man with no line of his own simply stands still, which is correct — a
 * blocker who is not drawn moving is not moving.
 */
export function sceneToPlay(scene: SceneLike, moves?: Moves): Play {
  const covers = coversFromBlocks(scene);
  const byOwner = new Map<string, SceneLineLike>();
  for (const l of scene.lines) {
    // a man's route is his movement line, not his block tee or a caption mark
    if (!l.owner || l.term === "none") continue;
    if (!byOwner.has(l.owner) || l.term === "arrow") byOwner.set(l.owner, l);
  }

  const build = (m: SceneManLike): PlayMan => {
    const nudge = moves?.[m.id] ?? { dx: 0, dy: 0 };
    const shift = (p: Pt): Pt => ({ x: p.x + nudge.dx, y: p.y + nudge.dy });
    const here = shift(pt(m.at));
    const line = byOwner.get(m.id) ?? byOwner.get(m.id.split("#")[0]);
    /* The nudge moves his whole line with him, not just his circle — a man
       dragged two yards wider still runs the route he was given. */
    const raw = line ? [here, ...linePoints(line).slice(1).map(shift)] : [here];
    return {
      id: m.id,
      label: m.id.replace(/^D:/, "").split("#")[0],
      side: m.side,
      x: here.x, y: here.y,
      covers: covers[m.id] ?? covers[m.id.split("#")[0]],
      path: smoothPts(raw),
      raw,
    };
  };

  return {
    offense: scene.men.filter((m) => m.side === "offense").map(build),
    defense: scene.men.filter((m) => m.side === "defense").map(build),
  };
}

/** Who each offensive man is responsible for, and where they come together. */
export function assignments(play: Play): { pairs: Record<string, number>; contacts: Meet[] } {
  const pairs = matchups(play.offense, play.defense, (d) => d.id);
  const contacts = meets(
    play.offense
      .filter((o) => pairs[o.id] !== undefined)
      .map((o) => ({
        id: o.id,
        bi: pairs[o.id].bi,
        assigned: pairs[o.id].assigned,
        ours: o.path,
        theirs: play.defense[pairs[o.id].bi].path,
      })),
  );
  return { pairs: Object.fromEntries(Object.entries(pairs).map(([k, v]) => [k, v.bi])), contacts };
}
