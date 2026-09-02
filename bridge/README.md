# bridge — the merged build

**This is the real build, not an experiment.** The decision, his: the practice
planner's app becomes the one everybody uses, and this app's field code is what
makes its plays run. It is developed and proved here first, then moved to
`sdalley32/8th-grade-practice-planner` when it is ready.

What that means for this repo: `playbook.html` at the root is that app, deployed
and live. It carries the special teams only — his half of the book is
password-protected and this site is public — but it is the same page, the same
engine and the same code path that goes across. Nothing about it is a mock-up.

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
| `build-combined.mjs` | Builds `combined.html`. Reads his `diagramArt.ts` and `diagrams.ts` off a local checkout, converts our plays into his SVG format, and fills in the shell. |
| `combined-shell.html` | **His app**, reproduced from his own `globals.css` and `PlaybookGrid` — navy bar, call-sheet rows, three-tap viewer — with Run it, Matchups and Edit added to it. Ships empty; the playbook is injected at build. |
| `react/PlayRunner.tsx` | The drop-in for his repo: a client component that runs a diagram, marks the matchups and lets a man be dragged. Uses **his** `sceneFromSvg`, so there is no second parser. Typechecks clean under his exact strict tsconfig. |
| `react/PlayRunner.module.css` | Its styles, in his tokens and his button sizing. |
| `ts-loader.mjs`, `register-ts.mjs` | Imports here are extensionless because that is what his bundler wants and these files are meant to land unchanged. His repo solves this the same way; this is the same loader so `prove.ts` still runs. |
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

## His app, with the field code threaded in

```bash
node bridge/build-combined.mjs ../8th-grade-practice-planner
```

**His app is the app.** His navy bar and nav, his tokens straight out of
`src/app/globals.css`, his call-sheet rows, his section headings, his three-tap
path — list, play, card — and his `‹ ›` viewer nav. None of it is
reinterpreted. `Original` drops his exact generated SVG on screen, arrowhead
markers and all.

What the special teams designer adds, and all it adds:

| | |
|---|---|
| **Run it** | every play walks its own routes on one clock — his too, which they have never done |
| **Matchups** | who takes whom, and the ring where they actually meet |
| **Edit** | drag a man and the pairings and contact points follow him |
| **Special teams** | Dom's kicking units, threaded into *his* list as one more section between THE CORE and EVERYTHING ELSE — not a second app, not a second picker |

Two things had to give to fit his format, and both are recorded here because
they are the parts a reader would otherwise call bugs:

- **A punt is not a 2:1 picture.** His box is 920×460, right for a snap from
  scrimmage. The punter stands fourteen yards back, so our plays size the box to
  the play — his width, whatever height the play needs — or the punter is simply
  cut off the bottom.
- **Our plays don't store an opposing eleven.** They name the play they face and
  reflect it across the ball at draw time. His pictures hold both sides, so the
  mirror is resolved once, at build.

Edits are kept per play in `localStorage` as a nudge against a man, never
written back to his artwork — the same shape as the diffs his own `playScene.ts`
keeps. **Undo my moves** puts one play back and touches no other.

**The output is gitignored and must stay that way.** It carries his artwork and
this repo is public.

## Running it

```bash
node --experimental-strip-types --import ./bridge/register-ts.mjs bridge/prove.ts
```

Against the planner's real book, locally, with a path to their file:

```bash
node --experimental-strip-types --import ./bridge/register-ts.mjs \
  bridge/prove.ts ../8th-grade-practice-planner/src/lib/diagramArt.ts
```

It only reads. Nothing is written either side.

### Typechecking the component

`PlayRunner.tsx` is written to compile in his repo, not here — this repo has no
TypeScript and is not getting any. To check it, copy `playEngine.ts`,
`sceneToPlay.ts` and `react/PlayRunner.*` into a checkout of his beside his
`playScene.ts` and run his `tsc --noEmit`. Last run: **no errors in these files**
under his exact `strict` config.

## A note on their artwork

`diagramArt.ts` says the offense is password-protected and the artwork never goes
in `public/`. **This repo is public**, so none of it is committed here — not as a
fixture, not as a test file. The fixture is our own play written out in their
format, which exercises the same code paths.

## Proved in his real app

Not a reimplementation of his UI — **his actual codebase, built and running,
with this engine in it.** Done in a scratch copy of his repo; nothing of his was
committed here.

```
npm install                → ok
tsc --noEmit               → 0 errors, his strict config, whole app
next build                 → ok: every route, the middleware, the players site
next start + Playwright    → his playbook, his viewer, our engine
```

What the browser showed at 390px, on his `/players` playbook:

- his list renders — **THE CORE / EVERYTHING ELSE, 28 rows**
- opening `12 Power` gives his navy viewer, his gold **THE FIELD CARD** button
  and his `‹ RUN · HB carries ›` nav
- inside it: **Run it / Slow / Again / Matchups / Original** and a scrub bar
- pressing Run it moves his men — 4 of 23, correct for a Power where only the
  line pulls
- **`T-R takes T — ASSIGNED`**, read straight off his own block tee
- **Original** puts his untouched artwork back

Two things had to be faked locally to see it, neither of which ships: his
Supabase is unreachable from here so the taught-plays list came back empty and
was stubbed, and his gate passwords come from env so local ones were set. His
own data and passwords were never needed.

## Moving it across

`react/PlaybookGrid.patch` is the entire change to his codebase — **7 lines
added, 2 removed**, verified to apply clean to a fresh copy of his `src/`:

```bash
patch -p1 < PlaybookGrid.patch      # one import, one swapped line
```

Plus four new files:

| From here | To there |
|---|---|
| `playEngine.ts` | `src/lib/playEngine.ts` |
| `sceneToPlay.ts` | `src/lib/sceneToPlay.ts` |
| `react/PlayRunner.tsx` | `src/components/PlayRunner.tsx` |
| `react/PlayRunner.module.css` | `src/components/PlayRunner.module.css` |

Nothing else of his is touched — the rows, the sections, the `‹ ›` nav, the
print sheet and the field cards are all his and all unchanged.

**One cosmetic thing to fix before this is proposed:** his `.vpics` is a flex
column sized for a picture, and the runner adds controls and a matchup list
under it, so on a tall phone there is a stretch of empty white between the
matchup list and the rotate hint. It belongs in his stylesheet, not ours.

The special teams arrive the same way they do here: written into his SVG format
by `build-combined.mjs` and added to the tile list as their own section.
