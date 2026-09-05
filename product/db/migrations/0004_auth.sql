-- product/db/migrations/0004_auth.sql
-- Accounts, invitations, revocation, the player word, and the audit log.
--
-- WHY THIS EXISTS
-- The head coach's gate today is a shared password with a tier baked into a
-- cookie and the hash namespace hardcoded to `lehi-8a::`. It has no identity in
-- it: there is no way to say who changed something, no way to revoke one coach
-- without changing the word for everybody, and no log to hand a league buyer.
-- It cannot be sold. This file replaces it with four things:
--
--   1. Coaches are real accounts. Identity arrives as auth.uid() -- Supabase
--      Auth, email magic link, in production -- and nothing here re-plumbs that.
--      migrations/0002_schema.sql already made auth.uid() the single door; this file walks
--      through it and adds one more claim off the same token, auth.email(),
--      because an invitation is addressed to an email.
--   2. INVITE ONLY. There is no self-signup path into an existing team or
--      league anywhere in this schema. A membership row is created by exactly
--      two things: a head/admin writing one directly (migrations/0003_rls.sql already governs
--      that), or app.accept_invite() redeeming a token that was minted by a
--      head/admin and emailed to one address. Nothing else can mint one --
--      pd_authenticated has no INSERT policy on memberships except through
--      memberships_write_head.
--   3. Revocation is a DELETE and it bites on the next statement. There is no
--      cached tier, no session table, and no cookie: every policy resolves
--      membership live, through the security definer helpers in migrations/0003_rls.sql.
--   4. Players get no account. A per-team, rotating, read-only word, deliberately
--      -- making 13-year-olds create accounts is the fastest way to trigger
--      COPPA at its strictest. The word is scoped to ONE team by primary key,
--      rotates without touching anything else, and grants SELECT on that team's
--      plays and roster and nothing else anywhere.
--
-- Load order: migrations/0002_schema.sql -> migrations/0003_rls.sql -> migrations/0004_auth.sql -> seed.sql -> auth-seed.sql
-- Tests:     test-isolation.sql (183, unchanged by this file) and test-auth.sql
--
-- COMPOSES WITH migrations/0003_rls.sql, DOES NOT EDIT IT. Everything here is additive: two new
-- permissive SELECT policies (the player word), three new tables with their own
-- policies, and one trigger apiece on memberships and league_memberships. Every
-- policy added here is false when its credential is absent, so a session that
-- holds no player word sees exactly what it saw before this file existed.
--
-- PORTABILITY. Stock PostgreSQL 16 and Supabase, unchanged, with no extensions:
-- sha256(), convert_to(), encode() and gen_random_uuid() are all core in PG 13+.
-- pgcrypto is deliberately not required, because on Supabase it lives in the
-- `extensions` schema and every function here runs with an empty search_path.

\set ON_ERROR_STOP on

-- The transaction is supplied by the runner (product/db/migrate.mjs), which
-- wraps this file and its ledger row in ONE transaction. A migration that
-- committed itself could succeed while its ledger row failed, and the next run
-- would replay it. Do not add begin/commit here.

-- ---------------------------------------------------------------------------
-- 0. The second claim: the email the magic link was sent to
-- ---------------------------------------------------------------------------
-- Identity is auth.uid(). An invitation, though, is addressed to an email
-- address, and the whole point of magic-link auth is that holding the mailbox
-- is the proof. So acceptance checks both: the token proves you were sent the
-- link, the email claim proves the mailbox that was sent it is yours.
--
-- HERE: the GUC `app.user_email`, stamped by the pooler exactly as `app.user_id`
-- is. ON SUPABASE: auth.email() already exists and reads the verified JWT, so
-- the guarded block below does nothing and no policy changes.
--
-- Fail closed, same as app.current_user_id(): anything malformed is NULL, and
-- NULL never matches an invite.

create or replace function app.current_user_email()
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  return nullif(lower(btrim(current_setting('app.user_email', true))), '');
exception when others then
  return null;
end $$;

comment on function app.current_user_email() is
  'Verified email from the GUC app.user_email. Maps 1:1 to Supabase auth.email() (JWT email claim). NULL on anything malformed, and a NULL email accepts no invitation.';

do $$
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'auth' and p.proname = 'email' and p.pronargs = 0
  ) then
    execute $f$
      create function auth.email() returns text
      language sql stable
      as 'select app.current_user_email()';
    $f$;
    comment on function auth.email() is
      'Stand-in for Supabase auth.email(). Delegates to app.current_user_email(). Not created if the platform already provides it.';
  end if;
end $$;

grant execute on function app.current_user_email() to pd_anon, pd_authenticated;
grant execute on function auth.email() to pd_anon, pd_authenticated;

