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
security guard nobody has tested. Run `node product/db/test.mjs` to reproduce
the counts; it builds each database from `db/migrations/` and runs the suite.

| Layer | Tests | State |
|---|---|---|
| `db/migrations/0002_schema.sql` + `0003_rls.sql` | **183** | Proven. 21 policies, `force row level security`, attacked from both leagues. |
| `0004_auth.sql` — invite-only membership | **243** | Proven. `app.accept_invite()` takes no team parameter; tokens are 244-bit and stored only as SHA-256. |
| `0005_platform.sql` — the vendor's own seat | **252** | Proven. The platform owner sees league size, seasons, seats and billing, and zero plays and zero children. |
| `0006_brand.sql` — white-label | 169 of 183 | **Partly proven. 14 failing.** The palette resolver and the WCAG guard work; the failures are real and unfixed. |
| `0007_consent.sql` — COPPA machinery | **187** | Proven, and see below. |
| `api/stripe-signature.js` | 11 | Proven for what it is — signature verification only. There is no billing. |
| `hub/` — the master hub | 0 | **Written, not proven.** It compiles and exports; nothing is wired to a URL and nothing is tested. |

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
- **A pilot.** Nobody outside Lehi has touched any of this.
