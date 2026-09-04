-- product/db/test-platform.sql
-- The adversarial suite for platform.sql. Same house rules as
-- test-isolation.sql and test-auth.sql, because the same thing is being
-- proved -- and here it matters more than anywhere else in the schema, since
-- this is the one seat that is allowed to look across tenants at all.
--
-- RUN:
--   psql -h /tmp -p 5433 -U app -d pd_plat -f product/db/test-platform.sql
-- FROM EMPTY:
--   createdb pd_plat
--   psql ... -f product/db/schema.sql   -f product/db/rls.sql \
--            -f product/db/auth.sql     -f product/db/platform.sql \
--            -f product/db/seed.sql     -f product/db/auth-seed.sql \
--            -f product/db/platform-seed.sql
--
-- Everything runs inside one transaction and ROLLS BACK, so the suite is
-- rerunnable and leaves the seed untouched. No SAVEPOINTs, for the same reason
-- the other two files have none: rolling back to one would roll back the
-- results table with it.
--
-- HOUSE RULES, inherited:
--   (a) Every refusal is paired with a CONTROL run as the bypassing owner,
--       proving the row was really there to be taken. A refusal whose control
--       returns 0 is a broken test, not a pass.
--   (b) Attacks address the other tenant's rows by literal uuid. A subselect
--       would return NULL under RLS and the attack would "pass" by asking
--       about nothing.
--   (c) Section 11 briefly ADDS a permissive policy and a grant, and shows the
--       identical queries leaking, so nobody has to take the zeroes on faith.
--
-- THE CLAIM THIS FILE TESTS, IN ONE SENTENCE. A platform owner can see how big
-- a league is, when its seasons run, how many seats it uses, whether it is paid
-- up, and who was given or refused access -- and cannot see a single play, a
-- single child, or a single row of anybody's football, cannot write anything a
-- tenant owns, and cannot edit the record of what it looked at.
--
-- WHAT THIS FILE CANNOT PROVE. Stated here rather than buried:
--   * That the GUCs were stamped honestly. app.user_id -> auth.uid() is the
--     same assumption test-isolation.sql and test-auth.sql already rest on: in
--     production the claim comes off a verified JWT and cannot be chosen by the
--     client. If an attacker can set app.user_id to a platform owner's uuid,
--     they are already inside the pooler and every suite here is moot.
--   * REFUSED platform calls are not logged in the database, and cannot be. A
--     raise aborts the statement, and an aborted statement takes its own INSERT
--     with it, so a denial cannot record itself from inside the function that
--     denies. Successful reads are logged, in the same transaction as the read,
--     which is the half that matters for "what did you actually see". Failed
--     attempts belong to the log in front of the database.
--   * Whether a human being should have been given the seat. The database can
--     say the seat is narrow; it cannot say it was well handed out.
--   * What happens to the numbers after app.platform_leagues() returns them --
--     screenshots, spreadsheets and support tickets are outside the boundary.

\set ON_ERROR_STOP on
\timing off
\pset pager off

begin;

-- ===========================================================================
-- Harness -- identical in shape to the other two suites
-- ===========================================================================

create schema t;
create table t.results (
  n      serial primary key,
  sect   text,
  name   text,
  ok     boolean not null,
  detail text
);
grant usage on schema t to public;
grant select, insert on t.results to public;
grant usage, select on sequence t.results_n_seq to public;

create function t.note(p_name text, p_ok boolean, p_detail text) returns void
language sql as $fn$
  insert into t.results (sect, name, ok, detail)
  values (coalesce(nullif(current_setting('t.sect', true), ''), '-'), p_name, p_ok, p_detail);
$fn$;

create function t.rows(p_name text, p_sql text, p_want bigint) returns void
language plpgsql as $fn$
declare got bigint;
begin
  execute 'select count(*) from (' || p_sql || ') _q' into got;
  perform t.note(p_name, got = p_want,
    format('%s row(s), want %s', got, p_want) ||
    case when got > p_want then '   <== LEAK' else '' end);
exception when others then
  perform t.note(p_name, false, format('ERROR %s: %s', sqlstate, left(sqlerrm, 100)));
end $fn$;

create function t.control(p_name text, p_sql text, p_min bigint) returns void
language plpgsql as $fn$
declare got bigint;
begin
  execute 'select count(*) from (' || p_sql || ') _q' into got;
  perform t.note('CONTROL ' || p_name, got >= p_min,
    format('%s row(s) exist to steal (need >= %s)', got, p_min) ||
    case when got < p_min then '   <== VACUOUS TEST' else '' end);
exception when others then
  perform t.note('CONTROL ' || p_name, false, format('ERROR %s: %s', sqlstate, left(sqlerrm, 100)));
end $fn$;

create function t.val(p_name text, p_sql text, p_want text) returns void
language plpgsql as $fn$
declare got text;
begin
  execute p_sql into got;
  perform t.note(p_name, got is not distinct from p_want,
    format('got %s, want %s', coalesce(quote_literal(got), 'NULL'), coalesce(quote_literal(p_want), 'NULL')));
exception when others then
  perform t.note(p_name, false, format('ERROR %s: %s', sqlstate, left(sqlerrm, 100)));
end $fn$;

create function t.blocked(p_name text, p_sql text) returns void
language plpgsql as $fn$
declare n bigint;
begin
  execute p_sql;
  get diagnostics n = row_count;
  perform t.note(p_name, n = 0,
    case when n = 0 then 'USING filtered it: 0 rows affected, no error'
         else format('LEAK: %s row(s) written', n) end);
exception
  when syntax_error_or_access_rule_violation then
    if sqlstate in ('42601','42703','42P01','42883') then
      perform t.note(p_name, false, format('BROKEN TEST %s: %s', sqlstate, left(sqlerrm, 90)));
    else
      perform t.note(p_name, true, format('refused %s: %s', sqlstate, left(sqlerrm, 90)));
    end if;
  when others then
    perform t.note(p_name, true, format('refused %s: %s', sqlstate, left(sqlerrm, 90)));
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

-- One difference from the harness in the other two suites, and it was earned in
-- the mutation run below: t.snap here CATCHES. A mutant that hands a tenant the
-- platform seat lets that tenant revoke the vendor's, and then the very next
-- t.snap -- creating a league -- raised, aborted the transaction, and the suite
-- died without printing a tally. "It exploded" is a weaker report than "39 tests
-- went red", so a failed snapshot is now a recorded failure and the run
-- continues; everything downstream that wanted the value fails too, which is
-- the honest count.
create function t.snap(p_key text, p_sql text) returns void
language plpgsql as $fn$
declare got text;
begin
  execute p_sql into got;
  insert into t.state (k, v) values (p_key, got)
    on conflict (k) do update set v = excluded.v;
exception when others then
  delete from t.state where k = p_key;
  perform t.note('SNAPSHOT ' || p_key, false, format('ERROR %s: %s', sqlstate, left(sqlerrm, 100)));
end $fn$;

create function t.unchanged(p_name text, p_key text, p_sql text) returns void
language plpgsql as $fn$
declare got text; was text;
begin
  select v into was from t.state where k = p_key;
  execute p_sql into got;
  perform t.note(p_name, got is not distinct from was,
    format('was %s, now %s', coalesce(was,'NULL'), coalesce(got,'NULL')));
end $fn$;

-- Read back something the suite stashed earlier -- a token, a new league's id.
-- Tests pass it as an ARGUMENT, t.tok('x'), rather than interpolating it into
-- SQL text, so nothing depends on quoting a uuid or a secret correctly.
create function t.tok(p_key text) returns text
language sql stable as $fn$ select v from t.state where k = p_key $fn$;

-- Become somebody. Both claims off one token, as in test-auth.sql.
create function t.be(p_user uuid, p_email text default null) returns void
language plpgsql as $fn$
begin
  perform set_config('app.user_id',    coalesce(p_user::text, ''), false);
  perform set_config('app.user_email', coalesce(p_email, ''), false);
end $fn$;

-- Everything the platform seat can read, as one blob of text. Section 4 hunts
-- through it for a child. It has to run as the platform owner, which is why it
-- is a plain SECURITY INVOKER function.
create function t.platform_sweep() returns text
language sql as $fn$
  select coalesce(string_agg(x, ' '), '') from (
    select row_to_json(q)::text as x from app.platform_leagues() q
    union all
    select row_to_json(q)::text from app.platform_league('a0000000-0000-4000-8000-000000000001') q
    union all
    select row_to_json(q)::text from app.platform_league('a0000000-0000-4000-8000-000000000002') q
    union all
    select row_to_json(q)::text from app.platform_audit('a0000000-0000-4000-8000-000000000001', 1000) q
    union all
    select row_to_json(q)::text from app.platform_audit('a0000000-0000-4000-8000-000000000002', 1000) q
    union all
    select row_to_json(q)::text from app.platform_owners_list() q
    union all
    select row_to_json(q)::text from app.platform_trail(null, 1000) q
  ) s