-- ---------------------------------------------------------------------------
-- 0b. Hashing. A token is stored the way a password is stored: not at all.
-- ---------------------------------------------------------------------------
-- SHA-256, not bcrypt, and deliberately so. bcrypt's cost factor exists to make
-- a dictionary attack on a LOW-ENTROPY human-chosen secret expensive. An invite
-- token here is 244 bits of gen_random_uuid() entropy; there is no dictionary,
-- and no salt is needed because there is nothing to precompute. What matters is
-- the property bcrypt and this share: the column holds a one-way digest, so a
-- copy of the database -- a backup, a support dump, a leaked read replica --
-- contains no usable invitation.
--
-- The player word IS low entropy on purpose (a boy types it), and that is
-- handled by scope and rotation rather than by cost: it reads one team, it
-- writes nothing, and rotating it is one function call. See section 3.

create or replace function app.hash_secret(p_secret text)
returns text
language sql
immutable strict parallel safe
set search_path = ''
as $$
  select encode(sha256(convert_to(p_secret, 'UTF8')), 'hex')
$$;

comment on function app.hash_secret(text) is
  'One-way digest for invite tokens and player words. Core sha256() -- no pgcrypto, because on Supabase it lives in a schema an empty search_path cannot see.';

-- 244 bits, from the same CSPRNG that backs gen_random_uuid() (pg_strong_random).
-- Two uuids rather than one because 122 bits is fine and 244 is free.
create or replace function app.new_invite_token()
returns text
language sql
volatile
set search_path = ''
as $$
  select replace(gen_random_uuid()::text, '-', '')
      || replace(gen_random_uuid()::text, '-', '')
$$;

comment on function app.new_invite_token() is
  'A 64-character, 244-bit invite token. Returned to the caller exactly once and never stored -- only app.hash_secret() of it is.';

-- A word a coach can say out loud to a huddle and a boy can type on a phone.
-- Three syllables and three digits: ~30 bits. That is a usability decision, not
-- an oversight -- see the comment on public.player_words.
create or replace function app.new_player_word()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  cons text[] := array['b','d','f','g','k','l','m','n','p','r','s','t','v','z','br','cl','dr','fl','gr','st'];
  vows text[] := array['a','e','i','o','u'];
  h    text   := replace(gen_random_uuid()::text, '-', '');   -- 32 hex chars, strong
  w    text   := '';
  i    int;
begin
  for i in 0..2 loop
    w := w
      || cons[1 + (('x' || substr(h, 1 + i * 4, 2))::bit(8)::int % 20)]
      || vows[1 + (('x' || substr(h, 3 + i * 4, 2))::bit(8)::int % 5)];
  end loop;
  return w || '-' || lpad((('x' || substr(h, 25, 4))::bit(16)::int % 1000)::text, 3, '0');
end $$;

-- ---------------------------------------------------------------------------
-- 1. invites -- the only way into a team or a league
-- ---------------------------------------------------------------------------
-- One row names exactly ONE scope (a team or a league, never both) and exactly
-- one role. That is the security crux: acceptance takes a token and nothing
-- else, so there is no team parameter for an attacker to tamper with. The team
-- is a property of the row the token hashes to, and the row is not writable by
-- any tenant -- no INSERT, UPDATE or DELETE privilege is granted on this table
-- to pd_authenticated or pd_anon at all. Only the security definer functions
-- below write it.
--
-- No ON DELETE CASCADE, here or anywhere else in this file: test-isolation.sql
-- asserts that the only cascade in the schema is player_consents -> players,
-- and that assertion is load-bearing (CLAUDE.md rule 1).

create table public.invites (
  id          uuid primary key default gen_random_uuid(),
  team_id     uuid references public.teams(id)   on delete restrict,
  league_id   uuid references public.leagues(id) on delete restrict,
  role        text not null,
  email       text not null,
  token_hash  text not null unique,
  issued_by   uuid,
  issued_at   timestamptz not null default now(),
  expires_at  timestamptz not null,
  accepted_at timestamptz,
  accepted_by uuid,
  revoked_at  timestamptz,
  -- Exactly one scope. A row that named both would be a row whose meaning
  -- depended on the reader.
  constraint invites_one_scope check ((team_id is null) <> (league_id is null)),
  -- The role has to be legal for the scope it is in. A 'head' of a league or a
  -- 'board' of a team is not a thing, and the membership tables would refuse it
  -- later -- better to refuse it at issue time than at accept time.
  constraint invites_role_matches_scope check (
    case when team_id is not null then role in ('head','assistant','helper')
                                  else role in ('board','admin') end),
  constraint invites_email_normalised check (email = lower(btrim(email)) and email like '%_@_%'),
  -- The shape of a sha256 hex digest. A plaintext token in this column is not
  -- 64 lowercase hex characters, so the constraint would reject it.
  constraint invites_token_hash_shape check (token_hash ~ '^[0-9a-f]{64}$'),
  constraint invites_expiry_after_issue check (expires_at > issued_at),
  constraint invites_accept_complete check ((accepted_at is null) = (accepted_by is null))
);

