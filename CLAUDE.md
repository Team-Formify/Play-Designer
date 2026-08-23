# Lehi Special Teams — Play Designer

Interactive play designer for a **Lehi Youth Football 8th grade** special teams unit.
Dom is the assistant coach running special teams. This tool designs, stores, and prints
the four kicking units plus variants.

Current state: `index.html` plus `special-teams-plays.json`. No build step, no
dependencies, deploys as a static site.

---

## Read this before you change anything

This project has a history of losing the user's work. Every rule below exists because
it was broken once and cost him hours of re-entry. Treat them as hard constraints.

1. **Never delete a play automatically.** Not "retired" ones, not duplicates, not empty
   ones. The only thing that removes a play is the user pressing Delete play.
2. **Never overwrite a name the user set.** Seeding may fill a play that is *completely*
   empty. The moment any player on that play has a name, the code does not touch it.
3. **Match on `slug`, never on display name.** Renaming a play must never break a lookup.
   Names are for humans; slugs are the key.
4. **Storage must degrade gracefully.** The app runs in three contexts: hosted URL,
   downloaded local file, and inside an artifact viewer. `window.storage` only exists in
   the last one. There is a `STORE` shim that falls back to `localStorage`. Keep it.
5. **Show save state.** There is a badge next to the play dropdown that reads SAVED (green)
   or NOT SAVED (orange). Never remove it. Silent save failure is what caused most of the
   pain here. The badge tracks the *pending edit*, not the last successful write: `save()`
   bumps `saveSeq` and paints orange immediately, and only a completed write moves
   `savedSeq` up to meet it. Never make it green on anything but a resolved write.
6. **Migrations rename, they never rewrite.** If a data shape changes, migrate forward
   additively.

---

## The league: UYFC, 8th grade

These rules constrain what plays are legal. Verify against the current UYFC rulebook
before relying on any of them; they were correct as of the 2026 preseason.

| Rule | Detail |
|---|---|
| Field | 100 yards (8th and 9th grade). Kickoff from the 40. |
| Clock | 16-minute running quarters. 25-second play clock. |
| Field goals | **Not allowed below 9th grade.** There are only four units, not five. |
| Conversions | Run or pass. 1 point from the 1.5, 2 points from the 3. Failed attempts are dead. |
| Punts | Full NFHS rules for grades 5–9. Live rush, live return. |
| Minimum plays | Every player gets 10. Special teams snaps count. Escalates to 16/13/12 if leading by 21+ after Q1/Q2/Q3. |
| X-men | 165 lbs+ at 8th grade. On special teams they must be on the **front two lines or the LOS**. May kick or punt but **may not fake a punt**. On a mishandled snap they may only fall on the ball. |
| Illegal | Pop-up kicks. Wedge of 3+ shoulder to shoulder within 2 yards. Blindside blocks. |
| Auto first down | Roughing the kicker, snapper, holder, or passer. |

