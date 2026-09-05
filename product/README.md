# product — the multi-tenant build

Sold to a league, layered down to the teams inside it. Built from the ground up,
with both existing codebases as the baseline: this repo's engine and play format,
and the practice planner's structure and data model.

**Steve is a co-founder, not a customer** — see CLAUDE.md. That settles ownership.
It does **not** settle publishing: this repo is public and his artwork is
password-protected, so none of his diagrams are here and the three generated
bundles stay gitignored.

| | |
|---|---|
| `engine/` | the play engine, byte-identical to the proven one at the repo root. **Not a fork** — `scripts/sync-engine.js` keeps it honest and `--check` fails on drift, because this project has already paid for having two engines once. |
| `db/` | leagues → teams → seasons → memberships → players → plays. Isolation lives in Postgres RLS, not in application code. |
| `brand/` | white-label. One codebase, a look per league and per team. |
| `formations/` | what a new team's empty playbook starts with. **Formations, not plays** — parametric generators for the alignments everybody already knows, so nothing anybody owns is ever shipped to a customer. `node product/formations/validate.js` proves every one of them legal. |

## A team can buy this without its league

**A solo team is a CLUB, and a club is a league of one.** It gets its own
private league row, its own season, and its head coach is the admin of it.

The obvious design — make `teams.league_id` nullable — is the dangerous one, and
the reason is not the composite foreign keys or the null branches it would put
in every policy. It is **consent**. A consent notice is published *by a league*,
and `app.issue_consent_notice()` is league-admin only. A team with no league has
nobody who can publish one, so `app.request_consent()` never finds a live notice,
and the collection gate in `0007` stays shut forever — an independent team could
not write a single child's name. It holds children's data exactly like a league
team does, and COPPA does not care that nobody sold them a league.

Making it a league of one means **not one line of RLS, consent, branding or
platform code changes**, because nothing downstream can tell the difference.

**The one new rule is that a club holds exactly one team**, enforced by a trigger
that binds the owner too. That rule is the entire price boundary: without it, a
club is a free league — sign up as one team, then add the other twenty-nine.
Growing up is `app.convert_club_to_league()`, which is the *vendor's* call
because it is the moment the rate changes, and it is recorded in the platform
trail. Nothing moves when it happens: same ids, same plays, same children, same
consent.

`app.billable_units()` is the seam an invoice is built from — kind, plan, teams,
seats, children — and it contains no money at all, asserted. **What a club is
charged is the founders' decision and is not in the schema.**

## Two positions that are already settled

**`players` carries last name, first name and jersey in v1 — nothing else.** No
photos, no weights, no forty times. A league product covers under-13s even though
Lehi's 8th graders are not, which is what brings COPPA in; those fields are the
highest risk and the least necessary to sell a play designer. The existing
convention — names read as last name and number — is already data minimisation.

**Deletion tombstones; it does not cascade.** A parent asks for a child removed:
the player row goes and every play he was in degrades to a jersey number. A play
is never destroyed by a player deletion. That is CLAUDE.md rules 1 and 2 restated
for a new domain.

## The field client still has to work with no signal

The practice planner sets `force-dynamic` in three layouts on purpose — caching
it once served a page to somebody with no password. So it cannot run offline by
construction, and that is why there are two clients rather than one: the static
field client for a practice field, the React desk client for everything else.
The engine and the play format are what they share.

## What is PROVEN, and what is merely WRITTEN

The distinction this table draws is the one that matters before a sale: code
that loads is not code that works, and a security guard nobody attacked is a
security guard nobody has tested. Run `node product/db/test.mjs` to reproduce the counts; it builds each database
from `db/migrations/` and runs the suite, and it fails if a count moves — so a
suite that silently shrinks is a red build rather than a quiet one.

**1,249 tests, all passing.** Every suite has been mutation-tested: each guard
broken on purpose, the red count recorded in that suite's header. No guard sits
at zero.

