# Lehi Special Teams — Play Designer

Interactive play designer for a **Lehi Youth Football 8th grade** special teams unit.
Dom is the assistant coach running special teams. This tool designs, stores, and prints
the four kicking units plus variants.

Current state: `index.html` (the coach's tool), `learn.html` (the boys' version) and
`special-teams-plays.json`, which both read. No build step, no dependencies, deploys as
a static site.

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

## Working with Dom

He talks, you change the repo. He is on a phone, usually mid-thought, and writes short.
Read the whole message before acting — he often corrects a premise in passing ("those are
plays I made", "I have two kick returns"), and that correction matters more than the
request around it.

Standing decisions. Do not relitigate these:

- **He is the special teams coach and the only user.** Nothing goes toward sharing,
  accounts, multi-user, or making it work for other teams.
- **The app is for practice and planning. Print is the game-day output.** He barely uses
  a device on a sideline. Anything meant for game day has to be printable.
- **Personnel is his.** Who lines up where is a coaching decision, not a code decision.
  Seed a draft if he asks, say plainly that it is a draft, and do not question it again.
  Same for the written jobs and the generated routes — drafts he corrects.
- **The league hands him the minimum-play form at kickoff.** Do not build one.
- Names read as last name and number, on the field and in the boys' app.

How his work reaches you: edits live in `localStorage` on his device, not in the repo.
The badge under the export buttons says whether this device matches the repo. Either he
taps **Save to repo** (needs `GITHUB_TOKEN` and `SAVE_SECRET` on Vercel), or he taps
**Export as file** and pastes it into the chat and you commit it. If he describes a change
to a play you cannot see in the JSON, that is why — ask for the export before assuming
the data is wrong.

Verify in a browser, not by reading. Every real bug this project has produced —
the save badge lying, the game-day bar leaking onto the normal screen, names stacked
unreadably on a kickoff, lanes crossing each other — was invisible in the source and
obvious in a screenshot or a measurement.

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

**`learn.html` is for the players.** Same JSON, its own page, so the coaching tool stays
uncluttered and the boys get a link that cannot edit anything. Three modes: **Watch it**
animates each man along his route with a scrub bar; **Line me up** asks where a spot
lines up and scores the tap by distance in yards; **My job** is multiple choice built
from the written jobs. Names show as last name and number, same as the field diagram.
It fetches the JSON, and prefers `pd-source` from `localStorage` when it is there.
`index.html` writes that key on every save (and on load), so on Dom's own device the
boys' page shows his live edits instead of the shipped playbook — otherwise nothing he
changed would ever appear there. A player on his own phone has no `pd-source` and gets
the published version, which is the point: his edits reach them when he exports and it
ships. A note under the field says which is showing, with a button to switch, and an
open boys tab updates the moment he saves in the other one.

```
index.html
├─ PLAYDATA      parsed special-teams-plays.json; BY_SLUG indexes it
├─ TEAM[]        roster, seeded from PLAYDATA.roster if nothing is saved
├─ buildPlay()   pure: slug in, fresh play out (new ids every call)
├─ STORE         storage shim (window.storage → localStorage), rejects on failure
├─ save()        debounced write + honest badge; flushes on pagehide/visibilitychange
├─ backups       rolling local snapshots + download/restore
├─ computeView() crops the viewBox to the play, capped at 2.4x so a tight cluster
│                keeps its context; placeLabels() keeps names clear of circles,
│                of each other, and of the line caption
├─ look()        the current look; the only path to a play's routes and target
├─ drawAim()     the target mark — where the ball is meant to end up
├─ drawField()   renders the SVG; pal() swaps to black-on-white for printing
├─ toSourceJSON()writes the playbook back out as special-teams-plays.json
├─ game day      read-only, one unit, swipe/arrows to move between them
├─ paintLineup() editable position/name list under the field
└─ migration     runs on load: rename, seed-if-empty, never delete
```

**Looks — one alignment, several outcomes.** A kickoff is the same eleven in the same
spots however the ball comes off the foot; what changes is where it lands and how the
lanes fit. So a play holds `looks[]`, each with its own `aim`, its own `routes` and a
`how` sentence, over the shared `players[]`. `look(p)` is the only way to reach the
current one — nothing reads `p.routes` or `p.aim` any more, and `look()` self-heals a
play that still carries the flat shape rather than failing a render. The file writes a
single-look unit **flat**, exactly as it always did, so the seven units that happen one
way produce no diff; a multi-look unit writes a `looks` list. `buildPlay()` reads both.
Chips above the field switch looks and are hidden entirely on a one-look unit.
Print puts each look on its own page and names it in the title; the jobs handout stays
one page per unit, because the lane names and the jobs are the same whichever kick it
is — only the target line names the look. `#lookBar` is in the print hide list on
purpose: a new element left out of it prints, which is how the game-day bar leaked.

The three kickoffs carry **Deep / Pooch / Squib** — what an 8th grade leg actually
produces. The coverage for the short kicks is generated by constricting the deep-kick
lanes about the landing spot: a scale about one point with a positive factor, so the
order the men stand in is the order they stay in and no two lanes can cross. A flat
lean slid the whole unit sideways across the field, which is not coverage; a per-man
lean tangled them. Men whose job is a sideline (`role: OUTSIDE` on the clusters) are
left alone — the sideline is the same distance away whatever the kick does. A cluster's
paths do cross, and that is correct: the men leave the huddle at different times.

**The target mark.** Each play carries an optional `aim` — `{x, y, label, from}` — drawn
as a crosshair where the ball is supposed to end up. On a kicking unit `from` names the
player it leaves (`P`, `K`, `PP`) and a dashed arc traces the flight; on a return there is
no `from`, because the returner's own route already shows the path. `aimCapRect()` breaks
the caption at the em dash into two lines, clamps it inside the view, and keeps it off the
line of scrimmage and its caption — a single long line ran off the side of a cropped view
and landed on the line label. It is draggable in move mode only, edits in the Selected
player panel, exports with the playbook, and counts toward `playFingerprint` so moving it
shows up in the repo badge. Delete mode cannot touch it; only its own Remove button does.

**The other team is one of his own plays.** His idea, and it removed a whole category of
guesswork. A kickoff and a kick return are the two sides of the same snap, so the likely
opposing look on one *is* the other. Each play names a `mirrorOf` slug; `themOf(p)` reflects
that play's eleven across the line of scrimmage and flips it left-to-right — their left is
our right — scaled to fit the host play's depth. Nothing is stored: there is no opponent
data to overwrite, to lose, or to keep in sync, and when he edits a return the kickoff it
faces changes with it. Only Onside has no true counterpart; it borrows the 5-2-2-2 hands
team. A **Them** toggle shows or hides them, default off in the coach's app and on in the
boys' animation. Hidden opponents do not widen `computeView`; they are never hit-testable,
because they belong to another play and are edited there; and they are drawn underneath our
eleven so our circles are never covered. Older saves may still carry `team:'x'` players from
when they were seeded — those are left alone and simply ignored.

**Matchups.** Because the other team is a real play, every opposing man has a label, a lane
and a written job. `matchups(p)` pairs each of our eleven with the nearest of theirs,
best-pair-first so two of ours cannot claim the same man while a third goes unmatched.
Selecting a player lights up the man he has to beat and draws the line between them; the
Selected panel and the printed handout name the matchup; the boys' **My job** answers with
*who you are across from*, *what he will try*, and *how you beat him* — all three read off
his own two sheets rather than invented. All 110 spots resolve.

**Print is the game-day output.** The app is a practice and planning tool; Dom barely
uses a device on the sideline. Three modes, routed by `data-print` on `<body>`:
`play` (the current unit), `book` (all ten, one per page) and `jobs` (the teaching
handout). Anything meant for game day must be printable.

**Printing.** `beforeprint` (plus a `matchMedia('print')` listener) sets `printing`,
redraws through `PAL_PRINT`, and `paintPrintSheet()` builds a plain table so the
interactive `<select>` lineup never reaches paper. `@page` is letter portrait, the
diagram is pinned to 96mm, and every play fits one sheet — re-check that with the PDF
page count if you change either.

**Game day.** Its chrome is shown by `body.gd`, never by the `hidden` attribute — an
id rule outranks the UA `[hidden]` rule, and that is exactly how the bar once leaked
onto the normal screen. `body.gd` hides all editing chrome. The field is read-only: `pointerdown`
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
LGD/RGD guards, S snapper, LW/RW wings, PP protector, P punter. Kickoff: L1→L5 and
R1→R5 numbering outward from K; the 2 spots used to read LG/RG, and "gunner" is a role
now, not a label. Onside: L1→L6 kick side, R1→R4 away side. Kick return: H1–H5 hands team, LM/RM and LB/RB blockers, LR/RR deep. Punt return:
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
- ~~Minimum-play sheet~~ — dropped. The league hands him the form at kickoff; the app's
  job is the *planning* side, which the who's-on-what grid covers.
- ~~Per-spot coaching notes~~ — done. Each player carries `role` (the lane name, e.g.
  CONTAIN) and `job` (what to do, in words a first-year kid gets), both editable in the
  Selected player panel and exported with the playbook. A `glossary` in the JSON explains
  the terms, and only the ones used on the current unit are shown. **Print jobs** produces
  a one-page handout per unit. Deliberately *not* on the play sheet — adding it there
  pushed that to two pages, and the one-page play sheet is the contract.
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

- ~~Kickoff lane numbering~~ — settled. Numbering runs **outward from the kicker**
  (L1/R1 beside him, L5/R5 widest), which is the commoner convention and was already the
  app's direction; the real inconsistency was LG/RG sitting in a numbered row, and those
  are L2/R2 now. His handwritten sheet numbers the same row the other way (L1 widest).
  The lanes (BALL CONTAIN FORCE ALLEY BALL | SAFETY | BALL ALLEY FORCE CONTAIN BALL) are
  mapped by **where the man stands**, not by his number, so they land on the same eleven
  bodies either way. Flipping the numbering is a one-line data edit if he prefers his.
- **The target marks are drafts.** Where each unit is trying to put the ball is a coaching
  decision. Seeded so every unit has one; the onside mark sits on their restraining line
  because the kick has to travel ten yards, which is the one that is geometry rather than
  preference. The rest — corner or middle on a kickoff, which sideline on a return — are
  his to move.
- **The three kicks are drafts, and so is the coverage on two of them.** Deep is his
  own routes, untouched. Pooch and Squib are generated from it, so the angles are a
  starting point, not a scheme. Which three kicks a unit should even carry is his call.
- ~~The opposing alignments are drafts.~~ Gone — they are his own paired plays now. What is
  still his call is **which play faces which** (`mirrorOf`), and the onside borrow.
- **Onside personnel is a draft.** Assigned so the three men under the kick are the
  surest hands and all four ten-play boys get a snap. His call to change.
- The written jobs are drafts. Punt-return wall/hold-up spots and both cluster kickoffs
  were left blank rather than guessed at.

Do not silently resolve these; they are personnel decisions, not code decisions.

- Snapper is Paulich, who is the #1 LT. Rowley (#1 C) and Martinez (#2 C) are the actual
  centers. Dom knows and is handling it — do not re-raise unprompted.
- Punt interior is skill players rather than linemen. Same: known, his call.
- Two handwritten punt personnel sheets never reconciled (Bagley/Severts vs Dalley/Steinke).
- "Kickoff — Spread" alignment was flagged as misread from the original sheet and never
  corrected.

---

## Saving to the repo

Edits live in `localStorage` until they are pushed. Two things close that gap:

- **The badge.** `repoDiff()` compares the current state against the
  `special-teams-plays.json` the site is actually serving and says, by name, which plays
  differ. Green means this device matches the repo. Compare on *values*, not key sets —
  the file omits `xman`/`tenPlay` when false and `toSourceJSON()` always writes them, so a
  raw stringify reports a phantom roster edit.
- **Save to repo.** `api/save-playbook.js` on Vercel commits straight from the app. The
  GitHub token is a server-side env var and never reaches the browser; the browser only
  holds a passphrase, checked against `SAVE_SECRET`. It writes the JSON **and** the
  embedded block in `index.html` in one commit via the git trees API, so the two cannot
  drift. Needs `GITHUB_TOKEN` (fine-grained, this repo, Contents: read+write) and
  `SAVE_SECRET` set on the Vercel project. Without both it returns 501 and says so.

`Export as file` still works and is the offline path.

## Deploy

Static. Vercel serves `index.html` at the root; `vercel.json` disables aggressive caching
so a redeploy shows up immediately. Plays live in `localStorage` keyed to the deployed
origin, so **replacing index.html does not touch the user's data** — that is the entire
reason this is hosted rather than passed around as a file.
