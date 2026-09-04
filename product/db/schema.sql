-- product/db/schema.sql
-- Play Designer, the product: multi-tenant schema for leagues -> teams.
--
-- WHY THIS EXISTS
-- The head coach's schema is single-tenant in the primary key: eight tables are
-- literally one row (`id text primary key default 'current'`), two are keyed by
-- date alone (two teams practising on the same Tuesday collide), and no table
-- carries a team_id or a league_id. That schema cannot be sold. This one can.
--
-- THE FOUR RULES THIS FILE ENCODES (CLAUDE.md, restated for a database)
--   1. Isolation lives in RLS, not in route handlers. Every leaf table carries
--      team_id. league_id is NOT denormalised downward -- a leaf row's league is
--      reached by joining teams, inside a security definer helper, once.
--   2. A play is never destroyed by anything but a coach pressing Delete play.
--      There is no ON DELETE CASCADE anywhere on the path to plays, there is no
--      foreign key from plays to players at all, and a trigger refuses any
--      DELETE on plays that does not carry an explicit human intent flag.
--   3. Deleting a player TOMBSTONES. The player row goes; every play that named
--      him degrades to his jersey number and keeps its geometry, its routes, its
--      looks and its jobs. That is rules 1 and 2 of CLAUDE.md in a new domain.
--   4. Retention hangs off the season. Roster rows age out. Plays never do.
--
-- Load order: schema.sql -> rls.sql -> seed.sql -> test-isolation.sql
--
-- PORTABILITY. This file targets stock PostgreSQL 16 and Supabase unchanged.
-- On Supabase, auth.uid() and the anon/authenticated roles already exist and the
-- guarded blocks below do nothing. Off Supabase they are created as stand-ins.

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------------
-- 0. Schemas, roles, and the auth.uid() stand-in
-- ---------------------------------------------------------------------------

create schema if not exists app;      -- our helpers; never contains tenant data
create schema if not exists auth;     -- Supabase owns this schema in production

comment on schema app is
  'Security definer helpers for RLS. No tenant data lives here.';

-- The two tenant-facing roles. On Supabase these are `anon` (holder of the
-- public anon key, not signed in) and `authenticated` (a signed-in JWT). Here
-- they are pd_anon / pd_authenticated because the test harness connects as a
-- superuser and has to SET ROLE down into them: a superuser BYPASSES RLS, so a
-- policy tested as the owner is a policy that was never tested.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'pd_anon') then
    create role pd_anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'pd_authenticated') then
    create role pd_authenticated nologin;
  end if;
end $$;

grant usage on schema public, app, auth to pd_anon, pd_authenticated;

-- app.current_user_id() is the single point where identity enters the database.
--
-- HERE (plain Postgres, and the test suite): it reads the GUC `app.user_id`,
-- which a session sets with
--     select set_config('app.user_id', '<uuid>', false);
-- exactly the way a connection pooler would stamp a request.
--
-- ON SUPABASE: auth.uid() already exists and reads
--     current_setting('request.jwt.claims', true)::json ->> 'sub'
-- which PostgREST sets from the verified JWT. The policies below never call
-- app.current_user_id() directly -- they call auth.uid() -- so moving to
-- Supabase means deleting the guarded shim below and changing nothing else.
--
-- Fail closed: a malformed identity is not an identity, it is NULL, and every
-- policy in rls.sql is false for NULL.
create or replace function app.current_user_id()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  return nullif(current_setting('app.user_id', true), '')::uuid;
exception when others then
  return null;
end $$;

comment on function app.current_user_id() is
  'Identity from the GUC app.user_id. Maps 1:1 to Supabase auth.uid() (JWT sub). Returns NULL on anything malformed, and every policy is false for NULL.';

-- Only define auth.uid() if the platform has not already. On Supabase this block
-- is a no-op and the real, JWT-backed function is used.
do $$
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'auth' and p.proname = 'uid' and p.pronargs = 0
  ) then
    execute $f$
      create function auth.uid() returns uuid
      language sql stable
      as 'select app.current_user_id()';
    $f$;
    comment on function auth.uid() is
      'Stand-in for Supabase auth.uid(). Delegates to app.current_user_id(). Not created if the platform already provides it.';
  end if;
end $$;

grant execute on function app.current_user_id() to pd_anon, pd_authenticated;
grant execute on function auth.uid() to pd_anon, pd_authenticated;