$fn$;

grant execute on all functions in schema t to public;

-- ===========================================================================
-- 0. CONTROL -- what exists, seen by the bypassing owner
-- ===========================================================================
select set_config('t.sect', '0 control', false);
\echo '=== 0. What the platform layer starts with (owner, RLS bypassed) ==='
select (select count(*) from public.platform_owners)       as owners,
       (select count(*) from public.league_platform_state) as league_state,
       (select count(*) from public.platform_events)       as trail_rows,
       (select count(*) from public.leagues)               as leagues,
       (select count(*) from public.players)               as children,
       (select count(*) from public.plays)                 as plays;

select o.user_id, o.email, o.note from public.platform_owners o order by o.email;

select t.control('platform seats exist',       $q$select 1 from public.platform_owners$q$, 2);
select t.control('leagues exist to look at',   $q$select 1 from public.leagues$q$, 2);
select t.control('children exist to protect',  $q$select 1 from public.players$q$, 31);
select t.control('plays exist to withhold',    $q$select 1 from public.plays$q$, 6);
select t.control('consents exist to withhold', $q$select 1 from public.player_consents$q$, 4);
select t.control('invitations exist to withhold', $q$select 1 from public.invites$q$, 6);
select t.control('player words exist to withhold', $q$select 1 from public.player_words$q$, 3);
select t.control('a staffing history exists',  $q$select 1 from public.auth_events$q$, 20);

-- The separation rule, checked against the fixture rather than assumed.
select t.val('no platform owner holds a team membership',
  $q$select count(*)::text from public.memberships m
      where m.user_id in (select o.user_id from public.platform_owners o)$q$, '0');
select t.val('no platform owner holds a league membership',
  $q$select count(*)::text from public.league_memberships lm
      where lm.user_id in (select o.user_id from public.platform_owners o)$q$, '0');
select t.val('the bootstrap wrote itself into the trail',
  $q$select count(*)::text from public.platform_events where action='owner_grant'$q$, '2');
select t.val('and did it with a NULL actor, because a migration is not a person',
  $q$select count(*)::text from public.platform_events where action='owner_grant' and actor is null$q$, '2');

-- A tombstone, so section 3's refusal has something real to refuse. Written as
-- the owner, which is the only thing that can write one outside the trigger.
insert into public.player_tombstones (player_id, team_id, jersey, reason)
values ('e0000000-0000-4000-8000-0000000000ff', 'c0000000-0000-4000-8000-000000000001', '99', 'roster_correction');
select t.control('a tombstone exists to withhold', $q$select 1 from public.player_tombstones$q$, 1);

-- ===========================================================================
-- 1. The seat: who holds it, and who may even look at the list
-- ===========================================================================
select set_config('t.sect', '1 the seat', false);
set role pd_authenticated;

select t.be('10000000-0000-4000-8000-000000000001', 'founder@example.com');
select t.val('the platform owner knows he is one', $q$select app.is_platform_owner()::text$q$, 'true');
select t.be('d0000000-0000-4000-8000-000000000002', 'steve@example.com');
select t.val('a head coach is not one',   $q$select app.is_platform_owner()::text$q$, 'false');
select t.be('d0000000-0000-4000-8000-000000000006', 'whitmore@example.com');
select t.val('a league admin is not one', $q$select app.is_platform_owner()::text$q$, 'false');
select t.be('d0000000-0000-4000-8000-000000000005', 'reeves@example.com');
select t.val('a board member is not one', $q$select app.is_platform_owner()::text$q$, 'false');
select t.be('d0000000-0000-4000-8000-00000000000a', 'stranger@example.com');
select t.val('a stranger is not one',     $q$select app.is_platform_owner()::text$q$, 'false');
select t.be(null, null);
select t.val('and an anonymous session is not one', $q$select app.is_platform_owner()::text$q$, 'false');
reset role;

-- The table is not readable by anybody, in any role. Privilege first, policy
-- behind it, and the function is the only list there is.
select t.val('pd_authenticated holds no SELECT on the seat table',
  $q$select has_table_privilege('pd_authenticated','public.platform_owners','select')::text$q$, 'false');
select t.val('nor any INSERT',
  $q$select has_table_privilege('pd_authenticated','public.platform_owners','insert')::text$q$, 'false');
select t.val('nor does pd_anon',
  $q$select has_table_privilege('pd_anon','public.platform_owners','select')::text$q$, 'false');
select t.val('and the table carries no policy at all, so a stray grant would still read nothing',
  $q$select count(*)::text from pg_policies where schemaname='public' and tablename='platform_owners'$q$, '0');
select t.val('RLS is enabled AND forced on it',
  $q$select (relrowsecurity and relforcerowsecurity)::text from pg_class where oid='public.platform_owners'::regclass$q$, 'true');

set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000002', 'steve@example.com');
select t.raises('a head coach cannot read the seat table', $q$select 1 from public.platform_owners$q$, '42501');
select t.be('d0000000-0000-4000-8000-000000000006', 'whitmore@example.com');
select t.raises('nor can a league admin',                  $q$select 1 from public.platform_owners$q$, '42501');
select t.be('d0000000-0000-4000-8000-000000000005', 'reeves@example.com');
select t.raises('nor a board member',                      $q$select 1 from public.platform_owners$q$, '42501');
select t.be('10000000-0000-4000-8000-000000000001', 'founder@example.com');
select t.raises('NOR THE PLATFORM OWNER HIMSELF -- the list is a function, not a table',
  $q$select 1 from public.platform_owners$q$, '42501');
select t.val('and the function gives him the list', $q$select count(*)::text from app.platform_owners_list()$q$, '2');
select t.be('d0000000-0000-4000-8000-000000000006', 'whitmore@example.com');
select t.raises('which a league admin cannot call', $q$select * from app.platform_owners_list()$q$, '42501');
reset role;

-- ===========================================================================
-- 2. Bootstrapping: nobody promotes themselves
-- ===========================================================================
select set_config('t.sect', '2 bootstrap', false);
set role pd_authenticated;

-- Every tenant seat in the fixture, trying every door.
select t.be('d0000000-0000-4000-8000-000000000002', 'steve@example.com');
select t.raises('a HEAD COACH cannot insert himself into platform_owners',
  $q$insert into public.platform_owners (user_id, email) values ('d0000000-0000-4000-8000-000000000002','steve@example.com')$q$, '42501');
select t.raises('nor call grant_platform_owner',
  $q$select app.grant_platform_owner('d0000000-0000-4000-8000-000000000002','steve@example.com')$q$, '42501');

select t.be('d0000000-0000-4000-8000-000000000006', 'whitmore@example.com');
select t.raises('a LEAGUE ADMIN -- the most powerful tenant there is -- cannot insert himself',
  $q$insert into public.platform_owners (user_id, email) values ('d0000000-0000-4000-8000-000000000006','whitmore@example.com')$q$, '42501');
select t.raises('nor call grant_platform_owner',
  $q$select app.grant_platform_owner('d0000000-0000-4000-8000-000000000006','whitmore@example.com')$q$, '42501');
select t.raises('nor hand the seat to somebody else',
  $q$select app.grant_platform_owner('d0000000-0000-4000-8000-00000000000e','outsider@example.com')$q$, '42501');

select t.be('d0000000-0000-4000-8000-000000000005', 'reeves@example.com');
select t.raises('a BOARD MEMBER cannot insert himself',
  $q$insert into public.platform_owners (user_id, email) values ('d0000000-0000-4000-8000-000000000005','reeves@example.com')$q$, '42501');
select t.raises('nor call grant_platform_owner',
  $q$select app.grant_platform_owner('d0000000-0000-4000-8000-000000000005','reeves@example.com')$q$, '42501');

select t.be('d0000000-0000-4000-8000-000000000001', 'dom@example.com');
select t.raises('an ASSISTANT cannot either',
  $q$insert into public.platform_owners (user_id, email) values ('d0000000-0000-4000-8000-000000000001','dom@example.com')$q$, '42501');
select t.be('d0000000-0000-4000-8000-000000000003', 'parent@example.com');
select t.raises('nor a HELPER',
  $q$insert into public.platform_owners (user_id, email) values ('d0000000-0000-4000-8000-000000000003','parent@example.com')$q$, '42501');