comment on table public.invites is
  'Invite only. A membership is created by a head/admin writing one, or by redeeming a token from this table. There is no self-signup path in this schema.';
comment on column public.invites.token_hash is
  'sha256 hex of the token. The token itself is returned by app.issue_invite() once and is never stored -- a database backup contains no usable invitation.';
comment on column public.invites.email is
  'Lowercased. Acceptance requires the accepting account''s verified email claim to equal this, so a forwarded link is useless to the person it was forwarded to.';

create index invites_team_idx   on public.invites (team_id)   where team_id is not null;
create index invites_league_idx on public.invites (league_id) where league_id is not null;
create index invites_email_idx  on public.invites (email);

-- ---------------------------------------------------------------------------
-- 2. auth_events -- the audit trail his gate does not have
-- ---------------------------------------------------------------------------
-- Who changed what, when. A league buyer asks this question and "the cookie had
-- a tier in it" is not an answer.
--
-- INSERT ONLY, and enforced three ways, because one way is a promise and three
-- are a design:
--   * no INSERT/UPDATE/DELETE privilege for any tenant role -- the rows are
--     written by security definer triggers and functions, never by a client;
--   * a BEFORE UPDATE OR DELETE trigger that refuses, which binds the table
--     OWNER too, so not even the migration role can quietly rewrite history;
--   * a BEFORE TRUNCATE trigger, because TRUNCATE skips row triggers.
--
-- NO FOREIGN KEYS, deliberately. An audit row has to outlive the thing it
-- describes: the log of a team being deleted cannot be a row that a team
-- deletion is allowed to block or take with it.

create table public.auth_events (
  id           bigint generated always as identity primary key,
  at           timestamptz not null default now(),
  actor        uuid,                       -- auth.uid() at the time; NULL = a job or a migration
  action       text not null,
  team_id      uuid,
  league_id    uuid,
  subject_user uuid,
  subject_email text,
  detail       jsonb not null default '{}'::jsonb,
  constraint auth_events_action check (action in (
    'membership_grant','membership_revoke','membership_role_change',
    'league_membership_grant','league_membership_revoke','league_membership_role_change',
    'invite_issue','invite_accept','invite_revoke','invite_superseded',
    'player_word_rotate','player_word_clear')),
  constraint auth_events_detail_object check (jsonb_typeof(detail) = 'object')
);

comment on table public.auth_events is
  'Insert-only audit of every membership grant, revocation and role change, every invitation issued/accepted/withdrawn, and every player-word rotation. No foreign keys: an audit row outlives its subject.';
comment on column public.auth_events.detail is
  'Never holds a credential. The invite token and the player word are not written here -- test-auth.sql greps the log for both.';

create index auth_events_team_idx   on public.auth_events (team_id, at desc);
create index auth_events_league_idx on public.auth_events (league_id, at desc);
create index auth_events_actor_idx  on public.auth_events (actor, at desc);

create or replace function app.auth_events_append_only()
returns trigger
language plpgsql
as $$
begin
  raise exception 'auth_events is insert-only: refusing to % row %',
    lower(tg_op), coalesce(old.id::text, '?')
    using errcode = '42501',
          hint = 'an audit trail you can edit is not an audit trail';
  return null;
end $$;

create trigger auth_events_no_update
  before update on public.auth_events
  for each row execute function app.auth_events_append_only();

create trigger auth_events_no_delete
  before delete on public.auth_events
  for each row execute function app.auth_events_append_only();

create or replace function app.auth_events_no_truncate()
returns trigger
language plpgsql
as $$
begin
  raise exception 'refusing to truncate public.auth_events: the log is insert-only'
    using errcode = '42501';
end $$;

create trigger auth_events_no_truncate
  before truncate on public.auth_events
  for each statement execute function app.auth_events_no_truncate();

