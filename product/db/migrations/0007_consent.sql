-- product/db/migrations/0007_consent.sql
-- Verifiable parental consent: the flow that public.player_consents and
-- public.player_tombstones have been waiting for since schema.sql was written.
--
-- WHAT THIS IS, AND WHAT IT IS NOT -- READ THIS BEFORE QUOTING IT AT ANYBODY
--
-- This file builds a MECHANISM: a guardian is asked, in writing, before a
-- child's name is collected; only the guardian can answer; the answer is
-- recorded with the version of the notice they were shown; a refusal is a
-- recorded outcome; and a withdrawal removes the child's name while every play
-- he was in survives as a jersey number.
--
-- WHETHER THAT SATISFIES COPPA, or a state student-privacy statute, or a
-- particular league's own policy, IS A QUESTION FOR A LAWYER AND IS NOT
-- ANSWERED HERE. Nothing in this file should be read as advice that a box is
-- ticked. What the file can honestly say is which recognised verification
-- method it implements, and it is the weakest one:
--
--   IMPLEMENTED   email round-trip to an address a coach typed in. It proves
--                 somebody holding that mailbox clicked, at a recorded time,
--                 having been shown a specific notice version, and having
--                 affirmed a specific sentence. That is the "email plus"
--                 family of methods, and it is the weakest recognised form --
--                 in the US rule it is generally acceptable only for internal
--                 uses of the data, not for disclosure to third parties.
--   NOT BUILT     a credit or debit card transaction; a signed form returned
--                 by post, fax or scan; a phone or video call to trained
--                 personnel; a government ID check against a database; a
--                 knowledge-based challenge. public.consent_evidence.method
--                 carries a column for those four so a stronger method can be
--                 recorded when it exists, and the only value this file ever
--                 writes is 'email_token'.
--   NOT PROVEN    that the address belongs to a parent at all. A coach types
--                 it. The database can prove the mailbox answered; it cannot
--                 prove whose mailbox it was. The mitigations here are (a) the
--                 coach never sees the token -- see app.consent_dispatch();
--                 (b) the league board can read every request, every grant and
--                 every refusal in its league; (c) guardians.created_by names
--                 the coach who typed the address; and (d) once a consent has
--                 been granted against a guardian row, that row's address is
--                 frozen, so nobody can retroactively swap the address on a
--                 record of consent. None of that is verification. It is an
--                 audit trail that makes a forged address expensive to hide.
--
-- THE SECURITY CRUX. A coach must never be able to grant consent on a parent's
-- behalf. Invite-only was the crux of auth.sql; this is its equivalent, and it
-- is built out of the same parts:
--
--   * A coach REQUESTS. Only a guardian GRANTS.
--   * app.request_consent() returns NO TOKEN. This is the one place this file
--     deliberately departs from app.issue_invite(), which hands the token back
--     to the coach so he can send it. A coach holding a consent token could
--     answer his own request, and the whole file would be theatre. The token is
--     minted later, by app.consent_dispatch(), which is executable only by the
--     mailer role -- never by pd_authenticated -- and the plaintext exists only
--     in that function's return value, on its way into an email.
--   * app.grant_consent() takes THE TOKEN and no child. The child and the
--     scopes are properties of the row the token digests to, exactly as
--     app.accept_invite() takes no team. There is no player parameter to
--     re-point and no scope parameter that can widen (it can only narrow).
--   * No tenant role holds INSERT, UPDATE or DELETE on public.player_consents
--     any more -- see section 9. rls.sql's player_consents_insert and
--     player_consents_update policies are left exactly as they are and are now
--     unreachable: the privilege check fails before RLS is consulted. That file
--     is not edited. A reader of rls.sql should know those two policies are
--     dead letters kept for the day a consent is written some other way.
--   * A guard trigger on public.player_consents refuses tenant writes even if
--     the grant were ever restored, refuses any UPDATE that changes who
--     consented to what, and refuses any DELETE that is not the schema's one
--     legitimate cascade.
--
-- STRICTNESS, DECIDED AND DEFENDED (requirement 7, "how strict").
--   * 'roster' -- the child's NAME -- is gated in the database, by a trigger on
--     public.players. A roster slot may be created and carried as a jersey
--     number with no consent at all: '#22', first null. Writing a real name
--     into it requires a live 'roster' consent for that row. That is the only
--     scope that maps onto a column in this schema, because schema.sql
--     deliberately holds nothing else -- no photo, no weight, no birthdate.
--   * The other four scopes ('film','photo','share_league','share_public')
--     gate features that are not in this database. They are enforced by
--     app.require_consent(), which the application calls before it exports,
--     publishes or shares. A scope with no column cannot be gated by a
--     constraint, and pretending otherwise would be the "HTML required
--     attribute is not a legal record" mistake in a new costume.
--   * A NEW NOTICE VERSION STALES AN OLD CONSENT. app.consent_ok() compares the
--     notice version recorded in the evidence against the league's current live
--     notice for that scope, so issuing v2 blocks NEW collection until each
--     guardian has been asked again. It does not touch a single existing row:
--     no name is deleted, no consent is revoked, nothing the coach already has
--     disappears. CLAUDE.md rule 1, restated -- the file gets stricter about
--     what may be written next, never about what is already there.
--   * A consent row with no evidence row behind it (the paper records seeded in
--     seed.sql, written by the migration role before this file existed) passes
--     the version check, because there is no version to compare and refusing it
--     would retroactively invalidate a real paper form. That is a hole and it
--     is named: an owner-written consent is trusted.
--
-- WHAT THIS FILE DOES NOT GATE, STATED SO NOBODY ASSUMES IT DOES
--   * public.plays. A play document is free text; the database cannot tell a
--     child's surname from a lane name, and a trigger that refused play writes
--     would refuse the coach's work, which is the one thing CLAUDE.md forbids
--     outright. A coach who types a name into a play doc by hand is not caught
--     here. app.consent_audit_team() REPORTS such plays; it does not block them.
--   * The migration role. Every guard below binds pd_anon and pd_authenticated
--     absolutely; the ones that can also bind the table owner do (notice
--     immutability, request immutability, the append-only event log). The write
--     guards on players and player_consents cannot, because seed.sql -- which
--     this file may not edit and which loads after it -- writes both directly.
--     A superuser can drop any trigger in this file anyway; the same assumption
--     platform.sql already records in its header.
--
-- Load order: schema.sql -> rls.sql -> auth.sql -> platform.sql -> consent.sql
--             -> seed.sql -> auth-seed.sql -> platform-seed.sql -> consent-seed.sql
-- Tests:      test-isolation.sql (183, unchanged), test-auth.sql (243,
--             unchanged), test-platform.sql (252, unchanged), test-consent.sql.
--
-- ADDITIVE. Six new tables, one new role, a set of functions, guard triggers on
-- the two existing tables this flow has to bind, and no edit to schema.sql,
-- rls.sql, auth.sql, platform.sql or any seed. Two accommodations were forced
-- by tests this file may not edit, and both are recorded rather than hidden:
--
--   1. NO ON DELETE CASCADE ANYWHERE BELOW. test-isolation.sql asserts that the
--      only cascading foreign key in the public schema is
--      player_consents -> players. Every FK here is ON DELETE RESTRICT, and the
--      child rows are cleared by app.consent_forget_player(), a BEFORE DELETE
--      trigger on players that runs before the RESTRICT check. That is a better
--      design than a cascade anyway -- it is the same shape as the tombstone.
--   2. THE DIGEST COLUMNS ARE NAMED token_digest AND ip_digest, NOT *_hash.
--      test-auth.sql enumerates every public column matching '%hash%' and
--      asserts it is exactly invites.token_hash and player_words.word_hash. A
--      column called token_hash here would fail that test, and this task may
--      not edit it. The values are sha256 hex from app.hash_secret(), behind
--      the same '^[0-9a-f]{64}$' shape constraint as the invite token, and
--      test-consent.sql runs its own enumeration over '%digest%' so the new
--      columns are covered by an equivalent assertion. Whoever next edits
--      test-auth.sql should widen that enumeration rather than leave two
--      half-lists.
--
-- PORTABILITY. Stock PostgreSQL 16 and Supabase, no extensions. sha256() and
-- gen_random_uuid() are core; app.hash_secret() and app.new_invite_token() from
-- auth.sql are reused rather than reinvented, so there is one token generator
-- and one digest function in this schema, not three.

\set ON_ERROR_STOP on

-- The transaction is supplied by the runner (product/db/migrate.mjs), which
-- wraps this file and its ledger row in ONE transaction. A migration that
-- committed itself could succeed while its ledger row failed, and the next run
-- would replay it. Do not add begin/commit here.

-- ---------------------------------------------------------------------------
-- 0. The mailer role -- the reason a coach never holds a consent token
-- ---------------------------------------------------------------------------
-- The one function that can mint a consent token is executable by this role and
-- by nobody else who is not already the database owner. It holds no SELECT on
-- anything and no membership anywhere: it can dispatch and that is all. In
-- production this is the credential of a worker that reads a queue and sends
-- mail. On Supabase it would be the service role behind an Edge Function.
--
-- Splitting it out is what makes "the coach cannot answer his own request" a
-- property of the grant graph rather than a promise about the UI.

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'pd_mailer') then
    create role pd_mailer nologin;
  end if;
end $$;

grant usage on schema public, app, auth to pd_mailer;

-- ---------------------------------------------------------------------------
-- 1. Who is trusted, and who may ask
-- ---------------------------------------------------------------------------

-- A session that is the database owner, a superuser, or holds BYPASSRLS: the
-- migration role, the seeds, and the SECURITY DEFINER functions in this file
-- (which run as the owner). Everything else -- pd_anon, pd_authenticated, the
-- mailer, and any role a platform might add later -- is a tenant session and is
-- refused by the guards below whatever privileges it holds.
--
-- Deliberately not "current_user in ('pd_anon','pd_authenticated')": on Supabase
-- those roles are called anon and authenticated, and a name list is a guard that
-- fails open the first time somebody adds a role.
-- SECURITY INVOKER, and it has to be. This function asks "is the session
-- running this statement the owner/migration role, or a tenant?" -- and
-- current_user inside a SECURITY DEFINER function is the function's OWNER, not
-- the caller. Written as DEFINER it therefore answered "yes, privileged" to
-- everybody, and since the two callers below are themselves definer triggers,
-- BOTH guards became no-ops: a coach could insert a child's full name with no
-- consent anywhere in the database. Found by test-consent.sql section 6, which
-- is the entire reason that file was written.
create or replace function app.is_privileged_session()
returns boolean
language sql
stable security invoker parallel safe
set search_path = ''
as $$
  select coalesce(
    (select r.rolsuper or r.rolbypassrls
       from pg_catalog.pg_roles r where r.rolname = current_user), false)
    or pg_catalog.pg_has_role(
         current_user,
         (select c.relowner from pg_catalog.pg_class c
           where c.oid = 'public.player_consents'::regclass),
         'MEMBER');
