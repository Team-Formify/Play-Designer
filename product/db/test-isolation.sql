-- product/db/test-isolation.sql
-- The adversarial suite. A policy that has not been attacked is not a policy.
--
-- RUN:
--   node product/db/test.mjs isolation
--
-- That builds pd_t_isolation from product/db/migrations/ via the migration runner and
-- applies the seeds in order, then runs this file. The hand-ordered list of
-- -f flags that used to live here was wrong twice and is now in test.mjs,
-- executed rather than described.
--
-- Against a database you have already built:
--   psql -h /tmp -p 5433 -U app -d pd_t_isolation -f product/db/test-isolation.sql
--
-- Everything runs inside one transaction and ROLLS BACK, so the suite is
-- rerunnable and leaves the seed untouched.
--
-- TWO HOUSE RULES, because a test that passes by querying nothing is worse than
-- no test:
--
--   (a) Every attack is paired with a CONTROL run as the owner (who bypasses
--       RLS) proving the rows are really there to be stolen. An attack whose
--       control returns 0 is reported as a broken test, not as a pass.
--   (b) Attacks address the other tenant's rows by literal uuid, never by
--       `(select id from teams where name='Logan')`. That subselect returns NULL
--       under RLS, so the attack would "pass" because it asked about nothing.
--       Hardcoded ids are the honest version.
--
-- And once, in section 3c, the suite briefly ADDS a permissive policy and shows
-- the same attack succeeding -- so nobody has to take the controls on faith.

\set ON_ERROR_STOP on
\timing off
\pset pager off

begin;

-- ===========================================================================
-- Harness
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

-- Count the rows an attack gets back. Want 0 for a blocked read.
create function t.rows(p_name text, p_sql text, p_want bigint) returns void
language plpgsql as $fn$
declare got bigint;
begin
  execute 'select count(*) from (' || p_sql || ') _q' into got;
  perform t.note(p_name, got = p_want,
    format('%s row(s), want %s', got, p_want) ||
    case when got > p_want then '   <== LEAK' else '' end);
exception when others then
  -- An error here is never a pass: an RLS side channel that throws is a leak.
  perform t.note(p_name, false, format('ERROR %s: %s', sqlstate, left(sqlerrm, 100)));
end $fn$;

-- The control half of every pair: the rows exist, run as the bypassing owner.
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

-- A write attack is blocked either by WITH CHECK (an error) or by USING
-- (silently zero rows). Both are a pass; anything that lands rows is a leak.
-- A syntax or typo error is a FAIL -- otherwise a broken test looks like a win.
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

-- Remembers a value now so a later section can prove it did not move. There are
-- deliberately NO SAVEPOINTs in this file: rolling back to a savepoint would
-- also roll back the results table, and a suite that loses its own findings is
-- how you end up reporting 79 passes out of an unknown number of tests.
create table t.state (k text primary key, v text);
grant select, insert, update on t.state to public;

create function t.snap(p_key text, p_sql text) returns void
language plpgsql as $fn$
declare got text;
begin
  execute p_sql into got;
  insert into t.state (k, v) values (p_key, got)
    on conflict (k) do update set v = excluded.v;
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

-- The performance rule, measured. A membership lookup written as
-- `team_id in (select app.team_ids())` has no outer reference, so the planner
-- hashes it ONCE per statement -- "hashed SubPlan", loops=1 -- instead of
-- calling it per row.
create function t.subplan_once(p_name text, p_sql text) returns void
language plpgsql as $fn$
declare line text; n_set int := 0; n_bad int := 0;
begin
  for line in execute 'explain (analyze, costs off, timing off, summary off) ' || p_sql loop
    if line like '%ProjectSet%' then
      n_set := n_set + 1;
      if line not like '%loops=1)%' then n_bad := n_bad + 1; end if;
    end if;
  end loop;
  perform t.note(p_name, n_set > 0 and n_bad = 0,
    format('%s membership subplan node(s), %s of them re-run per row', n_set, n_bad));
end $fn$;

create function t.plan_has(p_name text, p_sql text, p_needle text) returns void
language plpgsql as $fn$
declare line text; blob text := '';
begin
  for line in execute 'explain (costs off) ' || p_sql loop blob := blob || line || E'\n'; end loop;
  perform t.note(p_name, blob like '%' || p_needle || '%',
    format('plan %s %s', case when blob like '%'||p_needle||'%' then 'contains' else 'MISSING' end, p_needle));
end $fn$;

-- Become somebody. This is the whole point of the suite: the connection is a
-- superuser and a superuser bypasses RLS even with FORCE, so every attack is
-- made from inside pd_authenticated / pd_anon.
create function t.be(p_user uuid) returns void
language plpgsql as $fn$
begin
  perform set_config('app.user_id', coalesce(p_user::text, ''), false);
end $fn$;

grant execute on all functions in schema t to public;

-- ===========================================================================
-- 0. CONTROL -- what is actually in the database, seen by the bypassing owner
-- ===========================================================================
select set_config('t.sect', '0 control', false);
\echo '=== 0. What exists (owner, RLS bypassed) ==='
select (select count(*) from public.leagues)   as leagues,
       (select count(*) from public.teams)     as teams,
       (select count(*) from public.players)   as players,
       (select count(*) from public.plays)     as plays,
       (select count(*) from public.memberships) as memberships,
       (select count(*) from public.player_consents) as consents;

select t.control('players exist',           $q$select 1 from public.players$q$, 31);
select t.control('plays exist',             $q$select 1 from public.plays$q$, 6);
select t.control('two leagues exist',       $q$select 1 from public.leagues$q$, 2);
select t.control('logan players exist',     $q$select 1 from public.players where team_id='c0000000-0000-4000-8000-000000000004'$q$, 3);
select t.control('logan plays exist',       $q$select 1 from public.plays   where team_id='c0000000-0000-4000-8000-000000000004'$q$, 1);
select t.control('three players wear 22',   $q$select 1 from public.players where jersey='22'$q$, 3);
select t.control('punt-base on 3 teams',    $q$select 1 from public.plays where slug='punt-base'$q$, 3);

