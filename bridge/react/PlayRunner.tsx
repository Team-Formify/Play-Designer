"use client";

/**
 * PLAY RUNNER — the diagram, played.
 *
 * Drop-in for the playbook viewer. It takes a generated diagram exactly as it
 * ships, reads it with this repo's own `sceneFromSvg`, and does three things
 * the picture cannot do on its own:
 *
 *   · runs it     — all twenty-two walk their own lines on one clock
 *   · matches up  — who takes whom, read off the block tees where they exist
 *   · marks it    — where a pair actually meets, ringed on the field
 *
 * WHAT IT DOES NOT DO IS REDRAW ANYTHING. The artwork is the source of truth
 * and stays so: `Original` puts the untouched SVG back on screen, and nothing
 * here is ever written to a diagram. A coach's nudge is a delta held by the
 * caller, the same shape `playScene.ts` already keeps for edits.
 *
 * The geometry lives in `playEngine.ts` and the shape change in
 * `sceneToPlay.ts`, both pure and both testable without a browser. This file is
 * only the drawing and the clock.
 */

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { sceneFromSvg } from "@/lib/playScene";
import { sceneToPlay, assignments, type PlayMan } from "@/lib/sceneToPlay";
import { smoothD, walk } from "@/lib/playEngine";
import s from "./PlayRunner.module.css";

/** Where a man is drawn right now: on his route, or stopped at his collision. */
interface Freeze { t: number; at: { x: number; y: number } }

export interface PlayRunnerProps {
  /** The diagram, exactly as `DIAGRAM_SVG` holds it. */
  svg: string;
  /** Per-man nudges, keyed by `SceneMan.id`. The caller owns persistence. */
  moves?: Record<string, { dx: number; dy: number }>;
  /** Called when a man is dragged, so the caller can store the delta. */
  onMove?: (manId: string, delta: { dx: number; dy: number }) => void;
  /** Editing is off unless the caller turns it on. */
  editable?: boolean;
}

const VB_FALLBACK = [0, 0, 920, 460] as const;