select t.be('d0000000-0000-4000-8000-00000000000a', 'stranger@example.com');
select t.raises('nor a STRANGER with a valid account',
  $q$insert into public.platform_owners (user_id, email) values ('d0000000-0000-4000-8000-00000000000a','stranger@example.com')$q$, '42501');

-- Knowing the bootstrap flag exists buys a tenant nothing: the privilege check
-- fires first, and the flag was only ever the migration's second lock.
select t.be('d0000000-0000-4000-8000-000000000006', 'whitmore@example.com');
select set_config('app.platform_bootstrap', 'on', true);
select t.raises('knowing the bootstrap flag does not help a league admin',
  $q$insert into public.platform_owners (user_id, email) values ('d0000000-0000-4000-8000-000000000006','whitmore@example.com')$q$, '42501');
select t.raises('and neither does setting every GUC he can think of',
  $q$insert into public.platform_owners (user_id, email) values ('d0000000-0000-4000-8000-000000000006','whitmore@example.com')$q$, '42501');
select set_config('app.platform_bootstrap', '', true);
select t.val('and he still is not one', $q$select app.is_platform_owner()::text$q$, 'false');
reset role;

-- Now the doors only the migration has, tested as the bypassing owner. This is
-- the half a privilege cannot cover: the trigger binds whoever arrives.
select set_config('app.platform_bootstrap', '', true);
select t.raises('EVEN THE OWNER cannot add a seat without saying so',
  $q$insert into public.platform_owners (user_id, email) values ('10000000-0000-4000-8000-00000000000f','someone@example.com')$q$, '42501');
select set_config('app.platform_bootstrap', 'on', true);
select t.raises('and not even then, if the uuid already coaches a team',
  $q$insert into public.platform_owners (user_id, email) values ('d0000000-0000-4000-8000-000000000001','dom@example.com')$q$, '42501');
select t.raises('or sits on a league board',
  $q$insert into public.platform_owners (user_id, email) values ('d0000000-0000-4000-8000-000000000005','reeves@example.com')$q$, '42501');
select t.allowed('a fresh uuid, with the flag, is how the first seat was made',
  $q$insert into public.platform_owners (user_id, email) values ('10000000-0000-4000-8000-00000000000f','someone@example.com')$q$, 1);
select t.val('and that seat is in the trail already',
  $q$select count(*)::text from public.platform_events
      where action='owner_grant' and subject_user='10000000-0000-4000-8000-00000000000f'$q$, '1');
delete from public.platform_owners where user_id='10000000-0000-4000-8000-00000000000f';
select set_config('app.platform_bootstrap', '', true);

-- A platform owner may open a second seat, and may not close his own.
set role pd_authenticated;
select t.be('10000000-0000-4000-8000-000000000001', 'founder@example.com');
select t.val('a platform owner opens another platform seat',
  $q$select app.grant_platform_owner('10000000-0000-4000-8000-000000000003','third@example.com','test seat')::text$q$, 'true');
select t.raises('but not for somebody who already coaches',
  $q$select app.grant_platform_owner('d0000000-0000-4000-8000-000000000002','steve@example.com')$q$, '42501');
select t.raises('and not for a sitting league admin',
  $q$select app.grant_platform_owner('d0000000-0000-4000-8000-000000000006','whitmore@example.com')$q$, '42501');
select t.val('he can close the seat he opened',
  $q$select app.revoke_platform_owner('10000000-0000-4000-8000-000000000003')::text$q$, 'true');
select t.raises('and cannot close his own',
  $q$select app.revoke_platform_owner('10000000-0000-4000-8000-000000000001')$q$, '22023');
reset role;
select t.val('both the grant and the revoke are in the trail',
  $q$select count(*)::text from public.platform_events
      where subject_user='10000000-0000-4000-8000-000000000003'$q$, '2');

-- The other direction of the separation rule: the vendor cannot be handed
-- football either, by a coach, by an admin, or by redeeming an invitation.
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000002', 'steve@example.com');
select t.raises('a head coach cannot put the platform owner on his staff',
  $q$insert into public.memberships (user_id, team_id, role)
     values ('10000000-0000-4000-8000-000000000001','c0000000-0000-4000-8000-000000000001','assistant')$q$, '42501');
select t.snap('plat_invite', $q$select token from app.issue_invite('founder@example.com','helper','c0000000-0000-4000-8000-000000000001')$q$);
select t.be('d0000000-0000-4000-8000-000000000006', 'whitmore@example.com');
select t.raises('nor can a league admin appoint him to the board',
  $q$insert into public.league_memberships (user_id, league_id, role)
     values ('10000000-0000-4000-8000-000000000001','a0000000-0000-4000-8000-000000000001','board')$q$, '42501');
select t.be('10000000-0000-4000-8000-000000000001', 'founder@example.com');
select t.raises('and the platform owner cannot accept an invitation addressed to him',
  $q$select app.accept_invite(t.tok('plat_invite'))$q$, '42501');
reset role;
select t.val('so he still holds no membership anywhere',
  $q$select count(*)::text from public.memberships m
      where m.user_id='10000000-0000-4000-8000-000000000001'$q$, '0');
select t.control('though the invitation really was minted and really was valid',
  $q$select 1 from public.invites where email='founder@example.com'
      and accepted_at is null and revoked_at is null and expires_at > now()$q$, 1);

-- ===========================================================================
-- 3. What the platform owner CANNOT read. Every tenant table, by literal uuid.
-- ===========================================================================
select set_config('t.sect', '3 no tenant reach', false);
set role pd_authenticated;
select t.be('10000000-0000-4000-8000-000000000001', 'founder@example.com');

select t.rows('plays: none at all',                   $q$select 1 from public.plays$q$, 0);
select t.rows('plays: not the first team''s, by uuid',
  $q$select 1 from public.plays where team_id='c0000000-0000-4000-8000-000000000001'$q$, 0);
select t.rows('plays: not the other league''s either',
  $q$select 1 from public.plays where team_id='c0000000-0000-4000-8000-000000000004'$q$, 0);
select t.rows('plays: not one play document by its own id',
  $q$select doc from public.plays where id='f0000000-0000-4000-8000-000000000001'$q$, 0);
select t.val('plays: count(*) does not leak the total either',
  $q$select count(*)::text from public.plays$q$, '0');
select t.rows('players: no child, anywhere',           $q$select 1 from public.players$q$, 0);
select t.rows('players: not one by uuid',
  $q$select last from public.players where id='e0000000-0000-4000-8000-000000000001'$q$, 0);
select t.rows('players: not by team either',
  $q$select 1 from public.players where team_id='c0000000-0000-4000-8000-000000000001'$q$, 0);
select t.rows('consents: none',                        $q$select 1 from public.player_consents$q$, 0);
select t.rows('tombstones: none -- they carry a jersey and a team',
  $q$select 1 from public.player_tombstones$q$, 0);
select t.rows('teams: none',                           $q$select 1 from public.teams$q$, 0);
select t.rows('leagues: not even the customer list he sells to',
  $q$select 1 from public.leagues$q$, 0);
select t.rows('seasons: none',                         $q$select 1 from public.seasons$q$, 0);
select t.rows('memberships: none',                     $q$select 1 from public.memberships$q$, 0);
select t.rows('league_memberships: none',              $q$select 1 from public.league_memberships$q$, 0);
-- Invitations are the one honest exception, and it is auth.sql's rule rather
-- than a platform one: invites_select lets ANY session read an invitation
-- addressed to its own verified email. Section 2 had a head coach mint one to
-- the founder's address, precisely to prove he could not redeem it -- so he can
-- see that one row, the way anybody can see their own post. He sees no other
-- invitation in the product, and the row holds an adult address and a digest.
select t.rows('invites: only the one addressed to his own mailbox',
  $q$select 1 from public.invites$q$, 1);
select t.rows('invites: and not one of anybody else''s',
  $q$select 1 from public.invites where email <> 'founder@example.com'$q$, 0);
select t.rows('invites: not by team, not by league, not by id',
  $q$select 1 from public.invites where id='90000000-0000-4000-8000-000000000001'$q$, 0);
select t.rows('player_words: none -- the boys'' word is not the vendor''s business',
  $q$select 1 from public.player_words$q$, 0);
select t.rows('league_platform_state: not even his own billing table, directly',
  $q$select 1 from public.league_platform_state$q$, 0);
select t.rows('auth_events: none, until he does something himself',
  $q$select 1 from public.auth_events$q$, 0);

-- The player word is a tenant credential, and holding the seat is not holding
-- the word. (The word is in auth-seed.sql; a platform owner presenting it is
-- just a session presenting a word, and it would work -- which is why the
-- interesting test is that the SEAT grants nothing extra on top of it.)
select t.rows('and the seat adds no reach to a play by slug',
  $q$select 1 from public.plays where slug='punt-base'$q$, 0);