-- ===========================================================================
-- 1. Identity plumbing
-- ===========================================================================
select set_config('t.sect', '1 identity', false);
set role pd_authenticated;
select t.be(null);
select t.val('no GUC  -> auth.uid() is NULL', $q$select auth.uid()::text$q$, null);
select t.be('d0000000-0000-4000-8000-000000000001');
select t.val('GUC set -> auth.uid() is the user', $q$select auth.uid()::text$q$, 'd0000000-0000-4000-8000-000000000001');
select set_config('app.user_id', 'not-a-uuid', false);
select t.val('malformed identity fails closed to NULL', $q$select auth.uid()::text$q$, null);
select t.rows('malformed identity sees no players', $q$select 1 from public.players$q$, 0);
-- The performance rule, checked rather than asserted: the membership lookup must
-- appear ONCE as an InitPlan, not as a per-row function call.
select t.be('d0000000-0000-4000-8000-000000000001');
select t.plan_has('membership lookup is hashed, not per-row', $q$select id from public.players$q$, 'hashed SubPlan');
select t.subplan_once('membership lookup runs once per statement', $q$select id from public.players$q$);
reset role;

\echo '=== 1b. The RLS-filtered plan (as a tenant) ==='
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000001');
explain (costs off) select id, last from public.players;
reset role;

-- ===========================================================================
-- 2. Nobody at all
-- ===========================================================================
select set_config('t.sect', '2 anonymous', false);
set role pd_anon;
select t.be(null);
select t.rows('anon: leagues',            $q$select 1 from public.leagues$q$, 0);
select t.rows('anon: seasons',            $q$select 1 from public.seasons$q$, 0);
select t.rows('anon: teams',              $q$select 1 from public.teams$q$, 0);
select t.rows('anon: memberships',        $q$select 1 from public.memberships$q$, 0);
select t.rows('anon: league_memberships', $q$select 1 from public.league_memberships$q$, 0);
select t.rows('anon: players',            $q$select 1 from public.players$q$, 0);
select t.rows('anon: plays',              $q$select 1 from public.plays$q$, 0);
select t.rows('anon: player_consents',    $q$select 1 from public.player_consents$q$, 0);
select t.rows('anon: player_tombstones',  $q$select 1 from public.player_tombstones$q$, 0);
select t.rows('anon: count(*) leaks no total', $q$select count(*) c from public.players having count(*) > 0$q$, 0);
reset role;

set role pd_authenticated;
-- A real, well-formed uuid that simply is not a member of anything.
select t.be('d0000000-0000-4000-8000-00000000000a');
select t.rows('stranger with a valid uuid: players', $q$select 1 from public.players$q$, 0);
select t.rows('stranger with a valid uuid: plays',   $q$select 1 from public.plays$q$, 0);
select t.rows('stranger with a valid uuid: teams',   $q$select 1 from public.teams$q$, 0);
select t.blocked('stranger cannot insert a play',
  $q$insert into public.plays (team_id, slug, doc) values ('c0000000-0000-4000-8000-000000000001','stolen','{"players":[{"id":"p0"}]}')$q$);
reset role;

-- ===========================================================================
-- 3. Dom -- assistant on Lehi 8 (2026) and Lehi 8 (2019). The everyday tenant.
-- ===========================================================================
select set_config('t.sect', '3 coach A reads', false);
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000001');

\echo '=== 3. Coach A (Dom, Lehi) reading players: 23 of the 31 that exist ==='
select count(*) as players_visible from public.players;
select team_id, count(*) from public.players group by team_id order by 1;

select t.val('count(*) on players does not leak the total', $q$select count(*)::text from public.players$q$, '23');
select t.rows('sees only his two teams'' rosters',
  $q$select 1 from public.players where team_id in ('c0000000-0000-4000-8000-000000000001','c0000000-0000-4000-8000-000000000003')$q$, 23);
select t.rows('other league''s roster, addressed by literal team_id',
  $q$select 1 from public.players where team_id = 'c0000000-0000-4000-8000-000000000004'$q$, 0);
select t.rows('same league, other team''s roster (Lehi 7)',
  $q$select 1 from public.players where team_id = 'c0000000-0000-4000-8000-000000000002'$q$, 0);
select t.rows('crafted where: everything that is not mine',
  $q$select 1 from public.players where team_id <> 'c0000000-0000-4000-8000-000000000001'  and team_id <> 'c0000000-0000-4000-8000-000000000003'$q$, 0);
select t.rows('crafted where: 1=1 or true',
  $q$select 1 from public.players where 1=1 or true$q$, 23);
select t.rows('jersey 22 -- three exist, he may see one',
  $q$select 1 from public.players where jersey = '22'$q$, 1);
select t.val('and it is HIS 22',
  $q$select last from public.players where jersey = '22'$q$, 'Martinez');
select t.rows('another team''s player by primary key',
  $q$select 1 from public.players where id = 'e0000000-0000-4000-8000-000000000050'$q$, 0);

-- Qual-ordering side channel. Logan has a player whose jersey is 'TBD'. If the
-- planner ran this user qual before the RLS qual, the cast would throw 22P02 and
-- the error itself would prove a hidden row exists. t.rows() counts any error as
-- a failure, which is the point.
select t.rows('side channel: jersey::int cannot see a hidden non-numeric row',
  $q$select 1 from public.players where jersey::int > 0$q$, 22);

select t.rows('plays: his three, not the other six',  $q$select 1 from public.plays$q$, 3);
select t.rows('other team''s play by primary key',
  $q$select 1 from public.plays where id = 'f0000000-0000-4000-8000-000000000004'$q$, 0);
select t.rows('cross-league join: plays x teams x leagues',
  $q$select 1 from public.plays p join public.teams t on t.id = p.team_id
      where t.league_id = 'a0000000-0000-4000-8000-000000000002'$q$, 0);
select t.rows('jsonb hunt for another team''s scheme',
  $q$select 1 from public.plays where doc->>'name' like '%Logan%'$q$, 0);
