-- product/db/migrations/0009_clubs.sql
-- WHY: a team whose league has not bought the product must be able to buy it on
-- its own, and pay less, because it is one team rather than thirty. Until now
-- every team reached the product through a league: public.teams.league_id is NOT
-- NULL, seasons hang off a league, and a team's season is tied to its league by
-- a composite foreign key.
--
-- WHY NOT SIMPLY MAKE league_id NULLABLE. It looks like the small change and it
-- is the dangerous one. Three things break, and the third is the one that
-- matters:
--
--   1. The composite FKs. teams.(season_id, league_id) -> seasons, and the leaf
--      tables point at teams.(id, league_id). All of them go soft against NULL.
--   2. Every RLS policy and helper that resolves a team's league to answer "may
--      this person see this row" would need a null branch, and a null branch in
--      a policy is where isolation bugs live.
--   3. CONSENT. A consent notice is published BY A LEAGUE
--      (public.consent_notices.league_id, and app.issue_consent_notice() is
--      league-admin only). A team with no league has nobody who can publish one,
--      so app.request_consent() can never find a live notice, and the collection
--      gate in 0007 stays shut forever -- an independent team could not write a
--      single child's name. An independent team holds children's data exactly
--      like a league team does, and COPPA does not care that nobody sold them a
--      league.
--
-- SO: A SOLO TEAM IS A CLUB, AND A CLUB IS A LEAGUE OF ONE. It gets its own
-- private league row, its own season, and its head coach is the admin of it. Not
-- one line of RLS, consent, branding or platform code changes, because nothing
-- downstream can tell the difference -- which is the point. The only new rule is
-- that a club holds exactly one team, and that rule is what keeps a thirty-team
-- league from paying a one-team price.
--
-- WHAT THIS FILE DELIBERATELY DOES NOT DO: set a price. There is no Stripe
-- account yet and the entity is new (see product/REUSE.md). What it adds is the
-- seam an invoice is built from -- app.billable_units() -- and the guard that
-- makes the cheaper rate honest. The numbers are the founders'.

-- ---------------------------------------------------------------------------
-- 1. What kind of customer this is
-- ---------------------------------------------------------------------------

alter table public.leagues
  add column if not exists kind text not null default 'league';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'leagues_kind') then
    alter table public.leagues
      add constraint leagues_kind check (kind in ('league', 'club'));
  end if;
end $$;

comment on column public.leagues.kind is
  'league = a governing body that signed up and brought its teams. club = one team that signed up on its own, at the single-team rate. A club is a league row with exactly one team in it, so every policy, notice and brand below works unchanged.';

-- Every existing row is a league. The default handles that, and it is stated
-- rather than assumed because a mis-defaulted tenancy column is a pricing bug.
create index if not exists leagues_kind_idx on public.leagues (kind);

-- ---------------------------------------------------------------------------
-- 1b. Two new things the trail has to be able to say
-- ---------------------------------------------------------------------------
-- public.platform_events has a CHECK listing every action it accepts, so a
-- typo cannot invent a category nobody reads. Two actions are new here, and the
-- constraint is REPLACED ADDITIVELY -- every existing value stays legal, so the
-- 252 tests in test-platform.sql do not move. 0005_platform.sql is not edited,
-- for the same reason it did not edit 0004_auth.sql.
alter table public.platform_events drop constraint if exists platform_events_action;
alter table public.platform_events add constraint platform_events_action check (
  action = any (array[
    'leagues_list', 'league_detail', 'audit_read', 'league_create',
    'admin_invite', 'admin_invite_superseded',
    'league_suspend', 'league_unsuspend',
    'owner_grant', 'owner_revoke', 'owner_change',
    -- new in 0009
    'club_start',      -- a team signed itself up with no league behind it
    'club_convert'     -- and later became a league, which changes what it pays
  ])
);

-- ---------------------------------------------------------------------------
-- 2. THE RULE THAT MAKES THE CHEAPER RATE HONEST
-- ---------------------------------------------------------------------------
-- Without this, a club is a free league: sign up as one team, then add the other
-- twenty-nine. The cap lives in the database rather than in a signup screen,
-- because the signup screen is not what a determined customer talks to.

