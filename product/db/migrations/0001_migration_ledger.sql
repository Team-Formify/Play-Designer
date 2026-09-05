-- WHY: Before this table, product/db/*.sql were flat files applied by hand in
-- an order you had to know. That is fine while the only data is a seed and
-- catastrophic the moment a league's season depends on the schema — there is no
-- record of what ran, no way to replay from zero, and no rollback path.
--
-- Taken from the practice-planner org's own migrations/README.md, which states
-- the reason better than I would: "Worked fine for a beta tester whose data was
-- internal. Stops working the moment a paying customer's livelihood depends on
-- the schema."
--
-- What is deliberately NOT taken from there: that repo's tables all carry
-- `FOR ALL TO anon USING (true)`. Ours is force-RLS with real policies, and the
-- ledger is no exception — it is readable by nobody but the owner, because what
-- schema you are running is not a tenant's business.

create table if not exists public._schema_migrations (
  version     text primary key,
  applied_at  timestamptz not null default now(),
  description text,
  applied_by  text default current_user,
  checksum    text not null
);

comment on table public._schema_migrations is
  'One row per applied migration. version is the 4-digit file prefix; checksum is a digest of the file as applied, so an edited-after-the-fact migration is detectable.';

alter table public._schema_migrations enable row level security;
-- No policy at all: no tenant, and no platform owner, has any business reading
-- the deployment ledger. With RLS enabled and zero policies, every role except
-- the table's owner is refused.
--
-- Deliberately NOT `force row level security`, which the first version of this
-- file had. `force` subjects the OWNER to RLS as well, and with no policies
-- that locks out the deploying role itself -- invisible and unwritable. It
-- happened to work only because the dev runner connects as a superuser, who
-- bypasses RLS regardless; on Supabase or any sane production posture the
-- deploy role is not a superuser, and `--status` would have reported every
-- migration pending against a fully migrated production database. `force` is
-- right for tenant tables, where the owner must not be a way around isolation.
-- It is wrong here, where the owner IS the only legitimate reader.