select t.rows('teams: his two only',                  $q$select 1 from public.teams$q$, 2);
select t.rows('leagues: UYFC yes',                    $q$select 1 from public.leagues where id='a0000000-0000-4000-8000-000000000001'$q$, 1);
select t.rows('leagues: Cache Valley no',             $q$select 1 from public.leagues where id='a0000000-0000-4000-8000-000000000002'$q$, 0);
select t.val('another league''s rulebook reads NULL',
  $q$select app.league_rule('a0000000-0000-4000-8000-000000000002','8','field_goals_allowed')::text$q$, null);
select t.val('his own league''s rulebook reads',
  $q$select app.league_rule('a0000000-0000-4000-8000-000000000001','8','field_goals_allowed')::text$q$, 'false');
select t.rows('helper functions leak nothing: board_team_ids',
  $q$select 1 from app.board_team_ids()$q$, 0);
select t.rows('helper functions: team_ids is exactly his two',
  $q$select 1 from app.team_ids()$q$, 2);
select t.rows('consents of another team',
  $q$select 1 from public.player_consents where team_id='c0000000-0000-4000-8000-000000000004'$q$, 0);
reset role;

select t.control('lehi 7 roster exists', $q$select 1 from public.players where team_id='c0000000-0000-4000-8000-000000000002'$q$, 3);
select t.control('logan consent exists', $q$select 1 from public.player_consents where team_id='c0000000-0000-4000-8000-000000000004'$q$, 1);

-- ---------------------------------------------------------------------------
-- 3b. Write attacks. Reading was refused; now try to change, take, or move.
-- ---------------------------------------------------------------------------
select set_config('t.sect', '3b coach A writes', false);
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000001');

select t.blocked('UPDATE another team''s play',
  $q$update public.plays set doc = doc || '{"stolen":true}' where team_id='c0000000-0000-4000-8000-000000000004'$q$);
select t.blocked('UPDATE another team''s play by id',
  $q$update public.plays set slug='mine-now' where id='f0000000-0000-4000-8000-000000000004'$q$);
select t.blocked('UPDATE another team''s player',
  $q$update public.players set last='Redacted' where team_id='c0000000-0000-4000-8000-000000000004'$q$);
select t.blocked('DELETE another team''s player',
  $q$delete from public.players where id='e0000000-0000-4000-8000-000000000050'$q$);
select t.blocked('DELETE every player outside his own two teams',
  $q$delete from public.players
      where team_id not in ('c0000000-0000-4000-8000-000000000001','c0000000-0000-4000-8000-000000000003')$q$);
select t.blocked('UPDATE a same-league sibling team''s roster (Lehi 7)',
  $q$update public.players set jersey='00' where team_id='c0000000-0000-4000-8000-000000000002'$q$);

-- The unbounded sweep. This one is ALLOWED to write -- to his own three plays,
-- and to nothing else. An unqualified UPDATE is the shape of the mistake RLS
-- exists to contain, so it is worth watching it get contained.
select t.allowed('an unqualified UPDATE reaches only his own three plays',
  $q$update public.plays set doc = doc || '{"sweep":true}'$q$, 3);

-- Delete play intent is transaction-local and set immediately before the
-- statement, exactly as the app would. It does not buy him another team's play.
select set_config('app.intent', 'delete_play', true);
select t.blocked('DELETE another team''s play, even holding Delete play intent',
  $q$delete from public.plays where team_id='c0000000-0000-4000-8000-000000000004'$q$);
select set_config('app.intent', '', true);

-- WITH CHECK, not USING: these rows are perfectly legal, just not his to write.
select t.raises('INSERT a play onto another team (WITH CHECK)',
  $q$insert into public.plays (team_id, slug, doc)
     values ('c0000000-0000-4000-8000-000000000004','trojan','{"players":[{"id":"p0","player":"x"}]}')$q$, '42501');
select t.raises('INSERT a player onto another team (WITH CHECK)',
  $q$insert into public.players (team_id, last, jersey)
     values ('c0000000-0000-4000-8000-000000000004','Mole','99')$q$, '42501');
select t.raises('MOVE his own play into another team (WITH CHECK)',
  $q$update public.plays set team_id='c0000000-0000-4000-8000-000000000004'
      where id='f0000000-0000-4000-8000-000000000001'$q$, '42501');
-- Note, measured rather than assumed: this one is refused twice over. Setting
-- the UPDATE policy's WITH CHECK to true still refuses it, because the new row
-- also has to satisfy the SELECT policy. The INSERT cases above are the clean
-- WITH CHECK proof -- an INSERT has no USING clause, so WITH CHECK is the only
-- thing standing there, and mutating it to `true` fails 12 of these tests.
select t.raises('MOVE his own player into a sibling team (WITH CHECK)',
  $q$update public.players set team_id='c0000000-0000-4000-8000-000000000002'
      where id='e0000000-0000-4000-8000-000000000009'$q$, '42501');
select t.raises('INSERT a consent onto another team''s player (WITH CHECK)',
  $q$insert into public.player_consents (player_id, team_id, granted_by, scope)
     values ('e0000000-0000-4000-8000-000000000050','c0000000-0000-4000-8000-000000000004',
             'd0000000-0000-4000-8000-000000000001','photo')$q$, '42501');

-- Privilege escalation. If any of these worked, isolation would be one INSERT deep.
select t.raises('write himself into another league''s team',
  $q$insert into public.memberships (user_id, team_id, role)
     values ('d0000000-0000-4000-8000-000000000001','c0000000-0000-4000-8000-000000000004','head')$q$, '42501');
select t.raises('write himself into a sibling team in his own league',
  $q$insert into public.memberships (user_id, team_id, role)
     values ('d0000000-0000-4000-8000-000000000001','c0000000-0000-4000-8000-000000000002','head')$q$, '42501');
select t.raises('an assistant cannot staff even his own team',
  $q$insert into public.memberships (user_id, team_id, role)
     values ('d0000000-0000-4000-8000-00000000000a','c0000000-0000-4000-8000-000000000001','helper')$q$, '42501');
