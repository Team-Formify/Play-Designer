-- product/db/test-clubs.sql
-- The adversarial suite for 0009_clubs.sql. Same house rules as the other five.
--
-- RUN:
--   node product/db/test.mjs clubs
--
-- That builds pd_t_clubs from product/db/migrations/ via the migration runner and
-- applies the seeds in order, then runs this file.
--
-- Against a database you have already built:
--   psql -h /tmp -p 5433 -U app -d pd_t_clubs -f product/db/test-clubs.sql
--
-- Everything runs inside one transaction and ROLLS BACK.
--
-- THE CLAIM THIS FILE TESTS, IN ONE SENTENCE. A team with no league can sign
-- itself up and get a working tenant -- including the consent notice it needs
-- before it may write a child's name -- and cannot use that signup to reach
-- anybody else's data, to grow into a league without the vendor saying so, or
-- to pay a one-team rate for thirty teams.
--
-- WHY THE SECOND HALF IS THE POINT. "A team can sign up alone at a cheaper
-- rate" is two features in a trenchcoat. The first is a signup form. The second
-- is a PRICE BOUNDARY, and a price boundary that lives in a screen is not a
-- boundary. Most of this file attacks the boundary.
--
-- HOUSE RULES, inherited:
--   (a) Every refusal is paired with a CONTROL proving the row was really there.
--   (b) Attacks name the other tenant's rows by literal uuid.
--   (c) Section 8 removes the guard and shows the same statements landing.
--
-- WHAT THIS FILE CANNOT PROVE:
--   * That the cheaper rate is the right number. There is no price in the
--     schema and deliberately so -- app.billable_units() is the seam an invoice
--     is built from, and what a club is charged is the founders' decision.
--   * That a coach will not simply make ten clubs. Nothing here caps how many
--     tenants one account creates; they all start on 'trial' and the platform
--     can suspend. Worth a rate limit in front of the API before launch, and
--     that is a note rather than a test.
--   * Anything about Stripe. There is no billing integration yet.

-- MUTATION RUN. Each guard broken on purpose, red count recorded:
--
--   start_club makes a league instead of a club ..... 37 tests go red
--   start_club skips the league-admin seat .......... 13
--   drop the one-team cap ...........................  9
--   billable_units readable by anyone ...............  8
--   anybody may convert a club to a league ..........  4
--   the cap counts under the caller's RLS (INVOKER) ..  1
--
-- The 13 is worth reading. Dropping only the league-admin seat -- an easy thing
-- to call a tidy-up, since a coach being admin of his own league looks like
-- over-granting -- takes out the consent notice, and with it the collection
-- gate, and with it the club's ability to write a single child's name. That is
-- what "a club is a league of one" is buying.
--
-- Reproduce with:  psql ... -c '<mutation>' ; psql ... -f product/db/test-clubs.sql

\set ON_ERROR_STOP on
\timing off
\pset pager off

begin;

-- ===========================================================================
-- Harness
-- ===========================================================================
create schema t;
create table t.results (
  n serial primary key, sect text, name text, ok boolean not null, detail text);
grant usage on schema t to public;
grant select, insert on t.results to public;
grant usage, select on sequence t.results_n_seq to public;

create function t.note(p_name text, p_ok boolean, p_detail text) returns void
language sql as $fn$
  insert into t.results (sect, name, ok, detail)
  values (coalesce(nullif(current_setting('t.sect', true), ''), '-'), p_name, p_ok, p_detail);
$fn$;

create function t.val(p_name text, p_sql text, p_want text) returns void
language plpgsql as $fn$
declare got text;
begin
  execute p_sql into got;
  perform t.note(p_name, got is not distinct from p_want,
    format('got %s, want %s', coalesce(quote_literal(got),'NULL'), coalesce(quote_literal(p_want),'NULL')));
exception when others then
  perform t.note(p_name, false, format('ERROR %s: %s', sqlstate, left(sqlerrm, 100)));
end $fn$;

create function t.raises(p_name text, p_sql text, p_state text) returns void
language plpgsql as $fn$
begin
  execute p_sql;
  perform t.note(p_name, false, format('LEAK: statement succeeded, expected SQLSTATE %s', p_state));
exception when others then
  perform t.note(p_name, sqlstate = p_state,
    format('SQLSTATE %s (want %s): %s', sqlstate, p_state, left(sqlerrm, 90)));
end $fn$;

