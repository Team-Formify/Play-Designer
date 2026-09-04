-- product/db/platform.sql
-- The platform owner: the vendor's seat. The one deliberate exception to
-- everything else in this schema, and therefore the narrowest thing in it.
--
-- WHY THIS IS THE DANGEROUS FILE
-- schema.sql and rls.sql exist to stop one tenant seeing another. auth.sql
-- exists to stop anybody becoming a tenant they were not invited to be. This
-- file adds a seat that sits outside all of it, because a business that sells
-- to leagues has to be able to answer "how many leagues, how many teams, how
-- many seats, who is paid up" without asking its customers. That seat is the
-- single most valuable credential in the product. It is built on four rules:
--
--   1. IT SEES THE BUSINESS, NOT THE FOOTBALL AND NOT THE CHILDREN.
--      A platform owner holds NO row-level reach at all. There is not one
--      policy in this file that adds a row to what a platform owner can SELECT
--      from public.plays, public.players, public.player_consents,
--      public.player_tombstones, public.teams, public.leagues, or anything
--      else a tenant owns. `select * from public.players` as a platform owner
--      returns zero rows, exactly as it does for a stranger. Everything the
--      seat can see arrives through a handful of SECURITY DEFINER functions
--      that return COUNTS AND DATES. No child's name, no jersey, no play
--      document, no route, no lane, no job leaves those functions.
--
--   2. EVERY CROSS-TENANT READ IS LOGGED, IN THE SAME TRANSACTION AS THE READ.
--      A tenant reading its own rows is ordinary and is not logged here. The
--      vendor crossing a tenant boundary is an event. Because the log write is
--      inside the same function as the read, a read cannot commit without its
--      log row -- and public.platform_events refuses UPDATE, DELETE and
--      TRUNCATE from everybody, the platform owner and the table owner
--      included. The league's own admins can read the entries about their
--      league, which is the answer to "what can you see, and what did you see".
--
--   3. THE SEAT IS NOT A TENANT SEAT, IN EITHER DIRECTION. A uuid that holds a
--      team or league membership cannot be written into public.platform_owners,
--      and a uuid in public.platform_owners cannot be given a membership --
--      app.accept_invite() included. Dom the assistant coach and Dom the
--      co-founder are two accounts on purpose. It is what lets rule 1 be stated
--      without an "unless": a platform owner cannot read a play, full stop,
--      rather than "cannot read a play unless he also coaches somewhere".
--
--   4. SUSPENSION NEVER DELETES. CLAUDE.md rule 1 is absolute and does not stop
--      being absolute because an invoice was not paid. Suspending a league sets
--      a flag and refuses NEW SEATS. It removes no play, no player, no team, no
--      season and no membership; it hides nothing from the people already in
--      the league; and unsuspending is one function call.
--
-- Load order: schema.sql -> rls.sql -> auth.sql -> platform.sql
--             -> seed.sql -> auth-seed.sql -> platform-seed.sql
-- Tests:      test-isolation.sql (183, unchanged), test-auth.sql (243,
--             unchanged), test-platform.sql (this file's own attack suite).
--
-- ADDITIVE, LIKE auth.sql. Three new tables, their own policies, one guard
-- trigger apiece on memberships / league_memberships / invites, and a set of
-- functions. Nothing in schema.sql, rls.sql or auth.sql is edited or replaced.
-- Every guard added here is inert for a session that holds no platform
-- credential and belongs to no suspended league, which is why the 426 tests
-- that came before it do not move.
--
-- ONE INHERITED ASSUMPTION, STATED. The SECURITY DEFINER functions below read
-- and write across tenants with the rights of the role that owns them, which is
-- the migration role. That is the same assumption app.tombstone_player() in
-- schema.sql already makes (it rewrites plays on behalf of a board member who
-- has no write policy on plays), and the same one Supabase makes for functions
-- owned by `postgres`. If you ever run this schema with a table owner that
-- neither is a superuser nor holds BYPASSRLS, the definer functions here and
-- the tombstone sweep there both need explicit owner-scoped policies.

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------------
-- 1. platform_owners -- the seat itself
-- ---------------------------------------------------------------------------
-- Deliberately tiny. A user id, the address we know them by, and who let them
-- in. No tier, no scope, no per-league grant: the seat is all-or-nothing
-- because a half-platform-owner is a role nobody can reason about, and the
-- capability it unlocks is a fixed list of functions rather than a set of rows.
--
-- FOUR LAYERS KEEP A TENANT OUT OF THIS TABLE, and each is independent:
--   privilege  -- no SELECT, INSERT, UPDATE or DELETE is granted to pd_anon or
--                 pd_authenticated. Not even read. A tenant asking gets 42501
--                 from the privilege check before RLS is consulted.
--   policy     -- RLS is enabled and FORCEd with no policy at all, so if a
--                 grant were ever added by mistake it would still read nothing.
--   intent     -- a BEFORE INSERT trigger refuses a row unless the session is
--                 already a platform owner, or is holding the tx-local
--                 bootstrap flag. This binds the table OWNER too, which is the
--                 half a privilege cannot cover.
--   separation -- the same trigger refuses any user id that holds a team or
--                 league membership. A coach cannot be promoted; he would have
--                 to be un-coached first, and that leaves an audit trail of its
--                 own in auth_events.

create table public.platform_owners (
  user_id  uuid primary key,
  email    text not null,
  added_at timestamptz not null default now(),
  added_by uuid,
  note     text,
  constraint platform_owners_email_normalised
    check (email = lower(btrim(email)) and email like '%_@_%')
);

comment on table public.platform_owners is
  'The vendor seat. Holds no scope and no tier: platform ownership is a fixed capability list, not a set of rows. Unreadable and unwritable by every tenant role, and a uuid that holds any membership cannot be entered here.';
comment on column public.platform_owners.email is
  'How we contact the holder. An adult, and one of ours -- this column is the only personal data in the file, and it is our own.';

-- ---------------------------------------------------------------------------
-- 2. league_platform_state -- the commercial half of a league
-- ---------------------------------------------------------------------------
-- Kept OUT of public.leagues on purpose. public.leagues is the customer's row:
-- its name and its rulebook, which the customer's own coaches read to find out
-- whether field goals exist. Whether the invoice was paid is ours, it is not
-- part of the rulebook, and it has a different write path (nobody's but the
-- platform's). Two different owners, two different tables.
--
-- The customer may READ its own state -- a suspended league has an absolute
-- right to know it is suspended -- and may not write it.

create table public.league_platform_state (
  league_id         uuid primary key references public.leagues(id) on delete restrict,
  status            text not null default 'active',
  plan              text not null default 'trial',
  seats_purchased   integer,
  contract_ends_on  date,
  status_reason     text,
  status_changed_at timestamptz not null default now(),
  status_changed_by uuid,
  constraint league_platform_state_status check (status in ('active','suspended')),
  constraint league_platform_state_plan   check (plan in ('trial','season','annual','none')),
  constraint league_platform_state_seats  check (seats_purchased is null or seats_purchased >= 0)
);

comment on table public.league_platform_state is
  'Subscription state per league. Readable by that league, writable only by the platform functions in this file. A missing row reads as active -- a league we have not billed yet is not a suspended league.';
comment on column public.league_platform_state.status is
  'active | suspended. Suspension refuses NEW SEATS and nothing else: no row is deleted, nothing is hidden from the people already in the league, and unsuspending restores the seat path in one statement.';

-- ---------------------------------------------------------------------------
-- 3. platform_events -- the trail the vendor cannot touch
-- ---------------------------------------------------------------------------
-- A sibling of auth_events rather than an extension of it, for two reasons that
-- are both about not weakening what already works. auth_events' action check
-- constraint and its read policy are load-bearing in test-auth.sql; widening
-- either would mean editing a file that 243 tests already hold still. And these
-- rows answer a different question for a different reader: auth_events is the
-- LEAGUE's record of its own staffing, platform_events is the record of US
-- looking in. A league admin can read the entries about their own league, which
-- is the point -- a buyer who asks "what do you see" gets to check the answer.
--
-- Insert-only, enforced the same three ways as auth_events, because one way is
-- a promise and three are a design: no write privilege for any role, a BEFORE
-- UPDATE OR DELETE trigger that binds the owner, and a BEFORE TRUNCATE trigger
-- because TRUNCATE skips row triggers. No foreign keys: a log row has to
-- outlive the league it describes.

create table public.platform_events (
  id            bigint generated always as identity primary key,
  at            timestamptz not null default now(),
  actor         uuid,                     -- the platform owner; NULL = a migration
  action        text not null,
  league_id     uuid,
  team_id       uuid,
  subject_user  uuid,
  subject_email text,
  rows_returned integer,
  detail        jsonb not null default '{}'::jsonb,
  constraint platform_events_action check (action in (
    'leagues_list','league_detail','audit_read',
    'league_create','admin_invite','admin_invite_superseded',
    'league_suspend','league_unsuspend',
    'owner_grant','owner_revoke','owner_change')),
  constraint platform_events_detail_object check (jsonb_typeof(detail) = 'object')
);

comment on table public.platform_events is
  'Every time the vendor crosses a tenant boundary. Written inside the same transaction as the read it describes, so a platform read cannot commit without its log row. Insert-only against everybody, the platform owner and the table owner included.';
comment on column public.platform_events.rows_returned is
  'How much was returned, not what. The trail records the reach of a read; it never copies the read''s contents, or it would become a second store of the thing it is auditing.';

create index platform_events_league_idx on public.platform_events (league_id, at desc);
create index platform_events_actor_idx  on public.platform_events (actor, at desc);

create or replace function app.platform_events_append_only()
returns trigger
language plpgsql
as $$
begin
  raise exception 'platform_events is insert-only: refusing to % row %',
    lower(tg_op), coalesce(old.id::text, '?')
    using errcode = '42501',
          hint = 'the point of this log is that the person it is about cannot edit it';
  return null;
end $$;

create trigger platform_events_no_update
  before update on public.platform_events
  for each row execute function app.platform_events_append_only();

create trigger platform_events_no_delete
  before delete on public.platform_events
  for each row execute function app.platform_events_append_only();

create or replace function app.platform_events_no_truncate()
returns trigger
language plpgsql
as $$
begin
  raise exception 'refusing to truncate public.platform_events: the log is insert-only'
    using errcode = '42501';
end $$;

create trigger platform_events_no_truncate
  before truncate on public.platform_events
  for each statement execute function app.platform_events_no_truncate();

-- ---------------------------------------------------------------------------
-- 4. Identity, refusal, and the logger
-- ---------------------------------------------------------------------------

-- The only question a tenant may ask about this file. It answers false for
-- everybody who is not a platform owner and leaks nothing else -- the hub uses
-- it to decide whether to draw the tab.
create or replace function app.is_platform_owner()
returns boolean
language sql
stable security definer parallel safe
set search_path = ''
as $$
  select exists (
    select 1 from public.platform_owners o where o.user_id = (select auth.uid())
  )
$$;

comment on function app.is_platform_owner() is
  'Am I the vendor. The only platform question a tenant session may ask, and it answers false.';

-- One refusal, in one place, so no function can be added later that forgets it.
-- Note what it does NOT do: it does not log the refusal. A raise aborts the
-- statement, and a statement that aborts takes its own INSERT with it, so a
-- denial cannot be recorded from inside the function that denies. Refused
-- attempts belong in the log in front of the database. That boundary is stated
-- in test-platform.sql rather than left to be discovered.
create or replace function app.require_platform_owner(p_action text)
returns uuid
language plpgsql
stable security definer
set search_path = ''
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'no platform credential: % is not something an anonymous session does', p_action
      using errcode = '42501';
  end if;
  if not exists (select 1 from public.platform_owners o where o.user_id = v_uid) then
    raise exception 'no platform credential for %', p_action
      using errcode = '42501',
            hint = 'the platform seat is the vendor''s and is not reachable from any tenant role';
  end if;
  return v_uid;
end $$;

-- Not callable by any tenant. If it were, the log could be forged, and a log
-- that can be forged is worth less than no log at all because it invites
-- belief. Only the definer functions below call it, and they call it as the
-- function owner.
create or replace function app.platform_note(
  p_action        text,
  p_league        uuid    default null,
  p_team          uuid    default null,
  p_subject_user  uuid    default null,
  p_subject_email text    default null,
  p_rows          integer default null,
  p_detail        jsonb   default '{}'::jsonb)
returns void
language plpgsql
volatile security definer
set search_path = ''
as $$
begin
  insert into public.platform_events
    (actor, action, league_id, team_id, subject_user, subject_email, rows_returned, detail)
  values
    (auth.uid(), p_action, p_league, p_team, p_subject_user, p_subject_email, p_rows,
     coalesce(p_detail, '{}'::jsonb));
end $$;

-- ---------------------------------------------------------------------------
-- 5. Bootstrapping: how the first platform owner exists
-- ---------------------------------------------------------------------------
-- Answered deliberately, because "somebody has to be first" is where this kind
-- of role usually grows a back door.
--
-- THE FIRST OWNER IS A DEPLOY-TIME FACT, NOT A RUNTIME FEATURE. It is written
-- by platform-seed.sql, running as the migration role, which is the credential
-- that could drop the database anyway -- so it grants nothing that was not
-- already held. There is no env-gated function, no claim endpoint, no "first
-- user wins" rule and no default row: each of those is reachable from the
-- network, and this is not.
--
-- The insert still has to say so out loud. The trigger below refuses any INSERT
-- unless either the session is already a platform owner (that is how the SECOND
-- owner is made, by app.grant_platform_owner) or the tx-local flag
--     select set_config('app.platform_bootstrap', 'on', true);
-- is set -- the same explicit-intent pattern schema.sql uses to stop a play
-- being deleted by accident. A tenant may set that GUC all day; they hold no
-- INSERT privilege on the table, so it buys them nothing.
--
-- And the separation rule: a user id that holds ANY membership is refused,
-- whichever door it arrives at. That is what makes "a head coach, a league
-- admin and a board member cannot become a platform owner" true by
-- construction rather than by policy review.

create or replace function app.platform_owners_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not app.is_platform_owner()
     and coalesce(current_setting('app.platform_bootstrap', true), '') <> 'on' then
    raise exception 'refusing to create a platform owner: this is not a self-service seat'
      using errcode = '42501',
            hint = 'an existing platform owner calls app.grant_platform_owner(); the first one is written by the migration with app.platform_bootstrap set';
  end if;

  if exists (select 1 from public.memberships m where m.user_id = new.user_id)
     or exists (select 1 from public.league_memberships lm where lm.user_id = new.user_id) then
    raise exception 'refusing to promote a tenant account to the platform seat: % already holds a membership', new.user_id
      using errcode = '42501',
            hint = 'the vendor seat is a separate account, so that "a platform owner cannot read a play" needs no exceptions';
  end if;

  return new;
end $$;

create trigger platform_owners_guard
  before insert or update on public.platform_owners
  for each row execute function app.platform_owners_guard();

-- Seats are audited like everything else, including the bootstrap row.
create or replace function app.audit_platform_owner()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    perform app.platform_note('owner_grant', null, null, new.user_id, new.email, null,
                              jsonb_build_object('note', new.note));
    return new;
  elsif tg_op = 'UPDATE' then
    perform app.platform_note('owner_change', null, null, new.user_id, new.email, null,
                              jsonb_build_object('from_email', old.email));
    return new;
  else
    perform app.platform_note('owner_revoke', null, null, old.user_id, old.email, null, '{}'::jsonb);
    return old;
  end if;
end $$;

create trigger platform_owners_audit
  after insert or update or delete on public.platform_owners
  for each row execute function app.audit_platform_owner();

create or replace function app.grant_platform_owner(p_user uuid, p_email text, p_note text default null)
returns boolean
language plpgsql
volatile security definer
set search_path = ''
as $$
declare v_uid uuid := app.require_platform_owner('granting a platform seat');
begin
  if p_user is null then
    raise exception 'a platform seat needs a user' using errcode = '22023';
  end if;
  insert into public.platform_owners (user_id, email, added_by, note)
  values (p_user, lower(btrim(coalesce(p_email, ''))), v_uid, p_note);
  return true;
end $$;

comment on function app.grant_platform_owner(uuid, text, text) is
  'A platform owner opens a second platform seat. Cannot open the first: the caller has to be one already, and the first row is written by the migration.';

create or replace function app.revoke_platform_owner(p_user uuid)
returns boolean
language plpgsql
volatile security definer
set search_path = ''
as $$
declare
  v_uid uuid := app.require_platform_owner('revoking a platform seat');
  v_n   integer;
begin
  if p_user = v_uid then
    raise exception 'refusing to revoke your own platform seat'
      using errcode = '22023',
            hint = 'the last person out cannot lock the door behind themselves by accident';
  end if;
  delete from public.platform_owners where user_id = p_user;
  get diagnostics v_n = row_count;
  return v_n = 1;
end $$;

create or replace function app.platform_owners_list()
returns table (user_id uuid, email text, added_at timestamptz, added_by uuid)
language plpgsql
stable security definer
set search_path = ''
as $$
begin
  perform app.require_platform_owner('listing platform seats');
  return query
    select o.user_id, o.email, o.added_at, o.added_by
      from public.platform_owners o order by o.added_at, o.user_id;
end $$;

-- ---------------------------------------------------------------------------
-- 6. The seat is not a tenant seat -- the other direction
-- ---------------------------------------------------------------------------
-- Refuses a membership for a platform owner, and refuses a NEW SEAT of any kind
-- in a suspended league. One function, three triggers, shape-agnostic: it reads
-- the row through to_jsonb() so the same code covers memberships (team_id),
-- league_memberships (league_id) and invites (either).
--
-- This is inert for every session in the existing suites: nobody there is a
-- platform owner and no seeded league is suspended.

create or replace function app.tenant_seat_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  j        jsonb := to_jsonb(new);
  v_user   uuid;
  v_league uuid;
begin
  v_user := nullif(j ->> 'user_id', '')::uuid;
  if v_user is not null
     and exists (select 1 from public.platform_owners o where o.user_id = v_user) then
    raise exception 'refusing to give a tenant seat to the platform owner %', v_user
      using errcode = '42501',
            hint = 'the vendor seat holds no football; coach with a separate account';
  end if;

  v_league := coalesce(
    nullif(j ->> 'league_id', '')::uuid,
    (select t.league_id from public.teams t where t.id = nullif(j ->> 'team_id', '')::uuid));

  if v_league is not null
     and exists (select 1 from public.league_platform_state s
                  where s.league_id = v_league and s.status = 'suspended') then
    raise exception 'league % is suspended: no new seats until it is reinstated', v_league
      using errcode = '42501',
            hint = 'suspension refuses new seats. It deletes nothing and hides nothing -- everybody already in the league keeps working.';
  end if;

  return new;
end $$;

create trigger memberships_platform_guard
  before insert or update on public.memberships
  for each row execute function app.tenant_seat_guard();

create trigger league_memberships_platform_guard
  before insert or update on public.league_memberships
  for each row execute function app.tenant_seat_guard();

create trigger invites_platform_guard
  before insert on public.invites
  for each row execute function app.tenant_seat_guard();

-- ---------------------------------------------------------------------------
-- 7. What the platform owner may READ: counts, dates and money
-- ---------------------------------------------------------------------------
-- Read the return types of the next three functions as the specification of
-- what the vendor can see, because they are exactly that. There is no other
-- read path: the seat holds no SELECT policy on any tenant table.
--
-- WHAT IS DELIBERATELY ABSENT: no player last or first name, no jersey, no
-- play slug, no play document, no route, no lane, no job, no consent, no
-- tombstone, no player word. A jersey number would arguably have been
-- defensible -- CLAUDE.md's "last name and number" convention already treats a
-- number as the minimised form -- but no business question needs one, so the
-- seat does not get one. The narrowest thing that answers the question is the
-- right size for this seat.

create or replace function app.platform_leagues()
returns table (
  league_id          uuid,
  league_name        text,
  status             text,
  plan               text,
  seats_purchased    integer,
  contract_ends_on   date,
  season_count       bigint,
  season_first_start date,
  season_last_end    date,
  team_count         bigint,
  coach_seats        bigint,
  board_seats        bigint,
  player_count       bigint,
  play_count         bigint,
  last_play_edit     timestamptz,
  created_at         timestamptz)
language plpgsql
volatile security definer
set search_path = ''
as $$
declare v_n integer;
begin
  perform app.require_platform_owner('listing leagues');
  return query
    select l.id,
           l.name,
           coalesce(s.status, 'active'),
           coalesce(s.plan, 'none'),
           s.seats_purchased,
           s.contract_ends_on,
           (select count(*)          from public.seasons se where se.league_id = l.id),
           (select min(se.starts_on) from public.seasons se where se.league_id = l.id),
           (select max(se.ends_on)   from public.seasons se where se.league_id = l.id),
           (select count(*) from public.teams t where t.league_id = l.id),
           (select count(*) from public.memberships m
             where m.team_id in (select t.id from public.teams t where t.league_id = l.id)),
           (select count(*) from public.league_memberships lm where lm.league_id = l.id),
           (select count(*) from public.players p
             where p.team_id in (select t.id from public.teams t where t.league_id = l.id)),
           (select count(*) from public.plays pl
             where pl.team_id in (select t.id from public.teams t where t.league_id = l.id)),
           (select max(pl.updated_at) from public.plays pl
             where pl.team_id in (select t.id from public.teams t where t.league_id = l.id)),
           l.created_at
      from public.leagues l
      left join public.league_platform_state s on s.league_id = l.id
     order by l.name;
  get diagnostics v_n = row_count;

  perform app.platform_note('leagues_list', null, null, null, null, v_n,
    jsonb_build_object('returns', 'counts only', 'names', 'league names only'));
end $$;

comment on function app.platform_leagues() is
  'Every league on the platform, as counts, dates and subscription state. The only names in the result are league names. Logs one platform_events row per call.';

create or replace function app.platform_league(p_league uuid)
returns table (
  team_id        uuid,
  team_name      text,
  grade          text,
  season_name    text,
  season_ends_on date,
  coach_seats    bigint,
  player_count   bigint,
  play_count     bigint,
  last_play_edit timestamptz)
language plpgsql
volatile security definer
set search_path = ''
as $$
declare v_n integer;
begin
  perform app.require_platform_owner('reading a league');
  return query
    select t.id, t.name, t.grade, se.name, se.ends_on,
           (select count(*) from public.memberships m where m.team_id = t.id),
           (select count(*) from public.players  p  where p.team_id  = t.id),
           (select count(*) from public.plays    pl where pl.team_id = t.id),
           (select max(pl.updated_at) from public.plays pl where pl.team_id = t.id)
      from public.teams t
      join public.seasons se on se.id = t.season_id
     where t.league_id = p_league
     order by se.starts_on desc, t.grade, t.name;
  get diagnostics v_n = row_count;

  perform app.platform_note('league_detail', p_league, null, null, null, v_n,
    jsonb_build_object('returns', 'per-team counts'));
end $$;

comment on function app.platform_league(uuid) is
  'One league, team by team, as counts. A team name, a grade and a season -- never a roster, never a play.';

-- The trail a buyer asks for: who was given a seat, who lost one, what invites
-- were sent. It is the LEAGUE's own auth_events, unmodified.
--
-- THE ONE PLACE A PERSON IS NAMED, AND WHY IT IS DEFENSIBLE. auth_events rows
-- carry the email of the adult a seat was granted to or an invitation was
-- addressed to. That is the customer's staff -- the people we invoice, support
-- and revoke -- and a support question of the form "why can this coach not sign
-- in" is unanswerable without it. It is not a child: nothing in the auth_events
-- action list touches a player, and test-platform.sql asserts that no player's
-- surname appears anywhere in the log. The read is logged and the league's own
-- admins can see that we made it.
create or replace function app.platform_audit(p_league uuid, p_limit integer default 200)
returns table (
  at            timestamptz,
  action        text,
  actor         uuid,
  team_id       uuid,
  subject_user  uuid,
  subject_email text,
  detail        jsonb)
language plpgsql
volatile security definer
set search_path = ''
as $$
declare v_n integer;
begin
  perform app.require_platform_owner('reading a league audit trail');
  return query
    select e.at, e.action, e.actor, e.team_id, e.subject_user, e.subject_email, e.detail
      from public.auth_events e
     where e.league_id = p_league
        or e.team_id in (select t.id from public.teams t where t.league_id = p_league)
     order by e.at desc, e.id desc
     limit greatest(1, least(coalesce(p_limit, 200), 1000));
  get diagnostics v_n = row_count;

  perform app.platform_note('audit_read', p_league, null, null, null, v_n,
    jsonb_build_object('limit', p_limit));
end $$;

-- Our own trail, read back. Not logged: a read of the log by the only person
-- the log is about would be an entry saying that the person read the entries,
-- for ever. What matters is that it cannot be changed, and it cannot.
create or replace function app.platform_trail(p_league uuid default null, p_limit integer default 200)
returns setof public.platform_events
language plpgsql
stable security definer
set search_path = ''
as $$
begin
  perform app.require_platform_owner('reading the platform trail');
  return query
    select e.* from public.platform_events e
     where p_league is null or e.league_id = p_league
     order by e.at desc, e.id desc
     limit greatest(1, least(coalesce(p_limit, 200), 1000));
end $$;

-- ---------------------------------------------------------------------------
-- 8. What the platform owner may DO: sell, staff the first seat, suspend
-- ---------------------------------------------------------------------------

-- Provisioning a league is a sale. rls.sql says so already by giving nobody an
-- INSERT policy on public.leagues; this is the sale, and it is the only way in.
create or replace function app.create_league(
  p_name    text,
  p_ruleset jsonb default '{}'::jsonb,
  p_plan    text  default 'trial',
  p_seats   integer default null)
returns uuid
language plpgsql
volatile security definer
set search_path = ''
as $$
declare
  v_uid uuid := app.require_platform_owner('creating a league');
  v_id  uuid;
begin
  if coalesce(btrim(p_name), '') = '' then
    raise exception 'a league needs a name' using errcode = '22023';
  end if;
  insert into public.leagues (name, ruleset)
  values (btrim(p_name), coalesce(p_ruleset, '{}'::jsonb))
  returning id into v_id;

  insert into public.league_platform_state (league_id, plan, seats_purchased, status_changed_by)
  values (v_id, coalesce(p_plan, 'trial'), p_seats, v_uid);

  perform app.platform_note('league_create', v_id, null, null, null, 1,
    jsonb_build_object('name', btrim(p_name), 'plan', coalesce(p_plan, 'trial'), 'seats', p_seats));
  return v_id;
end $$;

comment on function app.create_league(text, jsonb, text, integer) is
  'Sell a league. Creates the row and its subscription state, and nothing else -- the first admin arrives by invitation, and builds their own seasons and teams from there.';

-- The first admin seat. A brand new league has no admin, so there is nobody
-- app.issue_invite() would accept as the issuer -- app.may_staff_league() is
-- admin-of-that-league and a platform owner is deliberately not one.
--
-- This is NOT a widening of app.issue_invite(). It is a second, narrower door
-- to the same table: role is fixed to 'admin', scope is fixed to a league, and
-- the redemption path is app.accept_invite() unchanged -- same token hashing,
-- same single use, same expiry, same email-claim check. auth.sql is not edited,
-- so its 243 tests do not move; the extra event goes to the platform trail so
-- the league can see that we opened the seat.
create or replace function app.platform_invite_admin(
  p_league    uuid,
  p_email     text,
  p_valid_for interval default interval '14 days')
returns table (invite_id uuid, token text)
language plpgsql
volatile security definer
set search_path = ''
as $$
declare
  v_uid    uuid := app.require_platform_owner('opening a league admin seat');
  v_email  text := lower(btrim(coalesce(p_email, '')));
  v_token  text;
  v_id     uuid;
  v_killed integer;
begin
  if not exists (select 1 from public.leagues l where l.id = p_league) then
    raise exception 'no such league' using errcode = '22023';
  end if;
  if v_email = '' or v_email not like '%_@_%' then
    raise exception 'an invitation needs an email address to be addressed to' using errcode = '22023';
  end if;
  if p_valid_for is null or p_valid_for <= interval '0' or p_valid_for > interval '90 days' then
    raise exception 'an invitation lives between 0 and 90 days' using errcode = '22023';
  end if;

  -- Same rule as app.issue_invite(): re-sending kills the outstanding token.
  with dead as (
    update public.invites i
       set revoked_at = now()
     where i.email = v_email
       and i.league_id = p_league
       and i.accepted_at is null and i.revoked_at is null
    returning i.id)
  insert into public.auth_events (actor, action, league_id, subject_email, detail)
  select v_uid, 'invite_superseded', p_league, v_email, jsonb_build_object('invite', d.id)
    from dead d;
  get diagnostics v_killed = row_count;

  v_token := app.new_invite_token();
  insert into public.invites (league_id, role, email, token_hash, issued_by, expires_at)
  values (p_league, 'admin', v_email, app.hash_secret(v_token), v_uid, now() + p_valid_for)
  returning id into v_id;

  insert into public.auth_events (actor, action, league_id, subject_email, detail)
  values (v_uid, 'invite_issue', p_league, v_email,
          jsonb_build_object('invite', v_id, 'role', 'admin',
                             'expires_at', now() + p_valid_for, 'superseded', v_killed,
                             'by', 'platform'));

  if v_killed > 0 then
    perform app.platform_note('admin_invite_superseded', p_league, null, null, v_email, v_killed, '{}'::jsonb);
  end if;
  perform app.platform_note('admin_invite', p_league, null, null, v_email, 1,
    jsonb_build_object('invite', v_id, 'role', 'admin'));

  invite_id := v_id;
  token     := v_token;
  return next;
end $$;

comment on function app.platform_invite_admin(uuid, text, interval) is
  'Open a league''s first admin seat. Role is fixed to admin and scope to one league; redemption is app.accept_invite() unchanged. Returns the token once, stores only its sha256.';

-- SUSPENSION. Read the return value: it is a census of everything the
-- suspension did not touch. That is not decoration -- it is the assertion the
-- test suite checks, written into the function so the promise and the proof are
-- the same numbers.
create or replace function app.suspend_league(p_league uuid, p_reason text default null)
returns jsonb
language plpgsql
volatile security definer
set search_path = ''
as $$
declare
  v_uid   uuid := app.require_platform_owner('suspending a league');
  v_stats jsonb;
begin
  if not exists (select 1 from public.leagues l where l.id = p_league) then
    raise exception 'no such league' using errcode = '22023';
  end if;

  select jsonb_build_object(
           'teams',    (select count(*) from public.teams t where t.league_id = p_league),
           'seasons',  (select count(*) from public.seasons se where se.league_id = p_league),
           'players',  (select count(*) from public.players p
                         where p.team_id in (select t.id from public.teams t where t.league_id = p_league)),
           'plays',    (select count(*) from public.plays pl
                         where pl.team_id in (select t.id from public.teams t where t.league_id = p_league)),
           'seats',    (select count(*) from public.memberships m
                         where m.team_id in (select t.id from public.teams t where t.league_id = p_league))
                     + (select count(*) from public.league_memberships lm where lm.league_id = p_league))
    into v_stats;

  insert into public.league_platform_state (league_id, status, status_reason, status_changed_at, status_changed_by)
  values (p_league, 'suspended', p_reason, now(), v_uid)
  on conflict (league_id) do update
    set status = 'suspended', status_reason = excluded.status_reason,
        status_changed_at = now(), status_changed_by = excluded.status_changed_by;

  perform app.platform_note('league_suspend', p_league, null, null, null, null,
    jsonb_build_object('reason', p_reason, 'left_intact', v_stats));

  return jsonb_build_object('league', p_league, 'status', 'suspended',
                            'deleted', 0, 'left_intact', v_stats);
end $$;

comment on function app.suspend_league(uuid, text) is
  'Billing lapsed. Sets a flag and refuses new seats. Deletes nothing, hides nothing, and returns a census of what it left alone. Reversible with app.unsuspend_league().';

create or replace function app.unsuspend_league(p_league uuid)
returns jsonb
language plpgsql
volatile security definer
set search_path = ''
as $$
declare v_uid uuid := app.require_platform_owner('reinstating a league');
begin
  update public.league_platform_state
     set status = 'active', status_reason = null,
         status_changed_at = now(), status_changed_by = v_uid
   where league_id = p_league;
  if not found then
    raise exception 'no such league state' using errcode = '22023';
  end if;
  perform app.platform_note('league_unsuspend', p_league, null, null, null, null, '{}'::jsonb);
  return jsonb_build_object('league', p_league, 'status', 'active');
end $$;

-- ---------------------------------------------------------------------------
-- 9. Privileges and policies
-- ---------------------------------------------------------------------------
-- Same discipline as rls.sql and auth.sql: privileges say which verbs exist,
-- policies say which rows, and both have to pass.

-- SECURITY DEFINER functions are EXECUTE-to-PUBLIC by default, which would hand
-- an anonymous session a function running as the owner. Take it all back first.
revoke all on function
  app.is_platform_owner(), app.require_platform_owner(text),
  app.platform_note(text, uuid, uuid, uuid, text, integer, jsonb),
  app.platform_owners_guard(), app.audit_platform_owner(), app.tenant_seat_guard(),
  app.grant_platform_owner(uuid, text, text), app.revoke_platform_owner(uuid),
  app.platform_owners_list(),
  app.platform_leagues(), app.platform_league(uuid),
  app.platform_audit(uuid, integer), app.platform_trail(uuid, integer),
  app.create_league(text, jsonb, text, integer),
  app.platform_invite_admin(uuid, text, interval),
  app.suspend_league(uuid, text), app.unsuspend_league(uuid)
from public;

-- The platform functions are granted to the ordinary signed-in role, and refuse
-- inside. That is on purpose: on Supabase every signed-in session arrives as
-- `authenticated`, so a separate database role would be a fiction. The seat is
-- an identity, checked against a table, not a connection string -- and an
-- anonymous session fails on the missing privilege before it reaches the check.
grant execute on function
  app.platform_leagues(), app.platform_league(uuid),
  app.platform_audit(uuid, integer), app.platform_trail(uuid, integer),
  app.create_league(text, jsonb, text, integer),
  app.platform_invite_admin(uuid, text, interval),
  app.suspend_league(uuid, text), app.unsuspend_league(uuid),
  app.grant_platform_owner(uuid, text, text), app.revoke_platform_owner(uuid),
  app.platform_owners_list()
to pd_authenticated;

-- Everybody may ask whether they are the vendor. Everybody who is not gets false.
grant execute on function app.is_platform_owner() to pd_anon, pd_authenticated;

-- Deliberately granted to NOBODY: app.platform_note (a callable logger is a
-- forgeable log) and app.require_platform_owner (nothing needs to ask the
-- question from outside; the functions above ask it for you).

-- platform_owners: no verb, for anybody. Not even SELECT.
revoke all on public.platform_owners from pd_anon, pd_authenticated;

-- The league may read its own commercial state and its own surveillance trail,
-- and may write neither.
grant select on public.league_platform_state, public.platform_events
  to pd_anon, pd_authenticated;
revoke insert, update, delete on public.league_platform_state, public.platform_events
  from pd_anon, pd_authenticated;

alter table public.platform_owners        enable row level security;
alter table public.league_platform_state  enable row level security;
alter table public.platform_events        enable row level security;

alter table public.platform_owners        force row level security;
alter table public.league_platform_state  force row level security;
alter table public.platform_events        force row level security;

-- platform_owners has NO POLICY AT ALL, which with FORCE means no row is
-- visible to anybody who does not bypass RLS. The absence below is the design;
-- do not add one because a screen wanted a list. app.platform_owners_list() is
-- the list, and it checks the seat.

-- A league sees what it is paying for and whether it is suspended.
create policy league_platform_state_select on public.league_platform_state
  for select to pd_anon, pd_authenticated
  using (league_id in (select app.visible_league_ids()));

-- A league sees every time we looked at it. This is the answer to "what can you
-- see, and what did you see" being checkable rather than promised. Scoped to
-- the board and admins of that league; a coach does not get the vendor's
-- movements, and no league sees another's.
create policy platform_events_select on public.platform_events
  for select to pd_anon, pd_authenticated
  using (league_id in (select app.league_ids()));

-- FORCE binds the owner, and the owner is who the definer logger runs as, so
-- the append needs a policy or the trail could not be written at all. Pinned to
-- the acting session, exactly as auth_events_append is: the real guard on
-- forgery is that no tenant holds the INSERT privilege, and this means that even
-- if that ever changed, nobody could write an entry attributed to somebody else.
create policy platform_events_append on public.platform_events
  for insert
  with check (actor is not distinct from (select auth.uid()));

commit;