**Ten-play boys** — start on neither offense nor defense, so they are the ones the rule
actually requires tracking: **Bullock, Grover (#55), Martinez (#22), Prasad (#67)**.

---

## Roster (21)

`last, first, number, X-man, offense depth, defense depth`

| Last | First | # | X | Offense | Defense |
|---|---|---|---|---|---|
| Archuletta | Cree | 14 | | QB / LG / X | MIKE |
| Bagley | Ledger | 27 | | Z | LCB / SS |
| Bearnson | Ryker | 49 | | RG / QB / Z / F / Y | SS |
| Black | Brave | 12 | | F / Y | RDE / FS |
| Bullock | Tistyn | — | ✓ | RG | LDT |
| Dalley | Caleb | 17 | | H / Y / F / RT | LDE |
| Debenham | Dolan | 16 | | C / RT | SAM |
| Grover | Ja'corey | 55 | | H | LCB / RCB |
| Martinez | Daxton | 22 | | C / LT | LDT / RDT |
| Mineer | Mason | 47 | | X | RCB |
| Mitchell | Cole | 48 | ✓ | LG | RDT |
| Pace | Kyler | 10 | | Y / H | FS |
| Paulich | Andrew | 35 | | LT | RDE / LDT / MIKE |
| Prasad | Joseph | 67 | | Z | LCB |
| Reary | Cache | 9 | | QB | FS |
| Rowley | Mason | 73 | | C | RDT |
| Ruelas | Jehudiel | 74 | ✓ | RG | LDT |
| Scott | Rowan | 99 | | Z | RCB / WILL |
| Severts | Cooper | 34 | | Z | WILL / FS |
| Steinke | Zander | 33 | | — | LDE / RDT / MIKE / SAM |
| Wentzel | Carter | 7 | | X | RCB |

**Starting defense ("purple")**: Ruelas, Steinke, Dalley, Black, Archuletta, Debenham,
Scott, Severts, Wentzel, Bagley, Pace. The other 10 are the "white" unit — a full second
defense needs one starter, currently Bagley.

---

## The ten plays

Order in the dropdown is by game phase. Data lives in `PRESETS` inside `index.html`;
a normalized copy is in `special-teams-plays.json`.

1. **Punt — Base** — spread punt, 1-yard splits, punter at 14 yards. Personal protector
   sits ~2 yards off the midline so the snap lane is clear.
2. **Punt — Villanova Fake** — snap to the protector, fake toss back to the punter, punter
   fakes a handoff to the crossing wing, protector breaks the other way.
3. **Punt Return — Purple D** — 6-2-2-1. Starting defense.
4. **Punt Return — White D** — same shape, second unit.
5. **Kickoff — Spread** — from the 40, ten across, four each side of the kicker.
6. **Kickoff — Cluster Speed** — huddle inside the numbers, twins pairs break to each
   sideline after the ready whistle. Fast kids.
7. **Kickoff — Cluster 10-Play** — same alignment, the boys who need snaps. X-men interior.
8. **Kickoff — Onside** — kangaroo kick right (2+ bounces; pop-ups are illegal). 6 right,
   4 left of the kicker.
9. **Kick Return — 5-2-2-2** — five up front doubling as the hands team.
10. **Kick Return — 5-4-2** — same hands team and same deep pair, but the four blockers
    align on one row instead of in two pairs. Dom runs both returns.

**Orientation:** punt and kickoff plays are mirrored left-to-right relative to the coach's
handwritten sheets; punt returns are not. This is deliberate and was arrived at painfully.
Do not "fix" it without asking.

---

## Architecture

Vanilla JS, SVG, no dependencies, no build.

**Plays are data.** `special-teams-plays.json` is the source of truth — edit it, push,
and the app changes with no code edit. `index.html` also carries a byte-identical copy
in a `<script type="application/json" id="play-data">` block, because `fetch()` cannot
reach a sibling file when the page is opened as a downloaded local file or run inside
the artifact viewer (rule 4). The fetched file always wins when it is reachable.
After editing the JSON, run `node scripts/sync-play-data.js` to regenerate the embedded
block; `--check` exits non-zero if the two have drifted. That is a maintenance command,
not a build step — running the app needs nothing.

The roster lives in the JSON too, and seeds `TEAM` only when the user has none saved.

```
index.html
├─ PLAYDATA      parsed special-teams-plays.json; BY_SLUG indexes it
├─ TEAM[]        roster, seeded from PLAYDATA.roster if nothing is saved
├─ buildPlay()   pure: slug in, fresh play out (new ids every call)
├─ STORE         storage shim (window.storage → localStorage), rejects on failure
├─ save()        debounced write + honest badge; flushes on pagehide/visibilitychange
├─ backups       rolling local snapshots + download/restore
├─ computeView() crops the viewBox to the play; placeLabels() keeps names clear
├─ drawField()   renders the SVG; pal() swaps to black-on-white for printing
├─ toSourceJSON()writes the playbook back out as special-teams-plays.json
├─ game day      read-only, one unit, swipe/arrows to move between them
├─ paintLineup() editable position/name list under the field
└─ migration     runs on load: rename, seed-if-empty, never delete
```

**Print is the game-day output.** The app is a practice and planning tool; Dom barely
uses a device on the sideline. Three modes, routed by `data-print` on `<body>`:
`play` (the current unit), `book` (all ten, one per page), `tally` (the minimum-play
form he has to fill in and hand in). Anything meant for game day must be printable.

**Printing.** `beforeprint` (plus a `matchMedia('print')` listener) sets `printing`,
redraws through `PAL_PRINT`, and `paintPrintSheet()` builds a plain table so the
interactive `<select>` lineup never reaches paper. `@page` is letter portrait, the
diagram is pinned to 96mm, and every play fits one sheet — re-check that with the PDF
page count if you change either.

**Game day.** `body.gd` hides all editing chrome. The field is read-only: `pointerdown`
returns early, so a swipe changes unit and nothing can be dragged by accident.

**No webfonts.** Everything is a system font stack. This gets used on a sideline with no
signal, so nothing may block on the network. Do not add a `<link>` to a font CDN.

**Backups.** `pd-bak-<ts>` keys with a `pd-bak-index` manifest. Up to 12, at most one per
30 minutes, plus a `pre-update` snapshot of the raw saved state taken *before* migration
runs whenever `BUILD` changes — that is the copy that matters when a new build misreads
old data. Pruning drops the oldest `auto` first so `pre-update` snapshots survive, and
restoring snapshots the current state as `pre-restore` first so it is reversible. Backups
are best effort and must never block or fail a real save.

**Coordinate system:** viewBox 420 × 500. Sidelines at x=14 and x=406, so 392px = 53.3
yards wide. Vertical scale varies per play and is not to scale — distances are labeled.

**Slugs are the key.** `slugFor(play)` resolves one: canonical slug first, then
`SLUG_ALIAS` for saves that still carry the old `PRESETS` key (`'STD Punt'` →
`std-punt`), then `NAME_SLUG` as a last resort for saves old enough to predate slugs.
Nothing matches on display name any more.

**Label convention:** `L`/`R` prefix for side. Punt: LG/RG gunners, LT/RT tackles,
LGD/RGD guards, S snapper, LW/RW wings, PP protector, P punter. Kickoff: L5→R5 outward
from K. Kick return: H1–H5 hands team, LM/RM and LB/RB blockers, LR/RR deep. Punt return:
LJ/RJ jammers, LH/MH/RH hold-up, LM/RM second level, LW/MW/RW wall, PR returner.
The mirroring the coach's sheets needed is baked into the stored coordinates, so
nothing flips a play at load time. `swapSideLabel()` is the shared L/R label swapper
used by the Mirror button — reuse it, don't hand-roll.

---

## What to fix first

~~Split data from code.~~ Done. `PRESETS` is gone; plays load from
`special-teams-plays.json` and `buildPlay()` is pure. `play-diagram.js` is still in the
repo as a standalone renderer for printed cards and is not yet wired into the app.

**Then, roughly in value order:**

- ~~Honest save badge~~, ~~rolling backups + download~~, ~~drop the webfonts~~,
  ~~split data from code~~, ~~fit the view to the play~~, ~~collision-placed labels~~,
  ~~export back out as source~~, ~~print stylesheet~~, ~~game-day mode~~ — done.
- ~~Minimum-play sheet~~ — done, as print. The count is turned in on paper, so the app
  prints the form rather than tallying on screen.
- Per-player coaching notes attached to a spot, so the printed sheet carries assignments.
- Multi-device sync. Supabase is the obvious fit but is explicitly **not** wanted for the
  2026 season. Revisit in the offseason.

**Do not** add a framework, a build step, or a dependency without asking. The single-file
property is why it works on a phone on a practice field.

---

## Fixed in the data/code split

All three were real and all three are gone. Recorded so they are not reintroduced:

- Renaming a play used to re-seed a duplicate — the CORE loop matched on
  `plays[k].name`. It matches on slug now.
- Saved plays carried the old `PRESETS` key as their slug. `SLUG_ALIAS` migrates them
  forward, additively, on load.
- Ids were `Math.random()*1e9|0` and could in principle collide, silently merging two
  players. `uid()` uses `crypto.randomUUID()` with a fallback.

**Applying a formation chip now also sets the play's slug** to that formation. This is
deliberate: the slug must describe what is actually on the field, or Fill names would
fill punt names into onside spots. A side effect is that the play's old formation counts
as missing, so "Add missing formations" will offer to restore it. That is the button
doing its job, not a bug.

## Open questions for the coach

Do not silently resolve these; they are personnel decisions, not code decisions.

- Snapper is Paulich, who is the #1 LT. Rowley (#1 C) and Martinez (#2 C) are the actual
  centers. Dom knows and is handling it — do not re-raise unprompted.
- Punt interior is skill players rather than linemen. Same: known, his call.
- Two handwritten punt personnel sheets never reconciled (Bagley/Severts vs Dalley/Steinke).
- "Kickoff — Spread" alignment was flagged as misread from the original sheet and never
  corrected.

---

## Deploy

Static. Vercel serves `index.html` at the root; `vercel.json` disables aggressive caching
so a redeploy shows up immediately. Plays live in `localStorage` keyed to the deployed
origin, so **replacing index.html does not touch the user's data** — that is the entire
reason this is hosted rather than passed around as a file.