-- ---------------------------------------------------------------------------
-- 1. leagues -- the rulebook becomes data
-- ---------------------------------------------------------------------------
-- Everything in CLAUDE.md's "The league: UYFC, 8th grade" table is a constant in
-- the app today: 165 lb x-men, no field goals below 9th, ten plays escalating to
-- 16/13/12, no pop-up kicks. A product sold to a second league has to be told
-- those, not compiled with them. They live in `ruleset`, per league, with
-- per-grade overrides, because a league's 8th grade and its 5th grade differ.

create table public.leagues (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  ruleset     jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  constraint leagues_name_present   check (length(btrim(name)) > 0),
  constraint leagues_ruleset_object check (jsonb_typeof(ruleset) = 'object'),
  -- Shape guard, not a schema: the app must be able to ask any league these.
  constraint leagues_ruleset_shape check (
    (not ruleset ? 'grades')     or jsonb_typeof(ruleset -> 'grades') = 'object'
  )
);

comment on table public.leagues is
  'A customer. The rules that are hardcoded constants in the single-team app live here as data.';
comment on column public.leagues.ruleset is
$c$Rules as data. Documented keys (all optional; app falls back to nothing, never
to a UYFC default):
  field_goals_allowed        bool
  x_man_min_weight_lb        number | null   (null = league has no weight class)
  x_man_restricted_to_lines  bool            (front two lines or the LOS)
  x_man_may_fake_punt        bool
  min_plays                  number
  min_plays_escalation       {"q1":16,"q2":13,"q3":12,"trigger_lead":21}
  special_teams_snaps_count  bool
  illegal                    ["pop_up_kick","wedge_3","blindside_block"]
  quarter_minutes            number
  play_clock_seconds         number
  field_yards                number
  kickoff_from_yard          number
  conversions                {"one_point_from":1.5,"two_point_from":3}
  grades                     {"8": {<any of the above, overriding>}}
Read it through app.league_rule(league, grade, key) so a grade override wins.$c$;

-- Per-grade override, then league default, then NULL. The only reader of the
-- ruleset shape, so the shape can change in one place.
-- SECURITY INVOKER, deliberately. This function reads leagues, and leagues is
-- RLS'd: a definer here would hand any signed-in coach the rulebook of every
-- league in the database. It returns NULL for a league you cannot see.
create or replace function app.league_rule(p_league uuid, p_grade text, p_key text)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(
           l.ruleset -> 'grades' -> p_grade -> p_key,
           l.ruleset -> p_key
         )
    from public.leagues l
   where l.id = p_league
$$;

comment on function app.league_rule(uuid, text, text) is
  'Resolve one rule for one grade: grade override, then league default, then NULL. Security INVOKER: RLS on leagues applies, so another league''s rulebook reads as NULL.';

-- ---------------------------------------------------------------------------
-- 2. seasons -- what retention hangs off
-- ---------------------------------------------------------------------------

create table public.seasons (
  id                 uuid primary key default gen_random_uuid(),
  league_id          uuid not null references public.leagues(id) on delete restrict,
  name               text not null,
  starts_on          date not null,
  ends_on            date not null,
  -- How long a roster row outlives the season it belongs to. The league sets it;
  -- app.expire_season_rosters() enforces it. Plays are not covered by it and
  -- there is no column here that could be made to cover them.
  retain_roster_days integer not null default 400,
  created_at         timestamptz not null default now(),
  constraint seasons_dates    check (ends_on >= starts_on),
  constraint seasons_retention_sane check (retain_roster_days between 0 and 3650),
  constraint seasons_name_unique unique (league_id, name),
  -- Target for the composite FK from teams: a team's season must be its league's.
  constraint seasons_id_league unique (id, league_id)
);

comment on column public.seasons.retain_roster_days is
  'Roster retention only. Plays never expire -- see the trigger on public.plays.';

-- ---------------------------------------------------------------------------
-- 3. teams -- the tenant boundary
-- ---------------------------------------------------------------------------

create table public.teams (
  id         uuid primary key default gen_random_uuid(),
  league_id  uuid not null references public.leagues(id) on delete restrict,
  name       text not null,
  grade      text not null,   -- text: leagues label grades differently ('8', '7/8', 'JV')
  season_id  uuid not null,
  created_at timestamptz not null default now(),
  constraint teams_name_present check (length(btrim(name)) > 0),
  constraint teams_unique_in_season unique (league_id, season_id, name, grade),
  -- Composite FK: you cannot point a team at another league's season.
  constraint teams_season_in_league
    foreign key (season_id, league_id)
    references public.seasons(id, league_id) on delete restrict,
  -- Target for composite FKs from leaf tables.
  constraint teams_id_league unique (id, league_id)
);