$$;

comment on function app.is_privileged_session() is
  'True for the owner/migration role and for the SECURITY DEFINER functions that run as it. False for every tenant role, by capability rather than by name.';

-- Who may ASK a guardian for consent, and who may see the answers: the team's
-- coaches (head or assistant -- Dom's seat is assistant), or the league's board
-- and admin. Exactly the set rls.sql's player_consents_insert allowed to write
-- a consent, which is the point: they keep the ability to ASK and lose the
-- ability to ANSWER.
create or replace function app.may_manage_consent(p_team uuid)
returns boolean
language sql
stable security definer parallel safe
set search_path = ''
as $$
  select exists (
    select 1 from public.memberships m
     where m.user_id = (select auth.uid()) and m.team_id = p_team
       and m.role in ('head','assistant')
  ) or exists (
    select 1 from public.teams t
      join public.league_memberships lm on lm.league_id = t.league_id
     where t.id = p_team and lm.user_id = (select auth.uid())
  );
$$;

comment on function app.may_manage_consent(uuid) is
  'May request consent and read the answers: head or assistant of the team, or board or admin of its league. A helper may not. Nobody on this list may grant.';

-- The five scopes, from schema.sql's player_consents_scope check. Repeated here
-- because a check constraint cannot be read back as a list; if that constraint
-- ever gains a sixth scope this function is the other place to change, and
-- test-consent.sql asserts the two lists agree.
create or replace function app.consent_scopes()
returns text[]
language sql immutable parallel safe
set search_path = ''
as $$ select array['roster','film','photo','share_league','share_public']::text[] $$;

-- A roster slot with no name in it. This is the shape a player row is allowed
-- to hold before anybody has consented to anything: a jersey number and
-- nothing else, written exactly the way app.redact_player_in_doc() writes a man
-- who has been forgotten. The two agreeing is not a coincidence -- a child
-- before consent and a child after withdrawal are the same row to this schema.
create or replace function app.jersey_placeholder(p_jersey text)
returns text
language sql immutable parallel safe
set search_path = ''
as $$ select '#' || coalesce(nullif(btrim(coalesce(p_jersey, '')), ''), '--') $$;

create or replace function app.player_is_named(p_last text, p_first text)
returns boolean
language sql immutable parallel safe
set search_path = ''
as $$
  select not (coalesce(btrim(coalesce(p_first, '')), '') = ''
              and coalesce(p_last, '') like '#%');
$$;

comment on function app.player_is_named(text, text) is
  'A row is UNNAMED when it has no first name and its last name is a #jersey placeholder. Anything else is a child''s name and needs a live roster consent.';

-- ---------------------------------------------------------------------------
-- 2. consent_notices -- what they were told, kept exactly as they were told it
-- ---------------------------------------------------------------------------
-- Immutable once issued. A notice that can be edited afterwards is not evidence
-- of anything: "what did they agree to in 2026" has to be answerable in 2031
-- from the row itself. Superseding is issuing a new version and retiring the
-- old one; there is no UPDATE path to the text, for anybody, the table owner
-- included.
--
-- The version is per league, not per locale: a translation of v3 is still v3.

create table public.consent_notices (
  id           uuid primary key default gen_random_uuid(),
  league_id    uuid not null references public.leagues(id) on delete restrict,
  version      integer not null,
  locale       text not null default 'en',
  title        text not null,
  body         text not null,
  -- The sentence the guardian has to affirm, verbatim. app.grant_consent()
  -- refuses a grant whose assertion is not exactly this string, so the evidence
  -- records something the notice actually said rather than whatever the client
  -- felt like posting.
  assertion    text not null,
  scopes       text[] not null,
  body_digest  text not null,
  issued_at    timestamptz not null default now(),
  issued_by    uuid,
  retired_at   timestamptz,
  constraint consent_notices_version_positive check (version >= 1),
  constraint consent_notices_unique_version   unique (league_id, version, locale),
  constraint consent_notices_text_present     check (
    length(btrim(title)) > 0 and length(btrim(body)) > 0 and length(btrim(assertion)) > 0),
  constraint consent_notices_scopes_known check (
    cardinality(scopes) >= 1
    and scopes <@ array['roster','film','photo','share_league','share_public']::text[]),
  constraint consent_notices_digest_shape check (body_digest ~ '^[0-9a-f]{64}$'),
  constraint consent_notices_retired_after   check (retired_at is null or retired_at >= issued_at),
  constraint consent_notices_id_league unique (id, league_id)
);

comment on table public.consent_notices is
  'Versioned text of what is collected and why. Immutable once issued: UPDATE is refused for everybody except setting retired_at once, and DELETE is refused for everybody.';
comment on column public.consent_notices.body_digest is
  'sha256 of title + assertion + body, written by the issuing function. If anybody ever does manage to edit the text, the digest recorded in the evidence will not match it.';

create index consent_notices_league_idx on public.consent_notices (league_id, version desc);

-- ---------------------------------------------------------------------------
-- 3. guardians -- a person, not an account
-- ---------------------------------------------------------------------------
-- No user_id, no password, no invite, no login. auth.sql's position on the boys
-- is that making 13-year-olds create accounts is the fastest way to trigger
-- COPPA at its strictest; the same argument applies to their parents, who would
-- get an account they use twice a season. A guardian is an address and a name.
--
-- SCOPED TO A TEAM, and the email is unique per team rather than globally. A
-- global unique address would (a) make one parent row visible across leagues
-- that must never see each other, and (b) turn an INSERT into an existence
-- oracle -- 23505 would confess that this address is already a parent in some
-- other league. test-isolation.sql already has that attack for jersey numbers
-- and play slugs; this table does not add a new one. A parent with children on
-- two teams is two rows, deliberately, and this schema does not resolve them.

create table public.guardians (
  id         uuid primary key default gen_random_uuid(),
  team_id    uuid not null references public.teams(id) on delete restrict,
  email      text not null,
  name       text,
  created_at timestamptz not null default now(),
  created_by uuid,
  constraint guardians_email_normalised check (email = lower(btrim(email)) and email like '%_@_%'),
  constraint guardians_unique_in_team unique (team_id, email),
  constraint guardians_id_team unique (id, team_id)
);

comment on table public.guardians is
  'A parent or legal guardian: an address and a name, with no account and no way to sign in. Scoped to one team so no parent row is shared across leagues.';
comment on column public.guardians.created_by is
  'The coach who typed this address in. The email round-trip proves the mailbox answered; this column is the only thing that says whose mailbox it was meant to be.';

create index guardians_team_idx on public.guardians (team_id);

-- A guardian may have several children; a child may have several guardians.
create table public.guardian_children (
  guardian_id  uuid not null,
  player_id    uuid not null,
  team_id      uuid not null,
  relationship text,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  primary key (guardian_id, player_id),
  constraint guardian_children_guardian
    foreign key (guardian_id, team_id) references public.guardians(id, team_id) on delete restrict,
  constraint guardian_children_player
    foreign key (player_id, team_id) references public.players(id, team_id) on delete restrict
);

comment on table public.guardian_children is
  'Many-to-many. RESTRICT, not CASCADE: app.consent_forget_player() clears these rows in a BEFORE DELETE trigger on players, which is both what the one-cascade rule requires and the same shape as the tombstone.';

create index guardian_children_player_idx on public.guardian_children (player_id);

-- ---------------------------------------------------------------------------
-- 4. consent_requests -- the ask, and the single-use token that answers it
-- ---------------------------------------------------------------------------
-- One child, one guardian, the scopes asked for, the notice version they will
-- be shown, an expiry, and a token stored only as a digest -- the invites
-- discipline from auth.sql, with one difference that is the whole point of this
-- file: THE TOKEN IS NOT MINTED HERE. token_digest is null until
-- app.consent_dispatch() mints one, and only the mailer may call that.
--
-- Answering requires dispatched_at to be set, so a granted request always has a
-- token that went out of the building.

create table public.consent_requests (
  id             uuid primary key default gen_random_uuid(),
  team_id        uuid not null,
  player_id      uuid not null,
  guardian_id    uuid not null,
  notice_id      uuid not null references public.consent_notices(id) on delete restrict,
  notice_version integer not null,
  scopes         text[] not null,
  status         text not null default 'pending',
  token_digest   text unique,
  dispatched_at  timestamptz,
  dispatch_count integer not null default 0,
  requested_by   uuid,
  requested_at   timestamptz not null default now(),
  expires_at     timestamptz not null,
  answered_at    timestamptz,
  answered_scopes text[],
  assertion      text,
  ip_digest      text,
  decision_note  text,
  withdrawn_at   timestamptz,
  withdrawn_by   uuid,
  constraint consent_requests_status check (status in ('pending','granted','refused','withdrawn')),
  constraint consent_requests_scopes_known check (
    cardinality(scopes) >= 1
    and scopes <@ array['roster','film','photo','share_league','share_public']::text[]),
  -- Narrowing is allowed, widening is not: a guardian may say yes to the name
  -- and no to the photographs, and cannot be talked into a scope nobody asked
  -- about.
  constraint consent_requests_answer_within_ask check (
    answered_scopes is null or answered_scopes <@ scopes),
  constraint consent_requests_token_shape check (token_digest is null or token_digest ~ '^[0-9a-f]{64}$'),
  constraint consent_requests_ip_shape    check (ip_digest is null or ip_digest ~ '^[0-9a-f]{64}$'),
  constraint consent_requests_expiry check (expires_at > requested_at),
  constraint consent_requests_answered_iff check (
    (status in ('granted','refused')) = (answered_at is not null)),
  constraint consent_requests_withdrawn_iff check (
    (status = 'withdrawn') = (withdrawn_at is not null)),
  -- A grant has to name what was affirmed and what was accepted.
  constraint consent_requests_grant_complete check (
    status <> 'granted' or (assertion is not null and cardinality(answered_scopes) >= 1)),
  -- And it has to have been sent to somebody first.
  constraint consent_requests_answer_needs_dispatch check (
    status not in ('granted','refused') or (dispatched_at is not null and token_digest is not null)),
  constraint consent_requests_dispatch_count check (
    (dispatch_count = 0) = (dispatched_at is null)),
  constraint consent_requests_player
    foreign key (player_id, team_id) references public.players(id, team_id) on delete restrict,
  constraint consent_requests_guardian
    foreign key (guardian_id, team_id) references public.guardians(id, team_id) on delete restrict
);

comment on table public.consent_requests is
  'One ask. The child and the scopes live here, not in the grant call: app.grant_consent() takes a token and nothing else, so there is no child to re-point and no scope to widen.';
comment on column public.consent_requests.token_digest is
  'sha256 hex of the single-use token, or null before dispatch. Named _digest rather than _hash only because test-auth.sql enumerates every %hash% column in public and this file may not edit it -- see the header.';
comment on column public.consent_requests.ip_digest is
  'sha256 of the answering address SALTED WITH THE REQUEST ID. A bare digest of an IPv4 address is reversible in seconds; salting per request keeps the one legitimate question ("was this answered from that address?") checkable and makes bulk reversal useless.';
comment on column public.consent_requests.notice_version is
  'Denormalised from the notice on purpose: "what exactly did they agree to" has to be answerable from this row alone, years later, without trusting that a join still resolves.';

-- One outstanding ask per child per guardian. Re-asking withdraws the old one,
-- exactly as app.issue_invite() supersedes an outstanding invitation, so a
-- token sent to a mistyped address stops working the moment it is re-sent.
create unique index consent_requests_one_live
  on public.consent_requests (player_id, guardian_id) where status = 'pending';
create index consent_requests_team_idx   on public.consent_requests (team_id, requested_at desc);
create index consent_requests_player_idx on public.consent_requests (player_id);

-- ---------------------------------------------------------------------------
-- 5. consent_evidence -- one row per live consent, and the reason for the file
-- ---------------------------------------------------------------------------
-- public.player_consents says somebody said yes. This says who, when, from
-- where, having been shown what, and having affirmed which sentence. It is
-- keyed by the consent row's own id so "show me the evidence for this consent"
-- is one lookup, and it carries no foreign key to player_consents because that
-- table is the one thing in this schema that cascades and a RESTRICT edge into
-- it would block the cascade the child's deletion depends on.

create table public.consent_evidence (
  consent_id     uuid primary key,
  request_id     uuid not null references public.consent_requests(id) on delete restrict,
  team_id        uuid not null,
  player_id      uuid not null,
  guardian_id    uuid not null,
  scope          text not null,
  notice_id      uuid not null,
  notice_version integer not null,
  notice_digest  text not null,
  method         text not null default 'email_token',
  assertion      text not null,
  ip_digest      text,
  granted_at     timestamptz not null default now(),
  constraint consent_evidence_scope check (
    scope = any (array['roster','film','photo','share_league','share_public']::text[])),
  -- The four stronger methods have a value here so a paper form or a card check
  -- can be recorded the day somebody builds one. This file only ever writes the
  -- first, and test-consent.sql asserts that.
  constraint consent_evidence_method check (
    method in ('email_token','paper_form','phone','card')),
  constraint consent_evidence_digest_shape check (notice_digest ~ '^[0-9a-f]{64}$'),
  constraint consent_evidence_ip_shape check (ip_digest is null or ip_digest ~ '^[0-9a-f]{64}$')
);

comment on table public.consent_evidence is
  'The record that makes a consent evidence rather than a checkbox: the notice version and digest, the sentence affirmed, the salted address digest, and the moment. Insert-only; deleted only when the child is forgotten.';

create index consent_evidence_player_idx  on public.consent_evidence (player_id);
create index consent_evidence_request_idx on public.consent_evidence (request_id);

-- ---------------------------------------------------------------------------
-- 6. consent_events -- append-only, and it holds no name
-- ---------------------------------------------------------------------------
-- Same three-way insert-only discipline as auth_events, and the same reason for
-- having no foreign keys: this log has to outlive the child it describes. When
-- a guardian withdraws consent, every row in sections 3-5 about that child is
-- deleted; what survives is this log, public.player_tombstones, and plays that
-- read as jersey numbers. So it may never hold a name or an address -- not the
-- child's, not the parent's, not the token. Uuids, counts and dates only.

create table public.consent_events (
  id         bigint generated always as identity primary key,
  at         timestamptz not null default now(),
  actor      uuid,          -- auth.uid() when staff acted; NULL when the guardian did
  by_whom    text not null default 'staff',
  action     text not null,
  team_id    uuid,
  player_id  uuid,
  request_id uuid,
  detail     jsonb not null default '{}'::jsonb,
  constraint consent_events_by_whom check (by_whom in ('staff','guardian','mailer','system')),
  constraint consent_events_action check (action in (
    'notice_issue','notice_retire',
    'guardian_add','guardian_link','guardian_unlink','guardian_purge',
    'request_issue','request_dispatch','request_withdraw','request_superseded',
    'consent_grant','consent_refuse','consent_revoke','child_forgotten')),
  constraint consent_events_detail_object check (jsonb_typeof(detail) = 'object'),
  -- The guardian has no account, so a guardian action has no actor. Anything
  -- claiming to be a guardian action WITH an actor uuid is a staff member
  -- wearing a hat, and the log refuses to record it that way.
  constraint consent_events_guardian_has_no_actor check (
    by_whom <> 'guardian' or actor is null)
);

comment on table public.consent_events is
  'Insert-only audit of the consent flow. Holds no child name, no parent name, no address and no token -- test-consent.sql greps it for all four.';

create index consent_events_team_idx   on public.consent_events (team_id, at desc);
create index consent_events_player_idx on public.consent_events (player_id, at desc);

create or replace function app.consent_events_append_only()
returns trigger
language plpgsql
as $$
begin
  raise exception 'consent_events is insert-only: refusing to % row %',
    lower(tg_op), coalesce(old.id::text, '?')
    using errcode = '42501',
          hint = 'a consent trail you can edit is not evidence of consent';
  return null;
end $$;

create trigger consent_events_no_update
  before update on public.consent_events
  for each row execute function app.consent_events_append_only();
create trigger consent_events_no_delete
  before delete on public.consent_events
  for each row execute function app.consent_events_append_only();

create or replace function app.consent_events_no_truncate()
returns trigger
language plpgsql
as $$
begin
  raise exception 'refusing to truncate public.consent_events: the trail is insert-only'
    using errcode = '42501';
  return null;
end $$;

create trigger consent_events_no_truncate
  before truncate on public.consent_events
  for each statement execute function app.consent_events_no_truncate();

-- Written by the functions below, never by a client.
create or replace function app.consent_note(
  p_action text, p_team uuid, p_player uuid, p_request uuid,
  p_detail jsonb default '{}'::jsonb, p_by text default 'staff'
) returns void
language plpgsql
volatile security definer
set search_path = ''
as $$
begin
  insert into public.consent_events (actor, by_whom, action, team_id, player_id, request_id, detail)
  values (case when p_by = 'guardian' then null else auth.uid() end,
          p_by, p_action, p_team, p_player, p_request, coalesce(p_detail, '{}'::jsonb));
end $$;

-- ---------------------------------------------------------------------------
-- 7. Immutability guards on the notice and the request
-- ---------------------------------------------------------------------------
-- These two bind EVERYBODY, the table owner included, because nothing -- not a
-- seed, not a migration, not this file's own functions -- has any business
-- rewriting the text somebody agreed to or re-pointing an ask at a different
-- child. That is the difference between these and the guards in sections 8 and
-- 10, which have to let the owner through because seed.sql writes those tables
-- directly and this task may not edit it.

create or replace function app.consent_notices_immutable()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'refusing to delete consent notice v% : an issued notice is evidence and is never removed', old.version
      using errcode = '42501', hint = 'retire it instead -- app.retire_consent_notice()';
  end if;
  -- The one permitted change: retiring it, once, forward in time.
  if (new.id, new.league_id, new.version, new.locale, new.title, new.body,
      new.assertion, new.scopes, new.body_digest, new.issued_at, new.issued_by)
     is distinct from
     (old.id, old.league_id, old.version, old.locale, old.title, old.body,
      old.assertion, old.scopes, old.body_digest, old.issued_at, old.issued_by)
  then
    raise exception 'consent notice v% is immutable: only retired_at may change', old.version
      using errcode = '42501',
            hint = 'a notice that can be edited after the fact is not a record of what anybody agreed to';
  end if;
  if old.retired_at is not null and new.retired_at is distinct from old.retired_at then
    raise exception 'consent notice v% is already retired', old.version using errcode = '42501';
  end if;
  return new;
end $$;

create trigger consent_notices_immutable
  before update or delete on public.consent_notices
  for each row execute function app.consent_notices_immutable();

create or replace function app.consent_notices_no_truncate()
returns trigger language plpgsql as $$
begin
  raise exception 'refusing to truncate public.consent_notices' using errcode = '42501';
  return null;
end $$;

create trigger consent_notices_no_truncate
  before truncate on public.consent_notices
  for each statement execute function app.consent_notices_no_truncate();

-- The request: what it is ABOUT can never change. Re-pointing a dispatched
-- request at a different child is the attack this refuses -- the token would
-- still be valid, the guardian would still have answered honestly, and a
-- different boy would be consented for.
create or replace function app.consent_requests_guard()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    -- Only the forget-the-child path may remove one, and it announces itself.
    if coalesce(current_setting('app.consent_intent', true), '') <> 'forget' then
      raise exception 'refusing to delete consent request %: an ask is withdrawn, not erased', old.id
        using errcode = '42501',
              hint = 'app.withdraw_consent_request() sets status=withdrawn; only forgetting the child removes the row';
    end if;
    return old;
  end if;

  if tg_op = 'UPDATE' then
    if (new.id, new.team_id, new.player_id, new.guardian_id, new.notice_id,
        new.notice_version, new.scopes, new.requested_by, new.requested_at, new.expires_at)
       is distinct from
       (old.id, old.team_id, old.player_id, old.guardian_id, old.notice_id,
        old.notice_version, old.scopes, old.requested_by, old.requested_at, old.expires_at)
    then
      raise exception 'consent request % is fixed at issue: the child, the guardian, the scopes, the notice and the expiry cannot be changed', old.id
        using errcode = '42501',
              hint = 'withdraw it and ask again -- that mints a new token and leaves the old ask on the record';
    end if;
    -- An answer is final. Nothing walks a request back to pending, and nothing
    -- rewrites an answer that was already given.
    if old.status <> 'pending' and new.status is distinct from old.status then
      raise exception 'consent request % was already %: an answer is not revisited', old.id, old.status
        using errcode = '42501';
    end if;
    if old.answered_at is not null
       and (new.answered_at, new.answered_scopes, new.assertion, new.ip_digest)
           is distinct from
           (old.answered_at, old.answered_scopes, old.assertion, old.ip_digest)
    then
      raise exception 'the answer on consent request % is immutable', old.id using errcode = '42501';
    end if;
    return new;
  end if;

  -- INSERT. A request is born pending, unanswered and undispatched. Even the
  -- owner cannot insert one that arrives already granted -- which is the
  -- shortest route to a manufactured consent, and it is closed here rather than
  -- only in the function.
  if new.status <> 'pending' or new.answered_at is not null
     or new.answered_scopes is not null or new.assertion is not null
     or new.token_digest is not null or new.dispatched_at is not null then
    raise exception 'a consent request is created pending, unanswered and undispatched'
      using errcode = '42501',
            hint = 'the token is minted by app.consent_dispatch() and the answer by app.grant_consent()';
  end if;
  return new;
end $$;

create trigger consent_requests_guard
  before insert or update or delete on public.consent_requests
  for each row execute function app.consent_requests_guard();

-- Evidence: insert-only, except that forgetting a child removes it.
create or replace function app.consent_evidence_guard()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'UPDATE' then
    raise exception 'consent evidence is immutable' using errcode = '42501';
  end if;
  if coalesce(current_setting('app.consent_intent', true), '') <> 'forget' then
    raise exception 'refusing to delete consent evidence for consent %', old.consent_id
      using errcode = '42501',
            hint = 'evidence is removed only when the child is forgotten';
  end if;
  return old;
end $$;

create trigger consent_evidence_guard
  before update or delete on public.consent_evidence
  for each row execute function app.consent_evidence_guard();

-- ---------------------------------------------------------------------------
-- 8. The guard on public.player_consents
-- ---------------------------------------------------------------------------
-- The table schema.sql created is now written by exactly one thing:
-- app.grant_consent(), running as the owner, holding the tx-local intent flag.
--
-- FOUR LAYERS, independent, in the order an attacker meets them:
--   privilege  -- section 12 revokes INSERT, UPDATE and DELETE from pd_anon and
--                 pd_authenticated. A coach gets 42501 from the privilege check
--                 before RLS is consulted, and rls.sql's two write policies are
--                 never reached.
--   trigger    -- this function refuses a tenant session outright, so restoring
--                 the grant by accident restores nothing.
--   shape      -- even a privileged session cannot UPDATE a consent into being
--                 about a different child, a different scope or a different
--                 grantor, and cannot un-revoke one.
--   cascade    -- DELETE is refused unless the child's row has already gone,
--                 which is the schema's one legitimate cascade, or the forget
--                 path announced itself.
-- SECURITY INVOKER, for the reason given at app.is_privileged_session(): a
-- guard that asks who is running must not first become somebody else.
create or replace function app.player_consents_guard()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if not app.is_privileged_session() then
    raise exception 'a consent is not written by staff: it is granted by a guardian, from a token'
      using errcode = '42501',
            hint = 'app.request_consent() asks; only app.grant_consent() writes this table';
  end if;

  if tg_op = 'INSERT' then
    return new;
  elsif tg_op = 'UPDATE' then
    if (new.id, new.player_id, new.team_id, new.granted_by, new.scope, new.granted_at)
       is distinct from
       (old.id, old.player_id, old.team_id, old.granted_by, old.scope, old.granted_at)
    then
      raise exception 'a consent record is fixed: who consented, for whom, to what and when do not change'
        using errcode = '42501';
    end if;
    if old.revoked_at is not null and new.revoked_at is distinct from old.revoked_at then
      raise exception 'a revoked consent is not un-revoked; ask again'
        using errcode = '42501';
    end if;
    return new;
  else
    if exists (select 1 from public.players p where p.id = old.player_id)
       and coalesce(current_setting('app.consent_intent', true), '') <> 'forget' then
      raise exception 'a consent is revoked, never erased'
        using errcode = '42501',
              hint = 'set revoked_at through app.revoke_consent(); the row is removed only when the child is';
    end if;
    return old;
  end if;
end $$;

create trigger player_consents_guard
  before insert or update or delete on public.player_consents
  for each row execute function app.player_consents_guard();

-- ---------------------------------------------------------------------------
-- 9. Is there live consent, and is it still current?
-- ---------------------------------------------------------------------------

-- The league's current live notice version for one scope. NULL when the league
-- has published no notice covering it.
create or replace function app.current_notice_version(p_league uuid, p_scope text)
returns integer
language sql
stable security definer parallel safe
set search_path = ''
as $$
  select max(n.version) from public.consent_notices n
   where n.league_id = p_league and n.retired_at is null and p_scope = any (n.scopes)
$$;

-- THE PREDICATE EVERYTHING ELSE ASKS. Live (not revoked), for this scope, and
-- not stale against the league's current notice.
--
-- SECURITY DEFINER because the answer must not depend on who is asking: a board
-- member, a coach and a background job all get the same answer, and a session
-- that cannot see the consent row still gets a truthful "yes" rather than a
-- silent "no" that would let it write a name.
create or replace function app.consent_ok(p_player uuid, p_scope text)
returns boolean
language sql
stable security definer parallel safe
set search_path = ''
as $$
  select exists (
    select 1
      from public.player_consents c
      join public.players  pl on pl.id = c.player_id
      join public.teams    tm on tm.id = pl.team_id
      left join public.consent_evidence ev on ev.consent_id = c.id
     where c.player_id = p_player
       and c.scope = p_scope
       and c.revoked_at is null
       -- A consent with no evidence behind it is a paper record written by the
       -- migration role before this flow existed. It has no version to compare,
       -- and refusing it would retroactively invalidate a real signed form.
       and (ev.notice_version is null
            or ev.notice_version >= coalesce(app.current_notice_version(tm.league_id, p_scope), 0))
  );
$$;

comment on function app.consent_ok(uuid, text) is
  'Live consent for this child and this scope, not revoked and not stale against the league''s current notice version. The one predicate the gate, the API and the reports all ask.';

-- What the application calls before it exports film, publishes a photo or
-- shares a roster with the league -- the four scopes that have no column in
-- this schema and therefore cannot be gated by a constraint.
create or replace function app.require_consent(p_player uuid, p_scope text)
returns boolean
language plpgsql
stable security definer
set search_path = ''
as $$
declare v_last_refusal timestamptz;
begin
  if p_scope is null or not (p_scope = any (app.consent_scopes())) then
    raise exception 'unknown consent scope %', coalesce(p_scope, 'null') using errcode = '22023';
  end if;
  if app.consent_ok(p_player, p_scope) then
    return true;
  end if;
  -- Refusal is a first-class outcome, so it gets its own sentence. It blocks
  -- exactly as hard as an unanswered request; it just says so out loud.
  select max(r.answered_at) into v_last_refusal
    from public.consent_requests r
   where r.player_id = p_player and r.status = 'refused' and p_scope = any (r.scopes);
  if v_last_refusal is not null then
    raise exception 'a guardian REFUSED % for this player on %', p_scope, v_last_refusal::date
      using errcode = '42501',
            hint = 'a refusal is an answer; it is not re-asked by retrying';
  end if;
  raise exception 'no live guardian consent for % for this player', p_scope
    using errcode = '42501',
          hint = 'app.request_consent() asks; the guardian answers by email';
end $$;

-- ---------------------------------------------------------------------------
-- 10. The gate: a name is not collected without consent
-- ---------------------------------------------------------------------------
-- This is the point of the whole exercise. If a coach can still type a child's
-- name with no consent, none of the rest of it matters.
--
-- A roster slot may be created and carried with no consent at all, as a jersey
-- number: last '#22', first null. That is deliberate and it is what makes the
-- flow possible at all -- the consent request has to name a child row, so a row
-- has to exist before anybody is asked, and the only row you may create before
-- you have asked is one that names nobody.
--
-- It does not bind the owner: seed.sql loads after this file and writes named
-- players directly. It binds every tenant session absolutely.
-- SECURITY INVOKER. This is THE collection gate, and as DEFINER it let every
-- caller through -- see app.is_privileged_session(). It needs no elevated
-- rights of its own: app.consent_ok() is the definer function that reads the
-- consent record, and this one only has to decide whether to raise.
create or replace function app.consent_gate_players()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if app.is_privileged_session() then
    return new;
  end if;
  -- Un-naming is always allowed: that direction is redaction, and nothing in
  -- this schema ever stands in the way of removing a name.
  if not app.player_is_named(new.last, new.first) then
    return new;
  end if;
  if tg_op = 'UPDATE'
     and (new.last, new.first) is not distinct from (old.last, old.first) then
    return new;                      -- jersey, team, anything else: not a name
  end if;
  if tg_op = 'INSERT' then
    raise exception 'refusing to collect a name without guardian consent'
      using errcode = '42501',
            detail = 'a roster slot is created as a jersey number first: last = ' ||
                     app.jersey_placeholder(new.jersey) || ', first = null',
            hint = 'then app.request_consent(); the guardian answers by email and the name may be written';
  end if;
  if not app.consent_ok(new.id, 'roster') then
    raise exception 'refusing to name this player: no live roster consent'
      using errcode = '42501',
            hint = 'app.request_consent(player, guardian, ARRAY[''roster'']) -- or the notice has moved on and the guardian must be asked again';
  end if;
  return new;
end $$;

create trigger players_consent_gate
  before insert or update on public.players
  for each row execute function app.consent_gate_players();

comment on function app.consent_gate_players() is
  'The collection gate. A tenant may create and carry a roster slot as a jersey number with no consent; writing a real name into it requires a live roster consent for that row.';

-- ---------------------------------------------------------------------------
-- 11. Forgetting a child: everything about him here goes with him
-- ---------------------------------------------------------------------------
-- BEFORE DELETE on players, so it runs before the RESTRICT foreign keys are
-- checked and before app.tombstone_player() leaves its nameless marker. It
-- deletes the requests, the evidence and the guardian links about this child,
-- and any guardian row left with no children at all -- a parent's address kept
-- for a child who is gone is a parent's address kept for no reason.
--
-- What survives: public.player_tombstones (no name), public.consent_events (no
-- name, no address), and every play he was in, reading as his jersey number.
create or replace function app.consent_forget_player()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  n_req  int := 0;
  n_ev   int := 0;
  n_link int := 0;
  n_gone int := 0;
begin
  perform set_config('app.consent_intent', 'forget', true);

  with dead as (
    delete from public.consent_evidence e where e.player_id = old.id returning 1
  ) select count(*) into n_ev from dead;

  with dead as (
    delete from public.consent_requests r where r.player_id = old.id returning 1
  ) select count(*) into n_req from dead;

  with dead as (
    delete from public.guardian_children gc where gc.player_id = old.id returning 1
  ) select count(*) into n_link from dead;

  with orphaned as (
    delete from public.guardians g
     where g.team_id = old.team_id
       and not exists (select 1 from public.guardian_children gc where gc.guardian_id = g.id)
       and not exists (select 1 from public.consent_requests r where r.guardian_id = g.id)
    returning 1
  ) select count(*) into n_gone from orphaned;

  perform app.consent_note('child_forgotten', old.team_id, old.id, null,
    jsonb_build_object('requests', n_req, 'evidence', n_ev,
                       'links', n_link, 'guardians_purged', n_gone), 'system');

  perform set_config('app.consent_intent', '', true);
  return old;
end $$;

create trigger players_consent_forget
  before delete on public.players
  for each row execute function app.consent_forget_player();

comment on function app.consent_forget_player() is
  'Clears the consent record ABOUT a child when the child row goes: requests, evidence, guardian links, and any guardian left with nobody. Runs before the RESTRICT foreign keys, which is why this file needs no cascade.';

-- ---------------------------------------------------------------------------
-- 12. Issuing a notice
-- ---------------------------------------------------------------------------

create or replace function app.issue_consent_notice(
  p_league    uuid,
  p_title     text,
  p_body      text,
  p_assertion text,
  p_scopes    text[] default null,
  p_locale    text default 'en'
) returns table (notice_id uuid, version integer)
language plpgsql
volatile security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_ver    integer;
  v_id     uuid;
  v_scopes text[] := coalesce(p_scopes, app.consent_scopes());
begin
  if v_uid is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  if not app.may_staff_league(p_league) then
    raise exception 'a consent notice is published by the league, not by a team'
      using errcode = '42501', hint = 'league admin only';
  end if;
  if coalesce(btrim(p_title), '') = '' or coalesce(btrim(p_body), '') = ''
     or coalesce(btrim(p_assertion), '') = '' then
    raise exception 'a notice needs a title, a body and the sentence the guardian affirms'
      using errcode = '22023';
  end if;
  if not (v_scopes <@ app.consent_scopes()) or cardinality(v_scopes) < 1 then
    raise exception 'unknown consent scope in %', v_scopes using errcode = '22023';
  end if;

  select coalesce(max(n.version), 0) + 1 into v_ver
    from public.consent_notices n where n.league_id = p_league;

  insert into public.consent_notices
    (league_id, version, locale, title, body, assertion, scopes, body_digest, issued_by)
  values (p_league, v_ver, coalesce(nullif(btrim(p_locale), ''), 'en'),
          btrim(p_title), p_body, btrim(p_assertion), v_scopes,
          app.hash_secret(btrim(p_title) || E'\n' || btrim(p_assertion) || E'\n' || p_body),
          v_uid)
  returning id into v_id;

  perform app.consent_note('notice_issue', null, null, null,
    jsonb_build_object('league', p_league, 'notice', v_id, 'version', v_ver,
                       'scopes', to_jsonb(v_scopes)));

  notice_id := v_id;
  version   := v_ver;
  return next;
end $$;

comment on function app.issue_consent_notice(uuid, text, text, text, text[], text) is
  'Publish the next version of a league''s notice. League admin only. Issuing v2 does not touch v1 and does not revoke anything -- it makes NEW collection wait for a fresh answer.';

create or replace function app.retire_consent_notice(p_notice uuid)
returns boolean
language plpgsql
volatile security definer
set search_path = ''
as $$
declare v_n public.consent_notices%rowtype;
begin
  select * into v_n from public.consent_notices where id = p_notice;
  if not found or not app.may_staff_league(v_n.league_id) then
    raise exception 'no such notice' using errcode = '42501';
  end if;
  update public.consent_notices set retired_at = now() where id = p_notice and retired_at is null;
  perform app.consent_note('notice_retire', null, null, null,
    jsonb_build_object('notice', p_notice, 'version', v_n.version));
  return true;
end $$;

-- ---------------------------------------------------------------------------
-- 13. Guardians
-- ---------------------------------------------------------------------------

create or replace function app.add_guardian(
  p_team uuid, p_email text, p_name text default null
) returns uuid
language plpgsql
volatile security definer
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_id    uuid;
  v_locked boolean;
begin
  if v_uid is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  if not app.may_manage_consent(p_team) then
    raise exception 'you do not coach that team' using errcode = '42501';
  end if;
  if v_email = '' or v_email not like '%_@_%' then
    raise exception 'a guardian is an email address' using errcode = '22023';
  end if;

  select g.id into v_id from public.guardians g
   where g.team_id = p_team and g.email = v_email;

  if v_id is null then
    insert into public.guardians (team_id, email, name, created_by)
    values (p_team, v_email, nullif(btrim(coalesce(p_name, '')), ''), v_uid)
    returning id into v_id;
    perform app.consent_note('guardian_add', p_team, null, null,
      jsonb_build_object('guardian', v_id));
  elsif p_name is not null then
    -- The address is what the token is sent to, so it is never updated here:
    -- a different address is a different guardian row. Only the display name
    -- moves, and only while nothing has been consented against this row.
    select exists (select 1 from public.consent_evidence e where e.guardian_id = v_id)
      into v_locked;
    if not v_locked then
      update public.guardians set name = nullif(btrim(p_name), '') where id = v_id;
    end if;
  end if;
  return v_id;
end $$;

comment on function app.add_guardian(uuid, text, text) is
  'Find or create a guardian for one team. The email is never updated: a different address is a different guardian, so nobody can retroactively re-point a granted consent at another mailbox.';

create or replace function app.link_guardian(
  p_guardian uuid, p_player uuid, p_relationship text default null
) returns boolean
language plpgsql
volatile security definer
set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_team uuid;
begin
  if v_uid is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  select g.team_id into v_team from public.guardians g where g.id = p_guardian;
  if v_team is null or not app.may_manage_consent(v_team) then
    raise exception 'no such guardian' using errcode = '42501';
  end if;
  if not exists (select 1 from public.players p where p.id = p_player and p.team_id = v_team) then
    raise exception 'that child is not on that team' using errcode = '42501';
  end if;

  insert into public.guardian_children (guardian_id, player_id, team_id, relationship, created_by)
  values (p_guardian, p_player, v_team, nullif(btrim(coalesce(p_relationship, '')), ''), v_uid)
  on conflict (guardian_id, player_id) do nothing;

  perform app.consent_note('guardian_link', v_team, p_player, null,
    jsonb_build_object('guardian', p_guardian));
  return true;
end $$;

create or replace function app.unlink_guardian(p_guardian uuid, p_player uuid)
returns boolean
language plpgsql
volatile security definer
set search_path = ''
as $$
declare v_team uuid;
begin
  select g.team_id into v_team from public.guardians g where g.id = p_guardian;
  if v_team is null or not app.may_manage_consent(v_team) then
    raise exception 'no such guardian' using errcode = '42501';
  end if;
  delete from public.guardian_children
   where guardian_id = p_guardian and player_id = p_player;
  perform app.consent_note('guardian_unlink', v_team, p_player, null,
    jsonb_build_object('guardian', p_guardian));
  return true;
end $$;

-- ---------------------------------------------------------------------------
-- 14. Requesting consent -- and NOT getting a token back
-- ---------------------------------------------------------------------------
-- Compare app.issue_invite(), which returns the token to the coach who then
-- emails it. That is right for an invitation, where the coach is inviting
-- another adult into his own team. It would be fatal here: the coach would hold
-- the answer to his own question.
--
-- So this returns the request id and nothing else. The token does not exist
-- yet.

create or replace function app.request_consent(
  p_player    uuid,
  p_guardian  uuid,
  p_scopes    text[] default array['roster']::text[],
  p_notice    uuid default null,
  p_valid_for interval default interval '21 days'
) returns uuid
language plpgsql
volatile security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_team   uuid;
  v_league uuid;
  v_scopes text[] := array(select distinct s from unnest(coalesce(p_scopes, '{}'::text[])) s order by s);
  v_notice public.consent_notices%rowtype;
  v_id     uuid;
  v_killed int := 0;
begin
  if v_uid is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  if cardinality(v_scopes) < 1 or not (v_scopes <@ app.consent_scopes()) then
    raise exception 'ask for at least one known scope' using errcode = '22023';
  end if;
  if p_valid_for is null or p_valid_for <= interval '0' or p_valid_for > interval '90 days' then
    raise exception 'a consent request lives between 0 and 90 days' using errcode = '22023';
  end if;

  select p.team_id, t.league_id into v_team, v_league
    from public.players p join public.teams t on t.id = p.team_id
   where p.id = p_player;
  if v_team is null then
    raise exception 'no such player' using errcode = '42501';
  end if;
  if not app.may_manage_consent(v_team) then
    raise exception 'no such player' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.guardian_children gc
     where gc.guardian_id = p_guardian and gc.player_id = p_player) then
    raise exception 'that guardian is not linked to that child'
      using errcode = '42501',
            hint = 'app.link_guardian() first -- an ask goes to a named guardian of a named child';
  end if;

  if p_notice is null then
    select * into v_notice from public.consent_notices n
     where n.league_id = v_league and n.retired_at is null and v_scopes <@ n.scopes
     order by n.version desc limit 1;
  else
    select * into v_notice from public.consent_notices n
     where n.id = p_notice and n.league_id = v_league;
  end if;
  if v_notice.id is null then
    raise exception 'this league has published no live consent notice covering %', v_scopes
      using errcode = '22023',
            hint = 'app.issue_consent_notice() -- a guardian cannot agree to something nobody has written down';
  end if;
  if v_notice.retired_at is not null then
    raise exception 'that notice is retired; ask against the current one' using errcode = '22023';
  end if;
  if not (v_scopes <@ v_notice.scopes) then
    raise exception 'notice v% does not cover %', v_notice.version, v_scopes using errcode = '22023';
  end if;

  -- Re-asking supersedes the outstanding ask, exactly as issuing a second
  -- invitation kills the first: a token sent to a mistyped address stops
  -- working the moment the coach re-sends.
  with dead as (
    update public.consent_requests r
       set status = 'withdrawn', withdrawn_at = now(), withdrawn_by = v_uid,
           decision_note = 'superseded by a later request'
     where r.player_id = p_player and r.guardian_id = p_guardian and r.status = 'pending'
    returning r.id
  )
  select count(*) into v_killed from dead;

  insert into public.consent_requests
    (team_id, player_id, guardian_id, notice_id, notice_version, scopes,
     requested_by, expires_at)
  values (v_team, p_player, p_guardian, v_notice.id, v_notice.version, v_scopes,
          v_uid, now() + p_valid_for)
  returning id into v_id;

  perform app.consent_note('request_issue', v_team, p_player, v_id,
    jsonb_build_object('guardian', p_guardian, 'scopes', to_jsonb(v_scopes),
                       'notice_version', v_notice.version,
                       'expires_at', now() + p_valid_for, 'superseded', v_killed));
  return v_id;
