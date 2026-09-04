-- product/db/platform-seed.sql
-- The first platform owner, and the commercial state of the seeded leagues.
--
-- THIS FILE IS THE BOOTSTRAP. It is the answer to "how does the first platform
-- owner exist", and it is deliberately a migration rather than a feature: the
-- row is written by the credential that runs migrations, which is already the
-- credential that could drop the database, so it hands out nothing new. There
-- is no claim endpoint, no env-gated function reachable from the network, no
-- "first account to sign up wins", and no default row shipped in schema.sql.
--
-- Even here the insert has to say what it is doing. platform.sql's guard
-- trigger refuses any INSERT on public.platform_owners unless the session is
-- already a platform owner or is holding the tx-local flag set below -- the
-- same explicit-intent pattern schema.sql uses to stop a play being deleted by
-- something that did not mean it. The flag binds the table owner too, so a
-- migration cannot create a vendor seat by accident either.
--
-- Load order: schema.sql -> rls.sql -> auth.sql -> platform.sql
--             -> seed.sql -> auth-seed.sql -> platform-seed.sql
--
-- WHAT THIS FILE DELIBERATELY DOES NOT DO
-- It adds no league, no season, no team, no player, no play, no invitation and
-- NO MEMBERSHIP. test-isolation.sql asserts exact counts of those (31 players,
-- 6 plays, 7 memberships, 3 board seats, 23 visible to Dom, 26 to the board)
-- and test-auth.sql asserts the invitation and audit counts on top; all 426 of
-- those tests have to keep passing with this file loaded. Everything here lives
-- in the two tables platform.sql adds that hold no tenant data.
--
-- AND THE TWO OWNERS BELOW HOLD NO MEMBERSHIP, which is not a convenience: the
-- guard trigger would refuse them if they did. The vendor seat is a separate
-- account from a coaching account, so that "a platform owner cannot read a
-- play" is true without an exception clause. Dom coaches as d..01 and runs the
-- business as 10000000-...-01, and the two accounts share nothing but a person.

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------------
-- The bootstrap flag. Transaction-local (the third argument is true), so it is
-- gone the moment this file commits and cannot be left switched on.
-- ---------------------------------------------------------------------------
select set_config('app.platform_bootstrap', 'on', true);

-- ---------------------------------------------------------------------------
-- The vendor. Two seats, because one seat is a single point of failure for the
-- business and because app.grant_platform_owner() needs somebody to test it
-- against.
--   10000000-...-01  the founder who runs the platform     (also coaches, as a
--                                                           SEPARATE account)
--   10000000-...-02  the co-founder
-- Neither uuid appears in public.memberships or public.league_memberships, and
-- the guard trigger is what makes that a rule rather than a habit.
-- ---------------------------------------------------------------------------

insert into public.platform_owners (user_id, email, added_by, note) values
('10000000-0000-4000-8000-000000000001', 'founder@example.com', null,
 'bootstrap seat, written by the migration'),
('10000000-0000-4000-8000-000000000002', 'cofounder@example.com', null,
 'second seat, so the business is not one password deep');

-- The seat changes are in the platform trail already: the audit trigger on
-- platform_owners wrote an owner_grant row for each of the two inserts above,
-- with a NULL actor because a migration is not a person. Nothing else needs to
-- be written by hand, and nothing here can be written by hand -- the log has no
-- INSERT privilege for anybody.

-- ---------------------------------------------------------------------------
-- Commercial state for the leagues seed.sql created.
--
-- Both ACTIVE. A suspended league in the fixture would change what the other
-- two suites see -- new seats would start being refused in the middle of
-- test-auth.sql -- so suspension is exercised inside test-platform.sql's own
-- transaction, on a league it creates and on a league it puts back.
-- ---------------------------------------------------------------------------

insert into public.league_platform_state
  (league_id, status, plan, seats_purchased, contract_ends_on, status_changed_by)
values
-- The first customer: a full season, paid, twelve seats.
('a0000000-0000-4000-8000-000000000001', 'active', 'season', 12, '2026-12-31',
 '10000000-0000-4000-8000-000000000001'),
-- The second: still on trial, no seat count agreed.
('a0000000-0000-4000-8000-000000000002', 'active', 'trial', null, null,
 '10000000-0000-4000-8000-000000000001');

-- A league with no row here reads as active, on no plan. That is deliberate:
-- "we have not billed them yet" and "we have cut them off" must not be the same
-- state, and a missing row is the first of the two.

commit;