select t.blocked('an assistant cannot promote himself to head',
  $q$update public.memberships set role='head'
      where user_id='d0000000-0000-4000-8000-000000000001' and team_id='c0000000-0000-4000-8000-000000000001'$q$);
select t.raises('appoint himself to his own league''s board',
  $q$insert into public.league_memberships (user_id, league_id, role)
     values ('d0000000-0000-4000-8000-000000000001','a0000000-0000-4000-8000-000000000001','admin')$q$, '42501');
select t.raises('appoint himself to the OTHER league''s board',
  $q$insert into public.league_memberships (user_id, league_id, role)
     values ('d0000000-0000-4000-8000-000000000001','a0000000-0000-4000-8000-000000000002','admin')$q$, '42501');
select t.raises('rewrite his league''s rulebook (no write policy at all)',
  $q$update public.leagues set ruleset = '{"min_plays":0}'
      where id='a0000000-0000-4000-8000-000000000001'$q$, '42501');
select t.raises('forge a tombstone',
  $q$insert into public.player_tombstones (player_id, team_id, jersey)
     values ('e0000000-0000-4000-8000-000000000050','c0000000-0000-4000-8000-000000000004','22')$q$, '42501');
select t.raises('run the retention job by hand',
  $q$select app.expire_season_rosters()$q$, '42501');

-- Two shapes that have historically walked around a naive tenant filter: an
-- upsert (the INSERT is refused, so the DO UPDATE never gets a turn) and a
-- writing CTE (the policy follows the DELETE into the CTE).
select t.raises('UPSERT onto another team''s existing play',
  $q$insert into public.plays (team_id, slug, doc)
     values ('c0000000-0000-4000-8000-000000000004','punt-base','{"players":[{"id":"p0","player":"x"}]}')
     on conflict (team_id, slug) do update set doc = excluded.doc$q$, '42501');
-- Deliberately written so that the ONLY thing that can stop it is the players
-- DELETE policy: the outer statement is a plain SELECT the tenant may run, so a
-- pass cannot come from a missing grant somewhere else.
select t.val('a writing CTE does not escape the policy',
  $q$with taken as (delete from public.players
                     where team_id='c0000000-0000-4000-8000-000000000004' returning 1)
    select count(*)::text from taken$q$, '0');
select t.rows('a reading CTE does not escape it either',
  $q$with everyone as (select * from public.players) select 1 from everyone
      where team_id='c0000000-0000-4000-8000-000000000004'$q$, 0);
select t.val('he cannot enumerate the platform''s memberships',
  $q$select count(*)::text from public.memberships$q$, '4');
select t.val('nor its board',
  $q$select count(*)::text from public.league_memberships$q$, '0');

-- Existence side channel: does a unique violation report on a row he cannot see?
-- Logan already holds slug 'punt-base'. 42501 means the policy answered first.
-- 23505 would be the index confessing that somebody else's row is there.
select t.raises('a unique violation does not confess another team''s slug',
  $q$insert into public.plays (team_id, slug, doc)
     values ('c0000000-0000-4000-8000-000000000004','punt-base','{"players":[{"id":"p0","player":"x"}]}')$q$, '42501');
select t.raises('nor another team''s jersey number',
  $q$insert into public.players (team_id, last, jersey)
     values ('c0000000-0000-4000-8000-000000000004','Mole','22')$q$, '42501');

reset role;
\echo '=== 3b. After every write attack: whose plays actually changed? ==='
select t.name, t.grade, l.name as league, p.slug, (p.doc ? 'sweep') as touched_by_the_sweep
  from public.plays p join public.teams t on t.id=p.team_id join public.leagues l on l.id=t.league_id
 order by l.name, t.grade, p.slug;

select t.val('the sweep landed on 3 plays',
  $q$select count(*)::text from public.plays where doc ? 'sweep'$q$, '3');
select t.val('all 3 of them are his own team''s',
  $q$select count(*)::text from public.plays
      where doc ? 'sweep' and team_id in ('c0000000-0000-4000-8000-000000000001','c0000000-0000-4000-8000-000000000003')$q$, '3');
select t.val('nothing of another team''s was stolen or renamed',
  $q$select count(*)::text from public.plays where doc ? 'stolen' or slug='mine-now' or slug='trojan'$q$, '0');
select t.control('logan play survived every attack',
  $q$select 1 from public.plays where id='f0000000-0000-4000-8000-000000000004' and slug='punt-base'$q$, 1);
select t.val('logan roster survived intact',
  $q$select count(*)::text from public.players where team_id='c0000000-0000-4000-8000-000000000004'$q$, '3');
select t.val('no membership was forged',        $q$select count(*)::text from public.memberships$q$, '7');
select t.val('no board seat was forged',        $q$select count(*)::text from public.league_memberships$q$, '3');
select t.val('no tombstone was forged',         $q$select count(*)::text from public.player_tombstones$q$, '0');
-- tidy up the sweep so later sections read clean
update public.plays set doc = doc - 'sweep' where doc ? 'sweep';

-- ---------------------------------------------------------------------------
-- 3c. Proof the controls above are not theatre: add a permissive policy and
--     watch the identical query leak everything. Then take it away again.
-- ---------------------------------------------------------------------------
select set_config('t.sect', '3c vacuity check', false);
create policy tmp_leak_players on public.players for select to pd_authenticated using (true);
create policy tmp_leak_plays   on public.plays   for select to pd_authenticated using (true);
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000001');
\echo '=== 3c. With one permissive policy added, the SAME query leaks everything ==='
select count(*) as players_visible_with_bad_policy,
       count(*) filter (where team_id='c0000000-0000-4000-8000-000000000004') as logan_rows_now_visible
  from public.players;
select t.val('with USING(true): he now sees all 31 players', $q$select count(*)::text from public.players$q$, '31');
select t.val('with USING(true): he now sees all 6 plays',    $q$select count(*)::text from public.plays$q$, '6');
select t.val('with USING(true): Logan''s roster is readable',
  $q$select count(*)::text from public.players where team_id='c0000000-0000-4000-8000-000000000004'$q$, '3');