reset role;

select t.control('all six plays are sitting there',   $q$select 1 from public.plays$q$, 6);
select t.control('all 31 children are sitting there', $q$select 1 from public.players$q$, 31);
select t.control('so are the words and the invitations',
  $q$select 1 from public.player_words union all select 1 from public.invites$q$, 9);

-- ===========================================================================
-- 4. Counts, not names. What he DOES get, stated exactly.
-- ===========================================================================
select set_config('t.sect', '4 counts not names', false);
set role pd_authenticated;
select t.be('10000000-0000-4000-8000-000000000001', 'founder@example.com');

-- Snapshotted rather than selected straight out, for the same reason as the
-- census in section 8: a bare platform call is a statement that a mutant can
-- make raise, and a raise here would take the whole transaction and the tally
-- with it. This prints exactly the same thing.
select t.snap('view', $q$select jsonb_pretty(jsonb_agg(to_jsonb(q) - 'league_id' - 'created_at'
                                                       - 'last_play_edit' order by q.league_name))
                        from app.platform_leagues() q$q$);
\echo '=== 4. The whole of what a platform owner can see about a league ==='
select t.tok('view') as everything_the_vendor_sees;

select t.val('he sees both leagues', $q$select count(*)::text from app.platform_leagues()$q$, '2');
select t.val('with the right team count',
  $q$select team_count::text from app.platform_leagues() where league_name='UYFC'$q$, '3');
select t.val('the right seat count',
  $q$select (coach_seats + board_seats)::text from app.platform_leagues() where league_name='UYFC'$q$, '7');
select t.val('the right head count, as a NUMBER',
  $q$select player_count::text from app.platform_leagues() where league_name='UYFC'$q$, '26');
select t.val('the right playbook size, as a NUMBER',
  $q$select play_count::text from app.platform_leagues() where league_name='UYFC'$q$, '4');
select t.val('the season dates',
  $q$select season_first_start::text || '..' || season_last_end::text
      from app.platform_leagues() where league_name='UYFC'$q$, '2019-08-01..2026-11-07');
select t.val('and the subscription state',
  $q$select status || '/' || plan || '/' || coalesce(seats_purchased::text,'-')
      from app.platform_leagues() where league_name='UYFC'$q$, 'active/season/12');
select t.val('a league we have not billed yet reads as active on no plan, not as suspended',
  $q$select status || '/' || plan from app.platform_leagues() where league_name='UYFC'$q$, 'active/season');

select t.val('per team, he gets counts and a grade',
  $q$select player_count::text || '/' || play_count::text || '/' || grade
      from app.platform_league('a0000000-0000-4000-8000-000000000001')
     where team_name='Lehi' and grade='8' and season_name='2026'$q$, '21/2/8');
select t.val('and three teams in that league',
  $q$select count(*)::text from app.platform_league('a0000000-0000-4000-8000-000000000001')$q$, '3');

-- THE SWEEP. Everything the seat can read, as text, hunted for a child.
select t.snap('sweep', $q$select t.platform_sweep()$q$);
reset role;

select t.val('the sweep really did capture the platform view',
  $q$select (t.tok('sweep') like '%UYFC%' and t.tok('sweep') like '%league_detail%')::text$q$, 'true');
select t.val('and it is not a trivial amount of text',
  $q$select (length(t.tok('sweep')) > 2000)::text$q$, 'true');
select t.val('NO CHILD''S SURNAME APPEARS ANYWHERE IN IT',
  $q$select count(*)::text from public.players p where t.tok('sweep') like '%' || p.last || '%'$q$, '0');
select t.val('nor any jersey number, drawn as a spot on a play',
  $q$select count(*)::text from public.plays pl, lateral jsonb_array_elements(pl.doc->'players') e
      where t.tok('sweep') like '%' || (e->>'player') || '%'$q$, '0');
select t.val('nor any play slug',
  $q$select count(*)::text from public.plays pl where t.tok('sweep') like '%' || pl.slug || '%'$q$, '0');
select t.val('nor any lane name off a play sheet',
  $q$select count(*)::text from (select distinct e->>'role' r from public.plays pl,
        lateral jsonb_array_elements(pl.doc->'players') e where e ? 'role') x
     where t.tok('sweep') like '%' || x.r || '%'$q$, '0');

-- Structural, not just empirical: no platform function even has an OUT column
-- that could carry one.
select t.val('no platform function returns a column that could hold a child',
  $q$select coalesce(string_agg(a, ','), '') from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace,
      lateral unnest(coalesce(p.proargnames, '{}')) a
     where n.nspname='app'
       and (p.proname like 'platform%' or p.proname in ('create_league','suspend_league','unsuspend_league'))
       and a in ('last','first','jersey','player','doc','slug','routes','looks','aim','job')$q$, '');

-- And the audit trail he is allowed to read holds no child in the first place.
select t.val('the staffing log names no child, so reading it cannot expose one',
  $q$select count(*)::text from public.auth_events e, public.players p
      where e::text like '%' || p.last || '%'$q$, '0');
select t.control('though the log is full of real staffing history',
  $q$select 1 from public.auth_events$q$, 20);

-- ===========================================================================
-- 5. He cannot write anything a tenant owns
-- ===========================================================================
select set_config('t.sect', '5 no tenant writes', false);
set role pd_authenticated;
select t.be('10000000-0000-4000-8000-000000000001', 'founder@example.com');

select t.raises('he cannot add a play',
  $q$insert into public.plays (team_id, slug, doc)
     values ('c0000000-0000-4000-8000-000000000001','vendor-play',
             '{"players":[{"id":"p0","label":"S"}]}'::jsonb)$q$, '42501');
select t.blocked('he cannot rewrite one',
  $q$update public.plays set doc = doc || '{"vendor":true}'::jsonb
      where team_id='c0000000-0000-4000-8000-000000000001'$q$);
select set_config('app.intent', 'delete_play', true);
select t.blocked('he cannot delete one, intent flag and all',
  $q$delete from public.plays where id='f0000000-0000-4000-8000-000000000001'$q$);
select set_config('app.intent', '', true);
select t.raises('he cannot add a child to a roster',
  $q$insert into public.players (team_id, last, jersey)
     values ('c0000000-0000-4000-8000-000000000001','Vendor','1')$q$, '42501');
select t.blocked('he cannot rename one',
  $q$update public.players set last='Redacted' where team_id='c0000000-0000-4000-8000-000000000001'$q$);
select t.blocked('he cannot delete one',
  $q$delete from public.players where id='e0000000-0000-4000-8000-000000000001'$q$);
select t.raises('he cannot staff a team',
  $q$insert into public.memberships (user_id, team_id, role)
     values ('d0000000-0000-4000-8000-00000000000a','c0000000-0000-4000-8000-000000000001','head')$q$, '42501');
select t.raises('he cannot edit a league''s rulebook',
  $q$update public.leagues set ruleset='{"min_plays":0}'::jsonb
      where id='a0000000-0000-4000-8000-000000000001'$q$, '42501');
-- He holds the UPDATE privilege on teams (every signed-in session does; that is
-- how a league admin renames one), so this is refused by the policy rather than
-- by the grant: USING matches nothing and the statement writes nothing. The
-- owner-side check below is what makes that a pass rather than a shrug.
select t.blocked('he cannot rename a team',
  $q$update public.teams set name='Ours now' where id='c0000000-0000-4000-8000-000000000001'$q$);
select t.raises('he cannot rotate a team''s player word',
  $q$select app.rotate_player_word('c0000000-0000-4000-8000-000000000001')$q$, '42501');
select t.raises('he cannot mint a team invitation to give himself a way in',
  $q$select * from app.issue_invite('founder@example.com','head','c0000000-0000-4000-8000-000000000001')$q$, '42501');
select t.raises('and he cannot set a league''s billing state by hand -- only through the logged function',
  $q$update public.league_platform_state set status='active'
      where league_id='a0000000-0000-4000-8000-000000000001'$q$, '42501');
reset role;

select t.val('after all of that, the playbook is untouched',
  $q$select count(*)::text from public.plays$q$, '6');
select t.val('and no play carries a vendor edit',
  $q$select count(*)::text from public.plays where doc ? 'vendor'$q$, '0');
select t.val('the roster is untouched',   $q$select count(*)::text from public.players$q$, '31');
select t.val('and nobody was staffed',    $q$select count(*)::text from public.memberships$q$, '7');
select t.val('and no team was renamed',
  $q$select name || ' ' || grade from public.teams where id='c0000000-0000-4000-8000-000000000001'$q$, 'Lehi 8');