-- The log writes itself. Auditing from the application would mean auditing the
-- paths the application remembered to audit; a trigger on the table catches the
-- head coach's UI, the invite function, a psql session and a migration alike.
create or replace function app.audit_membership()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.auth_events (actor, action, team_id, subject_user, detail)
    values (auth.uid(), 'membership_grant', new.team_id, new.user_id,
            jsonb_build_object('role', new.role) ||
            case when new.invited_by is null then '{}'::jsonb
                 else jsonb_build_object('invited_by', new.invited_by) end);
    return new;
  elsif tg_op = 'UPDATE' then
    if new.role is distinct from old.role then
      insert into public.auth_events (actor, action, team_id, subject_user, detail)
      values (auth.uid(), 'membership_role_change', new.team_id, new.user_id,
              jsonb_build_object('from', old.role, 'to', new.role));
    end if;
    return new;
  else
    insert into public.auth_events (actor, action, team_id, subject_user, detail)
    values (auth.uid(), 'membership_revoke', old.team_id, old.user_id,
            jsonb_build_object('role', old.role));
    return old;
  end if;
end $$;

create trigger memberships_audit
  after insert or update or delete on public.memberships
  for each row execute function app.audit_membership();

create or replace function app.audit_league_membership()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.auth_events (actor, action, league_id, subject_user, detail)
    values (auth.uid(), 'league_membership_grant', new.league_id, new.user_id,
            jsonb_build_object('role', new.role));
    return new;
  elsif tg_op = 'UPDATE' then
    if new.role is distinct from old.role then
      insert into public.auth_events (actor, action, league_id, subject_user, detail)
      values (auth.uid(), 'league_membership_role_change', new.league_id, new.user_id,
              jsonb_build_object('from', old.role, 'to', new.role));
    end if;
    return new;
  else
    insert into public.auth_events (actor, action, league_id, subject_user, detail)
    values (auth.uid(), 'league_membership_revoke', old.league_id, old.user_id,
            jsonb_build_object('role', old.role));
    return old;
  end if;
end $$;

create trigger league_memberships_audit
  after insert or update or delete on public.league_memberships
  for each row execute function app.audit_league_membership();

-- ---------------------------------------------------------------------------
-- 3. player_words -- the boys, with no accounts
-- ---------------------------------------------------------------------------
-- CLAUDE.md's position, restated: a league product covers under-13s, and the
-- cheapest compliance posture is not to hold the data. An account per player
-- means an email per player, which means a guardian consent flow for the
-- account itself before anyone has drawn a play. So there are no player
-- accounts. There is a word.
--
-- The whole design is in the primary key: ONE row per team. The word cannot be
-- scoped to more than one team because there is nowhere to write a second
-- team_id, and rotating it is an UPDATE of one row that touches nothing else --
-- not the roster, not the plays, not a membership, not another team's word.
--
-- It is a READ credential and there is no policy anywhere in this file or in
-- migrations/0003_rls.sql that lets it write. It reaches exactly two tables: this team's plays
-- and this team's players. Not consents, not tombstones, not memberships, not
-- the team row, not the league.
--
-- ~30 bits of entropy, on purpose: a boy types it on a phone at practice. The
-- defences that matter for a secret that weak are the ones this table has --
-- narrow scope, read-only, per team, instantly rotatable, and an optional
-- expiry so a season's word dies with the season. Online guessing is a
-- rate-limit problem and rate limiting lives in front of the database; see the
-- "not verified here" list in test-auth.sql.

create table public.player_words (
  team_id    uuid primary key references public.teams(id) on delete restrict,
  word_hash  text not null,
  rotated_at timestamptz not null default now(),
  rotated_by uuid,
  expires_at timestamptz,
  constraint player_words_hash_shape check (word_hash ~ '^[0-9a-f]{64}$'),
  constraint player_words_expiry check (expires_at is null or expires_at > rotated_at)
);

comment on table public.player_words is
  'One read-only word per team, for players, who get no accounts. Primary key is the team: a word cannot be scoped to two teams, and rotating one touches nothing else.';
comment on column public.player_words.word_hash is
  'sha256 hex. The word is shown to the coach once, when it is set, and is never stored in plaintext or written to the audit log.';

-- Resolve the team a player-word session may read. Called by the two policies
-- in section 6 as `(select app.player_team_id())`, so it folds to one InitPlan
-- per statement rather than a call per row.
--
-- The credential is presented per statement and verified per statement -- there
-- is no ticket, no session row and no cached tier. That is what makes rotation
-- immediate: the next statement re-reads player_words and the old word no
-- longer hashes to anything.
--
-- The team is named as well as the word. Verifying by word alone would mean two
-- teams that happened to pick the same word could read each other, which is a
-- tenant boundary decided by coincidence. The link the coach hands out carries
-- the team id; the word is the secret.
create or replace function app.player_team_id()
returns uuid
language plpgsql
stable
security definer
parallel safe
set search_path = ''
as $$
declare
  v_team uuid;
  v_word text;
  v_out  uuid;