export default function PlayRunner({ svg, moves, onMove, editable = false }: PlayRunnerProps) {
  const [t, setT] = useState(0);
  const [playing, setPlaying] = useState(false);
  const [slow, setSlow] = useState(false);
  const [marks, setMarks] = useState(true);
  const [original, setOriginal] = useState(false);
  const raf = useRef<number | null>(null);
  const host = useRef<SVGSVGElement | null>(null);

  /* The picture's own box and its line of scrimmage. Read from the artwork
     rather than assumed, because a diagram may be cropped. */
  const viewBox = useMemo(() => {
    const m = svg.match(/viewBox="([^"]+)"/);
    const n = m ? m[1].split(/\s+/).map(Number) : null;
    return n && n.length === 4 && n.every(Number.isFinite) ? n : [...VB_FALLBACK];
  }, [svg]);

  const los = useMemo(() => {
    const m = svg.match(/<line x1="28" y1="([-\d.]+)"/);
    return m ? Number(m[1]) : viewBox[1] + viewBox[3] / 2;
  }, [svg, viewBox]);

  /* The model. Rebuilt when the artwork changes or a man is nudged — never
     stored, so editing the diagram moves the matchups with it. */
  const { play, contacts, frozen, pairs } = useMemo(() => {
    const p = sceneToPlay(sceneFromSvg(svg), moves);
    const { contacts, pairs } = assignments(p);
    const frozen: Record<string, Freeze> = {};
    for (const c of contacts) {
      const ours = p.offense.find((m) => m.id === c.id);
      const theirs = c.bi === undefined ? undefined : p.defense[c.bi];
      if (ours) frozen[ours.id] = { t: c.t, at: c.a };
      if (theirs) frozen[theirs.id] = { t: c.t, at: c.b };
    }
    return { play: p, contacts, frozen, pairs };
  }, [svg, moves]);

  /* EVERY matchup, not only the ones that collide.
     Listing collisions alone gave one row on a Power — the line pulls and
     nobody else closes — which left most of the panel empty and answered a
     narrower question than the one a coach asks. He wants to know who has whom
     on all eleven; whether they physically meet is a property of the routes as
     drawn, so it is a mark on the row rather than the price of appearing. */
  const board = useMemo(() => {
    const met = new Map(contacts.map((c) => [c.id, c]));
    return play.offense
      .filter((o) => pairs[o.id] !== undefined)
      .map((o) => ({
        id: o.id, label: o.label,
        them: play.defense[pairs[o.id]]?.label ?? "?",
        drawn: Boolean(o.covers),
        meets: met.get(o.id),
      }))
      .sort((a, b) => Number(Boolean(b.meets)) - Number(Boolean(a.meets)));
  }, [play, pairs, contacts]);

  /* The clock only changes where a man is DRAWN. Nothing mutates his position,
     so a re-render mid-run can never write the halfway picture back. */
  useEffect(() => {
    if (!playing) return;
    let live = true;
    const step = () => {
      if (!live) return;
      setT((prev) => {
        const next = prev + (slow ? 0.0022 : 0.006);
        if (next >= 1) { setPlaying(false); return 1; }
        return next;
      });
      raf.current = requestAnimationFrame(step);
    };
    raf.current = requestAnimationFrame(step);
    return () => { live = false; if (raf.current) cancelAnimationFrame(raf.current); };
  }, [playing, slow]);

  const posOf = useCallback((m: PlayMan) => {
    const f = frozen[m.id];
    if (f && t >= f.t) return f.at;      // he met somebody: that is the block
    return walk(m.path, t);
  }, [frozen, t]);

  /* ── dragging ─────────────────────────────────────────────────────────── */
  const drag = useRef<{ id: string; from: { x: number; y: number } } | null>(null);
  const toSvg = (e: React.PointerEvent): { x: number; y: number } => {
    const el = host.current;
    if (!el) return { x: 0, y: 0 };
    const r = el.getBoundingClientRect();
    return {
      x: viewBox[0] + ((e.clientX - r.left) / r.width) * viewBox[2],
      y: viewBox[1] + ((e.clientY - r.top) / r.height) * viewBox[3],
    };
  };
  const onDown = (id: string) => (e: React.PointerEvent) => {
    if (!editable) return;
    drag.current = { id, from: toSvg(e) };
    (e.target as Element).setPointerCapture?.(e.pointerId);
    e.preventDefault();
  };
  const onDrag = (e: React.PointerEvent) => {
    const d = drag.current;
    if (!d || !onMove) return;
    const at = toSvg(e);
    const prev = moves?.[d.id] ?? { dx: 0, dy: 0 };
    onMove(d.id, { dx: prev.dx + (at.x - d.from.x), dy: prev.dy + (at.y - d.from.y) });
    d.from = at;
  };
  const endDrag = () => { drag.current = null; };

  const stop = () => { setPlaying(false); };
  const again = () => { setPlaying(false); setT(0); };

  /* Original is the artwork itself, not a re-render of it. */
  if (original) {
    return (
      <div className={s.wrap}>
        <div className={s.pic} dangerouslySetInnerHTML={{ __html: svg }} />
        <Controls {...{ playing, slow, marks, original, setSlow, setMarks, setOriginal, again }}
          onRun={() => { setOriginal(false); setPlaying(true); }} t={t} onScrub={(v) => { stop(); setT(v); }} />
      </div>
    );
  }

  return (
    <div className={s.wrap}>
      <div className={s.pic}>
        <svg ref={host} viewBox={viewBox.join(" ")} role="img" aria-label="The play, running"
             onPointerMove={onDrag} onPointerUp={endDrag} onPointerCancel={endDrag}>
          <rect x={viewBox[0]} y={viewBox[1]} width={viewBox[2]} height={viewBox[3]} className={s.field} />
          <line x1={viewBox[0] + 28} x2={viewBox[0] + viewBox[2] - 28} y1={los} y2={los} className={s.los} />

          {[...play.offense, ...play.defense].map((m) =>
            m.raw.length < 2 ? null : (
              <path key={"r" + m.id} d={smoothD(m.raw)}
                    className={m.side === "defense" ? s.routeThem : s.routeUs} />
            ))}

          {marks && contacts.map((c, i) => {
            const here = t >= c.t;
            return (
              <g key={"c" + i} className={here ? s.meetOn : s.meet}>
                <circle cx={c.x} cy={c.y} r={here ? 13 : 11} />
                {here && <circle cx={c.x} cy={c.y} r={3} className={s.meetDot} />}
              </g>
            );
          })}

          {play.defense.map((m) => {
            const p = posOf(m);
            return (
              <g key={m.id} onPointerDown={onDown(m.id)} className={editable ? s.grab : undefined}>
                <rect x={p.x - 11} y={p.y - 11} width={22} height={22} rx={3} className={s.them} />
                <text x={p.x} y={p.y + 4} className={s.themLabel}>{m.label}</text>
              </g>
            );
          })}
          {play.offense.map((m) => {
            const p = posOf(m);
            return (
              <g key={m.id} onPointerDown={onDown(m.id)} className={editable ? s.grab : undefined}>
                <circle cx={p.x} cy={p.y} r={11} className={s.us} />
                <text x={p.x} y={p.y + 4} className={s.usLabel}>{m.label}</text>
              </g>
            );
          })}
        </svg>
      </div>

      <Controls {...{ playing, slow, marks, original, setSlow, setMarks, setOriginal, again }}
        onRun={() => setPlaying((p) => !p)} t={t} onScrub={(v) => { stop(); setT(v); }} />

      {marks && board.length > 0 && (
        <>
          <div className={s.boardHead}>
            WHO TAKES WHO
            <span>{contacts.length} of {board.length} come together</span>
          </div>
          <ul className={s.pairs}>
            {board.map((r) => (
              <li key={r.id} className={r.meets ? s.meets : undefined}>
                <b>{r.label}</b> takes <em>{r.them}</em>
                <span>{r.drawn ? "blocked" : r.meets ? "meets" : "nearest"}</span>
              </li>
            ))}
          </ul>
        </>
      )}
    </div>
  );
}

interface ControlsProps {
  playing: boolean; slow: boolean; marks: boolean; original: boolean;
  setSlow: (v: boolean) => void; setMarks: (v: boolean) => void; setOriginal: (v: boolean) => void;
  again: () => void; onRun: () => void; t: number; onScrub: (v: number) => void;
}
function Controls(p: ControlsProps) {
  return (
    <>
      <div className={s.tools}>
        <button type="button" className={s.go} onClick={p.onRun}>
          {p.playing ? "❚❚ Stop" : "▶ Run it"}
        </button>
        <button type="button" className={s.btn} aria-pressed={p.slow}
                onClick={() => p.setSlow(!p.slow)}>{p.slow ? "Normal" : "Slow"}</button>
        <button type="button" className={s.btn} onClick={p.again}>Again</button>
        <button type="button" className={s.btn} aria-pressed={p.marks}
                onClick={() => p.setMarks(!p.marks)}>Matchups</button>
        <button type="button" className={s.btn} aria-pressed={p.original}
                onClick={() => p.setOriginal(!p.original)}>Original</button>
      </div>
      <input className={s.scrub} type="range" min={0} max={1000} value={Math.round(p.t * 1000)}
             aria-label="Scrub the play" onChange={(e) => p.onScrub(Number(e.target.value) / 1000)} />
    </>
  );
}