comment on table public.teams is
  'The tenant. Every leaf table carries team_id and nothing carries league_id -- the league is reached by joining this table inside a security definer helper.';

create index teams_league_idx on public.teams (league_id);
create index teams_season_idx on public.teams (season_id);

-- ---------------------------------------------------------------------------
-- 4. memberships -- who may touch a team
-- ---------------------------------------------------------------------------
-- head      : everything, including staffing the team
-- assistant : the coaching seat -- roster and plays, no staffing. Dom is this.
-- helper    : read only. A team parent running the sideline tablet.

create table public.memberships (
  user_id    uuid not null,
  team_id    uuid not null references public.teams(id) on delete restrict,
  role       text not null,
  invited_by uuid,
  created_at timestamptz not null default now(),
  primary key (user_id, team_id),
  constraint memberships_role check (role in ('head','assistant','helper'))
);

comment on column public.memberships.user_id is
  'On Supabase, add: references auth.users(id) on delete cascade. Kept a bare uuid here so the file loads on stock Postgres.';

create index memberships_team_idx on public.memberships (team_id);
create index memberships_user_idx on public.memberships (user_id);

-- ---------------------------------------------------------------------------
-- 5. league_memberships -- the board
-- ---------------------------------------------------------------------------
-- board : sees the league's teams, rosters and consents. NOT its plays.
-- admin : the above, plus creating teams and seasons and appointing the board.
--
-- The board deliberately cannot read plays. A play is the coach's IP; CLAUDE.md
-- already refuses to publish one coach's book on another's site. Compliance
-- oversight needs the roster and the consents, and stops there.

create table public.league_memberships (
  user_id    uuid not null,
  league_id  uuid not null references public.leagues(id) on delete restrict,
  role       text not null,
  created_at timestamptz not null default now(),
  primary key (user_id, league_id),
  constraint league_memberships_role check (role in ('board','admin'))
);

create index league_memberships_user_idx on public.league_memberships (user_id);

-- ---------------------------------------------------------------------------
-- 6. players -- and nothing else in v1
-- ---------------------------------------------------------------------------
-- A league product covers under-13s. That brings COPPA in, and the cheapest
-- compliance posture is not to hold the data: last name, first name, jersey.
-- No photo, no weight, no forty time, no date of birth, no parent email on the
-- child row. The app's own "last name and number" display convention is already
-- data minimisation; this table just stops there too.
--
-- Adding a column here is a policy decision, not a schema decision: it needs a
-- consent scope in player_consents and a per-league toggle in leagues.ruleset.

create table public.players (
  id         uuid primary key default gen_random_uuid(),
  team_id    uuid not null references public.teams(id) on delete restrict,
  last       text not null,
  first      text,
  jersey     text,                    -- text, and nullable: Bullock has no number
  created_at timestamptz not null default now(),
  constraint players_last_present check (length(btrim(last)) > 0),
  constraint players_id_team unique (id, team_id)   -- composite FK target
);

comment on table public.players is
  'COPPA position, deliberate: name and jersey only. No photos, no weights, no birthdates, no times. Adding a field requires a consent scope and a league toggle.';

create unique index players_team_jersey_uniq
  on public.players (team_id, jersey) where jersey is not null;
create index players_team_idx on public.players (team_id);

-- ---------------------------------------------------------------------------
-- 7. plays -- our existing play document, unchanged
-- ---------------------------------------------------------------------------
-- `doc` is exactly the shape in special-teams-plays.json: players[] with label /
-- x / y / role / job, routes keyed by the doc-local player id, looks[], aim,
-- mirrorOf, phase. The engine does not learn a new shape to become a product.
--
-- UNIQUE (team_id, slug) is CLAUDE.md's slug rule carried into multi-tenant:
-- the slug is the key, the name is for humans, and two teams may both run
-- punt-base without knowing about each other.
--
-- There is NO foreign key from plays to players, on purpose. The doc references
-- a roster row by uuid in `rosterId`, and that reference is deliberately not
-- enforced by the database, because an enforced reference is a cascade waiting
-- to be switched on. Deleting a player must degrade a play, never delete one.

create table public.plays (
  id         uuid primary key default gen_random_uuid(),
  team_id    uuid not null references public.teams(id) on delete restrict,
  slug       text not null,
  doc        jsonb not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint plays_slug_shape check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  constraint plays_team_slug unique (team_id, slug),
  constraint plays_doc_object check (jsonb_typeof(doc) = 'object'),
  constraint plays_doc_has_players check (jsonb_typeof(doc -> 'players') = 'array'),
  -- Never let an empty document overwrite a good one (inherited from 001_playbook.sql).
  constraint plays_doc_not_empty check (jsonb_array_length(doc -> 'players') > 0)
);