reset role;
drop policy tmp_leak_players on public.players;
drop policy tmp_leak_plays   on public.plays;
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000001');
select t.val('policy removed: back to his 23',  $q$select count(*)::text from public.players$q$, '23');
select t.val('policy removed: back to his 3',   $q$select count(*)::text from public.plays$q$, '3');
reset role;

-- ===========================================================================
-- 4. Roles inside one team: head staffs, assistant coaches, helper reads
-- ===========================================================================
select set_config('t.sect', '4 roles', false);
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000002');   -- Steve, head of Lehi 8
select t.allowed('head CAN staff his own team',
  $q$insert into public.memberships (user_id, team_id, role)
     values ('d0000000-0000-4000-8000-00000000000a','c0000000-0000-4000-8000-000000000001','helper')$q$, 1);
select t.raises('head CANNOT staff a team he does not run',
  $q$insert into public.memberships (user_id, team_id, role)
     values ('d0000000-0000-4000-8000-00000000000a','c0000000-0000-4000-8000-000000000002','helper')$q$, '42501');
select t.allowed('head CAN remove staff from his own team',
  $q$delete from public.memberships
      where user_id='d0000000-0000-4000-8000-00000000000a' and team_id='c0000000-0000-4000-8000-000000000001'$q$, 1);
select t.allowed('coach CAN edit his own play',
  $q$update public.plays set doc = doc || '{"note":"edited"}' where id='f0000000-0000-4000-8000-000000000001'$q$, 1);
select t.allowed('and undo it',
  $q$update public.plays set doc = doc - 'note' where id='f0000000-0000-4000-8000-000000000001'$q$, 1);

select t.be('d0000000-0000-4000-8000-000000000003');   -- the parent helper
select t.val('helper reads the roster',  $q$select count(*)::text from public.players$q$, '21');
select t.val('helper reads the plays',   $q$select count(*)::text from public.plays$q$, '2');
select t.blocked('helper cannot edit a play',
  $q$update public.plays set doc = doc || '{"helper":true}' where team_id='c0000000-0000-4000-8000-000000000001'$q$);
select t.raises('helper cannot add a player',
  $q$insert into public.players (team_id, last, jersey) values ('c0000000-0000-4000-8000-000000000001','Ghost','00')$q$, '42501');
select t.blocked('helper cannot delete a player',
  $q$delete from public.players where id='e0000000-0000-4000-8000-000000000009'$q$);
select set_config('app.intent', 'delete_play', true);
select t.blocked('helper cannot delete a play, even holding intent',
  $q$delete from public.plays where id='f0000000-0000-4000-8000-000000000001'$q$);
select set_config('app.intent', '', true);
select t.raises('helper cannot staff the team',
  $q$insert into public.memberships (user_id, team_id, role)
     values ('d0000000-0000-4000-8000-00000000000a','c0000000-0000-4000-8000-000000000001','head')$q$, '42501');
reset role;
select t.val('the helper changed nothing',
  $q$select count(*)::text from public.plays where doc ? 'helper'$q$, '0');

-- ===========================================================================
-- 5. The board: league-wide oversight, no playbooks, no other league
-- ===========================================================================
select set_config('t.sect', '5 board', false);
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000005');   -- UYFC board

\echo '=== 5. UYFC board member sees UYFC teams and no others ==='
select t.id, t.name, t.grade from public.teams t order by t.name, t.grade;

select t.val('board sees its 3 league teams', $q$select count(*)::text from public.teams$q$, '3');
select t.rows('board sees no Cache Valley team',
  $q$select 1 from public.teams where league_id='a0000000-0000-4000-8000-000000000002'$q$, 0);
select t.rows('board sees no Cache Valley team, by literal id',
  $q$select 1 from public.teams where id in ('c0000000-0000-4000-8000-000000000004','c0000000-0000-4000-8000-000000000005')$q$, 0);
select t.val('board sees its league''s 26 players', $q$select count(*)::text from public.players$q$, '26');
select t.rows('board sees no Cache Valley players',
  $q$select 1 from public.players where team_id='c0000000-0000-4000-8000-000000000004'$q$, 0);
-- The coach's IP. The board is on the compliance side of the wall, not the
-- football side: rosters and consents yes, schemes no.
select t.rows('board sees NO plays, not even in its own league', $q$select 1 from public.plays$q$, 0);
select t.rows('board sees consents in its league',
  $q$select 1 from public.player_consents where team_id='c0000000-0000-4000-8000-000000000001'$q$, 3);
select t.rows('board sees no consents in the other league',
  $q$select 1 from public.player_consents where team_id='c0000000-0000-4000-8000-000000000004'$q$, 0);
select t.blocked('board cannot rewrite a player''s name',
  $q$update public.players set last='Anonymous' where team_id='c0000000-0000-4000-8000-000000000001'$q$);
select t.raises('board cannot add a team (that is an admin)',
  $q$insert into public.teams (league_id, name, grade, season_id)
     values ('a0000000-0000-4000-8000-000000000001','Fake','8','b0000000-0000-4000-8000-000000000001')$q$, '42501');
select t.blocked('board cannot edit a play it cannot even see',
  $q$update public.plays set doc = doc || '{"board":true}' where team_id='c0000000-0000-4000-8000-000000000001'$q$);

select t.be('d0000000-0000-4000-8000-000000000009');   -- Cache Valley board
select t.val('the other board sees its own 2 teams', $q$select count(*)::text from public.teams$q$, '2');
select t.rows('the other board sees no UYFC team',
  $q$select 1 from public.teams where league_id='a0000000-0000-4000-8000-000000000001'$q$, 0);
select t.rows('the other board sees no UYFC player',
  $q$select 1 from public.players where team_id='c0000000-0000-4000-8000-000000000001'$q$, 0);
