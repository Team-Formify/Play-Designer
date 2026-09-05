-- product/db/migrations/0008_app_role.sql
-- WHY: product/hub/lib/db.ts describes the connection role in detail -- "an
-- ordinary role (pd_app in the test harness) that is a NOINHERIT member of
-- pd_anon and pd_authenticated and holds nothing itself" -- and no migration
-- ever created it. The design was real in a comment and absent from the schema,
-- so the desk client could not be run or tested against a database built from
-- these files at all.
--
-- WHY IT IS A SEPARATE ROLE FROM THE TWO IT SWITCHES INTO. The pool logs in
-- once and serves every caller: anonymous boys' sessions and signed-in coaches
-- over the same physical connections. If the login role itself held the
-- privileges, every request would carry them before `set local role` ran, and
-- any statement that escaped the binding -- a health check, a stray query, a
-- future bug -- would execute with a coach's reach. So pd_app holds NOTHING of
-- its own and is only a doorway into exactly one of the two.
--
-- WHY NOINHERIT, WHICH IS THE LOAD-BEARING WORD. A role that INHERITS gets its
-- members' privileges automatically, without SET ROLE -- which would hand
-- pd_app the union of pd_anon AND pd_authenticated on every connection and undo
-- the paragraph above. NOINHERIT means membership grants only the *right to
-- become*, never the privileges themselves. It is the difference between
-- holding a key and being able to ask for one.
--
-- ON SUPABASE this role is `authenticator` and it already works this way. The
-- names differ; the shape does not.

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'pd_app') then
    -- nologin here; the deployment gives it a password or an IAM identity.
    -- A migration must never write a credential into the schema.
    create role pd_app nologin noinherit;
  else
    -- Idempotent, and it re-asserts NOINHERIT: a role that was created by hand
    -- during setup may well have been created with the default (INHERIT), and
    -- that is the one property whose absence is silent and total.
    alter role pd_app noinherit;
  end if;
end $$;

-- Roles are cluster-wide, so on a cluster that already has them this re-grant
-- is a no-op that shouts twice. The migration is still doing its job.
set local client_min_messages = warning;
grant pd_anon, pd_authenticated to pd_app;
reset client_min_messages;

-- Enough to reach the schemas, and nothing in them. Every table privilege and
-- every function grant belongs to the two roles it switches into; this role
-- carries none. The suite asserts that emptiness rather than trusting it.
grant usage on schema public, app, auth to pd_app;

comment on role pd_app is
  'The application''s login role. Holds no privilege of its own and is a NOINHERIT member of pd_anon and pd_authenticated, so a connection has no reach until `set local role` picks one. See product/hub/lib/db.ts.';