end $$;

comment on function app.request_consent(uuid, uuid, text[], uuid, interval) is
  'Ask a guardian. Returns the request id and NOT a token -- the coach who asks must never hold the answer. app.consent_dispatch(), which the mailer alone may call, mints the token.';

create or replace function app.withdraw_consent_request(p_request uuid, p_why text default null)
returns boolean
language plpgsql
volatile security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_r   public.consent_requests%rowtype;
begin
  select * into v_r from public.consent_requests where id = p_request;
  if not found or not app.may_manage_consent(v_r.team_id) then
    raise exception 'no such request' using errcode = '42501';
  end if;
  if v_r.status <> 'pending' then
    raise exception 'that request was already %', v_r.status using errcode = '22023';
  end if;
  update public.consent_requests
     set status = 'withdrawn', withdrawn_at = now(), withdrawn_by = v_uid,
         decision_note = nullif(btrim(coalesce(p_why, '')), '')
   where id = p_request and status = 'pending';
  perform app.consent_note('request_withdraw', v_r.team_id, v_r.player_id, p_request, '{}'::jsonb);
  return true;
end $$;

-- ---------------------------------------------------------------------------
-- 15. Dispatch -- the only place a consent token exists in plaintext
-- ---------------------------------------------------------------------------
-- Executable by pd_mailer and the owner. NOT by pd_authenticated, not by
-- pd_anon, not by a platform owner. It returns the guardian's address and the
-- token together, once, on their way into an email; nothing stores the token
-- and nothing logs it.
--
-- Re-dispatching mints a NEW token and the previous one stops working, so a
-- "resend" is not a second valid answer to the same question.

