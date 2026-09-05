# Standing the product up on a real database

Everything in `product/` has been proved against Postgres running in a
container that disappears when the session ends. This is the list of what has
to exist in the world before any of it is reachable by a person.

Nothing here is hard. It is written down because the last four things that
looked finished were not deployed, and the reason each time was a step nobody
had written down.

---

## 1. A Postgres that Vercel can reach

**Neon** (neon.tech) or **Supabase** — either works, the schema is stock
Postgres 16. Neon's free tier is enough for a season; a youth league's whole
season is a few thousand rows.

Take the **pooled** connection string it gives you. It looks like:

```
postgresql://<role>:<password>@<host>.neon.tech/<db>?sslmode=require
```

### THE CONNECTION STRING IS A PASSWORD

It is not a setting, it is a live credential to every child's name in the
database. Two consequences:

- **Put it in Vercel, not in a chat window, not in this repo.** Anything pasted
  into a conversation lives in that transcript afterwards, and anything
  committed here is public.
- If it is ever exposed, **rotate it in Neon** rather than deleting the message.
  Neon can reset a role's password in one click; that is the only thing that
  actually revokes it.

---

## 2. Apply the schema to it

The runner takes a URL now:

```bash
node product/db/migrate.mjs --url "$DATABASE_URL" --status   # look first
node product/db/migrate.mjs --url "$DATABASE_URL" --yes      # apply
```

`--status` is read-only and needs no confirmation. Applying to a remote
database **requires `--yes`**, because doing it to somebody's live season is
not the same act as rebuilding a scratch database.

It prints the host it is talking to and never the credential.

**What to watch for on the first run.** `0002_schema.sql` and `0008_app_role.sql`
issue `CREATE ROLE` (`pd_anon`, `pd_authenticated`, `pd_mailer`, `pd_app`). A
managed provider may not let the database owner create roles. If a migration
fails there, that is the reason, and the fix is to create those four roles once
by hand in the provider's SQL console — not to weaken the migration. The
runner applies each file in a transaction, so a failure leaves nothing behind
and no ledger row; fix and re-run.

**`pd_app` is created NOLOGIN on purpose** — a migration must never write a
credential into the schema. Give it a password once, in the provider's console:

```sql
alter role pd_app login password '<a long random one>';
```

That password, in that role's connection string, is what `HUB_DATABASE_URL`
should hold — **not** the owner's. The owner bypasses RLS; `pd_app` holds
nothing at all and is the whole point of `0008`.

---

## 3. Environment variables on the Vercel project

| Name | What it is | Used by |
|---|---|---|
| `HUB_DATABASE_URL` | the **`pd_app`** connection string, not the owner's | the hub's data layer |
| `HUB_SESSION_SECRET` | 32+ random bytes; `openssl rand -base64 32` | signing session cookies |
| `GITHUB_TOKEN` | already set — **add `Issues: read and write`** | the lightbulb, and Save to repo |
| `SAVE_SECRET` | already set | Save to repo |

Until `GITHUB_TOKEN` can write issues, `/api/feedback` answers 501 and the app
keeps notes on the device and says so. That is by design, not a failure — but
it means nothing he types reaches anybody.

---

## 4. What is still missing after all that

Being honest about the gap, because steps 1–3 make the database reachable and
**do not by themselves give anybody a way to log in.**

- **No login exists for any tier.** The database knows all four roles and
  refuses across them, proved by 1,308 tests. Nothing lets a human exercise
  that yet. `product/hub/lib/session.ts` mints and verifies a signed cookie and
  is tested; no page calls it.
- **No route handler is wired to a URL.** The hub is a static export, so it
  cannot run Next route handlers — but this Vercel project *does* run Node
  functions (`api/save-playbook.js` is live). The hub's `lib/routes/*` become
  plain functions under `api/`, the same shape as the two that already work.
  No second Vercel project is needed.
- **`/hub` is a map, not an admin app.** Every tier on it is read from
  `lib/tiers.ts`. It names the database function behind each capability; it
  calls none of them.

---

## 5. Checking a deploy, every time

```bash
curl -s https://play-designer-nine.vercel.app/          | grep -o "BUILD_TAG='[^']*'"
curl -s https://play-designer-nine.vercel.app/designer  | grep -o "BUILD_TAG='[^']*'"
```

**Do this before believing anybody, including me, about whether something
shipped.** Seven commits sat on a branch while the live site served a build
from three weeks earlier, and the whole time the work was being reported as
done. `main` is what Vercel deploys. A commit on any other branch is not
deployed, however green its tests are.