-- SECURITY DEFINER, and the reason is a correction. This was INVOKER, with a
-- comment claiming that made it "bind the owner too". That was wrong twice
-- over. A trigger fires for the table's owner whatever its security setting --
-- that is what makes it bind everybody -- so INVOKER was not buying that. And
-- INVOKER actively made the count WRONG: it runs under the caller's RLS, and a
-- session that cannot see a club's existing team counts zero teams in it.
-- Measured: a coach counting teams in a league he is not a member of gets 0,
-- where the owner gets 2. A cap whose count RLS can filter is not a cap.
--
-- Nothing was exploitable, because the RLS policy on public.teams refuses that
-- INSERT before the trigger runs -- but "another guard catches it" is the
-- reasoning that left four consent tables on USING (true), and it is not good
-- enough for the rule that holds the price list up.
create or replace function app.club_single_team_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare v_kind text; v_n integer;
begin
  select l.kind into v_kind from public.leagues l where l.id = new.league_id;
  if v_kind is distinct from 'club' then
    return new;
  end if;

  select count(*) into v_n from public.teams t
   where t.league_id = new.league_id
     and (tg_op = 'INSERT' or t.id <> old.id);

  if v_n >= 1 then
    raise exception 'a club is a single team; this one already has %', v_n
      using errcode = '42501',
            hint = 'a second team means this is a league. app.convert_club_to_league() changes the kind, and the rate, on purpose.';
  end if;
  return new;
end $$;

-- `if exists` so the file is re-runnable; on a first apply it says "skipping",
-- which is the migration working, not a warning.
set local client_min_messages = warning;
drop trigger if exists teams_club_single on public.teams;
reset client_min_messages;
create trigger teams_club_single
  before insert or update of league_id on public.teams
  for each row execute function app.club_single_team_guard();

comment on function app.club_single_team_guard() is
  'A club holds one team. SECURITY DEFINER so the count is the true one rather than whatever the caller''s RLS lets them see; it binds the owner because a trigger fires for the owner, not because of its security setting. A second team must be a deliberate conversion, not a quiet insert.';

-- ---------------------------------------------------------------------------
-- 3. Signing up alone
-- ---------------------------------------------------------------------------
-- 0004_auth.sql says, twice and in capitals, that there is no self-signup path.
-- That rule is about JOINING: nobody may put themselves into a team or a league
-- that already exists, because that is somebody else's data. This function does
-- not do that and cannot be made to.
--
-- It CREATES A NEW TENANT CONTAINING ONLY THE CALLER. There is no parameter
-- naming an existing league, an existing team or another user; every id it
-- touches is one it has just generated. The worst a caller can do with it is
-- make themselves an empty club, which is what a signup button is for.
--
-- The head coach is also made ADMIN of his own club, and that is required
-- rather than generous: app.issue_consent_notice() is league-admin only, so
-- without it he could never publish the notice that lets him write a child's
-- name. It grants him nothing outside his own one-team league -- every policy
-- scopes on league_id and his league contains only him.

create or replace function app.start_club(
  p_club_name  text,
  p_team_name  text,
  p_grade      text,
  p_season     text default null,
  p_starts_on  date default null,
  p_ends_on    date default null,
  p_ruleset    jsonb default '{}'::jsonb
) returns table (league_id uuid, season_id uuid, team_id uuid)
language plpgsql
volatile security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_email  text := auth.email();
  v_league uuid;
  v_season uuid;
  v_team   uuid;
  v_from   date := coalesce(p_starts_on, date_trunc('year', now())::date);
  v_to     date := coalesce(p_ends_on, (date_trunc('year', now()) + interval '1 year - 1 day')::date);
begin
  if v_uid is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;

  -- The vendor's seat holds no football. tenant_seat_guard() would refuse the
  -- membership anyway; refusing here means we do not leave an orphan league
  -- behind when it does.
  if exists (select 1 from public.platform_owners o where o.user_id = v_uid) then
    raise exception 'the platform seat does not coach'
      using errcode = '42501',
            hint = 'sign up a club with a separate account';
  end if;

  if coalesce(btrim(p_club_name), '') = '' or coalesce(btrim(p_team_name), '') = ''
     or coalesce(btrim(p_grade), '') = '' then
    raise exception 'a club needs a name, a team name and a grade' using errcode = '22023';
  end if;
  if v_to < v_from then
    raise exception 'a season ends after it starts' using errcode = '22023';
  end if;

  insert into public.leagues (name, kind, ruleset)
  values (btrim(p_club_name), 'club', coalesce(p_ruleset, '{}'::jsonb))
  returning id into v_league;

  insert into public.seasons (league_id, name, starts_on, ends_on)
  values (v_league, coalesce(nullif(btrim(coalesce(p_season, '')), ''),
                             to_char(v_from, 'YYYY') || ' season'), v_from, v_to)
  returning id into v_season;

  insert into public.teams (league_id, name, grade, season_id)
  values (v_league, btrim(p_team_name), btrim(p_grade), v_season)
  returning id into v_team;

  -- He runs the team, and administers the club so he can publish his own
  -- consent notice. Both scoped to rows that did not exist a moment ago.
  insert into public.memberships (user_id, team_id, role) values (v_uid, v_team, 'head');
  insert into public.league_memberships (user_id, league_id, role) values (v_uid, v_league, 'admin');

  -- A club starts on trial like anything else. What it is BILLED is decided by
  -- app.billable_units() and by a human; nothing here sets a price.
  insert into public.league_platform_state (league_id, plan, seats_purchased, status_changed_by)
  values (v_league, 'trial', 1, v_uid);

  -- (action, league, team, subject_user, subject_email, rows, detail)
  perform app.platform_note('club_start', v_league, v_team, v_uid, v_email, 1,
    jsonb_build_object('club', btrim(p_club_name), 'team', btrim(p_team_name),
                       'grade', btrim(p_grade)));

  league_id := v_league; season_id := v_season; team_id := v_team;
  return next;