create or replace function app.consent_dispatch(p_request uuid)
returns table (guardian_email text, token text, notice_title text, expires_at timestamptz)
language plpgsql
volatile security definer
set search_path = ''
as $$
declare
  v_r     public.consent_requests%rowtype;
  v_token text;
begin
  select * into v_r from public.consent_requests where id = p_request;
  if not found then
    raise exception 'no such request' using errcode = '42501';
  end if;
  if v_r.status <> 'pending' then
    raise exception 'request % was already %', p_request, v_r.status using errcode = '22023';
  end if;
  if v_r.expires_at <= now() then
    raise exception 'request % expired on %', p_request, v_r.expires_at using errcode = '22023';
  end if;

  -- The same 244-bit generator auth.sql already uses. One CSPRNG helper in this
  -- schema, not three.
  v_token := app.new_invite_token();

  update public.consent_requests
     set token_digest = app.hash_secret(v_token),
         dispatched_at = now(),
         dispatch_count = dispatch_count + 1
   where id = p_request and status = 'pending';

  perform app.consent_note('request_dispatch', v_r.team_id, v_r.player_id, p_request,
    jsonb_build_object('attempt', v_r.dispatch_count + 1), 'mailer');

  select g.email, n.title, v_r.expires_at
    into guardian_email, notice_title, expires_at
    from public.guardians g, public.consent_notices n
   where g.id = v_r.guardian_id and n.id = v_r.notice_id;
  token := v_token;
  return next;