create function t.raises_like(p_name text, p_sql text, p_state text, p_msg text) returns void
language plpgsql as $fn$
begin
  execute p_sql;
  perform t.note(p_name, false, format('LEAK: succeeded, expected %s / "%s"', p_state, p_msg));
exception when others then
  perform t.note(p_name, sqlstate = p_state and position(lower(p_msg) in lower(sqlerrm)) > 0,
    format('%s / %s', sqlstate,
      case when position(lower(p_msg) in lower(sqlerrm)) > 0
           then 'right guard: ' || left(sqlerrm, 55)
           else 'WRONG GUARD: ' || left(sqlerrm, 55) || ' (wanted "' || p_msg || '")' end));
end $fn$;

create function t.rows(p_name text, p_sql text, p_want bigint) returns void
language plpgsql as $fn$
declare got bigint;
begin
  execute 'select count(*) from (' || p_sql || ') _q' into got;
  perform t.note(p_name, got = p_want, format('%s row(s), want %s', got, p_want)
    || case when got > p_want then '   <== LEAK' else '' end);
exception when others then
  perform t.note(p_name, false, format('ERROR %s: %s', sqlstate, left(sqlerrm, 100)));
end $fn$;

create function t.control(p_name text, p_sql text, p_min bigint) returns void
language plpgsql as $fn$
declare got bigint;
begin
  execute 'select count(*) from (' || p_sql || ') _q' into got;
  perform t.note('CONTROL ' || p_name, got >= p_min,
    format('%s row(s) exist to steal (need >= %s)', got, p_min)
    || case when got < p_min then '   <== VACUOUS TEST' else '' end);
exception when others then
  perform t.note('CONTROL ' || p_name, false, format('ERROR %s: %s', sqlstate, left(sqlerrm, 100)));
end $fn$;

create function t.allowed(p_name text, p_sql text, p_want bigint) returns void
language plpgsql as $fn$
declare n bigint;
begin
  execute p_sql;
  get diagnostics n = row_count;
  perform t.note(p_name, n = p_want, format('%s row(s) affected, want %s', n, p_want));
exception when others then
  perform t.note(p_name, false, format('ERROR %s: %s', sqlstate, left(sqlerrm, 100)));
end $fn$;

create table t.state (k text primary key, v text);
grant select, insert, update, delete on t.state to public;

create function t.snap(p_key text, p_sql text) returns void
language plpgsql as $fn$
declare got text;
begin
  execute p_sql into got;
  insert into t.state (k, v) values (p_key, got) on conflict (k) do update set v = excluded.v;
exception when others then
  delete from t.state where k = p_key;
  perform t.note('SNAPSHOT ' || p_key, false, format('ERROR %s: %s', sqlstate, left(sqlerrm, 100)));
end $fn$;

create function t.tok(p_key text) returns text
language sql stable as $fn$ select v from t.state where k = p_key $fn$;

create function t.be(p_user uuid, p_email text default null) returns void
language plpgsql as $fn$
begin
  perform set_config('app.user_id', coalesce(p_user::text, ''), false);
  perform set_config('app.user_email', coalesce(p_email, ''), false);
end $fn$;

grant execute on all functions in schema t to public;

-- Seed identities.
--   d..01 Dom       assistant, Lehi 8      d..02 Steve   head, Lehi 8
--   d..07 Ostler    head, Logan 8          d..0a Stranger  nothing at all
--   1..01 founder   the platform seat
-- A coach with no membership anywhere is exactly the person this feature is for.

-- ===========================================================================
-- 0. CONTROL
-- ===========================================================================
select set_config('t.sect', '0 control', false);
\echo '=== 0. What exists before anybody signs up alone ==='

select t.control('leagues exist', $q$select 1 from public.leagues$q$, 2);
select t.val('and every one of them is a league, not a club',
  $q$select count(*)::text from public.leagues where kind <> 'league'$q$, '0');
select t.val('the kind column refuses anything else',
  $q$select count(*)::text from pg_constraint where conname = 'leagues_kind'$q$, '1');
select t.control('teams exist to be miscounted', $q$select 1 from public.teams$q$, 5);
select t.control('children exist, so consent is not hypothetical',
  $q$select 1 from public.players$q$, 31);

-- ===========================================================================
-- 1. A coach with no league signs himself up
-- ===========================================================================
select set_config('t.sect', '1 signing up alone', false);
\echo '=== 1. One team, no league, signs itself up ==='

set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-0000000000f1'::uuid, 'solo@example.com');

