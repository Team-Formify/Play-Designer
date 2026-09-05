# What we take from Team-Formify

Team-Formify (private, `Team-Formify/Team-Formify`) is a live multi-tenant SaaS
for a different industry, built by the same founder. It has solved things this
product has not, and this records what to lift rather than rebuild.

**A separate security review of that repo was delivered privately and is
deliberately NOT written down here — this repo is public and that one is live.
Read that before treating any of its patterns as a model.** In particular, do
not copy its tenancy approach; ours (`product/db/migrations/0003_rls.sql`, 21 policies, 183
attack tests) is the one to keep.

## Take as-is

**DONE** marks what has actually landed, with the commit's evidence beside it.
Everything else on this table is still a plan.

| From | To | Why |
|---|---|---|
| **DONE** `migrations/README.md`, `_schema_migrations` | `product/db/migrations/` | Numbered, ordered, idempotent, mandatory `-- WHY:` header, "no schema change without a migration in the same commit". |
| `LEGAL_CHECKLIST.md` | `product/` | Utah LLC → bank → Stripe on the LLC. Same founder, same state, costs on every line. |
| `LAUNCH_CHECKLIST.md` phase 1 | `product/` | Five items, none over two hours. |
| **DONE** `verifyStripeSignature()` + `readRawBody()` | `product/api/` | ~35 lines of raw-body webhook crypto, no SDK dependency. |
| the ToS-acceptance audit migration | a `product/db` migration | `accepted_at`, `ip_hash`, `by_email`, and a **version stamp** so a revised policy can demand re-acceptance. An HTML `required` checkbox is not a legal record. |

### What landed, and what was changed on the way

The migration ledger is theirs; the isolation on it is not. Their tables carry
`FOR ALL TO anon USING (true)` — ours is force-RLS with **no policy at all**,
because what schema version is deployed is not a tenant's business.

Two things the runner does that theirs does not, both because this is a schema
a season depends on:

- **A file and its ledger row commit together.** The migration is pulled in with
  `\i` between the runner's own `begin` and `commit`. A migration that failed
  halfway used to leave the schema changed and the ledger silent; proven now by
  applying a deliberately broken migration and finding neither the table nor the
  row afterwards.
- **An applied migration that is later edited is refused.** The ledger stores a
  checksum of the file as applied. Editing one after the fact exits non-zero
  rather than silently diverging from what is running in production.

`verifyStripeSignature()` came over essentially verbatim — it was already right.
What it did not have was a test; `product/api/test-stripe-signature.mjs` is 11
assertions covering an altered body, the wrong secret, the replay window at both
edges, a malformed header, a truncated signature, and the two-signature window
Stripe opens during a secret rotation.

## Take the idea, rewrite

- **Seat-sync billing.** Count active seats, derive a floor from
  `ceil(min_price / per_seat_price)`, push `max(actual, floor)` as the Stripe
  quantity. Seat-count billing is exactly our model — a league pays per team.
  Rewrite it to run as the caller through a `security definer` function, **not**
  with a service-role key that bypasses RLS in every endpoint.
- **`plan_pricing` with parallel live and test Price IDs**, test mode detected
  from the `sk_` prefix. Small table; prevents charging a real card in test.
- **Period-snapshot billing** — freeze the counts and the amount at bill time,
  unique on `(tenant, period)`, so changing a rate never rewrites a past invoice.
- **A per-tenant timeline with follow-ups.** For a league product whose buyer is
  a volunteer board that goes quiet in February, knowing which league has not
  logged in since the season ended is worth more than most features.
- **Dedup key on notifications** — `unique(type, target, period)` makes every
  cron idempotent in ten lines of schema.
- **Generate previews from one script**, never hand-edit them. Right pattern;
  none of the components transfer (a review app's vocabulary, not a field's).

## Leave

Its tenancy model; its 44k-line single-page app; its logo pack, which is one
company's wordmark and not a theming system; and its AI endpoint, which drags an
API key and a network call — nothing on a practice field may block on the
network.

**And the ceiling on its legal work:** its privacy policy says the service is not
intended for anyone under 16. That is a COPPA-*avoidance* disclaimer, and our
whole premise is holding under-13s' data. The structure of the policy transfers;
the hard part is simply absent there. We are already further along: see
`player_consents` (scoped, revocable) and `player_tombstones` (**no name
column** — a tombstone that stores the name defeats the deletion).

## Gaps neither repo fills

1. **Verifiable parental consent.** We have the rows. There is no flow — no
   guardian identity, no email round-trip, no evidence of who granted it.
2. **Season-end retention.** `player_tombstones.reason` already allows
   `season_retention`. Nothing writes it; there is no clock.
3. **A processor agreement** a league board could sign.
4. **Offline sync.** The field client is `localStorage` and the desk client is
   Postgres. Nobody has reconciled them, and Supabase is out for 2026 anyway.
5. **A billing UI.** Stripe work there is all backend.

## Open, and not ours to decide

- Is Team-Formify's LLC and Stripe account the same entity as this, or a second
  one with a co-founder? It decides whether the launch checklist is half done or
  resets to zero.
- Is the league billed, or each team? It changes the seat counter and who gets
  chased when a card fails.