select t.rows('the other board sees no UYFC consent',
  $q$select 1 from public.player_consents where team_id='c0000000-0000-4000-8000-000000000001'$q$, 0);
select t.blocked('the other board cannot delete a UYFC player',
  $q$delete from public.players where id='e0000000-0000-4000-8000-000000000009'$q$);
reset role;
select t.control('UYFC really has 4 plays to hide from its board',
  $q$select 1 from public.plays p join public.teams t on t.id=p.team_id
     where t.league_id='a0000000-0000-4000-8000-000000000001'$q$, 4);

-- ===========================================================================
-- 6. The slug rule, carried into multi-tenant
-- ===========================================================================
select set_config('t.sect', '6 slug uniqueness', false);
\echo '=== 6. punt-base belongs to three different teams at once ==='
select p.slug, t.name, t.grade, l.name as league
  from public.plays p join public.teams t on t.id=p.team_id join public.leagues l on l.id=t.league_id
 where p.slug='punt-base' order by l.name, t.grade;

select t.control('punt-base held by 3 teams', $q$select 1 from public.plays where slug='punt-base'$q$, 3);
select t.val('two of them are in different leagues',
  $q$select count(distinct t.league_id)::text from public.plays p join public.teams t on t.id=p.team_id
      where p.slug='punt-base'$q$, '2');
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000001');
select t.raises('one team cannot hold the same slug twice',
  $q$insert into public.plays (team_id, slug, doc)
     values ('c0000000-0000-4000-8000-000000000001','punt-base','{"players":[{"id":"p0","player":"x"}]}')$q$, '23505');
select t.allowed('but a slug another team already uses is fine',
  $q$insert into public.plays (team_id, slug, doc)
     values ('c0000000-0000-4000-8000-000000000001','kickoff-spread','{"players":[{"id":"p0","player":"x"}]}')$q$, 1);
select t.val('renaming a play does not move its key',
  $q$update public.plays set doc = jsonb_set(doc,'{name}','"Punt — Base (renamed)"')
      where team_id='c0000000-0000-4000-8000-000000000001' and slug='punt-base'
      returning slug$q$, 'punt-base');
-- Put it back: this is also the positive Delete play test.
select set_config('app.intent', 'delete_play', true);
select t.allowed('Delete play removes exactly one play',
  $q$delete from public.plays
      where team_id='c0000000-0000-4000-8000-000000000001' and slug='kickoff-spread'$q$, 1);
select set_config('app.intent', '', true);
reset role;
select t.val('lehi 7 still has its own kickoff-spread',
  $q$select count(*)::text from public.plays where team_id='c0000000-0000-4000-8000-000000000002' and slug='kickoff-spread'$q$, '1');

-- ===========================================================================
-- 7. Deletion tombstones. It does not cascade.
--    A parent asks for a child removed. The child goes. The playbook stays.
--    (From here the suite stops putting things back: everything after this
--     point is the real end state, and the whole transaction rolls back at the
--     bottom of the file.)
-- ===========================================================================
select set_config('t.sect', '7 tombstone', false);
select t.snap('plays_before_deletion', $q$select count(*)::text from public.plays$q$);

\echo '=== 7. Before: Martinez #22 is named in two Lehi plays ==='
select p.slug, e->>'label' as spot, e->>'player' as name, e->>'jersey' as jersey,
       (e ? 'rosterId') as linked_to_roster
  from public.plays p, lateral jsonb_array_elements(p.doc->'players') e
 where p.team_id='c0000000-0000-4000-8000-000000000001'
   and e->>'rosterId'='e0000000-0000-4000-8000-000000000009';

select t.control('two plays name him',
  $q$select 1 from public.plays p where p.doc->'players' @> '[{"rosterId":"e0000000-0000-4000-8000-000000000009"}]'$q$, 2);
select t.control('he has consents on file',
  $q$select 1 from public.player_consents where player_id='e0000000-0000-4000-8000-000000000009'$q$, 2);

-- The board does the deletion, on the parent's request. Note that the board has
-- NO read and NO write policy on plays -- and the plays are still degraded,
-- because the tombstone trigger is SECURITY DEFINER. Without that, a deleted
-- child's name would sit in a playbook the deleter is not allowed to open.
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000005');
select set_config('app.deletion_reason', 'parent_request', true);
select t.allowed('board deletes the player on a parent request',
  $q$delete from public.players where id='e0000000-0000-4000-8000-000000000009'$q$, 1);
reset role;

\echo '=== 7. After: the spot survives, the boy is a number ==='
select p.slug, e->>'label' as spot, e->>'player' as name, e->>'jersey' as jersey,
       (e ? 'rosterId') as linked_to_roster, e->>'role' as lane, left(e->>'job', 38) as job
  from public.plays p, lateral jsonb_array_elements(p.doc->'players') e
 where p.team_id='c0000000-0000-4000-8000-000000000001' and (e->>'redacted')::boolean;

select t.val('the player row is gone',
  $q$select count(*)::text from public.players where id='e0000000-0000-4000-8000-000000000009'$q$, '0');
select t.unchanged('NO PLAY WAS DELETED', 'plays_before_deletion', $q$select count(*)::text from public.plays$q$);
select t.val('his team still has both its plays',
  $q$select count(*)::text from public.plays where team_id='c0000000-0000-4000-8000-000000000001'$q$, '2');
select t.val('punt-base now reads him as a jersey number',
  $q$select doc->'players'->1->>'player' from public.plays where id='f0000000-0000-4000-8000-000000000001'$q$, '#22');
select t.val('and the number is still readable',
  $q$select doc->'players'->1->>'jersey' from public.plays where id='f0000000-0000-4000-8000-000000000001'$q$, '22');
select t.val('the roster link is severed',
  $q$select (doc->'players'->1 ? 'rosterId')::text from public.plays where id='f0000000-0000-4000-8000-000000000001'$q$, 'false');
select t.val('his spot, lane and coordinates are untouched',
  $q$select (doc->'players'->1->>'label') || '/' || (doc->'players'->1->>'role') || '/' || (doc->'players'->1->>'x')
      from public.plays where id='f0000000-0000-4000-8000-000000000001'$q$, 'LGD/PROTECT/186');