select t.snap('club', $q$select league_id::text from app.start_club(
  'Ridgeline Youth Football', 'Ridgeline', '8', '2026 season')$q$);
select t.val('a coach with no league can start a club',
  $q$select case when t.tok('club') is null then 'NULL' else 'ok' end$q$, 'ok');

reset role;
select t.val('it is recorded as a club, not a league',
  $q$select kind from public.leagues where id = t.tok('club')::uuid$q$, 'club');
select t.val('with exactly one team in it',
  $q$select count(*)::text from public.teams where league_id = t.tok('club')::uuid$q$, '1');
select t.val('and a season for that team to sit in',
  $q$select count(*)::text from public.seasons where league_id = t.tok('club')::uuid$q$, '1');
select t.val('he is the head coach of it',
  $q$select m.role from public.memberships m join public.teams t2 on t2.id = m.team_id
     where t2.league_id = t.tok('club')::uuid$q$, 'head');
select t.val('and the admin of his own club',
  $q$select role from public.league_memberships where league_id = t.tok('club')::uuid$q$, 'admin');
select t.val('it starts on trial like anything else',
  $q$select plan from public.league_platform_state where league_id = t.tok('club')::uuid$q$, 'trial');
select t.val('the platform trail recorded the signup',
  $q$select count(*)::text from public.platform_events where action = 'club_start'$q$, '1');

-- THE REASON A CLUB IS A LEAGUE OF ONE. Without league-admin he could never
-- publish the notice, and the collection gate in 0007 would never open, and an
-- independent team could not write a single child's name.
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-0000000000f1'::uuid, 'solo@example.com');
select t.snap('notice', $q$select notice_id::text from app.issue_consent_notice(
  t.tok('club')::uuid, 'Ridgeline consent',
  'We keep your child''s last name and jersey number.',
  'I am this child''s parent or legal guardian and I agree.',
  array['roster']) $q$);
select t.val('and he can publish his own consent notice, which is the whole reason',
  $q$select case when t.tok('notice') is null then 'NULL' else 'ok' end$q$, 'ok');

-- End to end: the gate really does open for him.
select t.snap('slot', $q$insert into public.players (team_id, last, first, jersey)
  select id, app.jersey_placeholder('7'), null, '7' from public.teams
   where league_id = t.tok('club')::uuid returning id::text$q$);
select t.raises('and the collection gate still refuses a name with no consent',
  $q$update public.players set last='Newkid', first='Sam' where id = t.tok('slot')::uuid$q$, '42501');

-- ===========================================================================
-- 2. THE PRICE BOUNDARY -- a club is one team, and stays one team
-- ===========================================================================
select set_config('t.sect', '2 one team', false);
\echo '=== 2. A club cannot quietly become a league ==='

set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-0000000000f1'::uuid, 'solo@example.com');
select t.raises_like('the club owner cannot add a second team',
  $q$insert into public.teams (league_id, name, grade, season_id)
     select t.tok('club')::uuid, 'Ridgeline B', '7', id from public.seasons
      where league_id = t.tok('club')::uuid$q$,
  '42501', 'a club is a single team');

select t.raises_like('nor start a second club and point it at the first''s season',
  $q$insert into public.teams (league_id, name, grade, season_id)
     select t.tok('club')::uuid, 'Ridgeline C', '9', id from public.seasons
      where league_id = t.tok('club')::uuid$q$,
  '42501', 'a club is a single team');

-- The guard is SECURITY INVOKER on purpose: a commercial rule binds the owner
-- too, or a migration role becomes the way around the price list.
reset role;
select t.raises_like('NOT EVEN THE OWNER can add a second team to a club',
  $q$insert into public.teams (league_id, name, grade, season_id)
     select t.tok('club')::uuid, 'Ridgeline D', '6', id from public.seasons
      where league_id = t.tok('club')::uuid$q$,
  '42501', 'a club is a single team');

select t.val('so the club still holds exactly one team',
  $q$select count(*)::text from public.teams where league_id = t.tok('club')::uuid$q$, '1');

-- And moving an existing team INTO a club is the same trick from the other end.
select t.raises_like('nor can an existing team be moved into a club',
  $q$update public.teams set league_id = t.tok('club')::uuid where id = 'c0000000-0000-4000-8000-000000000001'$q$,
  '42501', 'a club is a single team');
select t.val('and that team is still where it was',
  $q$select kind from public.leagues l join public.teams t2 on t2.league_id = l.id
     where t2.id = 'c0000000-0000-4000-8000-000000000001'$q$, 'league');