select t.val('nor any league rulebook rewritten',
  $q$select (ruleset -> 'min_plays')::text from public.leagues where id='a0000000-0000-4000-8000-000000000001'$q$, '10');

-- ===========================================================================
-- 6. No tenant can call a platform function. With no credential, none of them.
-- ===========================================================================
select set_config('t.sect', '6 functions refuse', false);

-- The negative controls for the whole section. A refusal that returns an error
-- but leaves a row behind is not a refusal, and the mutation run found that the
-- error code alone was too thin a check here.
select t.snap('s6_invites', $q$select count(*)::text from public.invites$q$);
select t.snap('s6_leagues', $q$select count(*)::text from public.leagues$q$);
select t.snap('s6_seats',   $q$select count(*)::text from public.platform_owners$q$);
select t.snap('s6_state',   $q$select string_agg(league_id::text || '=' || status, ',' order by league_id::text)
                                 from public.league_platform_state$q$);
select t.snap('s6_trail',   $q$select count(*)::text from public.platform_events$q$);

set role pd_authenticated;

-- The whole surface, against the most powerful tenant in the fixture.
select t.be('d0000000-0000-4000-8000-000000000006', 'whitmore@example.com');
select t.raises('league admin: platform_leagues',   $q$select * from app.platform_leagues()$q$, '42501');
select t.raises('league admin: platform_league',    $q$select * from app.platform_league('a0000000-0000-4000-8000-000000000001')$q$, '42501');
select t.raises('league admin: platform_audit',     $q$select * from app.platform_audit('a0000000-0000-4000-8000-000000000001')$q$, '42501');
select t.raises('league admin: platform_trail',     $q$select * from app.platform_trail()$q$, '42501');
select t.raises('league admin: create_league',      $q$select app.create_league('Free League')$q$, '42501');
select t.raises('league admin: platform_invite_admin',
  $q$select * from app.platform_invite_admin('a0000000-0000-4000-8000-000000000002','me@example.com')$q$, '42501');
select t.raises('league admin: suspend_league (on a rival)',
  $q$select app.suspend_league('a0000000-0000-4000-8000-000000000002','because I can')$q$, '42501');
select t.raises('league admin: unsuspend_league',   $q$select app.unsuspend_league('a0000000-0000-4000-8000-000000000001')$q$, '42501');
select t.raises('league admin: grant_platform_owner',
  $q$select app.grant_platform_owner('d0000000-0000-4000-8000-000000000006','whitmore@example.com')$q$, '42501');
select t.raises('league admin: revoke_platform_owner',
  $q$select app.revoke_platform_owner('10000000-0000-4000-8000-000000000001')$q$, '42501');
select t.raises('league admin: platform_owners_list', $q$select * from app.platform_owners_list()$q$, '42501');
select t.raises('league admin: platform_note (a forgeable log is worse than none)',
  $q$select app.platform_note('leagues_list')$q$, '42501');
select t.raises('league admin: require_platform_owner',
  $q$select app.require_platform_owner('anything')$q$, '42501');
select t.raises('and he cannot even suspend HIS OWN league',
  $q$select app.suspend_league('a0000000-0000-4000-8000-000000000001')$q$, '42501');

-- The other seats, on the four that matter.
select t.be('d0000000-0000-4000-8000-000000000002', 'steve@example.com');
select t.raises('head coach: platform_leagues',   $q$select * from app.platform_leagues()$q$, '42501');
select t.raises('head coach: platform_audit',     $q$select * from app.platform_audit('a0000000-0000-4000-8000-000000000001')$q$, '42501');
select t.raises('head coach: create_league',      $q$select app.create_league('Steve United')$q$, '42501');
select t.raises('head coach: suspend_league',     $q$select app.suspend_league('a0000000-0000-4000-8000-000000000002')$q$, '42501');

select t.be('d0000000-0000-4000-8000-000000000005', 'reeves@example.com');
select t.raises('board member: platform_leagues', $q$select * from app.platform_leagues()$q$, '42501');
select t.raises('board member: platform_league',  $q$select * from app.platform_league('a0000000-0000-4000-8000-000000000001')$q$, '42501');
select t.raises('board member: platform_trail',   $q$select * from app.platform_trail()$q$, '42501');
select t.raises('board member: suspend_league',   $q$select app.suspend_league('a0000000-0000-4000-8000-000000000002')$q$, '42501');

select t.be('d0000000-0000-4000-8000-000000000001', 'dom@example.com');
select t.raises('assistant: platform_leagues',    $q$select * from app.platform_leagues()$q$, '42501');
select t.raises('assistant: create_league',       $q$select app.create_league('Dom FC')$q$, '42501');
select t.be('d0000000-0000-4000-8000-000000000003', 'parent@example.com');
select t.raises('helper: platform_leagues',       $q$select * from app.platform_leagues()$q$, '42501');
select t.be('d0000000-0000-4000-8000-00000000000a', 'stranger@example.com');
select t.raises('stranger: platform_leagues',     $q$select * from app.platform_leagues()$q$, '42501');
select t.raises('stranger: platform_owners_list', $q$select * from app.platform_owners_list()$q$, '42501');

-- Signed in as nobody.
select t.be(null, null);
select t.raises('no identity: platform_leagues',  $q$select * from app.platform_leagues()$q$, '42501');
select t.raises('no identity: create_league',     $q$select app.create_league('Nobody FC')$q$, '42501');
select t.raises('no identity: suspend_league',    $q$select app.suspend_league('a0000000-0000-4000-8000-000000000001')$q$, '42501');
select t.raises('no identity: platform_trail',    $q$select * from app.platform_trail()$q$, '42501');
reset role;

-- And anonymously, where the privilege check refuses before the seat check does.
set role pd_anon;
select t.be(null, null);
select t.raises('anon: platform_leagues',         $q$select * from app.platform_leagues()$q$, '42501');
select t.raises('anon: platform_league',          $q$select * from app.platform_league('a0000000-0000-4000-8000-000000000001')$q$, '42501');
select t.raises('anon: create_league',            $q$select app.create_league('Anon FC')$q$, '42501');
select t.raises('anon: platform_invite_admin',
  $q$select * from app.platform_invite_admin('a0000000-0000-4000-8000-000000000001','me@example.com')$q$, '42501');
select t.raises('anon: suspend_league',           $q$select app.suspend_league('a0000000-0000-4000-8000-000000000001')$q$, '42501');
select t.raises('anon: platform_owners_list',     $q$select * from app.platform_owners_list()$q$, '42501');
select t.val('anon can still ask whether it is the vendor, and is told no',
  $q$select app.is_platform_owner()::text$q$, 'false');
reset role;

select t.val('and none of that created a league', $q$select count(*)::text from public.leagues$q$, '2');
select t.val('nor a platform seat',               $q$select count(*)::text from public.platform_owners$q$, '2');
select t.unchanged('NOR ONE INVITATION -- no tenant minted an admin seat anywhere', 's6_invites',
  $q$select count(*)::text from public.invites$q$);
select t.unchanged('nor moved a league in or out of suspension', 's6_state',
  $q$select string_agg(league_id::text || '=' || status, ',' order by league_id::text)
      from public.league_platform_state$q$);
select t.unchanged('and not one line was added to the platform trail by a tenant', 's6_trail',
  $q$select count(*)::text from public.platform_events$q$);

-- ===========================================================================
-- 7. The four actions the master hub needs
-- ===========================================================================
select set_config('t.sect', '7 the hub actions', false);
set role pd_authenticated;
select t.be('10000000-0000-4000-8000-000000000001', 'founder@example.com');

-- Create a league.
select t.snap('newleague', $q$select app.create_league('Timp Valley Football',
  '{"field_goals_allowed": false, "min_plays": 10}'::jsonb, 'trial', 8)::text$q$);
select t.val('a league was created', $q$select (t.tok('newleague') is not null)::text$q$, 'true');
select t.val('and the platform now sees three',
  $q$select count(*)::text from app.platform_leagues()$q$, '3');
select t.val('the new one is empty, active and on a trial',
  $q$select status || '/' || plan || '/' || team_count::text || '/' || player_count::text
      from app.platform_leagues() where league_name='Timp Valley Football'$q$, 'active/trial/0/0');
select t.raises('a league still needs a name',   $q$select app.create_league('   ')$q$, '22023');

-- Invite its first admin. There is nobody in it yet, which is exactly why
-- app.issue_invite() cannot do this job: it wants an admin of the league.
select t.snap('admintok', $q$select token from app.platform_invite_admin(t.tok('newleague')::uuid, 'outsider@example.com')$q$);
select t.val('the token is a real one, not a stub',
  $q$select (length(t.tok('admintok')) = 64)::text$q$, 'true');
