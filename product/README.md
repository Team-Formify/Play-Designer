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