-- A real league is unaffected: it may hold as many as it likes.
select t.control('the real league has several teams already',
  $q$select 1 from public.teams where league_id = 'a0000000-0000-4000-8000-000000000001'$q$, 3);
select t.allowed('adding another team to a real LEAGUE is fine',
  $q$insert into public.teams (league_id, name, grade, season_id)
     select 'a0000000-0000-4000-8000-000000000001', 'Lehi 6', '6', id from public.seasons
      where league_id = 'a0000000-0000-4000-8000-000000000001' limit 1$q$, 1);

-- ===========================================================================
-- 3. Signing up is not a way in to anybody else
-- ===========================================================================
select set_config('t.sect', '3 not a way in', false);
\echo '=== 3. Self-signup creates a tenant. It never joins one. ==='

set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-0000000000f1'::uuid, 'solo@example.com');

select t.rows('his club gives him no sight of the other league''s teams',
  $q$select 1 from public.teams where league_id = 'a0000000-0000-4000-8000-000000000001'$q$, 0);
select t.rows('nor of its children',
  $q$select 1 from public.players where team_id = 'c0000000-0000-4000-8000-000000000001'$q$, 0);
select t.control('CONTROL those children are really there, to the owner',
  $q$select 1 from public.players where team_id = 'c0000000-0000-4000-8000-000000000001'$q$, 0);
select t.rows('nor of any league but his own',
  $q$select 1 from public.leagues where id = 'a0000000-0000-4000-8000-000000000001'$q$, 0);
select t.val('he sees exactly one league: his',
  $q$select count(*)::text from public.leagues$q$, '1');

-- Being admin of his own club is not being admin anywhere else.
select t.val('he is an admin of his club',
  $q$select app.may_staff_league(t.tok('club')::uuid)::text$q$, 'true');
select t.val('and of no other league',
  $q$select app.may_staff_league('a0000000-0000-4000-8000-000000000001')::text$q$, 'false');
select t.raises('so he cannot publish a notice for somebody else''s league',
  $q$select app.issue_consent_notice('a0000000-0000-4000-8000-000000000001', 'x', 'y', 'z')$q$, '42501');
select t.raises('nor read what they are billed',
  $q$select * from app.billable_units('a0000000-0000-4000-8000-000000000001')$q$, '42501');

-- A stranger cannot sign up on somebody else's behalf: there is no parameter
-- for it. The strongest statement of that is the function's own signature.
reset role;
select t.val('start_club takes no user, team or league id -- only names',
  $q$select (position('uuid' in pg_get_function_arguments(p.oid)) = 0)::text
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='app' and p.proname='start_club'$q$, 'true');

set role pd_authenticated;
select t.be(null);
select t.raises('an unauthenticated visitor cannot start a club',
  $q$select * from app.start_club('X','Y','8')$q$, '42501');

-- The vendor's seat holds no football.
select t.be('10000000-0000-4000-8000-000000000001', 'founder@example.com');
select t.raises_like('the platform owner cannot sign himself up a club',
  $q$select * from app.start_club('Vendor FC','Vendor','8')$q$,
  '42501', 'platform seat does not coach');
reset role;
select t.val('and no orphan league was left behind by the attempt',
  $q$select count(*)::text from public.leagues where name = 'Vendor FC'$q$, '0');

-- ===========================================================================
-- 4. Two clubs cannot see each other
-- ===========================================================================
select set_config('t.sect', '4 club vs club', false);
\echo '=== 4. Two independent teams are two tenants ==='

set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-0000000000f2'::uuid, 'solo2@example.com');
select t.snap('club2', $q$select league_id::text from app.start_club(
  'Timpview Youth', 'Timpview', '8')$q$);
select t.val('a second coach starts his own club',
  $q$select case when t.tok('club2') is null then 'NULL' else 'ok' end$q$, 'ok');
select t.rows('and cannot see the first club at all',
  $q$select 1 from public.leagues where id = t.tok('club')::uuid$q$, 0);
select t.rows('nor its team',
  $q$select 1 from public.teams where league_id = t.tok('club')::uuid$q$, 0);
select t.raises('nor read its bill',
  $q$select * from app.billable_units(t.tok('club')::uuid)$q$, '42501');

select t.be('d0000000-0000-4000-8000-0000000000f1'::uuid, 'solo@example.com');
select t.rows('and the first cannot see the second',
  $q$select 1 from public.leagues where id = t.tok('club2')::uuid$q$, 0);