select t.raises('and no league admin seat can be opened on a league that does not exist',
  $q$select * from app.platform_invite_admin('a0000000-0000-4000-8000-0000000000ff','x@example.com')$q$, '22023');
select t.raises('nor addressed to nobody',
  $q$select * from app.platform_invite_admin(t.tok('newleague')::uuid, 'not-an-address')$q$, '22023');
reset role;
select t.val('the invitation is stored as a hash, never as the token',
  $q$select count(*)::text from public.invites where token_hash = t.tok('admintok')$q$, '0');
select t.val('and it is an ADMIN seat on that league, and nothing else',
  $q$select role || '/' || (league_id::text = t.tok('newleague'))::text || '/' || (team_id is null)::text
      from public.invites where email='outsider@example.com'$q$, 'admin/true/true');

-- Redeem it through the untouched auth.sql path.
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-00000000000e', 'outsider@example.com');
select t.val('the invitee redeems it and becomes the league admin',
  $q$select app.accept_invite(t.tok('admintok')) ->> 'result'$q$, 'joined');
select t.val('he can now read his league',   $q$select count(*)::text from public.leagues$q$, '1');
select t.val('and it is the right one',
  $q$select (id::text = t.tok('newleague'))::text from public.leagues$q$, 'true');
select t.rows('he cannot read anybody else''s',
  $q$select 1 from public.leagues where id='a0000000-0000-4000-8000-000000000001'$q$, 0);
select t.allowed('and he builds out his own season',
  $q$insert into public.seasons (id, league_id, name, starts_on, ends_on)
     values ('b0000000-0000-4000-8000-0000000000ff', t.tok('newleague')::uuid, '2027','2027-08-01','2027-11-01')$q$, 1);
select t.allowed('and his own team',
  $q$insert into public.teams (id, league_id, name, grade, season_id)
     values ('c0000000-0000-4000-8000-0000000000ff', t.tok('newleague')::uuid, 'Timp','8','b0000000-0000-4000-8000-0000000000ff')$q$, 1);
select t.rows('and he still cannot see one play of anybody''s', $q$select 1 from public.plays$q$, 0);

-- The vendor sees the growth, as numbers.
select t.be('10000000-0000-4000-8000-000000000001', 'founder@example.com');
select t.val('the platform sees the new team appear',
  $q$select team_count::text || '/' || board_seats::text
      from app.platform_leagues() where league_name='Timp Valley Football'$q$, '1/1');
select t.val('and per team, an empty roster and an empty book',
  $q$select player_count::text || '/' || play_count::text
      from app.platform_league(t.tok('newleague')::uuid)$q$, '0/0');

-- Re-sending kills the outstanding token, same rule as app.issue_invite().
select t.snap('admintok2', $q$select token from app.platform_invite_admin(t.tok('newleague')::uuid, 'second@example.com')$q$);
select t.snap('admintok3', $q$select token from app.platform_invite_admin(t.tok('newleague')::uuid, 'second@example.com')$q$);
reset role;
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-00000000000d', 'second@example.com');
select t.raises('the superseded token no longer works',
  $q$select app.accept_invite(t.tok('admintok2'))$q$, '22023');
select t.val('the re-sent one does',
  $q$select app.accept_invite(t.tok('admintok3')) ->> 'role'$q$, 'admin');
reset role;

-- ===========================================================================
-- 8. Suspension: it destroys nothing and it hides nothing
-- ===========================================================================
select set_config('t.sect', '8 suspension', false);

select t.snap('pre_teams',    $q$select count(*)::text from public.teams   where league_id='a0000000-0000-4000-8000-000000000001'$q$);
select t.snap('pre_seasons',  $q$select count(*)::text from public.seasons where league_id='a0000000-0000-4000-8000-000000000001'$q$);
select t.snap('pre_players',  $q$select count(*)::text from public.players$q$);
select t.snap('pre_plays',    $q$select count(*)::text from public.plays$q$);
select t.snap('pre_members',  $q$select count(*)::text from public.memberships$q$);
select t.snap('pre_board',    $q$select count(*)::text from public.league_memberships$q$);
select t.snap('pre_consents', $q$select count(*)::text from public.player_consents$q$);
select t.snap('pre_words',    $q$select count(*)::text from public.player_words$q$);
select t.snap('pre_docs',     $q$select md5(string_agg(p.doc::text, '|' order by p.id))
                                   from public.plays p$q$);

set role pd_authenticated;
select t.be('10000000-0000-4000-8000-000000000001', 'founder@example.com');
-- Through t.snap rather than as a bare statement, so a mutant that breaks the
-- seat cannot abort the transaction here and rob the run of its tally.
select t.snap('census', $q$select jsonb_pretty(app.suspend_league(
  'a0000000-0000-4000-8000-000000000001', 'invoice 90 days overdue'))$q$);
\echo '=== 8. Suspending a league, and the census it returns of what it left alone ==='
select t.tok('census') as suspension_returned;
select t.val('the suspension reports deleting nothing',
  $q$select (app.suspend_league('a0000000-0000-4000-8000-000000000001','still overdue') ->> 'deleted')$q$, '0');
select t.val('and reports what it left intact',
  $q$select (app.suspend_league('a0000000-0000-4000-8000-000000000001','still overdue')
             -> 'left_intact' ->> 'plays')$q$, '4');
reset role;

select t.unchanged('NO TEAM WAS DELETED',       'pre_teams',   $q$select count(*)::text from public.teams   where league_id='a0000000-0000-4000-8000-000000000001'$q$);
select t.unchanged('NO SEASON WAS DELETED',     'pre_seasons', $q$select count(*)::text from public.seasons where league_id='a0000000-0000-4000-8000-000000000001'$q$);
select t.unchanged('NO CHILD WAS DELETED',      'pre_players', $q$select count(*)::text from public.players$q$);
select t.unchanged('NO PLAY WAS DELETED',       'pre_plays',   $q$select count(*)::text from public.plays$q$);
select t.unchanged('NO SEAT WAS REMOVED',       'pre_members', $q$select count(*)::text from public.memberships$q$);
select t.unchanged('NO BOARD SEAT WAS REMOVED', 'pre_board',   $q$select count(*)::text from public.league_memberships$q$);
select t.unchanged('NO CONSENT WAS TOUCHED',    'pre_consents',$q$select count(*)::text from public.player_consents$q$);
select t.unchanged('NO PLAYER WORD WAS TOUCHED','pre_words',   $q$select count(*)::text from public.player_words$q$);
select t.unchanged('AND NOT ONE PLAY DOCUMENT CHANGED A BYTE', 'pre_docs',
  $q$select md5(string_agg(p.doc::text, '|' order by p.id)) from public.plays p$q$);
select t.val('no tombstone was written either',
  $q$select count(*)::text from public.player_tombstones where reason='parent_request'$q$, '0');

-- Nothing is hidden from the people already in the league.
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000001', 'dom@example.com');
select t.val('the coach of a suspended league still reads his plays',   $q$select count(*)::text from public.plays$q$, '3');
select t.val('and his roster',                                          $q$select count(*)::text from public.players$q$, '23');
select t.allowed('and can still edit a play -- practice does not stop because billing did',
  $q$update public.plays set doc = doc || '{"sweep":"left"}'::jsonb
      where team_id='c0000000-0000-4000-8000-000000000001'$q$, 2);
select t.be('d0000000-0000-4000-8000-000000000005', 'reeves@example.com');
select t.val('the board still sees its teams',   $q$select count(*)::text from public.teams$q$, '3');
select t.val('and the league can SEE that it is suspended',
  $q$select status from public.league_platform_state where league_id='a0000000-0000-4000-8000-000000000001'$q$, 'suspended');
select t.rows('while another league''s state is none of its business',
  $q$select 1 from public.league_platform_state where league_id='a0000000-0000-4000-8000-000000000002'$q$, 0);
select t.be('d0000000-0000-4000-8000-000000000006', 'whitmore@example.com');
select t.raises('and cannot reinstate itself by hand',
  $q$update public.league_platform_state set status='active'
      where league_id='a0000000-0000-4000-8000-000000000001'$q$, '42501');
select t.raises('nor by deleting the row that says so',
  $q$delete from public.league_platform_state where league_id='a0000000-0000-4000-8000-000000000001'$q$, '42501');

-- What suspension DOES do: no new seats.
select t.raises('a suspended league cannot mint a new invitation',
  $q$select * from app.issue_invite('newhire@example.com','board',null,'a0000000-0000-4000-8000-000000000001')$q$, '42501');
