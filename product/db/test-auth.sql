-- product/db/test-auth.sql
-- The adversarial suite for auth.sql. Same house rules as test-isolation.sql,
-- because the same thing is being proved: a guard nobody attacked is a guard
-- nobody has tested.
--
-- RUN:
--   psql -h /tmp -p 5433 -U app -d pd_auth -f product/db/test-auth.sql
-- FROM EMPTY:
--   createdb pd_auth
--   psql ... -f product/db/schema.sql -f product/db/rls.sql -f product/db/auth.sql \
--            -f product/db/seed.sql   -f product/db/auth-seed.sql
--
-- Everything runs inside one transaction and ROLLS BACK, so the suite is
-- rerunnable and leaves the seed untouched. There are deliberately no
-- SAVEPOINTs, for the same reason there are none in test-isolation.sql: rolling
-- back to one would roll back the results table with it.
--
-- HOUSE RULES, inherited:
--   (a) Every refusal is paired with a CONTROL run as the bypassing owner,
--       proving the row was really there to be taken. A refusal whose control
--       returns 0 is reported as a broken test, not as a pass.
--   (b) Attacks address the other tenant's rows by literal uuid. A subselect
--       would return NULL under RLS and the attack would "pass" by asking about
--       nothing.
--   (c) Section 11 briefly ADDS a permissive policy and shows the identical
--       query leaking everything, so nobody has to take the controls on faith.
--
-- WHAT THIS FILE CANNOT PROVE. Listed here rather than buried, because the
-- honest boundary of a test suite is part of its result:
--   * Magic-link DELIVERY. Supabase Auth's hosted email, its link expiry, its
--     one-time-use nonce and its rate limiting are not in this database and are
--     not exercised here. What is assumed is exactly this: that auth.uid() and
--     auth.email() are set from a verified JWT and cannot be chosen by the
--     client. Section 1 tests the shim (GUC -> auth.uid()/auth.email()); it
--     cannot test that the GUC was stamped honestly, and neither could
--     test-isolation.sql, which rests on the same assumption for app.user_id.
--   * Rate limiting a player word. ~30 bits is a usability decision defended by
--     scope, read-onlyness and rotation; online guessing has to be throttled in
--     front of the database. There is no throttle here to test.
--   * TLS, at rest encryption, backup handling, and where the token goes after
--     app.issue_invite() returns it.

\set ON_ERROR_STOP on
\timing off
\pset pager off

begin;

-- ===========================================================================
-- Harness -- same shape as test-isolation.sql, plus two helpers this suite needs
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

-- Read back a secret the suite minted earlier. Tests pass it as an ARGUMENT --
-- t.tok('x') inside the statement -- rather than interpolating it into SQL
-- text, so nothing here depends on quoting a token correctly.
create function t.tok(p_key text) returns text
language sql stable as $fn$ select v from t.state where k = p_key $fn$;

-- Become somebody. Both claims, because an invitation is addressed to an email:
-- app.user_id -> auth.uid(), app.user_email -> auth.email(). On Supabase both
-- come off one verified JWT and neither is chooseable by the client; here they
-- are GUCs, exactly as the pooler would stamp them.
create function t.be(p_user uuid, p_email text default null) returns void
language plpgsql as $fn$
begin
  perform set_config('app.user_id',    coalesce(p_user::text, ''), false);
  perform set_config('app.user_email', coalesce(p_email, ''), false);
end $fn$;

-- Present a player word, the way the boys' page would: the team from the link,
-- the word from the box.
create function t.word(p_team uuid, p_word text) returns void
language plpgsql as $fn$
begin
  perform set_config('app.player_team', coalesce(p_team::text, ''), false);
  perform set_config('app.player_word', coalesce(p_word, ''), false);
end $fn$;

create function t.noword() returns void
language plpgsql as $fn$
begin
  perform set_config('app.player_team', '', false);
  perform set_config('app.player_word', '', false);
end $fn$;

grant execute on all functions in schema t to public;

-- ===========================================================================
-- 0. CONTROL -- what exists, seen by the bypassing owner
-- ===========================================================================
select set_config('t.sect', '0 control', false);
\echo '=== 0. What the auth layer starts with (owner, RLS bypassed) ==='
select (select count(*) from public.invites)       as invites,
       (select count(*) from public.player_words)  as player_words,
       (select count(*) from public.auth_events)   as audit_rows,
       (select count(*) from public.memberships)   as memberships;

select i.id, coalesce(i.team_id::text, i.league_id::text) as scope, i.role, i.email,
       (i.revoked_at is not null) as withdrawn, (i.expires_at < now()) as expired
  from public.invites i order by i.id;

select t.control('invitations exist to attack',        $q$select 1 from public.invites$q$, 6);
select t.control('two live ones share one address',
  $q$select 1 from public.invites where email='newcoach@example.com'
      and accepted_at is null and revoked_at is null and expires_at > now()$q$, 2);
select t.control('and they name teams in different leagues',
  $q$select 1 from public.teams t where t.id in
      (select i.team_id from public.invites i where i.email='newcoach@example.com')
      group by t.league_id$q$, 2);
select t.control('player words exist',                 $q$select 1 from public.player_words$q$, 3);
select t.control('the audit log already has the seed''s own staffing in it',
  $q$select 1 from public.auth_events where action in ('membership_grant','league_membership_grant')$q$, 10);
select t.control('Lehi 8 has plays a word could read', $q$select 1 from public.plays where team_id='c0000000-0000-4000-8000-000000000001'$q$, 2);
select t.control('Logan 8 has plays a word must NOT reach', $q$select 1 from public.plays where team_id='c0000000-0000-4000-8000-000000000004'$q$, 1);
select t.control('Lehi 8 has consents a word must not reach',
  $q$select 1 from public.player_consents where team_id='c0000000-0000-4000-8000-000000000001'$q$, 3);

-- The trigger, not the application, is what writes the log. Nothing in seed.sql
-- knows auth.sql exists, and its seven memberships are all in there anyway.
select t.val('every seeded membership is in the log',
  $q$select (select count(*) from public.memberships)::text
          = (select count(*)::text from public.auth_events where action='membership_grant')$q$, 'true');

-- ===========================================================================
-- 1. Identity: two claims off one token, and no third source of authority
-- ===========================================================================
select set_config('t.sect', '1 identity', false);
set role pd_authenticated;

select t.be(null, null);
select t.val('no GUC -> auth.uid() is NULL',   $q$select auth.uid()::text$q$, null);
select t.val('no GUC -> auth.email() is NULL', $q$select auth.email()$q$, null);
select t.be('d0000000-0000-4000-8000-000000000001', 'dom@example.com');
select t.val('GUC set -> auth.uid() is the user',   $q$select auth.uid()::text$q$, 'd0000000-0000-4000-8000-000000000001');
select t.val('GUC set -> auth.email() is the claim', $q$select auth.email()$q$, 'dom@example.com');
select set_config('app.user_email', '  DOM@Example.COM  ', false);
select t.val('the email claim is normalised, so case cannot fork an identity',
  $q$select auth.email()$q$, 'dom@example.com');
select set_config('app.user_email', '', false);
select t.val('an empty email claim fails closed to NULL', $q$select auth.email()$q$, null);

-- The thing his current gate got wrong: a tier that travels with the client.
-- There is nowhere in this schema to put one, and inventing GUCs does not help.
select t.be('d0000000-0000-4000-8000-00000000000a', 'stranger@example.com');
select set_config('app.tier', 'head', false);
select set_config('app.role', 'admin', false);
select set_config('app.team_id', 'c0000000-0000-4000-8000-000000000001', false);
select t.rows('a made-up tier GUC buys no plays',   $q$select 1 from public.plays$q$, 0);
select t.rows('a made-up role GUC buys no roster',  $q$select 1 from public.players$q$, 0);
select t.rows('a made-up team GUC buys no team',    $q$select 1 from public.teams$q$, 0);
select set_config('app.tier', '', false);
select set_config('app.role', '', false);
select set_config('app.team_id', '', false);
reset role;