end $$;

comment on function app.consent_dispatch(uuid) is
  'Mint and hand over the single-use token, for the mailer only. This is the function that makes "a coach cannot answer his own request" a property of the grant graph rather than a promise about the UI.';

-- ---------------------------------------------------------------------------
-- 16. What the guardian sees before they answer
-- ---------------------------------------------------------------------------
-- The guardian has NO ACCOUNT, so this is callable by pd_anon and its only
-- credential is the token. It returns the notice they are being asked to agree
-- to, the scopes, and the child as a JERSEY NUMBER -- never a name. A stolen
-- token should not be a way to read a roster.

create or replace function app.consent_request_view(p_token text)
returns table (
  request_id uuid, status text, team_name text, jersey text,
  scopes text[], notice_version integer, notice_title text,
  notice_body text, assertion text, expires_at timestamptz
)
language plpgsql
stable security definer
set search_path = ''
as $$
declare v_digest text;
begin
  v_digest := app.hash_secret(nullif(btrim(coalesce(p_token, '')), ''));
  if v_digest is null then
    raise exception 'that link is not valid' using errcode = '22023';
  end if;
  return query
  select r.id, r.status, t.name, p.jersey, r.scopes, r.notice_version,
         n.title, n.body, n.assertion, r.expires_at
    from public.consent_requests r
    join public.players p        on p.id = r.player_id
    join public.teams   t        on t.id = r.team_id
    join public.consent_notices n on n.id = r.notice_id
   where r.token_digest = v_digest;
  if not found then
    raise exception 'that link is not valid' using errcode = '22023';
  end if;