| Layer | Tests | State |
|---|---|---|
| `db/migrations/0002_schema.sql` + `0003_rls.sql` | **183** | Proven. 21 policies, `force row level security`, attacked from both leagues. |
| `0004_auth.sql` — invite-only membership | **243** | Proven. `app.accept_invite()` takes no team parameter; tokens are 244-bit and stored only as SHA-256. |
| `0005_platform.sql` — the vendor's own seat | **252** | Proven. The platform owner sees league size, seasons, seats and billing, and zero plays and zero children. |
| `0006_brand.sql` — white-label | **187** | Proven. The database refuses a palette a human cannot read, and the refusal is whole-record, not clamped. |
| `0007_consent.sql` — COPPA machinery | **187** | Proven, and see below. |
| `0009_clubs.sql` — a team that signs up alone | **72** | Proven. The signup, the isolation, and the one-team cap that makes the cheaper rate honest. |
| `api/stripe-signature.js` | 11 | Proven for what it is — signature verification only. There is no billing. |
| `hub/lib` — the desk client's data layer | **66** | Proven. Identity is bound per transaction and cannot reach the next request over a reused connection. |
| `hub/` UI and routing | 0 | **Written, not proven.** It compiles and exports as a static site; no route handler is wired to a URL yet. |
| `learn.html` — the boys' page | **58** | Proven, in a real browser at 390px. All three modes, every play, the collision marks, and the phone layout. |

### Vercel is not the blocker for the hub API, and I said it was

Recorded because it was wrong twice in one sentence. This Vercel project DOES
run Node functions — `api/save-playbook.js` is live and answers 501/405 today.
What it cannot run is a *Next.js route handler*, because the hub is statically
exported. The hub does not need one: its `lib/routes/*` can be exposed as plain
Vercel functions under `/api/`, exactly like `save-playbook.js`, with no new
project. **The real blocker is a Postgres that Vercel can reach** — everything
so far is tested against one inside a dev container.

### The boys' page, driven at last

`learn.html` is what a twelve-year-old opens on his own phone with nobody next
to him, and it had never been driven at all. 58 tests now, in a real browser at
390px: every play draws, the scrub bar moves men and puts them back, the
collision rings are dashed from the first frame and fill in as men arrive, Line
me up scores an exact tap and a corner tap differently, My job grades an answer
and then names the man you are across from — and no mode's controls leak into
another, which is the same class of bug as the game-day bar leaking.

It also turned up one real gap: `designer.html` carried an inline home-screen
icon and `learn.html` and `index.html` carried none, so the live site 404s on
`/favicon.ico` and a boy who adds the page to his home screen gets a blank
square. All three now declare both icons inline as data URIs — no request, same
rule as the absent webfonts.

Three of that suite's own first-draft assertions could not fail, and the file
records each one. The instructive one: "tapping the field scores in yards"
tapped the middle of the field and required the word "yards", and failed about
half the time — not randomly, but whenever the man it asked about was the
SNAPPER, who stands in the middle, so the tap was CORRECT and the page says
"That is the spot." with no yardage in it. The suite was flaky because it was
wrong about the feature.

### The hub suite found its own blind spot before it found anything else

`lib/db.ts` had a header describing, in detail, a test that had never been
written — and a `pd_app` connection role that no migration created, so the desk
client could not be run against a database built from these files at all.
`0008_app_role.sql` creates it: `NOINHERIT`, a member of `pd_anon` and
`pd_authenticated`, holding nothing of its own.

The suite that followed is worth reading for one reason. Its central claim is
that identity is bound per transaction and cannot survive onto the next request
over a pooled connection. **Flipping `set_config`'s `is_local` from `true` to
`false` — the exact edit the file warns about — left all 60 tests green.** Every
assertion read the GUC from inside a *later* `asCaller()`, and `asCaller()`
rebinds all four GUCs on entry, so the stale value was overwritten a microsecond
before anything looked at it.

A suite can be pointed straight at the thing it is named after and still not see
it. The fix was to observe from *outside* `asCaller()`, on a raw client from the
same pool — which is where the leak actually shows, because any statement that
reaches that connection without going through `asCaller()` runs as the last
caller. The same probe also kills a second surviving mutant: dropping the
rollback leaves the previous transaction *open*, so its `set local` values are
still live.

### The 14 brand failures were all in the tests