begin
  begin
    v_team := nullif(current_setting('app.player_team', true), '')::uuid;
  exception when others then
    return null;                       -- malformed is not an identity
  end;
  v_word := nullif(btrim(coalesce(current_setting('app.player_word', true), '')), '');
  if v_team is null or v_word is null then
    return null;
  end if;
  select w.team_id into v_out
    from public.player_words w
   where w.team_id = v_team
     and w.word_hash = app.hash_secret(v_word)
     and (w.expires_at is null or w.expires_at > now());
  return v_out;
exception when others then
  return null;
end $$;

comment on function app.player_team_id() is
  'The one team a player-word session may read, verified from scratch on every statement. NULL when no word is presented, when it is wrong, when it has expired, or when it belongs to another team.';

-- ---------------------------------------------------------------------------
-- 4. Issuing, accepting and withdrawing an invitation
-- ---------------------------------------------------------------------------

-- Who may staff what, in one place, so the invite path and migrations/0003_rls.sql's
-- memberships_write_head cannot drift apart. Head of the team, or admin of the
-- team's league -- exactly the pair in memberships_write_head (head_team_ids
-- union admin_team_ids). An ASSISTANT IS NOT ON THIS LIST: migrations/0003_rls.sql already says
-- an assistant cannot staff a team, and an assistant who could mint invitations
-- would be staffing a team through a side door.
create or replace function app.may_staff_team(p_team uuid)
returns boolean
language sql
stable security definer parallel safe
set search_path = ''
as $$
  select exists (
    select 1 from public.memberships m
     where m.user_id = (select auth.uid()) and m.team_id = p_team and m.role = 'head'
  ) or exists (
    select 1 from public.teams t
      join public.league_memberships lm on lm.league_id = t.league_id
     where t.id = p_team and lm.user_id = (select auth.uid()) and lm.role = 'admin'
  )
$$;

comment on function app.may_staff_team(uuid) is
  'Head of this team, or admin of its league. The same pair migrations/0003_rls.sql''s memberships_write_head allows, expressed once so the invite path cannot drift from the direct path.';

-- Appointing a league board is an admin's job, per migrations/0003_rls.sql's
-- league_memberships_write_admin. A board member is oversight, not staffing.
create or replace function app.may_staff_league(p_league uuid)
returns boolean
language sql
stable security definer parallel safe
set search_path = ''
as $$
  select exists (
    select 1 from public.league_memberships lm
     where lm.user_id = (select auth.uid()) and lm.league_id = p_league and lm.role = 'admin'
  )
$$;