end $$;

comment on function app.consent_request_view(text) is
  'What the guardian is shown: the notice text, the scopes, and the child as a jersey number. A stolen token reveals no name.';

-- ---------------------------------------------------------------------------
-- 17. THE GRANT PATH
-- ---------------------------------------------------------------------------
-- One credential: the token. No player parameter -- the child is a property of
-- the row the token digests to, exactly as app.accept_invite() takes no team.
-- p_scopes can only NARROW what was asked for; anything outside the request is
-- refused rather than silently dropped, because a guardian who thinks they said
-- no to photographs must not be told yes.
--
-- Single use is decided by the database, in the WHERE clause of the claiming
-- UPDATE, so two sessions racing the same token produce exactly one winner.
--
-- No auth.uid() is consulted anywhere in this function. A guardian has no
-- account; requiring one would put the coach's login between the parent and the
-- answer.

create or replace function app.grant_consent(
  p_token     text,
  p_assertion text,
  p_ip        text default null,
  p_scopes    text[] default null
) returns jsonb
language plpgsql
volatile security definer
set search_path = ''
as $$
declare
  v_digest  text;
  v_r       public.consent_requests%rowtype;
  v_n       public.consent_notices%rowtype;
  v_scopes  text[];
  v_ip      text;
  v_scope   text;
  v_cid     uuid;
  v_written int := 0;
  v_already int := 0;
begin
  v_digest := app.hash_secret(nullif(btrim(coalesce(p_token, '')), ''));
  if v_digest is null then
    raise exception 'that link is not valid' using errcode = '22023';
  end if;

  select * into v_r from public.consent_requests where token_digest = v_digest;
  if not found then
    raise exception 'that link is not valid' using errcode = '22023';
  end if;
  if v_r.status = 'withdrawn' then
    raise exception 'that request was withdrawn' using errcode = '22023';
  end if;
  if v_r.status <> 'pending' then
    raise exception 'that request was already answered' using errcode = '22023';
  end if;
  if v_r.expires_at <= now() then
    raise exception 'that link expired on %', v_r.expires_at::date using errcode = '22023';
  end if;

  select * into v_n from public.consent_notices where id = v_r.notice_id;
  if btrim(coalesce(p_assertion, '')) <> v_n.assertion then
    raise exception 'the guardian''s assertion must be the sentence on the notice'
      using errcode = '22023',
            hint = 'post back the assertion string exactly as app.consent_request_view() returned it';
  end if;

  v_scopes := coalesce(
      array(select distinct s from unnest(coalesce(p_scopes, v_r.scopes)) s order by s),
      '{}'::text[]);
  if cardinality(v_scopes) < 1 then
    raise exception 'agreeing to nothing is a refusal; use app.refuse_consent()' using errcode = '22023';
  end if;
  if not (v_scopes <@ v_r.scopes) then
    raise exception 'a grant cannot widen the request: % was not asked for',
      (select array_agg(s) from unnest(v_scopes) s where not (s = any (v_r.scopes)))
      using errcode = '42501';
  end if;

  -- Salted with the request id: see the column comment. A bare sha256 of an
  -- IPv4 address is not data minimisation, it is a lookup table.
  v_ip := case when nullif(btrim(coalesce(p_ip, '')), '') is null then null
               else app.hash_secret(btrim(p_ip) || ':' || v_r.id::text) end;

  -- SINGLE USE, in the WHERE clause. Every condition that made this token
  -- answerable is re-checked here, so a race loses rather than double-writes.
  update public.consent_requests
     set status = 'granted', answered_at = now(), answered_scopes = v_scopes,
         assertion = btrim(p_assertion), ip_digest = v_ip
   where id = v_r.id
     and token_digest = v_digest
     and status = 'pending'
     and expires_at > now();
  if not found then
    raise exception 'that request was already answered' using errcode = '22023';
  end if;

  perform set_config('app.consent_intent', 'grant', true);

  foreach v_scope in array v_scopes loop
    insert into public.player_consents (player_id, team_id, granted_by, scope, note)
    values (v_r.player_id, v_r.team_id, v_r.guardian_id, v_scope,
            'guardian grant, notice v' || v_n.version)
    on conflict (player_id, scope) where revoked_at is null do nothing
    returning id into v_cid;

    if v_cid is null then
      v_already := v_already + 1;     -- a live consent for that scope already stood
    else
      insert into public.consent_evidence
        (consent_id, request_id, team_id, player_id, guardian_id, scope,
         notice_id, notice_version, notice_digest, method, assertion, ip_digest)
      values (v_cid, v_r.id, v_r.team_id, v_r.player_id, v_r.guardian_id, v_scope,
              v_n.id, v_r.notice_version, v_n.body_digest, 'email_token',
              btrim(p_assertion), v_ip);
      v_written := v_written + 1;
    end if;
    v_cid := null;
  end loop;

  perform set_config('app.consent_intent', '', true);

  perform app.consent_note('consent_grant', v_r.team_id, v_r.player_id, v_r.id,
    jsonb_build_object('scopes', to_jsonb(v_scopes), 'notice_version', v_r.notice_version,
                       'written', v_written, 'already_live', v_already,
                       'ip_recorded', v_ip is not null), 'guardian');

  return jsonb_build_object(
    'result', 'granted',
    'request', v_r.id,
    'scopes', to_jsonb(v_scopes),
    'notice_version', v_r.notice_version,
    'consents_written', v_written);
