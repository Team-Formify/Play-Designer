-- product/db/migrations/0003_rls.sql
-- WHY: isolation has to live in Postgres, not in route handlers. An
-- application filter is one forgotten WHERE clause away from a cross-team
-- leak, and nobody can prove the absence of that mistake by reading code.
-- A policy is checked by the database on every row, every time, including on
-- the queries nobody thought to review.
-- Isolation. All of it. There is no tenant filter in application code, because
-- an application filter is one forgotten WHERE clause from a cross-team leak and
-- nobody can prove the absence of that mistake by reading route handlers.
--
-- HOW THE POLICIES ARE WRITTEN, AND WHY
--
-- 1. Every membership lookup goes through a SECURITY DEFINER function in the app
--    schema. Two reasons. The obvious one: a policy on players that queried
--    memberships directly would recurse into memberships' own policies. The
--    load-bearing one: the definer function reads memberships with the owner's
--    rights, so memberships itself can stay locked down.
--
-- 2. The helpers are SET-RETURNING and the policies say
--        team_id in (select app.team_ids())
--    not
--        app.is_team_member(team_id)
--    because the first has no reference to the outer row, so the planner runs it
--    ONCE as an InitPlan and hashes the result; the second is a function call per
--    row. On a 40-team league that is the difference between one lookup and forty
--    thousand. Same reason Supabase tells you to write `(select auth.uid())` and
--    not bare `auth.uid()`: the parenthesised subselect is folded to a constant
--    for the whole statement instead of being re-evaluated per row.
--
-- 3. Inside the helpers the identity is always `(select auth.uid())`, never bare.
--
-- 4. Every policy is false when auth.uid() is NULL. An unauthenticated session
--    does not get a smaller result set; it gets nothing.
--
-- WHO SEES WHAT
--   head       team: everything, plus staffing the team
--   assistant  team: roster + plays. No staffing. (Dom's seat.)
--   helper     team: read only
--   board      league: teams, rosters, consents, tombstones -- NOT plays
--   admin      league: the board's rights, plus creating teams/seasons/board
--
-- The board's exclusion from plays is deliberate and is the same judgement
-- CLAUDE.md already makes about publishing one coach's book on a public site: a
-- play is the coach's IP. Compliance oversight needs the roster and the
-- consents. It does not need the punt scheme.

\set ON_ERROR_STOP on

-- The transaction is supplied by the runner (product/db/migrate.mjs), which
-- wraps this file and its ledger row in ONE transaction. A migration that
-- committed itself could succeed while its ledger row failed, and the next run
-- would replay it. Do not add begin/commit here.

-- ---------------------------------------------------------------------------
-- Membership helpers. Security definer, stable, empty search_path.
-- ---------------------------------------------------------------------------

create or replace function app.team_ids()
returns setof uuid
language sql stable security definer parallel safe
set search_path = ''
as $$
  select m.team_id from public.memberships m
   where m.user_id = (select auth.uid())
$$;
comment on function app.team_ids() is 'Teams I belong to in any role.';

create or replace function app.coach_team_ids()
returns setof uuid
language sql stable security definer parallel safe
set search_path = ''
as $$
  select m.team_id from public.memberships m
   where m.user_id = (select auth.uid())
     and m.role in ('head','assistant')
$$;
comment on function app.coach_team_ids() is 'Teams I may write roster and plays for. Excludes helper.';

create or replace function app.head_team_ids()
returns setof uuid
language sql stable security definer parallel safe
set search_path = ''
as $$
  select m.team_id from public.memberships m
   where m.user_id = (select auth.uid())
     and m.role = 'head'
$$;

create or replace function app.league_ids()
returns setof uuid
language sql stable security definer parallel safe
set search_path = ''
as $$
  select lm.league_id from public.league_memberships lm
   where lm.user_id = (select auth.uid())
$$;
comment on function app.league_ids() is 'Leagues where I sit on the board.';

create or replace function app.admin_league_ids()
returns setof uuid
language sql stable security definer parallel safe
set search_path = ''
as $$
  select lm.league_id from public.league_memberships lm
   where lm.user_id = (select auth.uid())
     and lm.role = 'admin'
$$;

-- Leagues whose rulebook I am entitled to read: the ones I govern, plus the ones
-- my teams play in. A coach must be able to read his league's ruleset -- that is
-- what tells his app whether field goals exist -- without being able to
-- enumerate the league's other teams.
create or replace function app.visible_league_ids()
returns setof uuid
language sql stable security definer parallel safe
set search_path = ''
as $$
  select lm.league_id from public.league_memberships lm
   where lm.user_id = (select auth.uid())
  union
  select t.league_id from public.teams t
   where t.id in (select m.team_id from public.memberships m
                   where m.user_id = (select auth.uid()))
$$;

-- The one place league_id is resolved for a leaf row. Leaf tables carry team_id
-- only (never a denormalised league_id), so board reach is expressed by mapping
-- the board's leagues DOWN to a set of team ids, once per statement.
create or replace function app.board_team_ids()
returns setof uuid
language sql stable security definer parallel safe
set search_path = ''
as $$
  select t.id from public.teams t
   where t.league_id in (select lm.league_id from public.league_memberships lm
                          where lm.user_id = (select auth.uid()))
$$;
comment on function app.board_team_ids() is
  'Teams inside the leagues I govern. This is why leaf tables do not need a denormalised league_id: the join happens here, once per statement, with the owner''s rights.';

create or replace function app.admin_team_ids()
returns setof uuid
language sql stable security definer parallel safe
set search_path = ''
as $$
  select t.id from public.teams t
   where t.league_id in (select lm.league_id from public.league_memberships lm
                          where lm.user_id = (select auth.uid())
                            and lm.role = 'admin')
$$;

grant execute on function
  app.team_ids(), app.coach_team_ids(), app.head_team_ids(),
  app.league_ids(), app.admin_league_ids(), app.visible_league_ids(),
  app.board_team_ids(), app.admin_team_ids(),
  app.league_rule(uuid, text, text),
  app.redact_player_in_doc(jsonb, uuid, text)
to pd_anon, pd_authenticated;

-- Retention is a job, not a user action. No tenant may call it.
revoke all on function app.expire_season_rosters(date, uuid) from public;

-- ---------------------------------------------------------------------------
-- Grants. Privileges say which verbs exist; policies say which rows.
-- Both have to pass. pd_anon gets read verbs and no readable rows.
-- ---------------------------------------------------------------------------

grant select on
  public.leagues, public.seasons, public.teams, public.memberships,
  public.league_memberships, public.players, public.plays,
  public.player_consents, public.player_tombstones
to pd_anon, pd_authenticated;

grant insert, update, delete on
  public.teams, public.seasons, public.memberships, public.league_memberships,
  public.players, public.plays, public.player_consents
to pd_authenticated;

-- Tombstones are written by the trigger (security definer), never by a client.
-- No client-side INSERT/UPDATE/DELETE grant exists, so no policy is needed to
-- refuse one: the privilege check fails first.
revoke insert, update, delete on public.player_tombstones from pd_authenticated, pd_anon;

-- Leagues are provisioned by us, not by tenants. Read-only to everybody signed
-- in; there is deliberately no INSERT/UPDATE/DELETE policy below.
revoke insert, update, delete on public.leagues from pd_authenticated, pd_anon;

-- ---------------------------------------------------------------------------
-- Enable + FORCE. FORCE matters because the tables are owned by the migration
-- role: without it, the owner reads straight past every policy below. (A
-- superuser bypasses regardless, which is exactly why the test suite SET ROLEs
-- into pd_authenticated instead of trusting the connection it arrives on.)
-- ---------------------------------------------------------------------------

alter table public.leagues            enable row level security;
alter table public.seasons            enable row level security;
alter table public.teams              enable row level security;
alter table public.memberships        enable row level security;
alter table public.league_memberships enable row level security;
alter table public.players            enable row level security;
alter table public.plays              enable row level security;
alter table public.player_consents    enable row level security;
alter table public.player_tombstones  enable row level security;

alter table public.leagues            force row level security;
alter table public.seasons            force row level security;
alter table public.teams              force row level security;
alter table public.memberships        force row level security;
alter table public.league_memberships force row level security;
alter table public.players            force row level security;
alter table public.plays              force row level security;
alter table public.player_consents    force row level security;
alter table public.player_tombstones  force row level security;

-- ---------------------------------------------------------------------------
-- leagues -- read the rulebook of a league you are actually in
-- ---------------------------------------------------------------------------

create policy leagues_select on public.leagues
  for select to pd_anon, pd_authenticated
  using (id in (select app.visible_league_ids()));

-- No write policies on purpose. Provisioning a league is a sale, not a feature.

-- ---------------------------------------------------------------------------
-- seasons
-- ---------------------------------------------------------------------------

create policy seasons_select on public.seasons
  for select to pd_anon, pd_authenticated
  using (league_id in (select app.visible_league_ids()));

create policy seasons_write_admin on public.seasons
  for all to pd_authenticated
  using      (league_id in (select app.admin_league_ids()))
  with check (league_id in (select app.admin_league_ids()));

-- ---------------------------------------------------------------------------
-- teams
-- ---------------------------------------------------------------------------
-- A coach sees his own teams. A board member sees every team in his league --
-- and, because board_team_ids() is scoped by league membership, no team in any
-- other. A coach does NOT get to enumerate his league's other teams; he can read
-- the league row for its rules and that is all.

create policy teams_select on public.teams
  for select to pd_anon, pd_authenticated
  using (
    id in (select app.team_ids())
    or league_id in (select app.league_ids())
  );

create policy teams_write_admin on public.teams
  for all to pd_authenticated
  using      (league_id in (select app.admin_league_ids()))
  with check (league_id in (select app.admin_league_ids()));

-- ---------------------------------------------------------------------------
-- memberships -- the privilege-escalation surface, so it is the tightest
-- ---------------------------------------------------------------------------
-- If a coach could INSERT a membership naming another team, isolation would be
-- one INSERT deep. The WITH CHECK is on the TARGET team, so writing yourself
-- into a team you do not already run is refused.

create policy memberships_select on public.memberships
  for select to pd_anon, pd_authenticated
  using (
    user_id = (select auth.uid())
    or team_id in (select app.team_ids())
    or team_id in (select app.board_team_ids())
  );

create policy memberships_write_head on public.memberships
  for all to pd_authenticated
  using (
    team_id in (select app.head_team_ids())
    or team_id in (select app.admin_team_ids())
  )
  with check (
    team_id in (select app.head_team_ids())
    or team_id in (select app.admin_team_ids())
  );

-- ---------------------------------------------------------------------------
-- league_memberships -- appointing the board is a league admin's job only
-- ---------------------------------------------------------------------------

create policy league_memberships_select on public.league_memberships
  for select to pd_anon, pd_authenticated
  using (
    user_id = (select auth.uid())
    or league_id in (select app.league_ids())
  );

create policy league_memberships_write_admin on public.league_memberships
  for all to pd_authenticated
  using      (league_id in (select app.admin_league_ids()))
  with check (league_id in (select app.admin_league_ids()));

-- ---------------------------------------------------------------------------
-- players
-- ---------------------------------------------------------------------------

create policy players_select on public.players
  for select to pd_anon, pd_authenticated
  using (
    team_id in (select app.team_ids())
    or team_id in (select app.board_team_ids())
  );

create policy players_insert_coach on public.players
  for insert to pd_authenticated
  with check (team_id in (select app.coach_team_ids()));

-- USING picks the rows you may touch; WITH CHECK picks what they may become.
-- Both are needed: without WITH CHECK a coach could UPDATE one of his own
-- players' team_id and post the row into another team.
create policy players_update_coach on public.players
  for update to pd_authenticated
  using      (team_id in (select app.coach_team_ids()))
  with check (team_id in (select app.coach_team_ids()));

-- A parent's removal request reaches the board, not always the coach, so the
-- board can delete. The tombstone trigger does the rest -- and it is SECURITY
-- DEFINER precisely because the board has no write policy on plays.
create policy players_delete_coach_or_board on public.players
  for delete to pd_authenticated
  using (
    team_id in (select app.coach_team_ids())
    or team_id in (select app.board_team_ids())
  );

-- ---------------------------------------------------------------------------
-- plays -- the coach's IP. Team only. The board is not on this list.
-- ---------------------------------------------------------------------------

create policy plays_select_team on public.plays
  for select to pd_anon, pd_authenticated
  using (team_id in (select app.team_ids()));

create policy plays_insert_coach on public.plays
  for insert to pd_authenticated
  with check (team_id in (select app.coach_team_ids()));

create policy plays_update_coach on public.plays
  for update to pd_authenticated
  using      (team_id in (select app.coach_team_ids()))
  with check (team_id in (select app.coach_team_ids()));

-- Deleting a play needs the policy AND the explicit-intent trigger from
-- migrations/0002_schema.sql. Policy alone would let a bulk UPDATE-shaped mistake through.
create policy plays_delete_coach on public.plays
  for delete to pd_authenticated
  using (team_id in (select app.coach_team_ids()));

-- ---------------------------------------------------------------------------
-- player_consents
-- ---------------------------------------------------------------------------
-- No DELETE policy: a consent is revoked by setting revoked_at, never erased.
-- The FK cascade from players still removes them, and referential actions run
-- with the owner's rights, so RLS does not stand in the way of a real deletion.

create policy player_consents_select on public.player_consents
  for select to pd_anon, pd_authenticated
  using (
    team_id in (select app.team_ids())
    or team_id in (select app.board_team_ids())
  );

create policy player_consents_insert on public.player_consents
  for insert to pd_authenticated
  with check (
    team_id in (select app.coach_team_ids())
    or team_id in (select app.board_team_ids())
  );

create policy player_consents_update on public.player_consents
  for update to pd_authenticated
  using (
    team_id in (select app.coach_team_ids())
    or team_id in (select app.board_team_ids())
  )
  with check (
    team_id in (select app.coach_team_ids())
    or team_id in (select app.board_team_ids())
  );

-- ---------------------------------------------------------------------------
-- player_tombstones -- readable by the team and the board, written by nobody
-- ---------------------------------------------------------------------------

create policy player_tombstones_select on public.player_tombstones
  for select to pd_anon, pd_authenticated
  using (
    team_id in (select app.team_ids())
    or team_id in (select app.board_team_ids())
  );

-- (no commit; the runner commits)
