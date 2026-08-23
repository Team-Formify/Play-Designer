# Lehi Special Teams — Play Designer

Interactive play designer for a **Lehi Youth Football 8th grade** special teams unit.
Dom is the assistant coach running special teams. This tool designs, stores, and prints
the four kicking units plus variants.

Current state: one self-contained `index.html`, no build step, deploys as a static site.

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

## The nine plays

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

**Orientation:** punt and kickoff plays are mirrored left-to-right relative to the coach's
handwritten sheets; punt returns are not. This is deliberate and was arrived at painfully.
Do not "fix" it without asking.

---

## Architecture

Single file. Vanilla JS, SVG, no dependencies, no build.

```
index.html
├─ TEAM[]        roster
├─ PRESETS{}     play factories, each returns {players, los, losLabel, routes}
├─ STORE         storage shim (window.storage → localStorage), rejects on failure
├─ save()        debounced write + honest badge; flushes on pagehide/visibilitychange
├─ backups       rolling local snapshots + download/restore
├─ drawField()   renders the SVG
├─ paintLineup() editable position/name list under the field
└─ migration     runs on load: rename, seed-if-empty, never delete
```

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

**Label convention:** `L`/`R` prefix for side. Punt: LG/RG gunners, LT/RT tackles,
LGD/RGD guards, S snapper, LW/RW wings, PP protector, P punter. Kickoff: L5→R5 outward
from K. Kick return: H1–H5 hands team, LM/RM and LB/RB blockers, LR/RR deep. Punt return:
LJ/RJ jammers, LH/MH/RH hold-up, LM/RM second level, LW/MW/RW wall, PR returner.
`mir()` swaps these correctly when a play is mirrored — reuse it, don't hand-roll.

---

## What to fix first

**Split data from code.** `PRESETS` as inline JS factories is the root of most past bugs.
Move play data to JSON, load it, keep the render pure. `special-teams-plays.json` and
`play-diagram.js` in this repo are a working prototype of that split — the module renders
any play from the JSON with zero dependencies and has light/dark themes plus a `lineup()`
helper for printed cards.

**Then, roughly in value order:**

- ~~Honest save badge~~ and ~~rolling backups + download~~ and ~~drop the webfonts~~ — done.
- Print stylesheet needs a real pass. Printing a play should give a clean one-page sheet:
  diagram on top, lineup table below, black on white.
- A game-day mode: big text, one play at a time, swipe between units, no editing chrome.
- Minimum-play tracker — tally snaps per player across units. The 10-play rule is the
  thing the head coach actually worries about.
- Per-player coaching notes attached to a spot, so the printed sheet carries assignments.
- Multi-device sync. Supabase is the obvious fit but is explicitly **not** wanted for the
  2026 season. Revisit in the offseason.

**Do not** add a framework, a build step, or a dependency without asking. The single-file
property is why it works on a phone on a practice field.

---

## Known warts

- **Renaming a core play re-seeds a duplicate.** The migration's CORE loop matches on
  `plays[k].name`, so renaming "Punt — Base" makes it look missing and a fresh copy is
  added on next load. This contradicts rule 3 (match on slug, never name). Pre-existing,
  verified against the original build; fix it as part of the data/code split.
- **`PRESETS` slugs do not match `special-teams-plays.json` slugs.** Saved plays carry the
  old preset key (`'STD Punt'`); the JSON uses `std-punt`. The refactor needs an explicit
  old-key → new-slug alias map applied additively, or every existing play stops resolving.
- **ids are `Math.random()*1e9|0`** in `P()` and `blank()`. Collisions are unlikely, not
  impossible, and a collision silently merges two players. `crypto.randomUUID()` is
  available everywhere this runs.

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