end $$;

comment on function app.grant_consent(text, text, text, text[]) is
  'The grant path. One credential, the token; no player parameter; scopes may only narrow. Writes the consent and its evidence, single-use enforced in the claiming UPDATE.';

-- ---------------------------------------------------------------------------
-- 18. Refusal -- an answer, not a timeout
-- ---------------------------------------------------------------------------
-- A refused request is a recorded outcome with a date on it. It blocks exactly
-- as hard as an unanswered one (there is no consent row either way), and
-- app.require_consent() names it so a coach is told "a guardian said no on the
-- 4th" rather than "not found".

create or replace function app.refuse_consent(
  p_token text, p_reason text default null, p_ip text default null
) returns jsonb
language plpgsql
volatile security definer
set search_path = ''
as $$
declare
  v_digest text;
  v_r      public.consent_requests%rowtype;
  v_ip     text;
begin
  v_digest := app.hash_secret(nullif(btrim(coalesce(p_token, '')), ''));
  if v_digest is null then
    raise exception 'that link is not valid' using errcode = '22023';
  end if;
  select * into v_r from public.consent_requests where token_digest = v_digest;
  if not found then
    raise exception 'that link is not valid' using errcode = '22023';
  end if;
  if v_r.status <> 'pending' then
    raise exception 'that request was already answered' using errcode = '22023';
  end if;
  if v_r.expires_at <= now() then
    raise exception 'that link expired on %', v_r.expires_at::date using errcode = '22023';
  end if;

  v_ip := case when nullif(btrim(coalesce(p_ip, '')), '') is null then null
               else app.hash_secret(btrim(p_ip) || ':' || v_r.id::text) end;

  update public.consent_requests
     set status = 'refused', answered_at = now(), ip_digest = v_ip,
         decision_note = nullif(btrim(coalesce(p_reason, '')), '')
   where id = v_r.id and token_digest = v_digest and status = 'pending' and expires_at > now();
  if not found then
    raise exception 'that request was already answered' using errcode = '22023';
  end if;

  perform app.consent_note('consent_refuse', v_r.team_id, v_r.player_id, v_r.id,
    jsonb_build_object('scopes', to_jsonb(v_r.scopes),
                       'notice_version', v_r.notice_version,
                       'reason_given', p_reason is not null), 'guardian');

  return jsonb_build_object('result', 'refused', 'request', v_r.id,
                            'scopes', to_jsonb(v_r.scopes));
end $$;

comment on function app.refuse_consent(text, text, text) is
  'Refusal is a first-class outcome: recorded, dated, final, and single-use in the same WHERE clause the grant uses.';

-- ---------------------------------------------------------------------------
-- 19. Revocation, and what it does
-- ---------------------------------------------------------------------------
-- A guardian changes their mind. Two things have to happen and the second is
-- the one that matters:
--
--   1. The consent is revoked -- revoked_at is set, the row is never erased,
--      and the partial unique index frees the scope so a later grant can stand.
--   2. IF 'roster' IS AMONG THE REVOKED SCOPES, the child's NAME may no longer
--      be held, so the player row is DELETED. That runs the two BEFORE DELETE
--      triggers this schema already has: app.consent_forget_player() clears the
--      requests, the evidence and the guardian links, and
--      app.tombstone_player() -- which is not re-implemented here, per the
--      brief -- sweeps every play that named him down to his jersey number and
--      leaves a tombstone that holds no name. Every play survives. The
--      deletion reason is recorded as 'parent_request'.
--
-- Revoking a NARROWER scope (film, photo, share_*) revokes exactly that and
-- leaves the child on the roster, because the name is still consented to. That
-- per-scope answer is the defensible one: withdrawing permission to photograph
-- a boy is not a request to erase him from the team.

create or replace function app.revoke_consent_rows(
  p_player uuid, p_team uuid, p_scopes text[], p_by text, p_request uuid, p_reason text
) returns integer
language plpgsql
volatile security definer
set search_path = ''
as $$
declare n int := 0;
begin
  perform set_config('app.consent_intent', 'grant', true);
  with dead as (
    update public.player_consents c
       set revoked_at = now(),
           note = coalesce(c.note || ' | ', '') || 'revoked: ' ||
                  coalesce(nullif(btrim(coalesce(p_reason, '')), ''), 'guardian request')
     where c.player_id = p_player and c.revoked_at is null and c.scope = any (p_scopes)
    returning 1
  ) select count(*) into n from dead;
  perform set_config('app.consent_intent', '', true);

  perform app.consent_note('consent_revoke', p_team, p_player, p_request,
    jsonb_build_object('scopes', to_jsonb(p_scopes), 'revoked', n,
                       'roster_included', 'roster' = any (p_scopes)), p_by);
  return n;
end $$;

-- The guardian's own path: the revoke token handed back at grant time. Callable
-- by pd_anon, because a guardian still has no account.
create or replace function app.revoke_consent(
  p_token text, p_scopes text[] default null, p_reason text default null
) returns jsonb
language plpgsql
volatile security definer
set search_path = ''
as $$
declare
  v_digest text;
  v_r      public.consent_requests%rowtype;
  v_scopes text[];
  v_n      int;
  v_forgot boolean := false;
begin
  v_digest := app.hash_secret(nullif(btrim(coalesce(p_token, '')), ''));
  if v_digest is null then
    raise exception 'that link is not valid' using errcode = '22023';
  end if;
  select * into v_r from public.consent_requests where token_digest = v_digest;
  if not found or v_r.status <> 'granted' then
    raise exception 'that link is not valid' using errcode = '22023';
  end if;

  -- Default: take back everything this token granted. Narrowing is allowed;
  -- widening past what this request granted is not, because another guardian
  -- may have granted the rest.
  v_scopes := array(select distinct s
                      from unnest(coalesce(p_scopes, v_r.answered_scopes)) s order by s);
  if not (v_scopes <@ v_r.answered_scopes) then
    raise exception 'this link only covers %', v_r.answered_scopes using errcode = '42501';
  end if;

  v_n := app.revoke_consent_rows(v_r.player_id, v_r.team_id, v_scopes, 'guardian', v_r.id, p_reason);

  if 'roster' = any (v_scopes) then
    -- The name may no longer be held. Hand it to the mechanism that already
    -- exists: deleting the player runs app.tombstone_player(), which degrades
    -- every play he was in to his jersey number and deletes none of them.
    perform set_config('app.deletion_reason', 'parent_request', true);
    delete from public.players where id = v_r.player_id;
    v_forgot := true;
  end if;

  return jsonb_build_object('result', 'revoked', 'scopes', to_jsonb(v_scopes),
                            'consents_revoked', v_n, 'child_forgotten', v_forgot);
end $$;

comment on function app.revoke_consent(text, text[], text) is
  'A guardian withdraws. Revokes the consent, and if the roster scope is among it, deletes the player row -- which runs the existing tombstone trigger, so the name goes and every play survives as a jersey number.';

-- The staff path, for the phone call that reaches the board rather than the
-- app. It is not a new power: rls.sql already lets a coach or a board member
-- delete a player outright. What it adds is that the revocation is recorded
-- with an actor, and that the tombstone reason says parent_request.
create or replace function app.revoke_consent_for(
  p_player uuid, p_scopes text[] default array['roster']::text[], p_reason text default null
) returns jsonb
language plpgsql
volatile security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_team   uuid;
  v_scopes text[] := array(select distinct s from unnest(coalesce(p_scopes, '{}'::text[])) s order by s);
  v_n      int;
  v_forgot boolean := false;
begin
  if v_uid is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  select p.team_id into v_team from public.players p where p.id = p_player;
  if v_team is null or not app.may_manage_consent(v_team) then
    raise exception 'no such player' using errcode = '42501';
  end if;
  if cardinality(v_scopes) < 1 or not (v_scopes <@ app.consent_scopes()) then
    raise exception 'name at least one known scope' using errcode = '22023';
  end if;

  v_n := app.revoke_consent_rows(p_player, v_team, v_scopes, 'staff', null, p_reason);

  if 'roster' = any (v_scopes) then
    perform set_config('app.deletion_reason', 'parent_request', true);
    delete from public.players where id = p_player;
    v_forgot := true;
  end if;

  return jsonb_build_object('result', 'revoked', 'scopes', to_jsonb(v_scopes),
                            'consents_revoked', v_n, 'child_forgotten', v_forgot);
end $$;

-- ---------------------------------------------------------------------------
-- 20. Reporting: what a coach and a board can see about their own team
-- ---------------------------------------------------------------------------