select t.val('his written job is untouched',
  $q$select left(doc->'players'->1->>'job', 23) from public.plays where id='f0000000-0000-4000-8000-000000000001'$q$, 'Punch the man over you,');
select t.val('the other ten men are untouched',
  $q$select doc->'players'->0->>'player' from public.plays where id='f0000000-0000-4000-8000-000000000001'$q$, 'Paulich');
select t.val('routes and geometry are untouched',
  $q$select jsonb_array_length(doc->'routes')::text from public.plays where id='f0000000-0000-4000-8000-000000000001'$q$, '3');
select t.val('the fake still carries both looks',
  $q$select jsonb_array_length(doc->'looks')::text from public.plays where id='f0000000-0000-4000-8000-000000000002'$q$, '2');
select t.val('the second play was degraded too',
  $q$select doc->'players'->1->>'player' from public.plays where id='f0000000-0000-4000-8000-000000000002'$q$, '#22');
select t.val('no play anywhere still names him',
  $q$select count(*)::text from public.plays where doc->'players' @> '[{"rosterId":"e0000000-0000-4000-8000-000000000009"}]'$q$, '0');
select t.val('a tombstone records the deletion',
  $q$select reason || '/' || jersey || '/' || plays_redacted from public.player_tombstones
      where player_id='e0000000-0000-4000-8000-000000000009'$q$, 'parent_request/22/2');
select t.val('the tombstone holds no name',
  $q$select count(*)::text from information_schema.columns
      where table_schema='public' and table_name='player_tombstones'
        and column_name in ('last','first','name')$q$, '0');
select t.val('his consents went with him (the one cascade)',
  $q$select count(*)::text from public.player_consents where player_id='e0000000-0000-4000-8000-000000000009'$q$, '0');
select t.val('nobody else''s consents moved',
  $q$select count(*)::text from public.player_consents$q$, '2');

-- And the coach, who is the one who has to run the play on Saturday, can still
-- open it -- as himself, under RLS, not as the owner.
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000001');
select t.val('the coach can still open the play',
  $q$select doc->>'name' from public.plays where slug='punt-base' and team_id='c0000000-0000-4000-8000-000000000001'$q$,
  'Punt — Base (renamed)');
select t.val('and the spot reads #22 to him too',
  $q$select doc->'players'->1->>'player' from public.plays where id='f0000000-0000-4000-8000-000000000001'$q$, '#22');
reset role;

\echo '=== 7. The play as the app now reads it ==='
select e->>'label' as spot, e->>'player' as name, e->>'jersey' as num, e->>'role' as lane
  from public.plays p, lateral jsonb_array_elements(p.doc->'players') e
 where p.id='f0000000-0000-4000-8000-000000000001'
 order by (substring(e->>'id' from 2))::int;

-- ===========================================================================
-- 8. Plays never auto-delete
-- ===========================================================================
select set_config('t.sect', '8 plays never auto-delete', false);
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000002');   -- head of Lehi 8
select set_config('app.intent', '', true);
select t.raises('a DELETE with no human intent is refused',
  $q$delete from public.plays where team_id='c0000000-0000-4000-8000-000000000001'$q$, '42501');
select t.raises('so is a sweeping one',
  $q$delete from public.plays where true$q$, '42501');
select set_config('app.intent', 'delete_play', true);
select t.allowed('Delete play, pressed by the coach, works',
  $q$delete from public.plays where id='f0000000-0000-4000-8000-000000000001'$q$, 1);
select set_config('app.intent', '', true);
reset role;

select t.raises('even the owner cannot TRUNCATE plays',
  $q$truncate table public.plays$q$, '42501');
select t.raises('deleting a team cannot take a playbook with it',
  $q$delete from public.teams where id='c0000000-0000-4000-8000-000000000001'$q$, '23503');
select t.raises('nor can deleting a league',
  $q$delete from public.leagues where id='a0000000-0000-4000-8000-000000000001'$q$, '23503');
select t.raises('nor can deleting a season',
  $q$delete from public.seasons where id='b0000000-0000-4000-8000-000000000001'$q$, '23503');
select t.val('no ON DELETE CASCADE anywhere near plays, players, teams or seasons',
  $q$select count(*)::text from pg_constraint c
      where c.contype='f' and c.confdeltype='c'
        and c.conrelid in ('public.plays'::regclass,'public.players'::regclass,
                           'public.memberships'::regclass,'public.teams'::regclass,
                           'public.seasons'::regclass)$q$, '0');
select t.val('the only cascade in the schema is consents -> players',
  $q$select string_agg(c.conrelid::regclass::text, ',' order by c.conrelid::regclass::text)
      from pg_constraint c where c.contype='f' and c.confdeltype='c'
        and connamespace='public'::regnamespace$q$, 'player_consents');
select t.val('and no foreign key points from plays to players at all',
  $q$select count(*)::text from pg_constraint
      where contype='f' and conrelid='public.plays'::regclass and confrelid='public.players'::regclass$q$, '0');

-- ===========================================================================
-- 9. Retention: rosters age out with the season. Plays do not.
-- ===========================================================================
select set_config('t.sect', '9 retention', false);
select t.snap('plays_before_retention', $q$select count(*)::text from public.plays$q$);
select t.control('the 2019 team has a roster', $q$select 1 from public.players where team_id='c0000000-0000-4000-8000-000000000003'$q$, 2);
select t.control('and a playbook',             $q$select 1 from public.plays   where team_id='c0000000-0000-4000-8000-000000000003'$q$, 1);

\echo '=== 9. Retention sweep as of 2026-09-04 (2019 season + 400 days) ==='
select * from app.expire_season_rosters('2026-09-04');

select t.val('the 2019 roster aged out',
  $q$select count(*)::text from public.players where team_id='c0000000-0000-4000-8000-000000000003'$q$, '0');