Every one. The palette guard, the resolver and the fallback chain were correct
throughout; six root causes in `test-brand.sql` produced fourteen red lines:

- **Two tests were broken SQL** — a function result subscripted without
  parentheses, and a subquery aliased into nonsense. They had never run.
- **The check set grew from sixteen to seventeen** and three tests still named
  the old list. One of them, `its worst check is them-on-grass`, asserted
  `sideline-on-grass` in its own expectation — the title and the assertion had
  disagreed with each other and with reality, which is what happens when a
  check is added twice and nobody re-reads the line.
- **A fixture colour stopped being a near miss.** `#8FA05A` measured 5.01:1
  against the composited circle, comfortably over the 4.5 floor, so the palette
  passed, the guard accepted it — and three tests were asserting a refusal that
  could not happen. It then sat on the team for the rest of the run and took a
  fourth test down with it.
- **A hardcoded play count** of 4 against a seed holding 2, in the one section
  whose job is "rebranding destroys nothing". Snapshotted now, so it asserts
  the number did not go *down* rather than what the number is.
- **One test demanded a leak.** It asked a coach of a different team to resolve
  Lehi 8's brand and expected `lehi`. `app.team_brand()` is `SECURITY INVOKER`
  on purpose; another test in the same file forbids exactly that. The two could
  not both pass.
- **The vacuity check did not reproduce its own leak.** It opened a permissive
  policy on `teams` but not `leagues`, so the resolver still fell through to the
  product default and the "leak" never happened.

One claim in that file was simply false and is now recorded as such: a comment
said the composited circle is "the check a naive text-on-background audit would
miss". It is not, on a dark palette — the composite is *darker* than the grass,
so for light foregrounds it raises the ratio and can only make a check easier.
Searched exhaustively: no colour, light or dark, clears 4.5 against this grass
and fails it against the circle. What the composite does is tested elsewhere,
and passes.

### The consent suite paid for itself immediately

Writing `db/test-consent.sql` found a live hole in `0007_consent.sql`, which is
the file that exists to hold children's data lawfully.
`app.is_privileged_session()` was `SECURITY DEFINER`. Inside a definer function
`current_user` is the function's OWNER, not the caller — so it answered
"privileged" to everybody. Its only two callers are the guard triggers on
`public.players` and `public.player_consents`, and those are definer functions
too, so **both guards were no-ops**: a coach could write a child's full name
into the database with no consent anywhere behind it.

All three are `SECURITY INVOKER` now, and fixing it turned out to unlock a
second fix: four of the consent tables carried `FOR ALL TO public USING (true)`
write policies — the exact shape `REUSE.md` says we deliberately did not copy
from the other codebase — held back only by the absence of a `GRANT`. There had
been nothing to scope them to, because the one predicate that could do it did
not work. They are gated on `app.is_privileged_session()` now, and a stray
`grant insert` turns the suite red instead of opening a door.

Section 10 of the suite puts the original bug back
with `ALTER FUNCTION ... SECURITY DEFINER`, shows the identical insert
succeeding, and then puts it right — so the 172 zeroes above it cannot be
passing vacuously.

Two things to take from that beyond the fix. First, this is the same class of
bug as the one `0006_brand.sql` had (`app.league_rule()` as DEFINER leaking
every league's rulebook): **`security definer` on anything that asks "who is
calling" is a bug by construction.** Second, it sat in a file that loaded
cleanly, read well, and had 1,900 lines of careful comments. Reading did not
find it and was never going to.

### What no amount of SQL closes

- **Verifiable parental consent.** The database records who was asked, at what
  address, what they were shown, what they affirmed and when. Proving the human
  at that address is the child's guardian is a flow that does not exist.
- **The mailer role.** `app.consent_dispatch()` is safe from a coach because a
  coach is not `pd_mailer`. Whoever holds `pd_mailer` holds every pending token.
  That is a deployment property, not a schema one.
- **A pilot** — and that is deliberate, not a gap. His decision: nobody outside
  Lehi touches this until he says it is ready. So nothing here is waiting on
  outside feedback, and nothing should be shaped around getting some. The
  ordering comes from what is unproven in the code.
