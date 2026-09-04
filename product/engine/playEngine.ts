/**
 * PLAY ENGINE — the geometry that makes a diagram something you can play.
 *
 * A TypeScript port of `play-engine.js` from Team-Formify/Play-Designer, where it
 * drives the special teams tool. Pure: no DOM, no storage, no React, no knowledge
 * of anybody's data shapes. Numbers in, numbers out.
 *
 * It is what a picture cannot do on its own — walk a man down his route on a
 * clock, pair him with the man he is responsible for, and find the point where
 * the two of them actually come together.
 *
 * Drop this in `src/lib/`. It has no imports, so nothing here can drag anything
 * else in with it. `playEngine.test.ts` runs under the same `node --test` setup
 * as the rest of the library.
 */

export type Pt = { x: number; y: number };

/* ─────────────────────────────────────────────────────────────────── curves ── */

/**
 * Nobody runs in straight lines with corners on them. These round a list of
 * points into one continuous path, and sample that same path, so a man runs
 * along the line that is drawn rather than cutting its corners.
 *
 * Two points stay a straight line, because that is what a straight line is.
 */
const CURVE = 0.5;

export function smoothD(pts: Pt[]): string {
  if (!pts || pts.length < 2) return "";
  let d = `M${pts[0].x},${pts[0].y}`;
  if (pts.length === 2) return `${d} L${pts[1].x},${pts[1].y}`;
  for (let i = 0; i < pts.length - 1; i++) {
    const p0 = pts[i - 1] ?? pts[i], p1 = pts[i], p2 = pts[i + 1], p3 = pts[i + 2] ?? pts[i + 1];
    d += ` C${p1.x + (p2.x - p0.x) / 6 * CURVE},${p1.y + (p2.y - p0.y) / 6 * CURVE}` +
         ` ${p2.x - (p3.x - p1.x) / 6 * CURVE},${p2.y - (p3.y - p1.y) / 6 * CURVE}` +
         ` ${p2.x},${p2.y}`;
  }
  return d;
}

export function smoothPts(pts: Pt[]): Pt[] {
  if (!pts || pts.length < 3) return pts ?? [];
  const out: Pt[] = [{ x: pts[0].x, y: pts[0].y }];
  const STEP = 6;
  for (let i = 0; i < pts.length - 1; i++) {
    const p0 = pts[i - 1] ?? pts[i], p1 = pts[i], p2 = pts[i + 1], p3 = pts[i + 2] ?? pts[i + 1];
    const c1x = p1.x + (p2.x - p0.x) / 6 * CURVE, c1y = p1.y + (p2.y - p0.y) / 6 * CURVE;
    const c2x = p2.x - (p3.x - p1.x) / 6 * CURVE, c2y = p2.y - (p3.y - p1.y) / 6 * CURVE;
    for (let k = 1; k <= STEP; k++) {
      const u = k / STEP, v = 1 - u;
      out.push({
        x: v * v * v * p1.x + 3 * v * v * u * c1x + 3 * v * u * u * c2x + u * u * u * p2.x,
        y: v * v * v * p1.y + 3 * v * v * u * c1y + 3 * v * u * u * c2y + u * u * u * p2.y,
      });
    }
  }
  return out;
}

/** Where a man is when the clock reads `t`, measured along the whole path. */
export function walk(pts: Pt[], t: number): Pt {
  if (!pts || !pts.length) return { x: 0, y: 0 };
  const segs: number[] = [];
  let total = 0;
  for (let i = 1; i < pts.length; i++) {
    const L = Math.hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y);
    segs.push(L); total += L;
  }
  if (total <= 0) return pts[0];
  const want = total * t;
  let run = 0;
  for (let i = 0; i < segs.length; i++) {
    if (run + segs[i] >= want) {
      const f = segs[i] ? (want - run) / segs[i] : 0;
      return { x: pts[i].x + (pts[i + 1].x - pts[i].x) * f,
               y: pts[i].y + (pts[i + 1].y - pts[i].y) * f };
    }
    run += segs[i];
  }
  return pts[pts.length - 1];
}

/* ────────────────────────────────────────────────────────────── matchups ── */

export interface EngineMan {
  id: string;
  x: number;
  y: number;
  /** The label of the man he is assigned to. Empty means "work it out". */
  covers?: string;
}

export interface Matched {
  /** Index into the opposing list. */
  bi: number;
  /** True when a coach said so, false when it was worked out by distance. */
  assigned: boolean;
}