reset role;
select t.control('CONTROL both clubs really exist, to the owner',
  $q$select 1 from public.leagues where kind = 'club'$q$, 2);

-- ===========================================================================
-- 5. What the bill is built from
-- ===========================================================================
select set_config('t.sect', '5 billable units', false);
\echo '=== 5. The seam an invoice is made of -- and no money in it ==='

set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-0000000000f1'::uuid, 'solo@example.com');
select t.val('a club bills as a club',
  $q$select kind from app.billable_units(t.tok('club')::uuid)$q$, 'club');
select t.val('for one team',
  $q$select billable_teams::text from app.billable_units(t.tok('club')::uuid)$q$, '1');
select t.val('and one seat',
  $q$select active_seats::text from app.billable_units(t.tok('club')::uuid)$q$, '1');

-- Asked as UYFC's own admin. Being the database owner is not being a league
-- admin, and billable_units() is right to refuse that -- which is itself worth
-- asserting, since a bill nobody is entitled to read is the wrong default.
select t.be('d0000000-0000-4000-8000-000000000006', 'whitmore@example.com');
select t.val('the real league bills as a league, to its own admin',
  $q$select kind from app.billable_units('a0000000-0000-4000-8000-000000000001')$q$, 'league');
select t.val('for more than one team, which is why it costs more',
  $q$select (billable_teams > 1)::text from app.billable_units('a0000000-0000-4000-8000-000000000001')$q$, 'true');
select t.val('and it counts the children it is responsible for',
  $q$select (children > 0)::text from app.billable_units('a0000000-0000-4000-8000-000000000001')$q$, 'true');
select t.be(null);
select t.raises('a session with no identity is told nothing about any bill',
  $q$select * from app.billable_units('a0000000-0000-4000-8000-000000000001')$q$, '42501');
reset role;
select t.val('billable_units mentions no money at all',
  $q$select (position('price' in lower(pg_get_functiondef(p.oid))) = 0
        and position('cent'  in lower(pg_get_functiondef(p.oid))) = 0)::text
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='app' and p.proname='billable_units'$q$, 'true');

-- ===========================================================================
-- 6. Growing up is the vendor's call, because it is the price changing
-- ===========================================================================
select set_config('t.sect', '6 conversion', false);
\echo '=== 6. Club -> league is deliberate, recorded, and not the coach''s ==='

set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-0000000000f1'::uuid, 'solo@example.com');
select t.raises('the club owner cannot promote his own club',
  $q$select app.convert_club_to_league(t.tok('club')::uuid, 'we grew')$q$, '42501');
select t.raises('nor write the column directly',
  $q$update public.leagues set kind = 'league' where id = t.tok('club')::uuid$q$, '42501');
select t.val('so it is still a club',
  $q$select kind from public.leagues where id = t.tok('club')::uuid$q$, 'club');

select t.be('10000000-0000-4000-8000-000000000001', 'founder@example.com');
select t.val('the platform seat converts it',
  $q$select app.convert_club_to_league(t.tok('club')::uuid, 'signed a league deal')::text$q$, 'true');
reset role;
select t.val('and now it is a league',
  $q$select kind from public.leagues where id = t.tok('club')::uuid$q$, 'league');
select t.val('the conversion is in the trail',
  $q$select count(*)::text from public.platform_events where action = 'club_convert'$q$, '1');

-- Nothing moved. Rule 1 of CLAUDE.md, restated for tenancy.
select t.val('its team is still there',
  $q$select count(*)::text from public.teams where league_id = t.tok('club')::uuid$q$, '1');
select t.val('its notice is still there',
  $q$select count(*)::text from public.consent_notices where league_id = t.tok('club')::uuid$q$, '1');
select t.val('its child is still there',
  $q$select count(*)::text from public.players where id = t.tok('slot')::uuid$q$, '1');
select t.val('and the head coach is still the head coach',
  $q$select m.role from public.memberships m join public.teams t2 on t2.id=m.team_id
     where t2.league_id = t.tok('club')::uuid$q$, 'head');

-- Now that it is a league, the cap is gone -- which is exactly what was paid for.
select t.allowed('and NOW a second team is allowed',
  $q$insert into public.teams (league_id, name, grade, season_id)
     select t.tok('club')::uuid, 'Ridgeline B', '7', id from public.seasons
      where league_id = t.tok('club')::uuid limit 1$q$, 1);