select t.raises('nor write a membership by hand',
  $q$insert into public.memberships (user_id, team_id, role)
     values ('d0000000-0000-4000-8000-00000000000a','c0000000-0000-4000-8000-000000000001','helper')$q$, '42501');
select t.be('d0000000-0000-4000-8000-000000000002', 'steve@example.com');
select t.raises('and a head coach in it cannot staff his team either',
  $q$select * from app.issue_invite('newhire@example.com','assistant','c0000000-0000-4000-8000-000000000001')$q$, '42501');
select t.be('d0000000-0000-4000-8000-00000000000b', 'newcoach@example.com');
select t.raises('an invitation issued BEFORE the suspension cannot be redeemed during it',
  $q$select app.accept_invite('seed-live-lehi8-assistant')$q$, '42501');
select t.be('d0000000-0000-4000-8000-000000000007', 'ostler@example.com');
select t.val('and the other league is entirely unaffected',
  $q$select count(*)::text from public.plays$q$, '1');
reset role;

-- Reinstated.
set role pd_authenticated;
select t.be('10000000-0000-4000-8000-000000000001', 'founder@example.com');
select t.val('the platform puts it back',
  $q$select app.unsuspend_league('a0000000-0000-4000-8000-000000000001') ->> 'status'$q$, 'active');
select t.be('d0000000-0000-4000-8000-000000000002', 'steve@example.com');
select t.val('and seats work again immediately',
  $q$select count(*)::text from app.issue_invite('newhire@example.com','assistant','c0000000-0000-4000-8000-000000000001')$q$, '1');
reset role;
select t.unchanged('and after all of it, every play is still there', 'pre_plays',
  $q$select count(*)::text from public.plays$q$);
select t.unchanged('and every child',                               'pre_players',
  $q$select count(*)::text from public.players$q$);

-- ===========================================================================
-- 9. Every cross-tenant read leaves a trail, and the trail is not editable
-- ===========================================================================
select set_config('t.sect', '9 the trail', false);

select t.snap('trail_before', $q$select count(*)::text from public.platform_events$q$);
set role pd_authenticated;
select t.be('10000000-0000-4000-8000-000000000002', 'cofounder@example.com');
select t.val('a read happens', $q$select count(*)::text from app.platform_leagues()$q$, '3');
reset role;
select t.val('and it is logged, once, against the person who did it',
  $q$select count(*)::text from public.platform_events
      where action='leagues_list' and actor='10000000-0000-4000-8000-000000000002'$q$, '1');
select t.val('with how much it returned, and not what',
  $q$select rows_returned::text from public.platform_events
      where action='leagues_list' and actor='10000000-0000-4000-8000-000000000002'$q$, '3');
-- Per-call, not cumulative: earlier sections read this league several times and
-- every one of those is in the table too, which is the property being claimed.
select t.snap('detail_before', $q$select count(*)::text from public.platform_events
                                    where action='league_detail'
                                      and league_id='a0000000-0000-4000-8000-000000000001'$q$);
set role pd_authenticated;
select t.be('10000000-0000-4000-8000-000000000002', 'cofounder@example.com');
select t.val('one more league read happens',
  $q$select count(*)::text from app.platform_league('a0000000-0000-4000-8000-000000000001')$q$, '3');
reset role;
select t.val('reading one league logs that league by id, once per call',
  $q$select (count(*) - t.tok('detail_before')::bigint)::text from public.platform_events
      where action='league_detail' and league_id='a0000000-0000-4000-8000-000000000001'$q$, '1');
select t.val('and so does reading its audit trail',
  $q$select count(*)::text from public.platform_events
      where action='audit_read' and league_id='a0000000-0000-4000-8000-000000000001'$q$, '1');
select t.val('every league_detail row in the table names a league -- none is anonymous',
  $q$select count(*)::text from public.platform_events
      where action in ('league_detail','audit_read') and league_id is null$q$, '0');
select t.val('the sale, the seat and the suspensions are all in it',
  $q$select string_agg(distinct action, ',' order by action) from public.platform_events
      where action in ('league_create','admin_invite','league_suspend','league_unsuspend')$q$,
  'admin_invite,league_create,league_suspend,league_unsuspend');
select t.val('the trail never copies a credential into itself',
  $q$select count(*)::text from public.platform_events e
      where e::text like '%' || t.tok('admintok') || '%'
         or e::text like '%' || t.tok('admintok3') || '%'$q$, '0');
select t.val('nor does the staffing log',
  $q$select count(*)::text from public.auth_events e
      where e::text like '%' || t.tok('admintok') || '%'$q$, '0');

-- Insert-only, against the person it is about.
set role pd_authenticated;
select t.be('10000000-0000-4000-8000-000000000001', 'founder@example.com');
select t.raises('THE PLATFORM OWNER CANNOT DELETE HIS OWN TRAIL',
  $q$delete from public.platform_events$q$, '42501');
select t.raises('cannot delete the one line about a league he looked at',
  $q$delete from public.platform_events where action='league_detail'$q$, '42501');
select t.raises('cannot rewrite one',
  $q$update public.platform_events set action='leagues_list' where action='audit_read'$q$, '42501');
select t.raises('cannot truncate the table',
  $q$truncate table public.platform_events$q$, '42501');
select t.raises('cannot forge a flattering one',
  $q$insert into public.platform_events (actor, action) values
     ('10000000-0000-4000-8000-000000000001','leagues_list')$q$, '42501');
select t.raises('and cannot pin one on the other founder',
  $q$insert into public.platform_events (actor, action) values
     ('10000000-0000-4000-8000-000000000002','league_suspend')$q$, '42501');
select t.be('d0000000-0000-4000-8000-000000000006', 'whitmore@example.com');
select t.raises('nor can a league admin delete the evidence of being looked at',
  $q$delete from public.platform_events$q$, '42501');
reset role;

-- And the owner cannot either. This is the half a privilege cannot cover.
select t.raises('NOT EVEN THE TABLE OWNER can rewrite a line',
  $q$update public.platform_events set detail='{"tidied":true}'::jsonb
      where id=(select min(id) from public.platform_events)$q$, '42501');
select t.raises('nor delete one',
  $q$delete from public.platform_events where id=(select min(id) from public.platform_events)$q$, '42501');
select t.raises('nor truncate the table',
  $q$truncate table public.platform_events$q$, '42501');
select t.val('and no foreign key can take a trail row with it',
  $q$select count(*)::text from pg_constraint
      where contype='f' and conrelid='public.platform_events'::regclass$q$, '0');

-- Who may read it. The league sees what we did in the league.
select t.snap('trail_uyfc', $q$select count(*)::text from public.platform_events
                                 where league_id='a0000000-0000-4000-8000-000000000001'$q$);
select t.control('there is something for the league to read',
  $q$select 1 from public.platform_events where league_id='a0000000-0000-4000-8000-000000000001'$q$, 3);
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000006', 'whitmore@example.com');
select t.unchanged('THE LEAGUE ADMIN SEES EXACTLY WHAT WE DID IN HIS LEAGUE', 'trail_uyfc',
  $q$select count(*)::text from public.platform_events where league_id='a0000000-0000-4000-8000-000000000001'$q$);
select t.rows('and nothing we did in anybody else''s',
  $q$select 1 from public.platform_events where league_id <> 'a0000000-0000-4000-8000-000000000001'$q$, 0);
select t.be('d0000000-0000-4000-8000-000000000005', 'reeves@example.com');
select t.unchanged('so does his board', 'trail_uyfc',
  $q$select count(*)::text from public.platform_events where league_id='a0000000-0000-4000-8000-000000000001'$q$);
select t.be('d0000000-0000-4000-8000-000000000009', 'barlow@example.com');
select t.rows('the other league''s board sees none of ours',
  $q$select 1 from public.platform_events where league_id='a0000000-0000-4000-8000-000000000001'$q$, 0);
select t.be('d0000000-0000-4000-8000-000000000002', 'steve@example.com');
select t.rows('a head coach is not shown the vendor''s movements',
  $q$select 1 from public.platform_events$q$, 0);
select t.be('d0000000-0000-4000-8000-00000000000a', 'stranger@example.com');
select t.rows('and a stranger sees nothing at all',
  $q$select 1 from public.platform_events$q$, 0);
reset role;

-- ===========================================================================
-- 10. The reads he makes about himself, and the one place a person is named
-- ===========================================================================
select set_config('t.sect', '10 named adults', false);
set role pd_authenticated;
select t.be('10000000-0000-4000-8000-000000000001', 'founder@example.com');
select t.val('the audit trail he reads carries adult email addresses',
  $q$select (count(*) > 0)::text from app.platform_audit('a0000000-0000-4000-8000-000000000001', 1000)
      where subject_email is not null$q$, 'true');