-- Mint one. Returns the token in plaintext EXACTLY ONCE -- this return value is
-- the only time it exists outside the caller's hands, and only its hash is
-- written. The application emails it; nothing logs it.
create or replace function app.issue_invite(
  p_email      text,
  p_role       text,
  p_team       uuid     default null,
  p_league     uuid     default null,
  p_valid_for  interval default interval '14 days'
) returns table (invite_id uuid, token text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_email  text := lower(btrim(coalesce(p_email, '')));
  v_token  text;
  v_id     uuid;
  v_killed int;
begin
  if v_uid is null then
    raise exception 'not signed in: an invitation is issued by a person, not by a session'
      using errcode = '42501';
  end if;
  if (p_team is null) = (p_league is null) then
    raise exception 'name exactly one of p_team or p_league' using errcode = '22023';
  end if;
  if v_email = '' or v_email not like '%_@_%' then
    raise exception 'an invitation needs an email address to be addressed to' using errcode = '22023';
  end if;
  if p_valid_for is null or p_valid_for <= interval '0' or p_valid_for > interval '90 days' then
    raise exception 'an invitation lives between 0 and 90 days' using errcode = '22023';
  end if;

  if p_team is not null then
    if not app.may_staff_team(p_team) then
      raise exception 'you are not the head of that team'
        using errcode = '42501',
              hint = 'a head coach, or the league admin, staffs a team; an assistant does not';
    end if;
    if p_role not in ('head','assistant','helper') then
      raise exception 'role % is not a team role', p_role using errcode = '22023';
    end if;
  else
    if not app.may_staff_league(p_league) then
      raise exception 'you are not an admin of that league' using errcode = '42501';
    end if;
    if p_role not in ('board','admin') then
      raise exception 'role % is not a league role', p_role using errcode = '22023';
    end if;
  end if;

  -- One live invitation per address per scope. Minting a replacement kills the
  -- outstanding one, so a token that was emailed to the wrong address stops
  -- working the moment the coach re-sends it.
  with dead as (
    update public.invites i
       set revoked_at = now()
     where i.email = v_email
       and i.accepted_at is null and i.revoked_at is null
       and ((p_team   is not null and i.team_id   = p_team)
         or (p_league is not null and i.league_id = p_league))
    returning i.id, i.team_id, i.league_id
  )
  insert into public.auth_events (actor, action, team_id, league_id, subject_email, detail)
  select v_uid, 'invite_superseded', d.team_id, d.league_id, v_email,
         jsonb_build_object('invite', d.id)
    from dead d;
  get diagnostics v_killed = row_count;

  v_token := app.new_invite_token();

  insert into public.invites (team_id, league_id, role, email, token_hash, issued_by, expires_at)
  values (p_team, p_league, p_role, v_email, app.hash_secret(v_token), v_uid, now() + p_valid_for)
  returning id into v_id;

  insert into public.auth_events (actor, action, team_id, league_id, subject_email, detail)
  values (v_uid, 'invite_issue', p_team, p_league, v_email,
          jsonb_build_object('invite', v_id, 'role', p_role,
                             'expires_at', now() + p_valid_for,
                             'superseded', v_killed));

  invite_id := v_id;
  token     := v_token;
  return next;
end $$;

comment on function app.issue_invite(text, text, uuid, uuid, interval) is
  'Mint one invitation for one email into exactly one team or league. Head of the team or admin of the league only. Returns the plaintext token once; the table keeps only its sha256.';

-- Redeem one. THE SIGNATURE IS THE SECURITY PROPERTY: the only argument is the
-- token. There is no team parameter, so there is no payload for a client to
-- tamper with -- the team is read off the row the token hashes to, and no
-- tenant holds any write privilege on that row.
create or replace function app.accept_invite(p_token text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_email  text := lower(btrim(coalesce(auth.email(), '')));
  v_hash   text;
  v_inv    public.invites%rowtype;
  v_new    int;
  v_result text;
begin
  if v_uid is null then
    raise exception 'sign in first: an invitation is accepted by an account, not by a link'
      using errcode = '42501';
  end if;

  v_hash := app.hash_secret(nullif(btrim(coalesce(p_token, '')), ''));
  if v_hash is null then
    raise exception 'invitation is not valid' using errcode = '22023';
  end if;

  select * into v_inv from public.invites where token_hash = v_hash;
  if not found then
    raise exception 'invitation is not valid' using errcode = '22023';
  end if;
  if v_inv.revoked_at is not null then
    raise exception 'invitation was withdrawn' using errcode = '22023';
  end if;
  if v_inv.accepted_at is not null then
    raise exception 'invitation has already been accepted' using errcode = '22023';
  end if;
  if v_inv.expires_at <= now() then
    raise exception 'invitation expired on %', v_inv.expires_at using errcode = '22023';
  end if;
  if v_email = '' or v_email <> v_inv.email then
    raise exception 'invitation was addressed to somebody else'
      using errcode = '42501',
            hint = 'sign in with the address the invitation was sent to';
  end if;

  -- Single use, decided by the database rather than by the order of two
  -- statements: the guards are in the WHERE clause, so two sessions racing the
  -- same token produce exactly one winner.
  update public.invites
     set accepted_at = now(), accepted_by = v_uid
   where id = v_inv.id
     and accepted_at is null
     and revoked_at is null
     and expires_at > now();
  if not found then
    raise exception 'invitation has already been accepted' using errcode = '22023';
  end if;

  if v_inv.team_id is not null then
    -- ON CONFLICT DO NOTHING is the no-escalation rule: already a member means
    -- the row you already have, at the role you already have. An invitation
    -- never promotes anybody. Promotion is a head updating memberships.role,
    -- which migrations/0003_rls.sql governs and the audit trigger records as a role change.
    insert into public.memberships (user_id, team_id, role, invited_by)
    values (v_uid, v_inv.team_id, v_inv.role, v_inv.issued_by)
    on conflict (user_id, team_id) do nothing;
    get diagnostics v_new = row_count;
  else
    insert into public.league_memberships (user_id, league_id, role)
    values (v_uid, v_inv.league_id, v_inv.role)
    on conflict (user_id, league_id) do nothing;
    get diagnostics v_new = row_count;
  end if;

  v_result := case when v_new = 1 then 'joined' else 'already_member' end;

  insert into public.auth_events (actor, action, team_id, league_id, subject_user, subject_email, detail)
  values (v_uid, 'invite_accept', v_inv.team_id, v_inv.league_id, v_uid, v_email,
          jsonb_build_object('invite', v_inv.id, 'role', v_inv.role, 'result', v_result));

  return jsonb_build_object(
    'result',    v_result,
    'scope',     case when v_inv.team_id is not null then 'team' else 'league' end,
    'team_id',   v_inv.team_id,
    'league_id', v_inv.league_id,
    'role',      v_inv.role);
end $$;

comment on function app.accept_invite(text) is
  'Redeem an invitation. One argument, the token: the team is a property of the row, not of the request, so there is nothing to tamper with. Single use, expiry enforced, email claim must match, and an existing membership is never duplicated or escalated.';

create or replace function app.revoke_invite(p_invite uuid)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_inv public.invites%rowtype;
begin
  if v_uid is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  select * into v_inv from public.invites where id = p_invite;
  if not found then
    -- Same answer as "you may not touch it": an unauthorised caller learns
    -- nothing about whether the id exists.
    raise exception 'no such invitation' using errcode = '42501';
  end if;
  if not ((v_inv.team_id   is not null and app.may_staff_team(v_inv.team_id))
       or (v_inv.league_id is not null and app.may_staff_league(v_inv.league_id))) then
    raise exception 'no such invitation' using errcode = '42501';
  end if;
  if v_inv.accepted_at is not null then
    raise exception 'that invitation was already accepted; remove the membership instead'
      using errcode = '22023';
  end if;
  update public.invites set revoked_at = coalesce(revoked_at, now()) where id = p_invite;
  insert into public.auth_events (actor, action, team_id, league_id, subject_email, detail)
  values (v_uid, 'invite_revoke', v_inv.team_id, v_inv.league_id, v_inv.email,
          jsonb_build_object('invite', v_inv.id, 'role', v_inv.role));
  return true;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Setting and clearing a player word
-- ---------------------------------------------------------------------------
-- A coach hands the word to the huddle, so head AND assistant may rotate it --
-- Dom's seat is assistant and the boys' page is his. It is a read credential
-- for one team, not a staffing action, which is why it is not restricted to the
-- head the way invitations are.

create or replace function app.rotate_player_word(
  p_team      uuid,
  p_word      text     default null,
  p_valid_for interval default null
) returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_word text;
  v_exp  timestamptz;
begin
  if v_uid is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.memberships m
     where m.user_id = v_uid and m.team_id = p_team and m.role in ('head','assistant')
  ) and not app.may_staff_team(p_team) then
    raise exception 'you do not coach that team' using errcode = '42501';
  end if;

  v_word := nullif(btrim(coalesce(p_word, '')), '');
  if v_word is null then
    v_word := app.new_player_word();
  elsif length(v_word) < 6 then
    raise exception 'a player word is at least 6 characters' using errcode = '22023';
  end if;

  if p_valid_for is not null then
    if p_valid_for <= interval '0' then
      raise exception 'a player word cannot expire in the past' using errcode = '22023';
    end if;
    v_exp := now() + p_valid_for;
  end if;

  insert into public.player_words (team_id, word_hash, rotated_at, rotated_by, expires_at)
  values (p_team, app.hash_secret(v_word), now(), v_uid, v_exp)
  on conflict (team_id) do update
    set word_hash = excluded.word_hash,
        rotated_at = now(),
        rotated_by = excluded.rotated_by,
        expires_at = excluded.expires_at;

  -- The word itself is not in this row. Only that it changed, and who changed it.
  insert into public.auth_events (actor, action, team_id, detail)
  values (v_uid, 'player_word_rotate', p_team,
          jsonb_build_object('expires_at', v_exp, 'generated', p_word is null));

  return v_word;   -- shown to the coach once, the way the token is
end $$;

comment on function app.rotate_player_word(uuid, text, interval) is
  'Set or rotate one team''s player word. Returns it once, in plaintext, for the coach to read out; stores only its sha256. Rotation bites on the next statement -- there is no session to expire.';

create or replace function app.clear_player_word(p_team uuid)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.memberships m
     where m.user_id = v_uid and m.team_id = p_team and m.role in ('head','assistant')
  ) and not app.may_staff_team(p_team) then
    raise exception 'you do not coach that team' using errcode = '42501';
  end if;
  delete from public.player_words where team_id = p_team;
  insert into public.auth_events (actor, action, team_id, detail)
  values (v_uid, 'player_word_clear', p_team, '{}'::jsonb);
  return true;