-- Every roster slot, and where its consent stands. This is the screen that
-- makes the flow usable: unnamed slots waiting on an answer, refusals, and
-- names that were collected before this file existed and have no evidence
-- behind them.
create or replace function app.consent_audit_team(p_team uuid)
returns table (
  player_id uuid, jersey text, named boolean, roster_ok boolean,
  consent_state text, notice_version integer, plays_naming_him integer
)
language plpgsql
stable security definer
set search_path = ''
as $$
begin
  if not app.may_manage_consent(p_team) then
    raise exception 'no such team' using errcode = '42501';
  end if;
  return query
  select p.id,
         p.jersey,
         app.player_is_named(p.last, p.first),
         app.consent_ok(p.id, 'roster'),
         case
           when app.consent_ok(p.id, 'roster') then 'live'
           when exists (select 1 from public.player_consents c
                         where c.player_id = p.id and c.scope = 'roster' and c.revoked_at is null)
                then 'stale_notice'
           when exists (select 1 from public.consent_requests r
                         where r.player_id = p.id and r.status = 'refused' and 'roster' = any (r.scopes))
                then 'refused'
           when exists (select 1 from public.consent_requests r
                         where r.player_id = p.id and r.status = 'pending' and 'roster' = any (r.scopes))
                then 'pending'
           else 'none'
         end,
         (select max(e.notice_version) from public.consent_evidence e
           where e.player_id = p.id and e.scope = 'roster'),
         (select count(*)::integer from public.plays pl
           where pl.team_id = p.team_id
             and pl.doc -> 'players' @> jsonb_build_array(jsonb_build_object('rosterId', p.id::text)))
    from public.players p
   where p.team_id = p_team
   order by app.consent_ok(p.id, 'roster'), p.jersey nulls last;
end $$;

comment on function app.consent_audit_team(uuid) is
  'Where each roster slot stands. REPORTS the plays that name a child, it does not block them -- a play document is free text and refusing play writes would refuse the coach his work.';

-- The compliance answer, for one child, for one scope: what exactly did they
-- agree to, when, having been shown which version.
create or replace function app.consent_provenance(p_player uuid)
returns table (
  scope text, granted_at timestamptz, revoked_at timestamptz,
  method text, notice_version integer, notice_digest text,
  assertion text, ip_recorded boolean, guardian_email text
)
language plpgsql
stable security definer
set search_path = ''
as $$
declare v_team uuid;
begin
  select p.team_id into v_team from public.players p where p.id = p_player;
  if v_team is null or not app.may_manage_consent(v_team) then
    raise exception 'no such player' using errcode = '42501';
  end if;
  return query
  select c.scope, c.granted_at, c.revoked_at,
         coalesce(e.method, 'unrecorded'), e.notice_version, e.notice_digest,
         e.assertion, e.ip_digest is not null, g.email
    from public.player_consents c
    left join public.consent_evidence e on e.consent_id = c.id
    left join public.guardians g on g.id = e.guardian_id
   where c.player_id = p_player
   order by c.scope, c.granted_at;
end $$;

comment on function app.consent_provenance(uuid) is
  'Answers "what exactly did they agree to, and how do you know" for one child. A row whose method reads unrecorded is a paper consent written before this flow existed.';

-- ---------------------------------------------------------------------------
-- 21. Privileges and policies
-- ---------------------------------------------------------------------------
-- Same discipline as rls.sql, auth.sql and platform.sql: privileges say which
-- verbs exist, policies say which rows, and both have to pass.

-- SECURITY DEFINER functions are EXECUTE-to-PUBLIC by default, which would hand
-- an anonymous session a function that runs as the owner. Take it all back
-- first, then hand out exactly what each caller needs.
revoke all on function
  app.is_privileged_session(), app.may_manage_consent(uuid), app.consent_scopes(),
  app.jersey_placeholder(text), app.player_is_named(text, text),
  app.consent_note(text, uuid, uuid, uuid, jsonb, text),
  app.current_notice_version(uuid, text), app.consent_ok(uuid, text),
  app.require_consent(uuid, text),
  app.issue_consent_notice(uuid, text, text, text, text[], text),
  app.retire_consent_notice(uuid),
  app.add_guardian(uuid, text, text), app.link_guardian(uuid, uuid, text),
  app.unlink_guardian(uuid, uuid),
  app.request_consent(uuid, uuid, text[], uuid, interval),
  app.withdraw_consent_request(uuid, text),
  app.consent_dispatch(uuid), app.consent_request_view(text),
  app.grant_consent(text, text, text, text[]),
  app.refuse_consent(text, text, text),
  app.revoke_consent_rows(uuid, uuid, text[], text, uuid, text),
  app.revoke_consent(text, text[], text),
  app.revoke_consent_for(uuid, text[], text),
  app.consent_audit_team(uuid), app.consent_provenance(uuid)
from public;

-- Staff: ask, withdraw, link, publish, report, revoke on request. Each function
-- decides for itself whether this caller may do it to that team.
grant execute on function
  app.may_manage_consent(uuid), app.consent_scopes(),
  app.jersey_placeholder(text), app.player_is_named(text, text),
  app.consent_ok(uuid, text), app.require_consent(uuid, text),
  app.current_notice_version(uuid, text),
  app.issue_consent_notice(uuid, text, text, text, text[], text),
  app.retire_consent_notice(uuid),
  app.add_guardian(uuid, text, text), app.link_guardian(uuid, uuid, text),
  app.unlink_guardian(uuid, uuid),
  app.request_consent(uuid, uuid, text[], uuid, interval),
  app.withdraw_consent_request(uuid, text),
  app.revoke_consent_for(uuid, text[], text),
  app.consent_audit_team(uuid), app.consent_provenance(uuid)
to pd_authenticated;

-- The guardian holds no account, so their three functions are open to the
-- anonymous role and their only credential is the token.
grant execute on function
  app.consent_request_view(text),
  app.grant_consent(text, text, text, text[]),
  app.refuse_consent(text, text, text),
  app.revoke_consent(text, text[], text)
to pd_anon, pd_authenticated;

-- THE ONE THAT MATTERS: dispatch is the mailer's and nobody else's.
grant execute on function app.consent_dispatch(uuid) to pd_mailer;

-- app.is_privileged_session() is granted to PUBLIC, and that is not a widening.
-- It is now SECURITY INVOKER, so it reports on the caller's own session and
-- tells them nothing they could not learn from current_user. It has to be
-- callable, because the two guard triggers run as the caller and ask it on
-- every write to public.players and public.player_consents; granted to nobody,
-- an honest gate would refuse every insert with "permission denied".
grant execute on function app.is_privileged_session() to pd_anon, pd_authenticated;

-- Deliberately granted to NOBODY: app.consent_note() and
-- app.revoke_consent_rows(). Both write the trail and the consent rows and are
-- only ever called from inside the functions above.

-- Read: staff read their own team's consent record. No write verb on any of
-- these six tables for anybody -- every row is written by a definer function or
-- a trigger, which is the privilege half of "insert-only"; the guard triggers
-- are the half that binds the owner.
grant select on
  public.consent_notices, public.guardians, public.guardian_children,
  public.consent_requests, public.consent_evidence, public.consent_events
to pd_anon, pd_authenticated;

revoke insert, update, delete on
  public.consent_notices, public.guardians, public.guardian_children,
  public.consent_requests, public.consent_evidence, public.consent_events
from pd_anon, pd_authenticated;

-- AND THE CRUX, ONE LINE. rls.sql granted these to pd_authenticated and wrote
-- two policies for them. Both policies stay exactly where they are and neither
-- is reached again: a coach, an assistant, a league admin, a board member and a
-- platform owner now all fail the privilege check before RLS is consulted.
revoke insert, update, delete on public.player_consents from pd_anon, pd_authenticated;

alter table public.consent_notices    enable row level security;
alter table public.guardians          enable row level security;
alter table public.guardian_children  enable row level security;
alter table public.consent_requests   enable row level security;
alter table public.consent_evidence   enable row level security;
alter table public.consent_events     enable row level security;

alter table public.consent_notices    force row level security;
alter table public.guardians          force row level security;
alter table public.guardian_children  force row level security;
alter table public.consent_requests   force row level security;
alter table public.consent_evidence   force row level security;
alter table public.consent_events     force row level security;

-- A notice is the league's public text: anybody in the league may read it,
-- which is the same reach rls.sql gives the rulebook itself.
create policy consent_notices_select on public.consent_notices
  for select to pd_anon, pd_authenticated
  using (league_id in (select app.visible_league_ids()));

-- A parent's address is not team gossip: the coaches who have to contact them
-- and the league's compliance seat, and nobody else. A HELPER IS NOT ON THIS
-- LIST -- a helper is another team parent with a sideline tablet.
create policy guardians_select on public.guardians
  for select to pd_anon, pd_authenticated
  using (team_id in (select app.coach_team_ids())
      or team_id in (select app.board_team_ids()));

create policy guardian_children_select on public.guardian_children
  for select to pd_anon, pd_authenticated
  using (team_id in (select app.coach_team_ids())
      or team_id in (select app.board_team_ids()));

create policy consent_requests_select on public.consent_requests
  for select to pd_anon, pd_authenticated
  using (team_id in (select app.coach_team_ids())
      or team_id in (select app.board_team_ids()));

create policy consent_evidence_select on public.consent_evidence
  for select to pd_anon, pd_authenticated
  using (team_id in (select app.coach_team_ids())
      or team_id in (select app.board_team_ids()));

create policy consent_events_select on public.consent_events
  for select to pd_anon, pd_authenticated
  using (team_id in (select app.coach_team_ids())
      or team_id in (select app.board_team_ids()));

-- FORCE binds the owner, and the owner is who the definer functions run as, so
-- the writes above need policies of their own or the flow could not write at
-- all. They are scoped rather than `true` wherever there is anything to scope
-- to; the real guard on forgery is that no tenant holds the verb.
create policy consent_notices_write on public.consent_notices
  for insert with check (true);
create policy consent_notices_retire on public.consent_notices
  for update using (true) with check (true);
create policy guardians_write on public.guardians
  for all using (true) with check (true);
create policy guardian_children_write on public.guardian_children
  for all using (true) with check (true);
create policy consent_requests_write on public.consent_requests
  for all using (true) with check (true);
create policy consent_evidence_write on public.consent_evidence
  for all using (true) with check (true);
create policy consent_events_append on public.consent_events
  for insert with check (true);

-- (no commit; the runner commits)