end $$;

comment on function app.start_club(text, text, text, text, date, date, jsonb) is
  'Self-serve signup for one team with no league behind it. Creates a NEW tenant containing only the caller -- it takes no id of anything that already exists, so it cannot be used to join somebody else. Not a hole in "invite only", which is about joining.';

-- ---------------------------------------------------------------------------
-- 4. Growing up: a club that becomes a league
-- ---------------------------------------------------------------------------
-- Deliberately the platform's call and not the coach's, because it is the
-- moment the price changes. It is one column and an event; nothing moves, no id
-- changes, and every play, child and consent stays exactly where it is.

create or replace function app.convert_club_to_league(p_league uuid, p_why text default null)
returns boolean
language plpgsql
volatile security definer
set search_path = ''
as $$
declare
  v_uid  uuid := app.require_platform_owner('converting a club to a league');
  v_kind text;
begin
  select kind into v_kind from public.leagues where id = p_league;
  if v_kind is null then
    raise exception 'no such league' using errcode = '42501';
  end if;
  if v_kind <> 'club' then
    raise exception 'league % is already a league, not a club', p_league using errcode = '22023';
  end if;

  update public.leagues set kind = 'league' where id = p_league;

  perform app.platform_note('club_convert', p_league, null, v_uid, null, 1,
    jsonb_build_object('from', 'club', 'to', 'league', 'why', nullif(btrim(coalesce(p_why, '')), '')));
  return true;
end $$;

comment on function app.convert_club_to_league(uuid, text) is
  'Turn a one-team club into a league that may hold many. The vendor''s call, because it is the moment the rate changes; recorded in the platform trail either way.';

-- ---------------------------------------------------------------------------
-- 5. What an invoice would be built from
-- ---------------------------------------------------------------------------
-- The seam, not the price. Everything a bill needs to know about a tenant and
-- nothing about money, so that when there IS a Stripe account the pricing lives
-- in one place above this rather than smeared through the schema.
--
-- `billable_teams` rather than `teams`: a club is one by construction, and a
-- league is what it actually has. `active_seats` is people who can log in, which
-- is the other axis anybody prices on.

create or replace function app.billable_units(p_league uuid)
returns table (
  league_id uuid, kind text, plan text, status text,
  billable_teams integer, active_seats integer, children integer
)
language plpgsql
stable security definer
set search_path = ''
as $$
begin
  if not (app.is_platform_owner() or app.may_staff_league(p_league)) then
    raise exception 'no such league' using errcode = '42501';
  end if;
  return query
  select l.id, l.kind,
         coalesce(s.plan, 'trial'), coalesce(s.status, 'active'),
         (select count(*)::integer from public.teams t where t.league_id = l.id),
         (select count(distinct u)::integer from (
            select m.user_id u from public.memberships m
              join public.teams t2 on t2.id = m.team_id where t2.league_id = l.id
            union
            select lm.user_id from public.league_memberships lm where lm.league_id = l.id
          ) _),
         (select count(*)::integer from public.players p
            join public.teams t3 on t3.id = p.team_id where t3.league_id = l.id)
    from public.leagues l
    left join public.league_platform_state s on s.league_id = l.id
   where l.id = p_league;
end $$;

comment on function app.billable_units(uuid) is
  'The numbers a bill is made of -- kind, plan, teams, seats, children -- and no money. Readable by the league''s own admin and by the platform seat. Pricing belongs above this, in one place.';

-- ---------------------------------------------------------------------------
-- 6. Grants
-- ---------------------------------------------------------------------------

revoke all on function
  app.club_single_team_guard(),
  app.start_club(text, text, text, text, date, date, jsonb),
  app.convert_club_to_league(uuid, text),
  app.billable_units(uuid)
from public;

-- Signing up requires an account and nothing else. pd_anon is deliberately NOT
-- given this: a club is created by somebody who is already authenticated, so
-- there is always a person to attach the head-coach seat to.
grant execute on function app.start_club(text, text, text, text, date, date, jsonb)
  to pd_authenticated;

grant execute on function app.billable_units(uuid) to pd_authenticated;

-- The conversion is the platform's, and it checks that itself. Granted so the
-- vendor's own signed-in session can call it; refused inside for anybody else.
grant execute on function app.convert_club_to_league(uuid, text) to pd_authenticated;