select t.val('every one of which is a coach or a board seat, not a child',
  $q$select count(*)::text from app.platform_audit('a0000000-0000-4000-8000-000000000001', 1000) a
      join public.players p on a.subject_email like '%' || p.last || '%'$q$, '0');
select t.val('and he can read back the invitations he himself sent, and no others',
  $q$select count(*)::text from public.auth_events
      where actor <> '10000000-0000-4000-8000-000000000001'$q$, '0');
select t.rows('which is auth.sql''s own rule (actor = me), not a platform policy',
  $q$select 1 from public.auth_events where action='membership_grant'
      and subject_user='d0000000-0000-4000-8000-000000000001'$q$, 0);
reset role;

-- ===========================================================================
-- 11. Vacuity check. Add the policy, add the grant, watch it leak.
-- ===========================================================================
select set_config('t.sect', '11 vacuity check', false);
create policy tmp_leak_plays   on public.plays   for select to pd_authenticated using (true);
create policy tmp_leak_players on public.players for select to pd_authenticated using (true);
set role pd_authenticated;
select t.be('10000000-0000-4000-8000-000000000001', 'founder@example.com');
\echo '=== 11. With one permissive policy added, the platform owner reads every play in the product ==='
select count(*) as plays_visible_with_bad_policy,
       count(*) filter (where team_id='c0000000-0000-4000-8000-000000000004') as other_league
  from public.plays;
select t.val('with USING(true): the vendor reads all 6 playbooks',
  $q$select count(*)::text from public.plays$q$, '6');
select t.val('with USING(true): and all 31 children by name',
  $q$select count(*)::text from public.players$q$, '31');
select t.val('including a real surname',
  $q$select last from public.players where id='e0000000-0000-4000-8000-000000000001'$q$, 'Archuletta');
reset role;
drop policy tmp_leak_plays   on public.plays;
drop policy tmp_leak_players on public.players;
set role pd_authenticated;
select t.be('10000000-0000-4000-8000-000000000001', 'founder@example.com');
select t.val('policy removed: back to nothing at all', $q$select count(*)::text from public.plays$q$, '0');
select t.val('and no children',                        $q$select count(*)::text from public.players$q$, '0');
reset role;

-- The seat table's refusals are the missing grant AND the missing policy.
grant select on public.platform_owners to pd_authenticated;
create policy tmp_leak_owners on public.platform_owners for select to pd_authenticated using (true);
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000006', 'whitmore@example.com');
select t.val('with a grant and a policy, a league admin enumerates the vendor',
  $q$select count(*)::text from public.platform_owners$q$, '2');
reset role;
drop policy tmp_leak_owners on public.platform_owners;
revoke select on public.platform_owners from pd_authenticated;
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000006', 'whitmore@example.com');
select t.raises('taken away again: refused', $q$select 1 from public.platform_owners$q$, '42501');
reset role;

-- ===========================================================================
-- Results
-- ===========================================================================
\echo ''
\echo '=== RESULTS ==='
select n, sect, name, case when ok then 'PASS' else '*** FAIL ***' end as result, detail
  from t.results order by n;

\echo ''
select count(*) as tests,
       count(*) filter (where ok)     as passed,
       count(*) filter (where not ok) as failed
  from t.results;

select sect,
       count(*) filter (where ok) as passed,
       count(*) filter (where not ok) as failed
  from t.results group by sect order by sect;

do $$
declare bad int;
begin
  select count(*) into bad from t.results where not ok;
  if bad > 0 then
    raise exception '% PLATFORM TEST(S) FAILED', bad;
  end if;
  raise notice 'all % platform tests passed', (select count(*) from t.results);
end $$;

rollback;

-- ===========================================================================
-- MUTATION LOG -- what happens when a guard in platform.sql is deliberately
-- broken.
--
-- A suite that stays green when the guard is removed is decoration. Each line
-- below was applied to a database built from schema.sql + rls.sql + auth.sql +
-- platform.sql + seed.sql + auth-seed.sql + platform-seed.sql, all three suites
-- were run, and the mutant was thrown away. The 183 tests in
-- test-isolation.sql and the 243 in test-auth.sql were run against every mutant
-- too: NOT ONE OF THEM MOVED, for any mutation on this list. That is the other
-- half of the claim -- platform.sql is additive, and breaking it cannot make
-- the tenant isolation or the invitation layer quietly wrong.
--
--   mutation                                                     tests failed
--   ------------------------------------------------------------ ------------
--   baseline (nothing broken)                                               0
--   revoke_platform_owner: allow revoking your own seat                    90  *
--   drop the platform_owners guard trigger entirely                        64  *
--   platform_owners guard: drop the tenant-separation half                 62  *
--   tenant_seat_guard: drop the platform-owner half (seat can be staffed)  38  **
--   require_platform_owner: accept any signed-in user                      35
--   require_platform_owner: accept a NULL identity too                     10
--   platform_note: stop writing the trail                                   9
--   grant update/delete on league_platform_state to tenants                 9
--   select policy on plays for is_platform_owner()                          7
--   suspend_league: delete the league's plays                               7
--   is_platform_owner(): true for everybody signed in                       7
--   grant select on platform_owners + a permissive policy                   6
--   grant insert/update/delete on platform_events to tenants                5
--   suspend_league: strip the league's memberships instead                  5
--   grant select on platform_owners, no policy added                        5
--   select policy on players for is_platform_owner()                        4
--   drop the platform_events append-only triggers                           4
--   platform_events_select -> using (true)                                  4
--   tenant_seat_guard: drop the suspension half (new seats during it)       4
--   platform_invite_admin: drop the platform-owner check                    4
--   platform_league: append a child's surname to the team name              3
--   platform_owners guard: drop the explicit-intent half                    2
--   grant execute on app.platform_note to pd_authenticated                  2
--   ALTER TABLE platform_owners NO FORCE ROW LEVEL SECURITY                 1
--   platform_invite_admin: stop superseding the outstanding token           1
--   grant execute on app.require_platform_owner to pd_authenticated         0  ***
--
--   *   The three worst numbers are all the same failure: a tenant ends up
--       holding the seat. With the guard trigger gone the suite's own attacks
--       succeed -- a head coach, a board member and a league admin all land in
--       platform_owners -- and then the league admin, now a platform owner,
--       REVOKES THE FOUNDER'S SEAT. The same thing happens from the other end
--       when revoking your own seat is allowed: the founder revokes himself in
--       section 2 and every platform call after it fails. That last mutant is
--       also what taught this suite to catch instead of explode: t.snap used to
--       let the error out, the transaction aborted at the first
--       app.create_league(), and the run printed no tally at all. "It exploded"
--       is a worse report than "90 tests went red", so t.snap now records a
--       failed snapshot and carries on, and the two remaining bare platform
--       calls in the file (the section 4 view and the section 8 census) were
--       moved behind it. That is the most useful thing this mutation run
--       produced, and it was a hole in the tests rather than in platform.sql.
--
--   **  Worth reading closely, because it is the whole argument for the
--       separation rule. Nothing about the platform functions changes in this
--       mutant. What changes is that the vendor can accept a team invitation --
--       and section 3 immediately turns red, because he is now a helper on a
--       team and reads its playbook and its roster by the ordinary coach
--       policies. The separation rule is what lets "a platform owner cannot
--       read a play" be said with no "unless" on the end of it.
--
--   *** Not a mutation, and kept rather than dropped. Granting a tenant EXECUTE
--       on app.require_platform_owner() changes nothing, because the function's
--       entire body is the refusal: a league admin who calls it gets the same
--       42501 he got from the missing grant. Measured, not assumed. The missing
--       grant is a second lock on a door that is already locked -- unlike
--       app.platform_note(), where the grant IS the lock, and granting it
--       immediately lets a tenant write lines into the vendor's audit trail.
--
--   Two more that are quieter than they look:
--     * NO FORCE ROW LEVEL SECURITY on platform_owners fails exactly one test,
--       the structural one in section 1, and no attack at all. That is correct
--       and the test is still worth having: nobody holds a grant on the table,
--       so FORCE has nothing to bind today. It is the guard that matters on the
--       day somebody adds a grant for a screen, which is precisely the change
--       that would arrive without a policy to go with it.
--     * Dropping the explicit-intent half of the bootstrap guard fails only 2,
--       because that half exists to bind the MIGRATION ROLE, and the migration
--       role is not an attacker in the fixture -- no tenant can reach the table
--       either way. Two tests are the right number for a guard whose whole job
--       is to stop a deploy script creating a vendor seat by accident.
-- ===========================================================================
