# Migrations

Every schema change is a numbered file here. Nothing else changes the schema.

```
node product/db/migrate.mjs --db pd_dev --status   # what would run
node product/db/migrate.mjs --db pd_dev            # run it
node product/db/test.mjs                           # build fresh + run every suite
```

## The rules

1. **Four digits, no gaps.** `0008_add_thing.sql`. The runner refuses a gap or a
   duplicate, because a missing number means a file was written and never committed.
2. **A `-- WHY:` header.** Not what the SQL does — the file says that. Why the
   shape had to change. Six months from now that is the only thing you cannot
   reconstruct.
3. **Never edit an applied migration.** The ledger keeps a checksum; editing one
   exits non-zero. Write the next number instead.
4. **No `begin;` / `commit;` in the file.** The runner wraps the migration and its
   ledger row in one transaction, so a failure rolls back both. A file that
   commits itself can succeed while its ledger row fails, and the next run
   replays it. The runner refuses a file that tries.
5. **Every new table gets `enable row level security`, plus policies, in the
   same migration.** A table that arrives without them is open until somebody
   notices — which is exactly the failure this project was built to avoid.
6. **Tenant tables also get `force row level security`. Operator tables do
   not.** `force` binds the table's OWNER to RLS too. On a tenant table that is
   the point: the owner must not be a way around isolation. On an operator
   table like `_schema_migrations` it locks out the deploying role itself, and
   it only appeared to work here because the dev runner is a superuser and
   superusers bypass RLS regardless. On a non-superuser deploy role — which is
   what Supabase and any sane production posture gives you — a forced ledger is
   invisible and unwritable, and `--status` would have reported every migration
   pending against a fully migrated production database.
7. **No policy is `using (true)`.** A permissive policy held back only by the
   absence of a `GRANT` is one `grant insert` from being wrong, and nothing
   fails when that grant arrives. Where a definer function legitimately needs
   to write past `force`, gate it on `app.is_privileged_session()` — true
   inside a definer function running as the owner, false for any tenant
   statement. `product/db/test-consent.sql` asserts this across the schema.

## What is not a migration

`seed.sql`, `auth-seed.sql`, `platform-seed.sql` and `brand-seed.sql` stay in
`product/db/`. They invent a fictional league to attack in the tests. A seed
runs against a developer's database; a migration runs against a customer's.
Shipping the second as the first is how test fixtures reach production.

## The ledger

`public._schema_migrations` — version, when, by whom, and a checksum of the file
as applied. It is force-RLS with **no policy at all**: no tenant and no platform
owner has any business reading the deployment history. The runner connects as
the owner, which is the only thing that can see it.