end $$;

-- ---------------------------------------------------------------------------
-- 6. Privileges and policies
-- ---------------------------------------------------------------------------
-- Same discipline as migrations/0003_rls.sql: privileges say which verbs exist, policies say
-- which rows, and both have to pass.

-- SECURITY DEFINER functions are EXECUTE-to-PUBLIC by default, which would hand
-- an anonymous session a function that runs as the owner. Take it back first,
-- then hand out exactly what each role needs.
revoke all on function
  app.hash_secret(text), app.new_invite_token(), app.new_player_word(),
  app.may_staff_team(uuid), app.may_staff_league(uuid),
  app.issue_invite(text, text, uuid, uuid, interval),
  app.accept_invite(text), app.revoke_invite(uuid),
  app.rotate_player_word(uuid, text, interval), app.clear_player_word(uuid),
  app.player_team_id()
from public;

-- Signed in: you may issue, accept, withdraw and rotate. The functions
-- themselves decide whether you may do it to that team.
grant execute on function
  app.issue_invite(text, text, uuid, uuid, interval),
  app.accept_invite(text), app.revoke_invite(uuid),
  app.rotate_player_word(uuid, text, interval), app.clear_player_word(uuid),
  app.may_staff_team(uuid), app.may_staff_league(uuid)
to pd_authenticated;

