# bridge — making the planner's diagrams move

Built to drop into `sdalley32/8th-grade-practice-planner`. It stages here first so
it can be tested against a real book before anything is touched over there.

The planner's plays are generated SVG. That makes beautiful, consistent cards and
it is why they cannot be played: a picture has no model underneath it, so there is
nothing to walk down a route, nothing to pair a blocker with the man he blocks,
and nowhere to put a collision. This adds the model without changing a drawing.

## What's here

| | |
|---|---|
| `playEngine.ts` | The geometry, ported from `play-engine.js` in this repo. Pure — no DOM, no React, no imports. Curves, walking a path on a clock, matchup pairing, contact points. |
| `sceneToPlay.ts` | The bridge. Turns the planner's `PlayScene` into what the engine needs. About a hundred lines, and most of that is comments. |
| `prove.ts` | Runs the whole pipeline end to end and reports. Not shipped — it exists to answer "does this work on real diagrams" from outside their repo. |
| `fixtures/` | One diagram in the planner's exact SVG format, generated from **our** Offense — Base and Defense — Purple. See the note on artwork below. |

## Why it is small

`playScene.ts` in the planner already reads the artwork back into men and lines so
a coach can edit it. That parse does nearly all the work: a `SceneMan` is a player
with a position and a side, and the points of a line are a route. So this is a
shape change, not a conversion. Nothing is redrawn, nothing is stored, and the SVG
stays the source of truth.

Two things the artwork gives us for free:

- **Both sides are already in the same picture.** 1,422 of the planner's 1,433
  diagrams carry defenders as well as offense. The special teams tool has to
  *derive* the other team by reflecting a paired play across the ball, because its
  plays only ever hold one side. Here there is nothing to mirror.
- **Blocks are already assigned.** A line with `term: "tee"` ends on the man being
  blocked, so `coversFromBlocks()` reads that pairing straight off the drawing
  rather than guessing at it. Everyone else pairs by distance, and a coach can
  override any of it.

## Running it

```bash
node --experimental-strip-types bridge/prove.ts
```

Against the planner's real book, locally, with a path to their file:

```bash
node --experimental-strip-types bridge/prove.ts ../8th-grade-practice-planner/src/lib/diagramArt.ts
```

It only reads. Nothing is written either side.

## A note on their artwork

`diagramArt.ts` says the offense is password-protected and the artwork never goes
in `public/`. **This repo is public**, so none of it is committed here — not as a
fixture, not as a test file. The fixture is our own play written out in their
format, which exercises the same code paths.

## What it does not do yet

No rendering and no React. The next piece is a component that draws a scene on a
field and plays it — that belongs in their repo, in their tokens, and it should be
written there rather than guessed at from a zip.