comment on table public.plays is
  'One play, one row. doc is the app play shape unchanged. No FK to players: a roster deletion degrades this row, it never removes it.';

create index plays_team_idx on public.plays (team_id);
-- Supports the redaction sweep: doc->'players' @> [{"rosterId": ...}]
create index plays_doc_players_gin
  on public.plays using gin ((doc -> 'players') jsonb_path_ops);

-- ---------------------------------------------------------------------------
-- 8. player_consents
-- ---------------------------------------------------------------------------
-- Who said yes, to what, when, and whether they took it back. The only cascade
-- in this schema is here: when a child's row goes, the consents ABOUT that child
-- go with it, because keeping them would be keeping a record of the child.
-- The audit that survives is the tombstone, which holds no name.

create table public.player_consents (
  id         uuid primary key default gen_random_uuid(),
  player_id  uuid not null,
  team_id    uuid not null,           -- leaf tables carry team_id (rule 1)
  granted_by uuid not null,           -- the guardian's user id
  granted_at timestamptz not null default now(),
  scope      text not null,
  revoked_at timestamptz,
  note       text,
  constraint player_consents_scope check (
    scope in ('roster','film','photo','share_league','share_public')
  ),
  constraint player_consents_revoked_after check (revoked_at is null or revoked_at >= granted_at),
  constraint player_consents_player
    foreign key (player_id, team_id)
    references public.players(id, team_id) on delete cascade
);

comment on constraint player_consents_player on public.player_consents is
  'The one cascade in this schema, and it is the right direction: a consent is a record about a child, so it dies with the child row. Plays are not consents and have no such edge.';

create unique index player_consents_live_scope
  on public.player_consents (player_id, scope) where revoked_at is null;
create index player_consents_team_idx on public.player_consents (team_id);

-- ---------------------------------------------------------------------------
-- 9. player_tombstones -- what is left after a deletion
-- ---------------------------------------------------------------------------
-- Deliberately carries NO NAME. A tombstone that stored the name would defeat
-- the deletion it records. It carries the jersey, because the plays now read as
-- that jersey and a coach has to be able to work out which spot went blank.

create table public.player_tombstones (
  player_id      uuid primary key,
  team_id        uuid not null references public.teams(id) on delete restrict,
  jersey         text,
  deleted_at     timestamptz not null default now(),
  deleted_by     uuid,
  reason         text not null default 'unspecified',
  plays_redacted integer not null default 0,
  constraint player_tombstones_reason check (
    reason in ('parent_request','season_retention','roster_correction','unspecified')
  )
);

comment on table public.player_tombstones is
  'Audit of a deletion, holding no personal name -- jersey only. Written by the BEFORE DELETE trigger on players; never written by the application.';

create index player_tombstones_team_idx on public.player_tombstones (team_id);

-- ---------------------------------------------------------------------------
-- 10. Deletion degrades a play. It never destroys one.
-- ---------------------------------------------------------------------------

-- Pure, immutable: given a doc and a roster id, return the doc with that man
-- reduced to his number. Everything else -- his label, his x/y, his role, his
-- job, every route keyed by his doc-local id, every look -- is untouched. The
-- play still runs; the boy is no longer named in it.
create or replace function app.redact_player_in_doc(doc jsonb, p_player uuid, p_jersey text)
returns jsonb
language sql
immutable
as $$
  select case
    when jsonb_typeof(doc -> 'players') <> 'array' then doc
    else jsonb_set(doc, '{players}', coalesce((
      select jsonb_agg(
               case when el ->> 'rosterId' = p_player::text
                    then (el - 'rosterId')
                         || jsonb_build_object(
                              'player',   '#' || coalesce(nullif(p_jersey, ''), '--'),
                              'jersey',   coalesce(nullif(p_jersey, ''), '--'),
                              'redacted', true)
                    else el end
               order by ord)
        from jsonb_array_elements(doc -> 'players') with ordinality as e(el, ord)
    ), '[]'::jsonb))
  end
$$;

comment on function app.redact_player_in_doc(jsonb, uuid, text) is
  'Degrade one man in one play document to his jersey number. Geometry, routes, looks, roles and jobs are untouched.';

-- BEFORE DELETE on players: sweep this team's plays, then leave a tombstone.
-- SECURITY DEFINER because the sweep must succeed whoever is allowed to delete
-- the player -- a league board member removing a child on a parent's request has
-- no write policy on plays, and must still not leave a play naming that child.
create or replace function app.tombstone_player()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  n_redacted integer := 0;
  v_reason   text;