select t.val('so it holds two',
  $q$select count(*)::text from public.teams where league_id = t.tok('club')::uuid$q$, '2');

select t.raises('and it cannot be converted twice',
  $q$select app.convert_club_to_league(t.tok('club')::uuid)$q$, '22023');

-- ===========================================================================
-- 7. The grant graph
-- ===========================================================================
select set_config('t.sect', '7 grants', false);
\echo '=== 7. Who may call what ==='

select t.val('signing up requires an account -- pd_anon may not',
  $q$select has_function_privilege('pd_anon',
     'app.start_club(text,text,text,text,date,date,jsonb)','execute')::text$q$, 'false');
select t.val('a signed-in caller may',
  $q$select has_function_privilege('pd_authenticated',
     'app.start_club(text,text,text,text,date,date,jsonb)','execute')::text$q$, 'true');
select t.val('the single-team guard is callable by nobody directly',
  $q$select (has_function_privilege('pd_authenticated','app.club_single_team_guard()','execute')
          or has_function_privilege('pd_anon','app.club_single_team_guard()','execute'))::text$q$, 'false');
-- DEFINER, so the count is complete. As INVOKER it ran under the caller's RLS,
-- and a session that cannot see a club's existing team counts zero teams in it
-- -- measured at 0 where the owner sees 2. It binds the owner regardless,
-- because a trigger fires for the owner whatever its security setting, and
-- section 2 proves that by attacking as the owner.
select t.val('the single-team guard is SECURITY DEFINER, so RLS cannot shrink its count',
  $q$select prosecdef::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='app' and p.proname='club_single_team_guard'$q$, 'true');
select t.val('and it counts every team in the club, not the ones the caller can see',
  $q$select (position('public.teams' in pg_get_functiondef(p.oid)) > 0)::text
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='app' and p.proname='club_single_team_guard'$q$, 'true');

-- ===========================================================================
-- 8. VACUITY CHECK -- with the cap gone, a club IS a free league
-- ===========================================================================
select set_config('t.sect', '8 vacuity', false);
\echo '=== 8. Drop the guard and the price boundary disappears ==='

-- A fresh coach: section 6 left the platform founder signed in, and the
-- platform seat is refused a club on purpose.
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-0000000000f3'::uuid, 'vacuity@example.com');
select t.snap('club3', $q$select league_id::text from (
  select * from app.start_club('Vacuity FC','Vacuity','8')) _$q$);
reset role;

-- `if exists`, so a mutation run that has already dropped it produces a red
-- count instead of aborting the file -- an aborted suite counts zero failures
-- and reads exactly like a guard nobody needed.
drop trigger if exists teams_club_single on public.teams;
select t.allowed('with no guard, a club takes a second team',
  $q$insert into public.teams (league_id, name, grade, season_id)
     select t.tok('club3')::uuid, 'Vacuity B', '7', id from public.seasons
      where league_id = t.tok('club3')::uuid limit 1$q$, 1);
select t.allowed('and a third, and it is still billed as a club',
  $q$insert into public.teams (league_id, name, grade, season_id)
     select t.tok('club3')::uuid, 'Vacuity C', '6', id from public.seasons
      where league_id = t.tok('club3')::uuid limit 1$q$, 1);
select t.val('three teams paying a one-team rate',
  $q$select billable_teams::text || ' teams, billed as ' || kind
      from app.billable_units(t.tok('club3')::uuid)$q$, '3 teams, billed as club');

create trigger teams_club_single
  before insert or update of league_id on public.teams
  for each row execute function app.club_single_team_guard();
select t.raises_like('put back: refused again',
  $q$insert into public.teams (league_id, name, grade, season_id)
     select t.tok('club3')::uuid, 'Vacuity D', '5', id from public.seasons
      where league_id = t.tok('club3')::uuid limit 1$q$,
  '42501', 'a club is a single team');

-- ===========================================================================
-- RESULTS
-- ===========================================================================
\echo ''
\echo '=== RESULTS ==='
select n || '|' || sect || '|' || name || '|' ||
       case when ok then 'PASS' else '*** FAIL ***' end || '|' || coalesce(detail, '')
  from t.results order by n;

do $$
declare n_fail int; n_all int;
begin
  select count(*) filter (where not ok), count(*) into n_fail, n_all from t.results;
  if n_fail > 0 then raise exception '% CLUB TEST(S) FAILED', n_fail; end if;
  raise notice 'all % club tests passed', n_all;
end $$;

rollback;