select t.val('the 2019 playbook did NOT',
  $q$select count(*)::text from public.plays where team_id='c0000000-0000-4000-8000-000000000003'$q$, '1');
select t.unchanged('retention deleted no play at all', 'plays_before_retention',
  $q$select count(*)::text from public.plays$q$);
select t.val('the 2019 play now reads as numbers',
  $q$select (doc->'players'->0->>'player') || ' ' || (doc->'players'->1->>'player')
      from public.plays where id='f0000000-0000-4000-8000-000000000006'$q$, '#11 #44');
select t.val('with the reason recorded',
  $q$select distinct reason from public.player_tombstones where team_id='c0000000-0000-4000-8000-000000000003'$q$, 'season_retention');
select t.val('the current season was not touched (21 less the parent request)',
  $q$select count(*)::text from public.players where team_id='c0000000-0000-4000-8000-000000000001'$q$, '20');
select t.val('nor was the other league',
  $q$select count(*)::text from public.players where team_id='c0000000-0000-4000-8000-000000000004'$q$, '3');
select t.val('a shorter retention window does not reach a season still running',
  $q$select count(*)::text from app.expire_season_rosters('2026-09-04','a0000000-0000-4000-8000-000000000002')$q$, '0');

-- ===========================================================================
-- 10. The rulebook is data. The same question, asked of two leagues.
--     These are constants in the single-team app; a second customer turns them
--     into rows, which is the difference between a tool and a product.
-- ===========================================================================
select set_config('t.sect', '10 ruleset', false);
\echo '=== 10. One question, two leagues, different answers ==='
select l.name,
       app.league_rule(l.id,'8','field_goals_allowed') as fg_8th,
       app.league_rule(l.id,'9','field_goals_allowed') as fg_9th,
       app.league_rule(l.id,'8','min_plays')           as min_plays_8,
       app.league_rule(l.id,'7','x_man_min_weight_lb') as xman_lb_7,
       app.league_rule(l.id,'8','x_man_may_fake_punt') as fake_punt_8,
       app.league_rule(l.id,'8','illegal')             as illegal_8
  from public.leagues l order by l.name;

select t.val('UYFC: no field goals at 8th',
  $q$select app.league_rule('a0000000-0000-4000-8000-000000000001','8','field_goals_allowed')::text$q$, 'false');
select t.val('UYFC: field goals at 9th (grade override)',
  $q$select app.league_rule('a0000000-0000-4000-8000-000000000001','9','field_goals_allowed')::text$q$, 'true');
select t.val('Cache Valley: field goals at 8th',
  $q$select app.league_rule('a0000000-0000-4000-8000-000000000002','8','field_goals_allowed')::text$q$, 'true');
select t.val('UYFC: 165 lb x-man at 8th',
  $q$select app.league_rule('a0000000-0000-4000-8000-000000000001','8','x_man_min_weight_lb')::text$q$, '165');
select t.val('UYFC: 145 lb at 7th (grade override)',
  $q$select app.league_rule('a0000000-0000-4000-8000-000000000001','7','x_man_min_weight_lb')::text$q$, '145');
select t.val('UYFC: an x-man may NOT fake a punt',
  $q$select app.league_rule('a0000000-0000-4000-8000-000000000001','8','x_man_may_fake_punt')::text$q$, 'false');
select t.val('Cache Valley: an x-man MAY',
  $q$select app.league_rule('a0000000-0000-4000-8000-000000000002','8','x_man_may_fake_punt')::text$q$, 'true');
select t.val('UYFC: 10 plays, escalating to 16 after Q1',
  $q$select app.league_rule('a0000000-0000-4000-8000-000000000001','8','min_plays')::text || '/' ||
           (app.league_rule('a0000000-0000-4000-8000-000000000001','8','min_plays_escalation')->>'q1')$q$, '10/16');
select t.val('Cache Valley: 10 at 8th, 8 everywhere else',
  $q$select app.league_rule('a0000000-0000-4000-8000-000000000002','8','min_plays')::text || '/' ||
           app.league_rule('a0000000-0000-4000-8000-000000000002','5','min_plays')::text$q$, '10/8');
select t.val('a rule nobody has written is NULL, not a UYFC default',
  $q$select app.league_rule('a0000000-0000-4000-8000-000000000002','8','conversions')::text$q$, null);

set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000001');
select t.val('and a coach can only read his own league''s rulebook',
  $q$select coalesce(app.league_rule('a0000000-0000-4000-8000-000000000002','8','min_plays')::text,'NULL') || '/' ||
           coalesce(app.league_rule('a0000000-0000-4000-8000-000000000001','8','min_plays')::text,'NULL')$q$, 'NULL/10');
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
    raise exception '% ISOLATION TEST(S) FAILED', bad;
  end if;
  raise notice 'all % isolation tests passed', (select count(*) from t.results);
end $$;

rollback;

-- ===========================================================================
-- MUTATION LOG -- what happens when the schema is deliberately broken.
--
-- A suite that only ever sees a correct schema has not been shown to detect an
-- incorrect one. Each line below was applied to the live database, the suite was
-- run, and the policy was put back. Reproduce with:
--   psql ... -c '<mutation>' ; psql ... -f product/db/test-isolation.sql
--
--   mutation                                                     tests failed
--   ------------------------------------------------------------ ------------
--   baseline (nothing broken)                                               0
--   plays_select_team  ->  using (true)                                     8
--   plays_insert_coach ->  with check (true)                               12
--   players_insert_coach -> with check (true)                               9
--   memberships_write_head -> using (true) with check (true)                22
--   drop trigger plays_no_silent_delete                                     3
--   drop trigger players_tombstone                                          8
--   plays.team_id fkey -> on delete cascade                                 2
--   plays_select_team  ->  ... or board_team_ids()                          1
--   players_update_coach -> with check (true)                               0  *
--
--   * not a mutation at all: Postgres reuses USING as the WITH CHECK when none
--     is given, and the new row must satisfy the SELECT policy regardless. The
--     INSERT rows above are where the WITH CHECK claim is actually tested.
-- ===========================================================================