/**
 * Who is across from whom.
 *
 * Anything assigned by hand is the answer and takes its man off the board
 * first. The rest pair by distance, best pair first, so two men cannot claim
 * the same opponent while a third goes unmatched.
 *
 * Nearest-man is a fair guess on a kickoff and a poor one on a pass concept,
 * where a linebacker carries the man arriving in his zone rather than the one
 * standing closest to him at the snap — which is exactly what `covers` is for.
 */
export function matchups<T>(
  ours: EngineMan[],
  them: T[],
  labelOf: (m: T) => string,
): Record<string, Matched> {
  const out: Record<string, Matched> = {};
  if (!them.length) return out;
  const usedA = new Set<string>(), usedB = new Set<number>();

  for (const a of ours) {
    if (!a.covers) continue;
    const bi = them.findIndex((m) => labelOf(m) === a.covers);
    if (bi < 0 || usedB.has(bi)) continue;   // a label that no longer exists falls back to auto
    usedA.add(a.id); usedB.add(bi);
    out[a.id] = { bi, assigned: true };
  }

  const pairs: { id: string; bi: number; d: number }[] = [];
  for (const a of ours) {
    if (usedA.has(a.id)) continue;
    them.forEach((b, bi) => {
      if (usedB.has(bi)) return;
      const p = b as unknown as { x: number; y: number };
      pairs.push({ id: a.id, bi, d: Math.hypot(a.x - p.x, a.y - p.y) });
    });
  }
  pairs.sort((x, y) => x.d - y.d);
  for (const pr of pairs) {
    if (usedA.has(pr.id) || usedB.has(pr.bi)) continue;
    usedA.add(pr.id); usedB.add(pr.bi);
    out[pr.id] = { bi: pr.bi, assigned: false };
  }
  return out;
}

/* ────────────────────────────────────────────────────────────── contact ── */

export const MEET_TOUCH = 22;
export const MEET_NEAR = 44;
export const MEET_MOVED = 16;

export interface MeetPair {
  id: string;
  bi?: number;
  assigned?: boolean;
  ours: Pt[];
  theirs: Pt[];
}

export interface Meet {
  id: string;
  bi?: number;
  assigned: boolean;
  /** Where on the clock they come together, 0 to 1. */
  t: number;
  /** Where each man stops. */
  a: Pt;
  b: Pt;
  /** How far apart they actually got. */
  d: number;
  /** The point between them — where to draw the mark. */
  x: number;
  y: number;
}

/**
 * Where each pair comes together — the block, or the tackle.
 *
 * Both men are walked down their own routes on one clock. The collision is the
 * first step where they are within touching distance AND somebody has actually
 * run there. That last condition is not fussiness: a pair lined up across the
 * ball starts inside touching distance, and without it the very first sample
 * counts, both men freeze on their own alignment, and the play never moves.
 *
 * A pair that never quite touches counts at its closest approach, provided that
 * is close enough to be a collision rather than two men passing on opposite
 * sides of the field. A pair a coach assigned himself always gets a mark
 * however far apart their routes keep them — he has said this man takes that
 * man, so a mark sitting off on its own is the app telling him the route wants
 * redrawing.
 */
export function meets(pairs: MeetPair[]): Meet[] {
  const out: Meet[] = [];
  for (const pr of pairs ?? []) {
    const a = pr.ours ?? [], b = pr.theirs ?? [];
    if (a.length < 2 && b.length < 2) continue;   // nobody moves; there is no collision
    const a0 = a[0], b0 = b[0];
    let hit: { t: number; a: Pt; b: Pt; d: number } | null = null;
    let near: { t: number; a: Pt; b: Pt; d: number } | null = null;
    for (let i = 0; i <= 120; i++) {
      const t = i / 120, pa = walk(a, t), pb = walk(b, t);
      const gone = Math.hypot(pa.x - a0.x, pa.y - a0.y) + Math.hypot(pb.x - b0.x, pb.y - b0.y);
      if (gone < MEET_MOVED) continue;
      const d = Math.hypot(pa.x - pb.x, pa.y - pb.y);
      if (!near || d < near.d) near = { t, a: pa, b: pb, d };
      if (d <= MEET_TOUCH) { hit = { t, a: pa, b: pb, d }; break; }
    }
    const c = hit ?? ((near && (pr.assigned || near.d <= MEET_NEAR)) ? near : null);
    if (!c) continue;
    out.push({
      id: pr.id, bi: pr.bi, assigned: !!pr.assigned,
      t: c.t, a: c.a, b: c.b, d: c.d,
      x: (c.a.x + c.b.x) / 2, y: (c.a.y + c.b.y) / 2,
    });
  }
  return out;
}