select t.val('no table in the schema holds a tier or a password',
  $q$select count(*)::text from information_schema.columns
      where table_schema='public'
        and column_name in ('tier','password','password_hash','passphrase','secret','token')$q$, '0');
select t.val('the only credential columns there are, are one-way digests',
  $q$select string_agg(table_name||'.'||column_name, ',' order by table_name)
      from information_schema.columns
     where table_schema='public' and column_name like '%hash%'$q$,
  'invites.token_hash,player_words.word_hash');
select t.val('and the auth layer hardcodes no team, league or town',
  $q$select count(*)::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='app'
        and (lower(p.prosrc) like '%lehi%' or lower(p.prosrc) like '%uyfc%'
          or lower(p.prosrc) like '%8a::%')$q$, '0');

-- ===========================================================================
-- 2. Who may mint an invitation. This is the security crux: if the wrong person
--    can mint one, every other guard in this file is decoration.
-- ===========================================================================
select set_config('t.sect', '2 minting', false);
set role pd_authenticated;

-- The seat that must not have it. rls.sql already says an assistant cannot
-- staff a team; an assistant who could invite would be staffing it sideways.
select t.be('d0000000-0000-4000-8000-000000000001', 'dom@example.com');
select t.raises('an ASSISTANT cannot mint an invitation for his own team',
  $q$select * from app.issue_invite('mint-test@example.com','helper','c0000000-0000-4000-8000-000000000001')$q$, '42501');
select t.raises('nor a lesser role than his own',
  $q$select * from app.issue_invite('mint-test@example.com','helper','c0000000-0000-4000-8000-000000000003')$q$, '42501');

select t.be('d0000000-0000-4000-8000-000000000003', 'parent@example.com');
select t.raises('a HELPER cannot mint anything',
  $q$select * from app.issue_invite('mint-test@example.com','helper','c0000000-0000-4000-8000-000000000001')$q$, '42501');

select t.be('d0000000-0000-4000-8000-00000000000a', 'stranger@example.com');
select t.raises('a stranger with a valid account cannot mint',
  $q$select * from app.issue_invite('mint-test@example.com','head','c0000000-0000-4000-8000-000000000001')$q$, '42501');

select t.be(null, null);
select t.raises('an unauthenticated session cannot mint',
  $q$select * from app.issue_invite('mint-test@example.com','head','c0000000-0000-4000-8000-000000000001')$q$, '42501');

-- The head of a team, for his own team, is the one who can.
select t.be('d0000000-0000-4000-8000-000000000002', 'steve@example.com');
select t.val('a HEAD mints one for his own team',
  $q$select count(*)::text from app.issue_invite('mint-test@example.com','assistant','c0000000-0000-4000-8000-000000000001')$q$, '1');
select t.raises('but not for a sibling team in his own league',
  $q$select * from app.issue_invite('mint-test@example.com','assistant','c0000000-0000-4000-8000-000000000002')$q$, '42501');
select t.raises('and not for a team in another league',
  $q$select * from app.issue_invite('mint-test@example.com','assistant','c0000000-0000-4000-8000-000000000004')$q$, '42501');
select t.raises('nor can he appoint himself to the league board',
  $q$select * from app.issue_invite('steve@example.com','admin',null,'a0000000-0000-4000-8000-000000000001')$q$, '42501');
select t.raises('a team invitation cannot carry a league role',
  $q$select * from app.issue_invite('mint-test@example.com','board','c0000000-0000-4000-8000-000000000001')$q$, '22023');
select t.raises('an invitation must name exactly one scope, not both',
  $q$select * from app.issue_invite('mint-test@example.com','assistant','c0000000-0000-4000-8000-000000000001','a0000000-0000-4000-8000-000000000001')$q$, '22023');
select t.raises('nor neither',
  $q$select * from app.issue_invite('mint-test@example.com','assistant')$q$, '22023');
select t.raises('an invitation needs an address to be sent to',
  $q$select * from app.issue_invite('not-an-email','assistant','c0000000-0000-4000-8000-000000000001')$q$, '22023');
select t.raises('and cannot be made to live for a year',
  $q$select * from app.issue_invite('mint-test@example.com','assistant','c0000000-0000-4000-8000-000000000001',null,interval '365 days')$q$, '22023');

-- The board is oversight; the admin is staffing. rls.sql draws that line for
-- league_memberships and this draws the same one, on purpose.
select t.be('d0000000-0000-4000-8000-000000000005', 'reeves@example.com');
select t.raises('a league BOARD member cannot mint a team invitation',
  $q$select * from app.issue_invite('mint-test@example.com','head','c0000000-0000-4000-8000-000000000001')$q$, '42501');
select t.raises('nor appoint another board member',
  $q$select * from app.issue_invite('mint-test@example.com','board',null,'a0000000-0000-4000-8000-000000000001')$q$, '42501');

select t.be('d0000000-0000-4000-8000-000000000006', 'whitmore@example.com');
select t.val('a league ADMIN may staff a team in his league',
  $q$select count(*)::text from app.issue_invite('mint-admin@example.com','helper','c0000000-0000-4000-8000-000000000002')$q$, '1');
select t.val('and appoint his own board',
  $q$select count(*)::text from app.issue_invite('mint-admin@example.com','board',null,'a0000000-0000-4000-8000-000000000001')$q$, '1');
select t.raises('but not a team in the other league',
  $q$select * from app.issue_invite('mint-admin@example.com','head','c0000000-0000-4000-8000-000000000004')$q$, '42501');
select t.raises('and not the other league''s board',
  $q$select * from app.issue_invite('mint-admin@example.com','admin',null,'a0000000-0000-4000-8000-000000000002')$q$, '42501');
select t.raises('a league invitation cannot carry a team role',
  $q$select * from app.issue_invite('mint-admin@example.com','assistant',null,'a0000000-0000-4000-8000-000000000001')$q$, '22023');
reset role;

set role pd_anon;
select t.be(null, null);
select t.raises('an anonymous session cannot even execute the mint function',
  $q$select * from app.issue_invite('mint-test@example.com','head','c0000000-0000-4000-8000-000000000001')$q$, '42501');
select t.raises('nor the accept function',
  $q$select app.accept_invite('seed-live-lehi8-assistant')$q$, '42501');
reset role;

select t.val('every attempt above that should have failed, wrote nothing',
  $q$select count(*)::text from public.invites where email in ('mint-test@example.com','mint-admin@example.com')$q$, '3');

-- ===========================================================================
-- 3. The token itself: unguessable, and not in the database
-- ===========================================================================
select set_config('t.sect', '3 token', false);
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000002', 'steve@example.com');
select t.snap('tok_live', $q$select token from app.issue_invite('tokentest@example.com','helper','c0000000-0000-4000-8000-000000000001')$q$);
reset role;

select t.val('a token is 64 hex characters -- 244 bits of gen_random_uuid()',
  $q$select case when t.tok('tok_live') ~ '^[0-9a-f]{64}$' then 'ok' else t.tok('tok_live') end$q$, 'ok');
select t.val('200 freshly minted tokens are 200 different tokens',
  $q$select count(distinct app.new_invite_token())::text from generate_series(1,200)$q$, '200');

-- The storage rule, three ways. First: the plaintext is not the stored value.
select t.val('the token is NOT stored in the token_hash column',
  $q$select count(*)::text from public.invites where token_hash = t.tok('tok_live')$q$, '0');
-- Second: it is nowhere else in the row either -- not in a note, not in a
-- forgotten column. The whole row, rendered as text, does not contain it.
select t.val('nor anywhere else in the invitation row',
  $q$select count(*)::text from public.invites i where i::text like '%' || t.tok('tok_live') || '%'$q$, '0');
