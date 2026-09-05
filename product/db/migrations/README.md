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
5. **Every new table gets `enable row level security` *and* `force row level
   security`, plus policies, in the same migration.** A table that arrives
   without them is open until somebody notices — which is exactly the failure
   this project was built to avoid.

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