begin
  with touched as (
    update public.plays p
       set doc = app.redact_player_in_doc(p.doc, old.id, old.jersey),
           updated_at = now()
     where p.team_id = old.team_id
       and p.doc -> 'players' @> jsonb_build_array(jsonb_build_object('rosterId', old.id::text))
    returning 1
  )
  select count(*) into n_redacted from touched;

  v_reason := coalesce(nullif(current_setting('app.deletion_reason', true), ''), 'unspecified');
  if v_reason not in ('parent_request','season_retention','roster_correction','unspecified') then
    v_reason := 'unspecified';
  end if;

  insert into public.player_tombstones (player_id, team_id, jersey, deleted_by, reason, plays_redacted)
  values (old.id, old.team_id, old.jersey, app.current_user_id(), v_reason, n_redacted)
  on conflict (player_id) do update
    set deleted_at = now(), reason = excluded.reason, plays_redacted = excluded.plays_redacted;

  return old;
end $$;

create trigger players_tombstone
  before delete on public.players
  for each row execute function app.tombstone_player();

comment on function app.tombstone_player() is
  'Deletion tombstones, it does not cascade. Plays are UPDATEd to a jersey number; no play is ever deleted here. Set the GUC app.deletion_reason to record why.';

-- ---------------------------------------------------------------------------
-- 11. Plays never auto-delete
-- ---------------------------------------------------------------------------
-- CLAUDE.md rule 1: the only thing that removes a play is the user pressing
-- Delete play. In a database that means a DELETE has to prove it came from that
-- press. The app sets a transaction-local intent flag immediately before the
-- statement; nothing scheduled, nothing sweeping and nothing cascading ever does:
--
--   select set_config('app.intent', 'delete_play', true);   -- true = tx-local
--   delete from public.plays where id = $1;
--
-- A cascade cannot satisfy this either, which is the belt to the braces of
-- having no ON DELETE CASCADE pointing here.

create or replace function app.plays_require_explicit_delete()
returns trigger
language plpgsql
as $$
begin
  if coalesce(current_setting('app.intent', true), '') <> 'delete_play' then
    raise exception
      'refusing to delete play % (%): plays are only deleted by an explicit Delete play, which must set app.intent',
      old.id, old.slug
      using errcode = '42501',
            hint = 'select set_config(''app.intent'', ''delete_play'', true); before the DELETE';
  end if;
  return old;
end $$;

create trigger plays_no_silent_delete
  before delete on public.plays
  for each row execute function app.plays_require_explicit_delete();

-- TRUNCATE is a delete that skips row triggers. Close it.
create or replace function app.plays_no_truncate()
returns trigger
language plpgsql
as $$
begin
  raise exception 'refusing to truncate public.plays: plays are never bulk-deleted'
    using errcode = '42501';
end $$;

create trigger plays_no_truncate
  before truncate on public.plays
  for each statement execute function app.plays_no_truncate();

create or replace function app.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

create trigger plays_touch
  before update on public.plays
  for each row execute function app.touch_updated_at();

-- ---------------------------------------------------------------------------
-- 12. Retention: roster rows age out with a season. Plays do not.
-- ---------------------------------------------------------------------------
-- The asymmetry is the whole point, so it is one function and it can only reach
-- one table. Grep this file for "delete from public.plays": there is no such
-- statement, and the trigger above would refuse it if there were.
--
-- Deleting the player runs the tombstone trigger, so an aged-out roster leaves
-- last season's playbook intact and readable as numbers.

create or replace function app.expire_season_rosters(
  p_asof   date default current_date,
  p_league uuid default null
)
returns table (team_id uuid, players_removed integer)
language plpgsql
security definer                -- a scheduled job, not a signed-in user
set search_path = ''
as $$
begin
  perform set_config('app.deletion_reason', 'season_retention', true);

  return query
  with doomed as (
    select pl.id
      from public.players pl
      join public.teams   t on t.id = pl.team_id
      join public.seasons s on s.id = t.season_id
     where (p_league is null or t.league_id = p_league)
       and s.ends_on + make_interval(days => s.retain_roster_days) < p_asof
  ),
  gone as (
    delete from public.players p
     using doomed d
     where p.id = d.id
    returning p.team_id as tid
  )
  select g.tid, count(*)::integer from gone g group by g.tid;
end $$;

comment on function app.expire_season_rosters(date, uuid) is
  'Roster retention. Touches players only. Plays are never deleted by retention -- they degrade to jersey numbers via the tombstone trigger and stay.';

commit;