-- Both roles resolve a player word: the boys' page is anonymous, and a coach
-- reading his own team's page in the same browser is not.
grant execute on function app.player_team_id() to pd_anon, pd_authenticated;

-- Deliberately NOT granted to any tenant: app.hash_secret, app.new_invite_token
-- and app.new_player_word. Nothing tenant-facing needs to hash anything, and a
-- tenant who could hash arbitrary strings could grind a word hash offline if he
-- ever got hold of one.

grant select on public.invites, public.player_words, public.auth_events
  to pd_anon, pd_authenticated;

-- No write verb on any of the three, for anybody. Every row is written by a
-- security definer function or trigger above. This is the privilege half of
-- "insert-only"; the trigger is the half that binds the owner too.
revoke insert, update, delete on public.invites, public.player_words, public.auth_events
  from pd_anon, pd_authenticated;

alter table public.invites       enable row level security;
alter table public.player_words  enable row level security;
alter table public.auth_events   enable row level security;

alter table public.invites       force row level security;
alter table public.player_words  force row level security;
alter table public.auth_events   force row level security;

-- invites: the people who staff the scope can see what is outstanding, and the
-- person it was addressed to can see their own. Nobody else, in any league.
create policy invites_select on public.invites
  for select to pd_anon, pd_authenticated
  using (
    (team_id is not null and (team_id in (select app.head_team_ids())
                           or team_id in (select app.admin_team_ids())))
    or (league_id is not null and league_id in (select app.admin_league_ids()))
    or email = (select auth.email())
    or accepted_by = (select auth.uid())
  );

-- player_words: the coaches of that team, and the league admin. Not the helper,
-- not the board, not another team, and not a player-word session itself -- the
-- word does not let you read the word.
create policy player_words_select on public.player_words
  for select to pd_anon, pd_authenticated
  using (
    team_id in (select app.coach_team_ids())
    or team_id in (select app.admin_team_ids())
  );

-- auth_events: the head of the team, the league's board and admin, and any user
-- reading the entries about himself. An assistant does not get the team's
-- staffing history -- he cannot staff the team either.
create policy auth_events_select on public.auth_events
  for select to pd_anon, pd_authenticated
  using (
    (team_id is not null and (team_id in (select app.head_team_ids())
                           or team_id in (select app.board_team_ids())))
    or (league_id is not null and league_id in (select app.league_ids()))
    or subject_user = (select auth.uid())
    or actor = (select auth.uid())
  );

-- FORCE row level security binds the owner, and the owner is who the definer
-- triggers above run as -- so the append needs a policy or the log could not be
-- written at all. It is scoped rather than `true`: a row is attributable to the
-- session that caused it. The real guard on forgery is the line above that
-- grants INSERT to nobody; this one means that even if that grant were ever
-- made, a tenant could only write entries about himself and could not frame
-- another coach.
create policy auth_events_append on public.auth_events
  for insert
  with check (actor is not distinct from (select auth.uid()));

-- ---------------------------------------------------------------------------
-- 7. The player word reaches exactly two tables
-- ---------------------------------------------------------------------------
-- Additive, permissive policies. They OR with the membership policies already
-- in migrations/0003_rls.sql and they are FALSE whenever no valid word is presented, because
-- `team_id = NULL` is NULL and never true. A session with no word sees exactly
-- what it saw before this file was loaded -- which is why the 183 tests in
-- test-isolation.sql are untouched by it.
--
-- SELECT only. There is no player INSERT/UPDATE/DELETE policy here or anywhere,
-- and pd_anon holds no write privilege at all, so a boy with the word cannot
-- change a play even by accident. That is the same promise learn.html makes on
-- the field client: a link that cannot edit anything.

create policy plays_select_player_word on public.plays
  for select to pd_anon, pd_authenticated
  using (team_id = (select app.player_team_id()));

create policy players_select_player_word on public.players
  for select to pd_anon, pd_authenticated
  using (team_id = (select app.player_team_id()));

-- (no commit; the runner commits)