-- Third: what IS stored is the digest of it, so the hashing is not a no-op that
-- happens to store something unrecognisable.
select t.val('what is stored is sha256 of the token, and it matches',
  $q$select count(*)::text from public.invites
      where token_hash = app.hash_secret(t.tok('tok_live'))$q$, '1');
select t.val('the audit log does not carry the token either',
  $q$select count(*)::text from public.auth_events e where e::text like '%' || t.tok('tok_live') || '%'$q$, '0');
select t.val('and no player word is stored in plaintext',
  $q$select count(*)::text from public.player_words where word_hash in ('kicker-forty-one','bear-river-nine')$q$, '0');
select t.val('the seeded word IS the digest of the word the coach says',
  $q$select count(*)::text from public.player_words
      where team_id='c0000000-0000-4000-8000-000000000001'
        and word_hash = app.hash_secret('kicker-forty-one')$q$, '1');

-- A known-answer test on the digest itself. Every other check above compares a
-- stored value against app.hash_secret(), so every one of them would still pass
-- if that function were quietly weakened -- the mutation log found exactly that
-- hole (truncating the digest to 16 bits failed nothing). This pins it to the
-- published SHA-256 vector for 'abc'.
select t.val('the digest is really SHA-256, not something that looks like it',
  $q$select app.hash_secret('abc')$q$,
  'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
select t.val('and the stored digests are the full width of it',
  $q$select count(*)::text from public.invites where token_hash !~ '^[0-9a-f]{64}$'$q$, '0');

set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000001', 'dom@example.com');
select t.raises('a tenant cannot hash anything, so he cannot grind a digest',
  $q$select app.hash_secret('kicker-forty-one')$q$, '42501');
select t.raises('nor mint himself a token to compare against',
  $q$select app.new_invite_token()$q$, '42501');

-- Who may READ an invitation. The hash is useless without its preimage, but a
-- list of who has been invited to a team is still that team's business.
-- Dom is addressed by one of them (the head invitation in section 6), so he
-- sees that one and only that one. What he cannot do is list the team's.
select t.rows('an assistant sees only the invitation addressed to him',
  $q$select 1 from public.invites$q$, 1);
select t.val('and it is the one with his name on it',
  $q$select email from public.invites$q$, 'dom@example.com');
select t.rows('he cannot list the ones addressed to anybody else',
  $q$select 1 from public.invites where email <> 'dom@example.com'$q$, 0);
select t.be('d0000000-0000-4000-8000-000000000002', 'steve@example.com');
select t.rows('the head can list his own team''s',
  $q$select 1 from public.invites where team_id='c0000000-0000-4000-8000-000000000001'$q$, 6);
select t.rows('and no other team''s, in his league or out of it',
  $q$select 1 from public.invites where team_id <> 'c0000000-0000-4000-8000-000000000001'$q$, 0);
select t.be('d0000000-0000-4000-8000-000000000007', 'ostler@example.com');
select t.rows('the other league''s head sees only his own',
  $q$select 1 from public.invites$q$, 1);
select t.rows('and cannot read the invitation addressed to the same person on our team',
  $q$select 1 from public.invites where id='90000000-0000-4000-8000-000000000001'$q$, 0);
select t.be('d0000000-0000-4000-8000-00000000000a', 'stranger@example.com');
select t.rows('a stranger sees no invitation at all', $q$select 1 from public.invites$q$, 0);
select t.rows('nor any player word',                  $q$select 1 from public.player_words$q$, 0);
-- The invitee can see the ones addressed to him, in both leagues, and nothing else.
select t.be('d0000000-0000-4000-8000-00000000000b', 'newcoach@example.com');
select t.rows('the invitee sees the two addressed to him', $q$select 1 from public.invites$q$, 2);

-- Nobody holds a write verb on invites. Not the head who minted it.
select t.be('d0000000-0000-4000-8000-000000000002', 'steve@example.com');
select t.raises('even the issuing head cannot UPDATE an invitation',
  $q$update public.invites set role='head' where id='90000000-0000-4000-8000-000000000001'$q$, '42501');
select t.raises('nor DELETE one',
  $q$delete from public.invites where id='90000000-0000-4000-8000-000000000001'$q$, '42501');
select t.raises('nor forge one directly, with a hash he chose',
  $q$insert into public.invites (team_id, role, email, token_hash, expires_at)
     values ('c0000000-0000-4000-8000-000000000001','head','me@example.com',
             repeat('a',64), now() + interval '1 day')$q$, '42501');
reset role;

-- Guessing. A random token is refused, and the refusal is the same one an
-- expired token gets: nothing about the invitation is confessed to a guesser.
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-00000000000e', 'outsider@example.com');
select t.raises('a guessed token is refused',
  $q$select app.accept_invite('0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef')$q$, '22023');
select t.raises('an empty token is refused',  $q$select app.accept_invite('')$q$, '22023');
select t.raises('a NULL token is refused',    $q$select app.accept_invite(null)$q$, '22023');
select t.val('and none of that created a membership',
  $q$select count(*)::text from public.memberships where user_id='d0000000-0000-4000-8000-00000000000e'$q$, '0');
reset role;

-- ===========================================================================
-- 4. Accepting: once, in date, by the person it was addressed to
-- ===========================================================================
select set_config('t.sect', '4 accepting', false);
select t.control('the live invitation is really live',
  $q$select 1 from public.invites where id='90000000-0000-4000-8000-000000000001'
      and accepted_at is null and revoked_at is null and expires_at > now()$q$, 1);
select t.control('the expired one is otherwise perfect',
  $q$select 1 from public.invites where id='90000000-0000-4000-8000-000000000003'
      and accepted_at is null and revoked_at is null$q$, 1);

set role pd_authenticated;

-- Not signed in. A magic link is not an identity; it is a way to get one.
select t.be(null, null);
select t.raises('a link with no account behind it is refused',
  $q$select app.accept_invite('seed-live-lehi8-assistant')$q$, '42501');

-- The forwarded link. This is why the email claim is checked as well as the
-- token: holding the token is not proof you are who it was sent to.
select t.be('d0000000-0000-4000-8000-00000000000e', 'outsider@example.com');
select t.raises('a forwarded token is useless to the person it was forwarded to',
  $q$select app.accept_invite('seed-live-lehi8-assistant')$q$, '42501');
reset role;
select t.val('and it did not consume the invitation',
  $q$select (accepted_at is null)::text from public.invites where id='90000000-0000-4000-8000-000000000001'$q$, 'true');
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-00000000000e', null);
select t.raises('an account with no email claim cannot accept either',
  $q$select app.accept_invite('seed-live-lehi8-assistant')$q$, '42501');

-- Expired, and withdrawn. Both refused on the state of the ROW, not on whether
-- the token is known -- the token is perfectly good in both cases.
select t.be('d0000000-0000-4000-8000-00000000000c', 'latecomer@example.com');
select t.raises('an EXPIRED invitation is refused',
  $q$select app.accept_invite('seed-expired-lehi8-helper')$q$, '22023');
select t.val('and no membership came of it',
  $q$select count(*)::text from public.memberships where user_id='d0000000-0000-4000-8000-00000000000c'$q$, '0');

select t.be('d0000000-0000-4000-8000-00000000000f', 'wrongperson@example.com');
select t.raises('a WITHDRAWN invitation is refused',
  $q$select app.accept_invite('seed-revoked-lehi8-assistant')$q$, '22023');
select t.val('and no membership came of that either',
  $q$select count(*)::text from public.memberships where user_id='d0000000-0000-4000-8000-00000000000f'$q$, '0');

-- The real thing.
select t.be('d0000000-0000-4000-8000-00000000000b', 'newcoach@example.com');
select t.val('the right person, in date, with the right token: joined',
  $q$select app.accept_invite('seed-live-lehi8-assistant') ->> 'result'$q$, 'joined');
select t.val('at exactly the role the invitation named',
  $q$select role from public.memberships
      where user_id='d0000000-0000-4000-8000-00000000000b' and team_id='c0000000-0000-4000-8000-000000000001'$q$, 'assistant');
select t.val('and he can now read the team''s plays',
  $q$select count(*)::text from public.plays where team_id='c0000000-0000-4000-8000-000000000001'$q$, '2');

-- ONCE AND ONLY ONCE.
select t.raises('the same token a second time is refused',
  $q$select app.accept_invite('seed-live-lehi8-assistant')$q$, '22023');
select t.raises('and a third time',
  $q$select app.accept_invite('seed-live-lehi8-assistant')$q$, '22023');
select t.val('one acceptance, one membership row',
  $q$select count(*)::text from public.memberships
      where user_id='d0000000-0000-4000-8000-00000000000b' and team_id='c0000000-0000-4000-8000-000000000001'$q$, '1');
reset role;

-- A second account with the same address cannot spend the token again either:
-- the row is consumed, not the identity.
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000010', 'newcoach@example.com');
select t.raises('nor can a second account on the same mailbox spend it',
  $q$select app.accept_invite('seed-live-lehi8-assistant')$q$, '22023');
reset role;
select t.val('which left the team with one new coach, not two',
  $q$select count(*)::text from public.memberships where team_id='c0000000-0000-4000-8000-000000000001'$q$, '4');

select t.val('the consumed invitation records who took it and when',
  $q$select (accepted_by::text) || '/' || (accepted_at is not null)::text
      from public.invites where id='90000000-0000-4000-8000-000000000001'$q$,
  'd0000000-0000-4000-8000-00000000000b/true');

-- Superseding. Minting a replacement kills the outstanding token, so a link
-- emailed to a typo'd address stops working the moment the coach re-sends it.
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000002', 'steve@example.com');
select t.snap('tok_super1', $q$select token from app.issue_invite('supersede@example.com','helper','c0000000-0000-4000-8000-000000000001')$q$);
select t.snap('tok_super2', $q$select token from app.issue_invite('supersede@example.com','helper','c0000000-0000-4000-8000-000000000001')$q$);
select t.be('d0000000-0000-4000-8000-000000000011', 'supersede@example.com');
select t.raises('re-issuing kills the first token',
  $q$select app.accept_invite(t.tok('tok_super1'))$q$, '22023');
select t.val('and the replacement works',
  $q$select app.accept_invite(t.tok('tok_super2')) ->> 'result'$q$, 'joined');
reset role;
-- Put that one back: it was a mechanism test, not a staffing decision.
delete from public.memberships where user_id='d0000000-0000-4000-8000-000000000011';

-- ===========================================================================
-- 5. Team A is not team B, and there is no payload to say otherwise
-- ===========================================================================
select set_config('t.sect', '5 scope', false);

-- The structural answer first. Acceptance takes a token and nothing else, so
-- there is no team in the request for a client to tamper with -- the team is a
-- property of the row the token hashes to.
select t.val('accept_invite takes the token and nothing else',
  $q$select pg_get_function_arguments(p.oid) from pg_proc p
      join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='app' and p.proname='accept_invite'$q$, 'p_token text');
select t.val('and it names exactly one scope per row, by constraint',
  $q$select count(*)::text from pg_constraint
      where conrelid='public.invites'::regclass and conname='invites_one_scope'$q$, '1');
select t.raises('a row naming two scopes is refused by the database',
  $q$insert into public.invites (team_id, league_id, role, email, token_hash, expires_at)
     values ('c0000000-0000-4000-8000-000000000001','a0000000-0000-4000-8000-000000000001',
             'assistant','x@example.com', repeat('b',64), now()+interval '1 day')$q$, '23514');

set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-00000000000b', 'newcoach@example.com');
-- He holds a second, entirely valid token for a team in the OTHER league.
select t.control('he really does hold a Logan token',
  $q$select 1 from public.invites where id='90000000-0000-4000-8000-000000000002'
      and accepted_at is null and expires_at > now()$q$, 1);
select t.raises('he cannot repoint his Logan invitation at the team he already joined',
  $q$update public.invites set team_id='c0000000-0000-4000-8000-000000000001'
      where id='90000000-0000-4000-8000-000000000002'$q$, '42501');
select t.raises('nor upgrade its role from helper to head',
  $q$update public.invites set role='head' where id='90000000-0000-4000-8000-000000000002'$q$, '42501');
select t.raises('nor write the membership he wants directly',
  $q$insert into public.memberships (user_id, team_id, role)
     values ('d0000000-0000-4000-8000-00000000000b','c0000000-0000-4000-8000-000000000004','head')$q$, '42501');
select t.blocked('nor promote the membership he does have',
  $q$update public.memberships set role='head'
      where user_id='d0000000-0000-4000-8000-00000000000b' and team_id='c0000000-0000-4000-8000-000000000001'$q$);
-- Setting every GUC he can think of changes nothing: the team comes off the row.
select set_config('app.team_id', 'c0000000-0000-4000-8000-000000000001', false);
select set_config('app.player_team', 'c0000000-0000-4000-8000-000000000001', false);
select t.val('redeeming the Logan token lands him in Logan, whatever he sets',
  $q$select app.accept_invite('seed-live-logan8-helper') ->> 'team_id'$q$, 'c0000000-0000-4000-8000-000000000004');
select set_config('app.team_id', '', false);
select set_config('app.player_team', '', false);
select t.val('at the role Logan named, not the one he holds at Lehi',
  $q$select role from public.memberships
      where user_id='d0000000-0000-4000-8000-00000000000b' and team_id='c0000000-0000-4000-8000-000000000004'$q$, 'helper');
select t.val('two invitations, two teams, two memberships -- and no third',
  $q$select string_agg(team_id::text, ',' order by team_id::text) from public.memberships
      where user_id='d0000000-0000-4000-8000-00000000000b'$q$,
  'c0000000-0000-4000-8000-000000000001,c0000000-0000-4000-8000-000000000004');
select t.rows('and being in two leagues is not being in either board',
  $q$select 1 from public.league_memberships where user_id='d0000000-0000-4000-8000-00000000000b'$q$, 0);
-- As a Logan HELPER he reads Logan's play; as a Lehi assistant he reads Lehi's.
-- He does not read Lehi 7, Smithfield, or anything else in either league.
select t.val('he now reads exactly the two teams he was invited to',
  $q$select count(*)::text from public.plays$q$, '3');
select t.rows('and no team in either league that did not invite him',
  $q$select 1 from public.plays where team_id in
      ('c0000000-0000-4000-8000-000000000002','c0000000-0000-4000-8000-000000000003','c0000000-0000-4000-8000-000000000005')$q$, 0);
reset role;

-- ===========================================================================
-- 6. Already a member: no duplicate, no promotion
-- ===========================================================================
select set_config('t.sect', '6 no escalation', false);
select t.control('Dom is on the team as an assistant',
  $q$select 1 from public.memberships
      where user_id='d0000000-0000-4000-8000-000000000001'
        and team_id='c0000000-0000-4000-8000-000000000001' and role='assistant'$q$, 1);
select t.control('and holds a live invitation to the same team as HEAD',
  $q$select 1 from public.invites where id='90000000-0000-4000-8000-000000000005'
      and role='head' and accepted_at is null and expires_at > now()$q$, 1);
select t.snap('memberships_before_reaccept', $q$select count(*)::text from public.memberships$q$);

set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000001', 'dom@example.com');
select t.val('accepting it reports what actually happened',
  $q$select app.accept_invite('seed-live-lehi8-head-for-dom') ->> 'result'$q$, 'already_member');
select t.val('HIS ROLE DID NOT MOVE',
  $q$select role from public.memberships
      where user_id='d0000000-0000-4000-8000-000000000001' and team_id='c0000000-0000-4000-8000-000000000001'$q$, 'assistant');
select t.val('and he has one row on that team, not two',
  $q$select count(*)::text from public.memberships
      where user_id='d0000000-0000-4000-8000-000000000001' and team_id='c0000000-0000-4000-8000-000000000001'$q$, '1');
select t.raises('so he still cannot staff the team',
  $q$select * from app.issue_invite('after@example.com','helper','c0000000-0000-4000-8000-000000000001')$q$, '42501');
select t.raises('and the invitation is spent, not left lying around',
  $q$select app.accept_invite('seed-live-lehi8-head-for-dom')$q$, '22023');
reset role;
select t.unchanged('no membership row was added by any of that', 'memberships_before_reaccept',
  $q$select count(*)::text from public.memberships$q$);
select t.val('the log says what it was, in the coach''s own words',
  $q$select detail->>'result' from public.auth_events
      where action='invite_accept' and subject_user='d0000000-0000-4000-8000-000000000001'$q$, 'already_member');

-- ===========================================================================
-- 7. The league board seat, by invitation
-- ===========================================================================
select set_config('t.sect', '7 league invite', false);
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-00000000000d', 'newboard@example.com');
select t.rows('before accepting, he sees nothing', $q$select 1 from public.teams$q$, 0);
select t.val('the league invitation seats him on the board',
  $q$select app.accept_invite('seed-live-uyfc-board') ->> 'role'$q$, 'board');
select t.val('and it is a league seat, not a team one',
  $q$select count(*)::text from public.league_memberships
      where user_id='d0000000-0000-4000-8000-00000000000d'
        and league_id='a0000000-0000-4000-8000-000000000001' and role='board'$q$, '1');
select t.rows('he now sees his league''s teams',   $q$select 1 from public.teams$q$, 3);
select t.rows('and no team in the other league',
  $q$select 1 from public.teams where league_id='a0000000-0000-4000-8000-000000000002'$q$, 0);
-- rls.sql's judgement, unchanged by any of this: the board is compliance, not
-- football. An invitation cannot hand out what the role does not carry.
select t.rows('the board seat still carries NO plays',   $q$select 1 from public.plays$q$, 0);
select t.rows('it carries the league''s rosters',        $q$select 1 from public.players$q$, 26);
select t.raises('and a board seat cannot mint another one',
  $q$select * from app.issue_invite('another@example.com','board',null,'a0000000-0000-4000-8000-000000000001')$q$, '42501');
select t.blocked('nor can he write himself up to admin',
  $q$update public.league_memberships set role='admin'
      where user_id='d0000000-0000-4000-8000-00000000000d'$q$);
select t.val('he is still board, and the log would have caught it if he were not',
  $q$select role from public.league_memberships where user_id='d0000000-0000-4000-8000-00000000000d'$q$, 'board');
reset role;
select t.control('there really are 4 plays in that league to withhold',
  $q$select 1 from public.plays p join public.teams t on t.id=p.team_id
     where t.league_id='a0000000-0000-4000-8000-000000000001'$q$, 4);

-- ===========================================================================
-- 8. Revocation bites on the very next statement
--    One session. Read as the coach, revoke, read again, get nothing.
-- ===========================================================================
select set_config('t.sect', '8 revocation', false);
set role pd_authenticated;

select t.be('d0000000-0000-4000-8000-00000000000b', 'newcoach@example.com');
select t.val('the invited coach reads his team''s playbook',
  $q$select count(*)::text from public.plays where team_id='c0000000-0000-4000-8000-000000000001'$q$, '2');
select t.val('and its roster',
  $q$select count(*)::text from public.players where team_id='c0000000-0000-4000-8000-000000000001'$q$, '21');

-- The head takes the seat back. Same session, next statement.
select t.be('d0000000-0000-4000-8000-000000000002', 'steve@example.com');
select t.allowed('the head removes the membership',
  $q$delete from public.memberships
      where user_id='d0000000-0000-4000-8000-00000000000b' and team_id='c0000000-0000-4000-8000-000000000001'$q$, 1);

select t.be('d0000000-0000-4000-8000-00000000000b', 'newcoach@example.com');
select t.val('THE VERY NEXT STATEMENT: no plays',
  $q$select count(*)::text from public.plays where team_id='c0000000-0000-4000-8000-000000000001'$q$, '0');
select t.val('no roster',
  $q$select count(*)::text from public.players where team_id='c0000000-0000-4000-8000-000000000001'$q$, '0');
select t.val('no team',
  $q$select count(*)::text from public.teams where id='c0000000-0000-4000-8000-000000000001'$q$, '0');
select t.rows('and the membership row itself is gone from under him',
  $q$select 1 from public.memberships where user_id='d0000000-0000-4000-8000-00000000000b'
      and team_id='c0000000-0000-4000-8000-000000000001'$q$, 0);
-- No cached tier, no stale cookie: there is nothing to replay. Inventing the
-- GUCs a cookie-based gate would have carried does not put him back.
select set_config('app.tier', 'assistant', false);
select set_config('app.role', 'assistant', false);
select set_config('app.team_id', 'c0000000-0000-4000-8000-000000000001', false);
select t.val('replaying a tier does not put him back',
  $q$select count(*)::text from public.plays where team_id='c0000000-0000-4000-8000-000000000001'$q$, '0');
select set_config('app.tier', '', false); select set_config('app.role', '', false); select set_config('app.team_id', '', false);
-- And the invitation he came in on is spent, so the link in his mailbox is not
-- a way back in either.
select t.raises('and his old invitation link cannot let him back in',
  $q$select app.accept_invite('seed-live-lehi8-assistant')$q$, '22023');
select t.val('his OTHER team is untouched -- revocation is per team, not per person',
  $q$select count(*)::text from public.plays where team_id='c0000000-0000-4000-8000-000000000004'$q$, '1');
reset role;

select t.control('the playbook he could read a moment ago is still there',
  $q$select 1 from public.plays where team_id='c0000000-0000-4000-8000-000000000001'$q$, 2);
select t.val('and the revocation is in the log, with who did it',
  $q$select actor::text from public.auth_events
      where action='membership_revoke' and subject_user='d0000000-0000-4000-8000-00000000000b'$q$,
  'd0000000-0000-4000-8000-000000000002');

-- ===========================================================================
-- 9. The player word: one team, read only, rotatable
-- ===========================================================================
select set_config('t.sect', '9 player word', false);
set role pd_anon;
select t.be(null, null);
select t.noword();
select t.rows('anonymous, no word: no plays',   $q$select 1 from public.plays$q$, 0);
select t.rows('anonymous, no word: no roster',  $q$select 1 from public.players$q$, 0);

select t.word('c0000000-0000-4000-8000-000000000001', 'kicker-forty-one');
select t.val('the word resolves to exactly one team',
  $q$select app.player_team_id()::text$q$, 'c0000000-0000-4000-8000-000000000001');
select t.val('a boy reads his team''s plays',
  $q$select count(*)::text from public.plays$q$, '2');
select t.val('and his team''s roster',
  $q$select count(*)::text from public.players$q$, '21');
select t.val('with the names on it, which is the point of the page',
  $q$select last from public.players where jersey='22'$q$, 'Martinez');

-- ...and NOTHING else. Every one of these has rows behind it (see the controls).
select t.rows('the word does not read the team row',   $q$select 1 from public.teams$q$, 0);
select t.rows('nor the league',                        $q$select 1 from public.leagues$q$, 0);
select t.rows('nor the season',                        $q$select 1 from public.seasons$q$, 0);
select t.rows('nor who coaches the team',              $q$select 1 from public.memberships$q$, 0);
select t.rows('nor the league board',                  $q$select 1 from public.league_memberships$q$, 0);
select t.rows('NOR THE CONSENTS',                      $q$select 1 from public.player_consents$q$, 0);
select t.rows('NOR THE TOMBSTONES',                    $q$select 1 from public.player_tombstones$q$, 0);
select t.rows('nor the invitations',                   $q$select 1 from public.invites$q$, 0);
select t.rows('nor the audit log',                     $q$select 1 from public.auth_events$q$, 0);
select t.rows('nor the word itself, or any other team''s', $q$select 1 from public.player_words$q$, 0);

-- Cross-team. Both directions, by literal id.
select t.rows('his word does not read the other league''s plays',
  $q$select 1 from public.plays where team_id='c0000000-0000-4000-8000-000000000004'$q$, 0);
select t.rows('nor its roster',
  $q$select 1 from public.players where team_id='c0000000-0000-4000-8000-000000000004'$q$, 0);
select t.rows('nor a sibling team in his own league',
  $q$select 1 from public.plays where team_id='c0000000-0000-4000-8000-000000000002'$q$, 0);
select t.word('c0000000-0000-4000-8000-000000000004', 'kicker-forty-one');
select t.val('pointing his own word at another team resolves to nothing',
  $q$select coalesce(app.player_team_id()::text,'NULL')$q$, 'NULL');
select t.rows('and reads nothing',              $q$select 1 from public.plays$q$, 0);
select t.word('c0000000-0000-4000-8000-000000000001', 'bear-river-nine');
select t.val('and the other team''s word against this team resolves to nothing',
  $q$select coalesce(app.player_team_id()::text,'NULL')$q$, 'NULL');
select t.rows('and reads nothing either',       $q$select 1 from public.plays$q$, 0);
-- Not vacuous: that word does work, for the team it belongs to.
select t.word('c0000000-0000-4000-8000-000000000004', 'bear-river-nine');
select t.val('the Logan word reads Logan, so the pairing is what matters',
  $q$select count(*)::text from public.plays$q$, '1');
select t.val('and Logan''s roster, and no more',
  $q$select count(*)::text from public.players$q$, '3');

-- Wrong words.
select t.word('c0000000-0000-4000-8000-000000000001', 'kicker-forty-two');
select t.rows('one character out is not the word', $q$select 1 from public.plays$q$, 0);
select t.word('c0000000-0000-4000-8000-000000000001', 'KICKER-FORTY-ONE');
select t.rows('and the word is case sensitive',    $q$select 1 from public.plays$q$, 0);
select t.word('c0000000-0000-4000-8000-000000000001', '  kicker-forty-one  ');
select t.val('but stray spaces round it are forgiven, because a boy typed it',
  $q$select count(*)::text from public.plays$q$, '2');
select t.word('c0000000-0000-4000-8000-000000000001', '');
select t.rows('an empty word is not a word',       $q$select 1 from public.plays$q$, 0);
select set_config('app.player_team', 'not-a-uuid', false);
select set_config('app.player_word', 'kicker-forty-one', false);
select t.rows('a malformed team id fails closed',  $q$select 1 from public.plays$q$, 0);

-- Expired.
select t.word('c0000000-0000-4000-8000-000000000002', 'old-word-seven');
select t.val('last season''s word is expired and resolves to nothing',
  $q$select coalesce(app.player_team_id()::text,'NULL')$q$, 'NULL');
select t.rows('and reads none of that team''s roster', $q$select 1 from public.players$q$, 0);

-- Read only. pd_anon holds no write verb at all, which is the same promise
-- learn.html makes on the field client: a link that cannot edit anything.
select t.word('c0000000-0000-4000-8000-000000000001', 'kicker-forty-one');
select t.raises('a word cannot insert a play',
  $q$insert into public.plays (team_id, slug, doc)
     values ('c0000000-0000-4000-8000-000000000001','boys-play','{"players":[{"id":"p0"}]}')$q$, '42501');
select t.raises('cannot edit one',
  $q$update public.plays set doc = doc || '{"boys":true}' where team_id='c0000000-0000-4000-8000-000000000001'$q$, '42501');
select t.raises('cannot delete one, even holding Delete play intent',
  $q$delete from public.plays where team_id='c0000000-0000-4000-8000-000000000001'$q$, '42501');
select t.raises('cannot add himself to the roster',
  $q$insert into public.players (team_id, last, jersey) values ('c0000000-0000-4000-8000-000000000001','Ghost','00')$q$, '42501');
select t.raises('cannot write himself a membership',
  $q$insert into public.memberships (user_id, team_id, role)
     values ('d0000000-0000-4000-8000-00000000000a','c0000000-0000-4000-8000-000000000001','head')$q$, '42501');
select t.raises('and cannot rotate the word he holds',
  $q$select app.rotate_player_word('c0000000-0000-4000-8000-000000000001')$q$, '42501');
reset role;

-- A signed-in stranger who has been handed the word gets the same read and the
-- same nothing: the word is not a coaching seat.
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-00000000000a', 'stranger@example.com');
select t.word('c0000000-0000-4000-8000-000000000001', 'kicker-forty-one');
select t.val('a signed-in stranger with the word reads the plays',
  $q$select count(*)::text from public.plays$q$, '2');
select t.raises('but WITH CHECK still refuses him a play of his own',
  $q$insert into public.plays (team_id, slug, doc)
     values ('c0000000-0000-4000-8000-000000000001','stranger-play','{"players":[{"id":"p0"}]}')$q$, '42501');
select t.blocked('and USING refuses him an edit',
  $q$update public.plays set doc = doc || '{"stranger":true}' where team_id='c0000000-0000-4000-8000-000000000001'$q$);
select set_config('app.intent', 'delete_play', true);
select t.blocked('and a delete, intent or no intent',
  $q$delete from public.plays where team_id='c0000000-0000-4000-8000-000000000001'$q$);
select set_config('app.intent', '', true);
select t.rows('the word gave him no consents',  $q$select 1 from public.player_consents$q$, 0);
select t.noword();
reset role;
select t.val('nothing of the team''s was changed by any of that',
  $q$select count(*)::text from public.plays where doc ? 'boys' or doc ? 'stranger'$q$, '0');

-- Rotation. One session: read, rotate, the old word is dead on the next statement.
select set_config('t.sect', '9b rotation', false);
set role pd_anon;
select t.word('c0000000-0000-4000-8000-000000000001', 'kicker-forty-one');
select t.val('before rotating: the word reads 2 plays',
  $q$select count(*)::text from public.plays$q$, '2');
reset role;

set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000001', 'dom@example.com');   -- the assistant runs the boys' page
select t.snap('word_new', $q$select app.rotate_player_word('c0000000-0000-4000-8000-000000000001')$q$);
reset role;

set role pd_anon;
select t.be(null, null);
select t.word('c0000000-0000-4000-8000-000000000001', 'kicker-forty-one');
select t.val('THE VERY NEXT STATEMENT: the old word is dead',
  $q$select count(*)::text from public.plays$q$, '0');
select set_config('app.player_word', (select v from t.state where k='word_new'), false);
select t.val('and the new one works',
  $q$select count(*)::text from public.plays$q$, '2');
select t.val('the new word is a word a coach can say out loud',
  $q$select case when (select v from t.state where k='word_new') ~ '^[a-z]+-[0-9]{3}$'
                 then 'ok' else (select v from t.state where k='word_new') end$q$, 'ok');
-- Rotating one team's word touches nothing else. It is a single row keyed by
-- the team; there is nowhere for it to reach.
select t.word('c0000000-0000-4000-8000-000000000004', 'bear-river-nine');
select t.val('the other team''s word is untouched by the rotation',
  $q$select count(*)::text from public.plays$q$, '1');
select t.noword();
reset role;

select t.val('rotation is logged, and the new word is NOT in the log',
  $q$select count(*)::text from public.auth_events e
      where e.action='player_word_rotate'
        and e::text like '%' || (select v from t.state where k='word_new') || '%'$q$, '0');
select t.rows('the rotation itself is logged, with who turned it over',
  $q$select 1 from public.auth_events
     where action='player_word_rotate' and actor='d0000000-0000-4000-8000-000000000001'
       and not (detail ? 'seeded')$q$, 1);

-- Who may rotate.
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000003', 'parent@example.com');
select t.raises('a helper cannot rotate the word',
  $q$select app.rotate_player_word('c0000000-0000-4000-8000-000000000001')$q$, '42501');
select t.be('d0000000-0000-4000-8000-000000000005', 'reeves@example.com');
select t.raises('nor can the league board',
  $q$select app.rotate_player_word('c0000000-0000-4000-8000-000000000001')$q$, '42501');
select t.be('d0000000-0000-4000-8000-000000000007', 'ostler@example.com');
select t.raises('nor another league''s head coach',
  $q$select app.rotate_player_word('c0000000-0000-4000-8000-000000000001')$q$, '42501');
select t.be('d0000000-0000-4000-8000-00000000000a', 'stranger@example.com');
select t.raises('nor a stranger',
  $q$select app.rotate_player_word('c0000000-0000-4000-8000-000000000001')$q$, '42501');
select t.be('d0000000-0000-4000-8000-000000000002', 'steve@example.com');
select t.val('the head can, of course',
  $q$select case when app.rotate_player_word('c0000000-0000-4000-8000-000000000001') is not null then 'ok' end$q$, 'ok');
select t.raises('a word a boy could guess in one go is refused',
  $q$select app.rotate_player_word('c0000000-0000-4000-8000-000000000001','go')$q$, '22023');
reset role;

-- Who may READ the words. Not the boys, not the helper, not the board.
select set_config('t.sect', '9c word visibility', false);
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000001', 'dom@example.com');
select t.rows('a coach sees the word row for the team he coaches, and no other',
  $q$select 1 from public.player_words$q$, 1);
select t.rows('and it is his team''s',
  $q$select 1 from public.player_words where team_id='c0000000-0000-4000-8000-000000000001'$q$, 1);
select t.be('d0000000-0000-4000-8000-000000000004', 'kaye@example.com');
select t.rows('Lehi 7''s head sees his own team''s (expired) word', $q$select 1 from public.player_words$q$, 1);
select t.be('d0000000-0000-4000-8000-000000000003', 'parent@example.com');
select t.rows('a helper sees no word rows',                        $q$select 1 from public.player_words$q$, 0);
select t.be('d0000000-0000-4000-8000-000000000005', 'reeves@example.com');
select t.rows('the board sees no word rows either',                $q$select 1 from public.player_words$q$, 0);
select t.be('d0000000-0000-4000-8000-000000000006', 'whitmore@example.com');
select t.rows('the league admin sees his league''s',               $q$select 1 from public.player_words$q$, 2);
select t.rows('and none of the other league''s',
  $q$select 1 from public.player_words where team_id='c0000000-0000-4000-8000-000000000004'$q$, 0);
select t.be('d0000000-0000-4000-8000-000000000002', 'steve@example.com');
select t.raises('and nobody may write a word row by hand',
  $q$update public.player_words set word_hash=repeat('c',64)
      where team_id='c0000000-0000-4000-8000-000000000002'$q$, '42501');
reset role;
select t.control('there really is a Logan word to hide', $q$select 1 from public.player_words where team_id='c0000000-0000-4000-8000-000000000004'$q$, 1);

-- Clearing it: the boys' page goes dark for that team and for nobody else.
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000002', 'steve@example.com');
select t.val('the head clears the word entirely',
  $q$select app.clear_player_word('c0000000-0000-4000-8000-000000000001')::text$q$, 'true');
reset role;
set role pd_anon;
-- t.be(null) as well as the role: pd_anon carrying a coach's uid is still that
-- coach, because rls.sql's policies name both roles. The boys' page is anonymous
-- in both senses.
select t.be(null, null);
select t.word('c0000000-0000-4000-8000-000000000001', 'kicker-forty-one');
select t.rows('with no word set for the team, no word opens it',
  $q$select 1 from public.plays$q$, 0);
select t.word('c0000000-0000-4000-8000-000000000004', 'bear-river-nine');
select t.rows('and the other team''s boys are unaffected',
  $q$select 1 from public.plays$q$, 1);
select t.noword();
reset role;
select t.val('clearing it is logged too',
  $q$select count(*)::text from public.auth_events where action='player_word_clear'$q$, '1');

-- ===========================================================================
-- 10. The audit trail: complete, scoped, and insert-only
-- ===========================================================================
select set_config('t.sect', '10 audit', false);
\echo '=== 10. What the log has recorded during this suite ==='
select action, count(*) from public.auth_events group by action order by action;

select t.control('the log recorded this suite''s grants',
  $q$select 1 from public.auth_events where action='membership_grant'
      and subject_user='d0000000-0000-4000-8000-00000000000b'$q$, 1);
select t.control('and its revocation',
  $q$select 1 from public.auth_events where action='membership_revoke'$q$, 1);
select t.control('and its invitations',
  $q$select 1 from public.auth_events where action='invite_issue'$q$, 6);
select t.control('and its acceptances',
  $q$select 1 from public.auth_events where action='invite_accept'$q$, 4);
select t.control('and its rotations',
  $q$select 1 from public.auth_events where action='player_word_rotate'$q$, 4);
select t.val('an acceptance records the account, the address and the invitation',
  $q$select (subject_user is not null and subject_email is not null and detail ? 'invite')::text
      from public.auth_events where action='invite_accept'
       and subject_user='d0000000-0000-4000-8000-00000000000b' and team_id='c0000000-0000-4000-8000-000000000004'$q$, 'true');
select t.val('a grant and its revocation are two rows, not one edited row',
  $q$select count(*)::text from public.auth_events
      where subject_user='d0000000-0000-4000-8000-00000000000b'
        and team_id='c0000000-0000-4000-8000-000000000001'
        and action in ('membership_grant','membership_revoke')$q$, '2');
select t.val('no credential of any kind is in the log',
  $q$select count(*)::text from public.auth_events e
      where e::text like '%' || t.tok('tok_live') || '%'
         or e::text like '%kicker-forty-one%'
         or e::text like '%seed-live-lehi8-assistant%'$q$, '0');

-- Insert-only, tested against the people who would most like to edit it.
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000002', 'steve@example.com');
select t.raises('a head cannot DELETE a line of the log',
  $q$delete from public.auth_events where action='membership_revoke'$q$, '42501');
select t.raises('cannot UPDATE one',
  $q$update public.auth_events set actor='d0000000-0000-4000-8000-00000000000a' where action='membership_revoke'$q$, '42501');
select t.raises('cannot INSERT a flattering one',
  $q$insert into public.auth_events (actor, action, team_id, detail)
     values ('d0000000-0000-4000-8000-000000000002','membership_grant','c0000000-0000-4000-8000-000000000001','{}')$q$, '42501');
select t.raises('cannot frame somebody else with one',
  $q$insert into public.auth_events (actor, action, team_id, subject_user, detail)
     values ('d0000000-0000-4000-8000-000000000001','membership_revoke','c0000000-0000-4000-8000-000000000001',
             'd0000000-0000-4000-8000-000000000003','{}')$q$, '42501');
select t.be('d0000000-0000-4000-8000-000000000006', 'whitmore@example.com');
select t.raises('nor can the league admin, who can do nearly everything else',
  $q$delete from public.auth_events$q$, '42501');
reset role;

-- And the owner cannot either, which is the half a privilege cannot cover: the
-- trigger binds whoever the statement arrives as.
select t.raises('NOT EVEN THE OWNER can rewrite a line',
  $q$update public.auth_events set detail='{"tidied":true}' where id=(select min(id) from public.auth_events)$q$, '42501');
select t.raises('nor delete one',
  $q$delete from public.auth_events where id=(select min(id) from public.auth_events)$q$, '42501');
select t.raises('nor truncate the table',
  $q$truncate table public.auth_events$q$, '42501');
select t.val('and no foreign key can take a log row with it',
  $q$select count(*)::text from pg_constraint
      where contype='f' and conrelid='public.auth_events'::regclass$q$, '0');

-- Who may read it.
select t.snap('audit_lehi8', $q$select count(*)::text from public.auth_events where team_id='c0000000-0000-4000-8000-000000000001'$q$);
select t.control('there is a team history to read',
  $q$select 1 from public.auth_events where team_id='c0000000-0000-4000-8000-000000000001'$q$, 5);
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000002', 'steve@example.com');
select t.unchanged('the head reads his own team''s history in full', 'audit_lehi8',
  $q$select count(*)::text from public.auth_events where team_id='c0000000-0000-4000-8000-000000000001'$q$);
select t.rows('the head reads no other team''s history',
  $q$select 1 from public.auth_events where team_id='c0000000-0000-4000-8000-000000000004'$q$, 0);
select t.be('d0000000-0000-4000-8000-000000000001', 'dom@example.com');
select t.val('an assistant reads only the lines about himself',
  $q$select count(*)::text from public.auth_events
      where subject_user is distinct from 'd0000000-0000-4000-8000-000000000001'
        and actor is distinct from 'd0000000-0000-4000-8000-000000000001'$q$, '0');
select t.rows('and he can see that he was given his own seat',
  $q$select 1 from public.auth_events where action='membership_grant'
      and subject_user='d0000000-0000-4000-8000-000000000001'$q$, 2);
select t.be('d0000000-0000-4000-8000-000000000005', 'reeves@example.com');
select t.unchanged('the board reads its own league''s team history', 'audit_lehi8',
  $q$select count(*)::text from public.auth_events where team_id='c0000000-0000-4000-8000-000000000001'$q$);
select t.rows('and none of the other league''s',
  $q$select 1 from public.auth_events where team_id='c0000000-0000-4000-8000-000000000004'$q$, 0);
select t.be('d0000000-0000-4000-8000-000000000009', 'barlow@example.com');
select t.rows('the other board reads none of ours',
  $q$select 1 from public.auth_events where team_id='c0000000-0000-4000-8000-000000000001'$q$, 0);
select t.be('d0000000-0000-4000-8000-00000000000a', 'stranger@example.com');
select t.rows('a stranger reads no log at all', $q$select 1 from public.auth_events$q$, 0);
reset role;
select t.control('there is a Logan history being withheld',
  $q$select 1 from public.auth_events where team_id='c0000000-0000-4000-8000-000000000004'$q$, 2);

-- ===========================================================================
-- 11. Vacuity check. Add a permissive policy and watch the identical query
--     leak, so nobody has to take the zeroes above on faith.
-- ===========================================================================
select set_config('t.sect', '11 vacuity check', false);
create policy tmp_leak_plays   on public.plays   for select to pd_anon using (true);
create policy tmp_leak_players on public.players for select to pd_anon using (true);
set role pd_anon;
select t.be(null, null);
select t.noword();
\echo '=== 11. With one permissive policy added, an anonymous session with NO word reads everything ==='
select count(*) as plays_visible_with_bad_policy, count(*) filter (where team_id='c0000000-0000-4000-8000-000000000004') as other_league
  from public.plays;
select t.val('with USING(true): no word, all 6 plays', $q$select count(*)::text from public.plays$q$, '6');
select t.val('with USING(true): no word, all 31 players', $q$select count(*)::text from public.players$q$, '31');
reset role;
drop policy tmp_leak_plays   on public.plays;
drop policy tmp_leak_players on public.players;
set role pd_anon;
select t.val('policy removed: back to nothing', $q$select count(*)::text from public.plays$q$, '0');
reset role;

-- Same for the log: the scoped reads above are the policy, not an empty table.
create policy tmp_leak_audit on public.auth_events for select to pd_authenticated using (true);
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-00000000000a', 'stranger@example.com');
select t.val('with USING(true): a stranger reads the whole audit trail',
  $q$select case when count(*) > 20 then 'many' else count(*)::text end from public.auth_events$q$, 'many');
reset role;
drop policy tmp_leak_audit on public.auth_events;
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-00000000000a', 'stranger@example.com');
select t.val('policy removed: back to none', $q$select count(*)::text from public.auth_events$q$, '0');
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
    raise exception '% AUTH TEST(S) FAILED', bad;
  end if;
  raise notice 'all % auth tests passed', (select count(*) from t.results);
end $$;

rollback;

-- ===========================================================================
-- MUTATION LOG -- what happens when a guard in auth.sql is deliberately broken.
--
-- A suite that stays green when the guard is removed is decoration. Each line
-- below was applied to a database built from schema.sql + rls.sql + auth.sql +
-- seed.sql + auth-seed.sql, this suite was run, and the guard was put back.
-- The 183 tests in test-isolation.sql were run against every mutant too, and no
-- mutation of this file moved any of them -- which is the other half of the
-- claim: auth.sql is additive and does not reach into what was already proved.
--
--   mutation                                                     tests failed
--   ------------------------------------------------------------ ------------
--   baseline (nothing broken)                                               0
--   invites: store the token in plaintext                                  31
--   accept_invite: drop the email-claim check                              15
--   plays_select_player_word -> any valid word reads every team            10
--   invites_select -> using (true)                                          9
--   accept_invite: drop the single-use guard                                8
--   player_words_select -> using (true)                                     8
--   drop the auth_events append-only triggers                               7
--   auth_events_select -> using (true)                                      7
--   accept_invite: ON CONFLICT DO UPDATE SET role (escalation)              5
--   issue_invite: let an assistant mint too                                 5
--   player_team_id: match the word without naming the team                  4
--   grant insert/update/delete on auth_events to pd_authenticated           4
--   drop the memberships audit trigger                                      4
--   accept_invite: drop the expiry check                                    3
--   issue_invite: let a league board member mint seats                      3
--   plays_select_team also trusts a client-supplied team GUC                3
--   player word also reaches player_consents                                2
--   player_team_id: ignore the word's expiry                                2
--   issue_invite: stop superseding the outstanding token                    2
--   rotate_player_word: any member of the team may rotate                   1
--   hash_secret truncated to 16 bits of digest                              1  *
--   grant INSERT on public.plays to pd_anon                                 0  **
--
--   *  This one failed NOTHING until the suite was fixed. Every check on the
--      hashing compared a stored value against app.hash_secret(), so weakening
--      that function weakened both sides of the comparison and the suite stayed
--      green. Section 3 now carries a known-answer test against the published
--      SHA-256 vector for 'abc', which catches both truncation and a swap to
--      md5. Recorded because it is the most useful thing the mutation run
--      produced: the hole was in the tests, not in auth.sql.
--
--   ** Not a mutation, and worth keeping in the log rather than dropping.
--      Granting pd_anon the INSERT privilege on plays changes nothing because
--      the write is refused twice: by the missing grant AND by
--      plays_insert_coach's WITH CHECK, which a player-word session cannot
--      satisfy (it has no coaching membership). Measured, not assumed --
--      with the grant in place the insert fails with 'new row violates
--      row-level security policy for table "plays"'. Section 9 tests the
--      policy half separately, as a signed-in stranger holding the word.
--
--   Two mutations of note in what they did NOT break:
--     * dropping the append-only triggers turns four CONTROLs red, not just the
--       three owner-immutability tests -- because with the log deletable, the
--       suite's own earlier statements leave a different history behind.
--     * 'grant write on auth_events' leaves 'cannot frame somebody else with
--        one' passing: the INSERT policy pins actor to auth.uid(), so even with
--        the privilege a coach can only write entries about himself.
-- ===========================================================================
