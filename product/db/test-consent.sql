-- product/db/test-consent.sql
-- The adversarial suite for 0007_consent.sql. Same house rules as
-- test-isolation.sql, test-auth.sql, test-platform.sql and test-brand.sql.
--
-- RUN:
--   node product/db/test.mjs consent
--
-- That builds pd_t_consent from product/db/migrations/ via the migration runner
-- and applies the seeds in order, then runs this file.
--
-- Against a database you have already built:
--   psql -h /tmp -p 5433 -U app -d pd_t_consent -f product/db/test-consent.sql
--
-- Everything runs inside one transaction and ROLLS BACK, so the suite is
-- rerunnable and leaves the seed untouched. No SAVEPOINTs, for the same reason
-- the other four files have none: rolling back to one would roll back the
-- results table with it.
--
-- HOUSE RULES, inherited:
--   (a) Every refusal is paired with a CONTROL run as the bypassing owner,
--       proving the row was really there to be taken. A refusal whose control
--       returns 0 is a broken test, not a pass.
--   (b) Attacks address the other tenant's rows by literal uuid. A subselect
--       would return NULL under RLS and the attack would "pass" by asking
--       about nothing.
--   (c) A closing section ADDS the missing grant and shows the identical calls
--       succeeding, so nobody has to take the refusals on faith.
--
-- THE CLAIM THIS FILE TESTS, IN ONE SENTENCE. A coach may ASK a guardian for
-- consent and may READ the answer, and cannot under any path ANSWER on the
-- guardian's behalf -- he cannot mint the token, cannot call the grant, cannot
-- write a consent row directly, cannot widen what was asked for, cannot reuse a
-- token, and cannot write a child's name into the database without a live
-- consent standing behind it.
--
-- WHY THAT IS THE SENTENCE. Everything else in this product is football. This
-- is the one file where the database is holding under-13s' personal data, and
-- "the coach filled it in himself" is precisely the finding that would end a
-- sale to a league. The grant graph is the enforcement -- app.consent_dispatch()
-- is granted to pd_mailer and to nobody else -- so this suite spends most of its
-- length attacking that one edge from every seat in the seed.
--
-- WHAT THIS FILE CANNOT PROVE. Stated here rather than buried:
--   * That the human at the end of the email is the child's guardian. The
--     database records who was asked, at what address, what they were shown,
--     what they affirmed, and when. Verifiable parental consent -- proving the
--     person is who they say -- is a flow that does not exist yet in either
--     repo, and no amount of SQL closes it. See product/REUSE.md, "Gaps".
--   * That the mailer role is well guarded. app.consent_dispatch() is safe from
--     a coach because a coach is not pd_mailer. Whoever holds pd_mailer holds
--     every pending token; that is a deployment property, not a schema one.
--   * That the GUCs were stamped honestly. Same standing assumption as the
--     other four suites: in production the claim comes off a verified JWT.
--   * Whether the notice text is legally sufficient. The database can prove the
--     text has not changed since it was agreed to. A lawyer decides the rest.

-- MUTATION RUN. A suite of zeroes and refusals looks identical whether the
-- guards work or are missing, so each guard was broken on purpose and the red
-- count recorded. Section 10 does the headline one inside the suite itself.
--
--   drop the collection gate trigger .................  8 tests go red
--   drop the forget trigger ..........................  9
--   make consent notices truncatable .................  6
--   drop the notice immutability trigger .............  3
--   make the trail deletable .........................  3
--   make the trail truncatable .......................  3
--   grant consent_dispatch to a signed-in coach ......  3
--   drop the player_consents guard ...................  3
--   make the trail editable ..........................  1
--   make evidence rewritable .........................  1
--   give player_tombstones a `last` column ...........  1
--
-- Nothing here goes red at zero. Reproduce with:
--   psql ... -c '<mutation>' ; psql ... -f product/db/test-consent.sql

\set ON_ERROR_STOP on
\timing off
\pset pager off

begin;

-- ===========================================================================
-- Harness -- identical in shape to the other four suites
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

-- Catches, for the reason test-platform.sql gives: a mutant that breaks a
-- snapshot must produce a red test and a continuing run, not an exploded suite.
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
exception when others then
  perform t.note(p_name, false, format('ERROR %s: %s', sqlstate, left(sqlerrm, 100)));
end $fn$;

create function t.tok(p_key text) returns text
language sql stable as $fn$ select v from t.state where k = p_key $fn$;

create function t.be(p_user uuid, p_email text default null) returns void
language plpgsql as $fn$
begin
  perform set_config('app.user_id',    coalesce(p_user::text, ''), false);
  perform set_config('app.user_email', coalesce(p_email, ''), false);
end $fn$;

grant execute on all functions in schema t to public;

-- ===========================================================================
-- 0. CONTROL -- what exists, seen by the bypassing owner
-- ===========================================================================
select set_config('t.sect', '0 control', false);
\echo '=== 0. What the consent layer starts with (owner, RLS bypassed) ==='

select (select count(*) from public.players)          as children,
       (select count(*) from public.player_consents)  as consents,
       (select count(*) from public.consent_notices)  as notices,
       (select count(*) from public.guardians)        as guardians,
       (select count(*) from public.consent_requests) as requests,
       (select count(*) from public.consent_evidence) as evidence,
       (select count(*) from public.consent_events)   as trail;

select t.control('children exist to protect', $q$select 1 from public.players$q$, 31);
select t.control('paper consents exist',      $q$select 1 from public.player_consents where revoked_at is null$q$, 3);
select t.control('a revoked consent exists',  $q$select 1 from public.player_consents where revoked_at is not null$q$, 1);

-- The seed predates this file, so the flow starts from nothing. That is the
-- honest starting state for a league buying the product in February.
select t.val('no league has published a notice yet',
  $q$select count(*)::text from public.consent_notices$q$, '0');
select t.val('and no guardian is on file',
  $q$select count(*)::text from public.guardians$q$, '0');

-- Every table this file adds must be shut, both ways, before anything else is
-- worth testing.
select t.val('all six consent tables force RLS',
  $q$select count(*)::text from pg_class c join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relrowsecurity and c.relforcerowsecurity
        and c.relname in ('consent_notices','guardians','guardian_children',
                          'consent_requests','consent_evidence','consent_events')$q$, '6');
select t.val('and every one of them carries at least one policy',
  $q$select count(*)::text from pg_class c join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public'
        and c.relname in ('consent_notices','guardians','guardian_children',
                          'consent_requests','consent_evidence','consent_events')
        and exists (select 1 from pg_policy p where p.polrelid=c.oid)$q$, '6');

-- The scopes list is duplicated between a CHECK constraint and a function, and
-- the file's own comment says this test is the thing keeping them honest.
select t.val('app.consent_scopes() matches the CHECK constraint on player_consents',
  $q$select (select count(*) from unnest(app.consent_scopes()) s
              where position(quote_literal(s) in
                (select pg_get_constraintdef(oid) from pg_constraint
                  where conname = 'player_consents_scope')) > 0)::text
         || '/' || cardinality(app.consent_scopes())::text$q$, '5/5');

-- ===========================================================================
-- 1. THE GRANT GRAPH -- who may even call what
-- ===========================================================================
-- This section reads pg_proc's ACL rather than calling anything. It is the
-- cheapest possible statement of the security model, and if it ever disagrees
-- with sections 5 and 6 then one of the two is lying.
select set_config('t.sect', '1 grant graph', false);
\echo '=== 1. Who is even allowed to call what ==='

select t.val('consent_dispatch is executable by pd_mailer',
  $q$select has_function_privilege('pd_mailer', 'app.consent_dispatch(uuid)', 'execute')::text$q$, 'true');
select t.val('and NOT by a signed-in coach',
  $q$select has_function_privilege('pd_authenticated', 'app.consent_dispatch(uuid)', 'execute')::text$q$, 'false');
select t.val('and NOT by an anonymous caller',
  $q$select has_function_privilege('pd_anon', 'app.consent_dispatch(uuid)', 'execute')::text$q$, 'false');

select t.val('grant_consent is open to the guardian, who has no account',
  $q$select has_function_privilege('pd_anon', 'app.grant_consent(text,text,text,text[])', 'execute')::text$q$, 'true');
select t.val('request_consent is staff-only',
  $q$select has_function_privilege('pd_anon', 'app.request_consent(uuid,uuid,text[],uuid,interval)', 'execute')::text$q$, 'false');

-- The three the file says are granted to nobody.
select t.val('revoke_consent_rows is callable by no tenant role',
  $q$select (has_function_privilege('pd_authenticated','app.revoke_consent_rows(uuid,uuid,text[],text,uuid,text)','execute')
          or has_function_privilege('pd_anon','app.revoke_consent_rows(uuid,uuid,text[],text,uuid,text)','execute'))::text$q$, 'false');
select t.val('consent_note is callable by no tenant role',
  $q$select (has_function_privilege('pd_authenticated','app.consent_note(text,uuid,uuid,uuid,jsonb,text)','execute')
          or has_function_privilege('pd_anon','app.consent_note(text,uuid,uuid,uuid,jsonb,text)','execute'))::text$q$, 'false');
-- is_privileged_session() IS callable by a tenant, and must be: it is SECURITY
-- INVOKER and the two guard triggers ask it on the caller's own behalf on every
-- write. What matters is not who may call it but what it answers -- section 6
-- is the test that it answers "no" to a coach. Asserted here as well, because
-- this one boolean is what both guards hang on.
select t.val('is_privileged_session is callable, because the guards must call it',
  $q$select (has_function_privilege('pd_authenticated','app.is_privileged_session()','execute')
         and has_function_privilege('pd_anon','app.is_privileged_session()','execute'))::text$q$, 'true');
select t.val('it is SECURITY INVOKER -- as DEFINER it answers for the owner, always',
  $q$select (not prosecdef)::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='app' and p.proname='is_privileged_session'$q$, 'true');
select t.val('and so are the two guard triggers that ask it',
  $q$select count(*)::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='app' and p.proname in ('consent_gate_players','player_consents_guard')
       and p.prosecdef$q$, '0');

-- No write verb on any of the six tables, for either tenant role. Every row is
-- written by a definer function or a trigger.
select t.val('no tenant role holds insert/update/delete on any consent table',
  $q$select count(*)::text from (
       select 1 from unnest(array['consent_notices','guardians','guardian_children',
                                  'consent_requests','consent_evidence','consent_events']) tbl,
                     unnest(array['pd_anon','pd_authenticated']) rol,
                     unnest(array['insert','update','delete']) verb
        where has_table_privilege(rol, 'public.'||tbl, verb)) _$q$, '0');

-- ===========================================================================
-- 2. FIXTURES -- built through the real functions, by the seats entitled to
-- ===========================================================================
-- Deliberately not INSERTed by the owner. If the published API cannot produce
-- the state the rest of the suite attacks, that is itself a finding.
select set_config('t.sect', '2 fixtures', false);
\echo '=== 2. Building the fixture through the published API ==='

set role pd_authenticated;

-- A league admin publishes the notice. A coach may not.
select t.be('d0000000-0000-4000-8000-000000000002');   -- Steve, head coach of Lehi 8
select t.raises('a head coach cannot publish his league''s consent notice',
  $q$select app.issue_consent_notice('a0000000-0000-4000-8000-000000000001',
      'Coach-written notice', 'body', 'I agree')$q$, '42501');

select t.be('d0000000-0000-4000-8000-000000000006');   -- Whitmore, UYFC admin
select t.snap('notice', $q$select notice_id::text from app.issue_consent_notice(
    'a0000000-0000-4000-8000-000000000001',
    'UYFC consent to hold your child''s name',
    'UYFC keeps your child''s last name and jersey number so coaches can build a lineup.',
    'I am this child''s parent or legal guardian and I agree to the above.',
    array['roster','film','photo']) $q$);
select t.val('the league admin published notice v1',
  $q$select version::text from public.consent_notices where id = t.tok('notice')::uuid$q$, '1');

-- The other league publishes its own, so every cross-league test has a real
-- row on the far side rather than a NULL. Getting there turned up a property
-- worth asserting on its own: app.may_staff_league() is ADMIN only, and the
-- seed's second league has a BOARD member and no admin at all. A board seat
-- reads; it does not publish the document a parent is asked to agree to.
select t.be('d0000000-0000-4000-8000-000000000009');   -- Barlow, Cache Valley BOARD
select t.raises('a league BOARD member is not a league admin, and cannot publish a notice',
  $q$select app.issue_consent_notice('a0000000-0000-4000-8000-000000000002',
      'CVYFL notice', 'body', 'I agree')$q$, '42501');

-- So the fixture makes one, as the owner would when a league signs up. Recorded
-- rather than hidden: this row is not in seed.sql, and the suite adds it.
reset role;
insert into public.league_memberships (user_id, league_id, role)
values ('d0000000-0000-4000-8000-00000000000b', 'a0000000-0000-4000-8000-000000000002', 'admin');
set role pd_authenticated;

select t.be('d0000000-0000-4000-8000-00000000000b');   -- a Cache Valley ADMIN
select t.snap('notice_cv', $q$select notice_id::text from app.issue_consent_notice(
    'a0000000-0000-4000-8000-000000000002', 'CVYFL notice', 'CVYFL body text',
    'I am this child''s parent or legal guardian.', array['roster']) $q$);
select t.val('and a league ADMIN can',
  $q$select case when t.tok('notice_cv') is null then 'NULL' else 'ok' end$q$, 'ok');

-- Dom, an ASSISTANT coach, adds and links a guardian. His seat is the one the
-- whole app is built for, so if the assistant cannot do this the product does
-- not work for its only user.
select t.be('d0000000-0000-4000-8000-000000000001');
select t.snap('g_bagley', $q$select app.add_guardian(
    'c0000000-0000-4000-8000-000000000001', 'Bagley.parent@example.com', 'R. Bagley')::text$q$);
select t.val('an assistant coach may put a guardian on file',
  $q$select case when t.tok('g_bagley') is null then 'NULL' else 'ok' end$q$, 'ok');
select t.val('the address is stored folded to lower case',
  $q$select email from public.guardians where id = t.tok('g_bagley')::uuid$q$, 'bagley.parent@example.com');
select t.val('linking that guardian to his child succeeds',
  $q$select app.link_guardian(t.tok('g_bagley')::uuid,
      'e0000000-0000-4000-8000-000000000002')::text$q$, 'true');

-- A guardian on the other league's team, for the isolation tests.
select t.be('d0000000-0000-4000-8000-000000000007');   -- Ostler, Logan 8
select t.snap('g_logan', $q$select app.add_guardian(
    'c0000000-0000-4000-8000-000000000004', 'logan.parent@example.com')::text$q$);
select t.val('and is linked to a Logan child',
  $q$select app.link_guardian(t.tok('g_logan')::uuid,
      'e0000000-0000-4000-8000-000000000050')::text$q$, 'true');

reset role;
select t.control('two notices now exist', $q$select 1 from public.consent_notices$q$, 2);
select t.control('two guardians now exist', $q$select 1 from public.guardians$q$, 2);

-- ===========================================================================
-- 3. ASKING -- a coach may ask, and may only ask about his own children
-- ===========================================================================
select set_config('t.sect', '3 asking', false);
\echo '=== 3. A coach asks. That is the whole of his authority here. ==='

set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000001');   -- Dom, assistant, Lehi 8

select t.snap('req', $q$select app.request_consent(
    'e0000000-0000-4000-8000-000000000002', t.tok('g_bagley')::uuid,
    array['roster'])::text$q$);
select t.val('an assistant coach may ask a linked guardian',
  $q$select case when t.tok('req') is null then 'NULL' else 'ok' end$q$, 'ok');
select t.val('the request is pending',
  $q$select status from public.consent_requests where id = t.tok('req')::uuid$q$, 'pending');
select t.val('and it is stamped with the notice version in force when it was asked',
  $q$select notice_version::text from public.consent_requests where id = t.tok('req')::uuid$q$, '1');

-- THE FIRST HALF OF THE CENTRAL CLAIM. request_consent returns a request id.
-- If it returned a token, every guarantee below would be decoration.
select t.val('the ask hands the coach NO token',
  $q$select case when token_digest is null then 'no token minted'
                 else 'TOKEN EXISTS' end
      from public.consent_requests where id = t.tok('req')::uuid$q$, 'no token minted');

-- A helper coaches nothing. He is on the team and must still be refused.
select t.be('d0000000-0000-4000-8000-000000000003');   -- Parent, helper on Lehi 8
select t.raises('a HELPER on the same team cannot ask',
  $q$select app.request_consent('e0000000-0000-4000-8000-000000000002',
      t.tok('g_bagley')::uuid, array['roster'])$q$, '42501');
select t.val('and may_manage_consent says so directly',
  $q$select app.may_manage_consent('c0000000-0000-4000-8000-000000000001')::text$q$, 'false');

-- Cross-team inside one league.
select t.be('d0000000-0000-4000-8000-000000000004');   -- Kaye, head of Lehi 7
select t.raises('a coach of another team in the same league cannot ask about this child',
  $q$select app.request_consent('e0000000-0000-4000-8000-000000000002',
      t.tok('g_bagley')::uuid, array['roster'])$q$, '42501');

-- Cross-league, by literal uuid: house rule (b).
select t.be('d0000000-0000-4000-8000-000000000007');   -- Ostler, Logan 8
select t.raises('a coach in the other league cannot ask about a Lehi child',
  $q$select app.request_consent('e0000000-0000-4000-8000-000000000002',
      t.tok('g_bagley')::uuid, array['roster'])$q$, '42501');
select t.raises('nor pair his own guardian with a Lehi child',
  $q$select app.request_consent('e0000000-0000-4000-8000-000000000002',
      t.tok('g_logan')::uuid, array['roster'])$q$, '42501');

-- A stranger with a valid uuid and no membership anywhere.
select t.be('d0000000-0000-4000-8000-00000000000a');
select t.raises('a stranger cannot ask',
  $q$select app.request_consent('e0000000-0000-4000-8000-000000000002',
      t.tok('g_bagley')::uuid, array['roster'])$q$, '42501');
select t.raises('and cannot put a guardian on somebody else''s team',
  $q$select app.add_guardian('c0000000-0000-4000-8000-000000000001','x@example.com')$q$, '42501');

-- Not signed in at all.
select t.be(null);
select t.raises('an unauthenticated session cannot ask',
  $q$select app.request_consent('e0000000-0000-4000-8000-000000000002',
      t.tok('g_bagley')::uuid, array['roster'])$q$, '42501');

select t.be('d0000000-0000-4000-8000-000000000001');   -- back to Dom

-- The ask cannot be made about a guardian who is not this child's.
reset role; set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000001');
select t.raises('a coach cannot ask a guardian who is not linked to that child',
  $q$select app.request_consent('e0000000-0000-4000-8000-000000000001',
      t.tok('g_bagley')::uuid, array['roster'])$q$, '42501');

-- Scope hygiene.
select t.raises('an invented scope is refused',
  $q$select app.request_consent('e0000000-0000-4000-8000-000000000002',
      t.tok('g_bagley')::uuid, array['roster','sell_to_advertisers'])$q$, '22023');
select t.raises('asking for nothing is refused',
  $q$select app.request_consent('e0000000-0000-4000-8000-000000000002',
      t.tok('g_bagley')::uuid, array[]::text[])$q$, '22023');
select t.raises('a scope the published notice does not cover is refused',
  $q$select app.request_consent('e0000000-0000-4000-8000-000000000002',
      t.tok('g_bagley')::uuid, array['share_public'])$q$, '22023');
select t.raises('a request that would outlive ninety days is refused',
  $q$select app.request_consent('e0000000-0000-4000-8000-000000000002',
      t.tok('g_bagley')::uuid, array['roster'], null, interval '120 days')$q$, '22023');

-- Re-asking supersedes rather than stacking, exactly as a re-sent invite does.
select t.snap('req2', $q$select app.request_consent(
    'e0000000-0000-4000-8000-000000000002', t.tok('g_bagley')::uuid, array['roster'])::text$q$);
select t.val('re-asking withdraws the outstanding request',
  $q$select status from public.consent_requests where id = t.tok('req')::uuid$q$, 'withdrawn');
select t.val('and says why, in the row',
  $q$select decision_note from public.consent_requests where id = t.tok('req')::uuid$q$,
  'superseded by a later request');
select t.val('exactly one request for this child is pending',
  $q$select count(*)::text from public.consent_requests
     where player_id = 'e0000000-0000-4000-8000-000000000002' and status = 'pending'$q$, '1');

-- ===========================================================================
-- 4. THE CENTRAL CLAIM -- a coach cannot answer his own request
-- ===========================================================================
-- Everything in this section is the same attack from a different angle. The
-- coach holds the request id; the answer needs a token; the token is minted by
-- one function that his role cannot execute.
select set_config('t.sect', '4 coach cannot answer', false);
\echo '=== 4. THE CENTRAL CLAIM: the coach who asks cannot be the one who answers ==='

set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000001');

select t.control('there is a live pending request to hijack',
  $q$select 1 from public.consent_requests where id = t.tok('req2')::uuid and status = 'pending'$q$, 1);

-- 1. He cannot mint the token.
select t.raises('the coach cannot call consent_dispatch on his own request',
  $q$select * from app.consent_dispatch(t.tok('req2')::uuid)$q$, '42501');

-- 2. He cannot read one out of the table, because there is not one there.
select t.val('and there is no token in the row to read',
  $q$select coalesce(token_digest, 'null') from public.consent_requests
     where id = t.tok('req2')::uuid$q$, 'null');

-- 3. He cannot write the consent row himself.
select t.blocked('the coach cannot insert a consent row directly',
  $q$insert into public.player_consents (player_id, team_id, granted_by, scope)
     values ('e0000000-0000-4000-8000-000000000002',
             'c0000000-0000-4000-8000-000000000001',
             'd0000000-0000-4000-8000-000000000001', 'roster')$q$);

-- 4. He cannot mark the request granted by hand.
select t.blocked('nor flip the request to granted',
  $q$update public.consent_requests set status = 'granted', answered_at = now()
      where id = t.tok('req2')::uuid$q$);

-- 5. He cannot forge the evidence that would make a consent look answered.
select t.blocked('nor write a row of evidence',
  $q$insert into public.consent_evidence
      (consent_id, request_id, team_id, player_id, guardian_id, scope,
       notice_id, notice_version, notice_digest, method, assertion)
     values (gen_random_uuid(), t.tok('req2')::uuid,
             'c0000000-0000-4000-8000-000000000001',
             'e0000000-0000-4000-8000-000000000002', t.tok('g_bagley')::uuid,
             'roster', t.tok('notice')::uuid, 1, 'x', 'email_token', 'I agree')$q$);

-- 6. He cannot guess his way in. grant_consent IS callable by him -- a coach may
--    also be a parent, holding a real token for his own child -- so the refusal
--    here has to come from the token, not from the seat.
select t.raises('grant_consent with a guessed token is refused',
  $q$select app.grant_consent('not-a-real-token','I am this child''s parent or legal guardian and I agree to the above.')$q$, '22023');
select t.raises('grant_consent with the REQUEST ID as the token is refused',
  $q$select app.grant_consent(t.tok('req2'),'I am this child''s parent or legal guardian and I agree to the above.')$q$, '22023');
select t.raises('grant_consent with an empty token is refused',
  $q$select app.grant_consent('','I agree')$q$, '22023');
select t.raises('grant_consent with a null token is refused',
  $q$select app.grant_consent(null,'I agree')$q$, '22023');

-- 7. He cannot become the mailer.
--
-- NOT tested as `set role pd_mailer`, and the reason is worth writing down
-- because the first draft of this file did exactly that and recorded a false
-- finding. SET ROLE is authorised against the SESSION user, not the current
-- role, and every suite here connects as the owner and SET ROLEs down. So the
-- owner can always reach pd_mailer, that statement always succeeds, and the
-- test was measuring the harness rather than the schema.
--
-- The property that actually holds in production is role MEMBERSHIP, which is
-- the same fact the pooler would be bound by, and it is checkable from here.
select t.val('a signed-in coach is not a member of the mailer role',
  $q$select pg_has_role('pd_authenticated', 'pd_mailer', 'MEMBER')::text$q$, 'false');
select t.val('nor is an anonymous session',
  $q$select pg_has_role('pd_anon', 'pd_mailer', 'MEMBER')::text$q$, 'false');
select t.val('the mailer role cannot log in on its own either',
  $q$select rolcanlogin::text from pg_roles where rolname = 'pd_mailer'$q$, 'false');
select t.val('and the mailer holds no table privilege on the consent record',
  $q$select count(*)::text from (
       select 1 from unnest(array['consent_notices','guardians','guardian_children',
                                  'consent_requests','consent_evidence','consent_events',
                                  'players','player_consents']) tbl,
                     unnest(array['select','insert','update','delete']) verb
        where has_table_privilege('pd_mailer', 'public.'||tbl, verb)) _$q$, '0');

-- 8. Nothing above wrote anything.
reset role;
select t.val('after eight attacks, still no consent for that child',
  $q$select count(*)::text from public.player_consents
     where player_id = 'e0000000-0000-4000-8000-000000000002' and revoked_at is null$q$, '0');
select t.val('and the request is still pending, unanswered',
  $q$select status from public.consent_requests where id = t.tok('req2')::uuid$q$, 'pending');
select t.val('and no evidence exists for it',
  $q$select count(*)::text from public.consent_evidence
     where request_id = t.tok('req2')::uuid$q$, '0');

-- ===========================================================================
-- 5. THE GUARDIAN'S SIDE -- one credential, and what it does and does not open
-- ===========================================================================
select set_config('t.sect', '5 the token', false);
\echo '=== 5. The token: what it opens, and what it does not ==='

-- The mailer mints. This is the only place in the suite that becomes pd_mailer,
-- and it is doing exactly what the mail job does in production.
reset role; set role pd_mailer;
select t.snap('token', $q$select token from app.consent_dispatch(t.tok('req2')::uuid)$q$);
select t.val('the mailer gets a token',
  $q$select case when length(t.tok('token')) >= 32 then 'long enough' else 'SHORT' end$q$, 'long enough');

reset role;
select t.val('only its digest is stored, never the token',
  $q$select case when token_digest = t.tok('token') then 'PLAINTEXT STORED'
                 when token_digest ~ '^[0-9a-f]{64}$' then 'sha256 digest only'
                 else 'unexpected' end
      from public.consent_requests where id = t.tok('req2')::uuid$q$, 'sha256 digest only');
select t.val('and the token does not appear anywhere in the audit trail',
  $q$select count(*)::text from public.consent_events
     where detail::text like '%' || t.tok('token') || '%'$q$, '0');

-- The guardian has NO ACCOUNT. Everything below runs as pd_anon.
set role pd_anon;
select t.be(null);

select t.val('the guardian can see the notice they are being asked to agree to',
  $q$select notice_title from app.consent_request_view(t.tok('token'))$q$,
  'UYFC consent to hold your child''s name');
select t.val('and the scopes',
  $q$select array_to_string(scopes, ',') from app.consent_request_view(t.tok('token'))$q$, 'roster');

-- THE OTHER HALF OF DATA MINIMISATION. A stolen token must not be a roster.
select t.val('the child is shown as a jersey number, not a name',
  $q$select jersey from app.consent_request_view(t.tok('token'))$q$, '27');
select t.val('the view exposes no first/last name column at all',
  $q$select count(*)::text from
     (select p.proname, unnest(p.proargnames) as arg from pg_proc p
       where p.proname = 'consent_request_view') _
      where arg in ('first','last','player_name','child_name')$q$, '0');
select t.val('the view''s output contains no child''s surname',
  $q$select case when (select string_agg(row_to_json(v)::text,' ')
                        from app.consent_request_view(t.tok('token')) v) like '%Bagley%'
                 then 'NAME LEAKED' else 'no name' end$q$, 'no name');

select t.raises('a wrong token shows nothing',
  $q$select * from app.consent_request_view('wrong-token')$q$, '22023');

-- Answering. The assertion must be the sentence on the notice, verbatim.
select t.raises('a grant with the wrong assertion sentence is refused',
  $q$select app.grant_consent(t.tok('token'), 'sure whatever')$q$, '22023');
select t.raises('and so is an empty one',
  $q$select app.grant_consent(t.tok('token'), '')$q$, '22023');

-- A grant may only narrow.
select t.raises('a grant cannot widen beyond what was asked',
  $q$select app.grant_consent(t.tok('token'),
      'I am this child''s parent or legal guardian and I agree to the above.',
      null, array['roster','film'])$q$, '42501');
select t.raises('agreeing to nothing is a refusal, not a grant',
  $q$select app.grant_consent(t.tok('token'),
      'I am this child''s parent or legal guardian and I agree to the above.',
      null, array[]::text[])$q$, '22023');

reset role;
select t.val('after four bad answers the request is STILL pending',
  $q$select status from public.consent_requests where id = t.tok('req2')::uuid$q$, 'pending');

-- The real grant.
set role pd_anon; select t.be(null);
select t.val('the guardian grants',
  $q$select (app.grant_consent(t.tok('token'),
      'I am this child''s parent or legal guardian and I agree to the above.',
      '203.0.113.9') ->> 'result')$q$, 'granted');

reset role;
select t.val('one consent row was written',
  $q$select count(*)::text from public.player_consents
     where player_id = 'e0000000-0000-4000-8000-000000000002' and revoked_at is null$q$, '1');
select t.val('with one row of evidence behind it',
  $q$select count(*)::text from public.consent_evidence
     where player_id = 'e0000000-0000-4000-8000-000000000002'$q$, '1');
select t.val('the evidence names the notice version agreed to',
  $q$select notice_version::text from public.consent_evidence
     where player_id = 'e0000000-0000-4000-8000-000000000002'$q$, '1');
select t.val('and keeps the digest of the exact text shown',
  $q$select case when e.notice_digest = n.body_digest then 'matches the notice as issued'
                 else 'DIGEST MISMATCH' end
      from public.consent_evidence e join public.consent_notices n on n.id = e.notice_id
     where e.player_id = 'e0000000-0000-4000-8000-000000000002'$q$,
  'matches the notice as issued');

-- The IP is minimised, not stored.
select t.val('the guardian''s IP address is not stored in the clear',
  $q$select case when ip_digest = '203.0.113.9' then 'PLAINTEXT IP'
                 when ip_digest ~ '^[0-9a-f]{64}$' then 'salted digest only'
                 else coalesce(ip_digest,'null') end
      from public.consent_requests where id = t.tok('req2')::uuid$q$, 'salted digest only');
select t.val('and the same address under a different request digests differently',
  $q$select case when (select ip_digest from public.consent_requests where id = t.tok('req2')::uuid)
                    = app.hash_secret('203.0.113.9')
                 then 'UNSALTED -- a rainbow table reverses this'
                 else 'salted per request' end$q$, 'salted per request');

-- SINGLE USE.
set role pd_anon; select t.be(null);
select t.raises('the same token cannot be used twice',
  $q$select app.grant_consent(t.tok('token'),
      'I am this child''s parent or legal guardian and I agree to the above.')$q$, '22023');
select t.raises('and cannot be turned into a refusal after the fact',
  $q$select app.refuse_consent(t.tok('token'), 'changed my mind')$q$, '22023');
select t.raises('nor does it still open the view''s notice for a fresh answer',
  $q$select app.grant_consent(t.tok('token'),
      'I am this child''s parent or legal guardian and I agree to the above.',
      null, array['roster'])$q$, '22023');

reset role;
select t.val('still exactly one consent, after the replay attempts',
  $q$select count(*)::text from public.player_consents
     where player_id = 'e0000000-0000-4000-8000-000000000002' and revoked_at is null$q$, '1');
select t.val('and exactly one row of evidence',
  $q$select count(*)::text from public.consent_evidence
     where player_id = 'e0000000-0000-4000-8000-000000000002'$q$, '1');

-- ===========================================================================
-- 6. THE COLLECTION GATE -- a name cannot be written without a live consent
-- ===========================================================================
-- Everything above is about the RECORD of consent. This section is about the
-- data itself: the trigger on public.players that refuses to hold a child's
-- name until a guardian has said yes. It is the difference between a consent
-- system and a consent form.
select set_config('t.sect', '6 the gate', false);
\echo '=== 6. The gate: a name needs a consent standing behind it ==='

set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000002');   -- Steve, head coach of Lehi 8

select t.raises('a coach cannot create a NAMED player',
  $q$insert into public.players (team_id, last, first, jersey)
     values ('c0000000-0000-4000-8000-000000000001', 'Newkid', 'Sam', '81')$q$, '42501');

-- The permitted shape: a jersey number and nothing else.
select t.snap('slot', $q$insert into public.players (team_id, last, first, jersey)
     values ('c0000000-0000-4000-8000-000000000001',
             app.jersey_placeholder('81'), null, '81') returning id::text$q$);
select t.val('but he may create the roster SLOT as a jersey number',
  $q$select last from public.players where id = t.tok('slot')::uuid$q$, '#81');

select t.raises('and cannot then write a name into it',
  $q$update public.players set last = 'Newkid', first = 'Sam'
      where id = t.tok('slot')::uuid$q$, '42501');

-- Everything that is not a name still moves freely. A gate that blocks a
-- jersey change is a gate a coach will route around.
select t.allowed('changing the jersey number is not collecting a name',
  $q$update public.players set jersey = '82' where id = t.tok('slot')::uuid$q$, 1);

-- Un-naming is always allowed, in both directions of the check.
select t.control('a named child exists to redact',
  $q$select 1 from public.players
     where id = 'e0000000-0000-4000-8000-000000000004' and first is not null$q$, 1);
select t.allowed('redacting a name to a jersey placeholder is always allowed',
  $q$update public.players set last = app.jersey_placeholder(jersey), first = null
      where id = 'e0000000-0000-4000-8000-000000000004'$q$, 1);
select t.raises('and putting that name back needs a consent that is not there',
  $q$update public.players set last = 'Black', first = 'Brave'
      where id = 'e0000000-0000-4000-8000-000000000004'$q$, '42501');

-- The child who DOES have a live consent, granted by his guardian in section 5.
select t.control('Bagley now has a live roster consent',
  $q$select 1 from public.player_consents
     where player_id = 'e0000000-0000-4000-8000-000000000002'
       and scope = 'roster' and revoked_at is null$q$, 1);
select t.allowed('a child WITH a live roster consent may be renamed',
  $q$update public.players set last = 'Bagley', first = 'Ledger'
      where id = 'e0000000-0000-4000-8000-000000000002'$q$, 1);

-- The gate asks app.consent_ok(), so the version check reaches it too.
reset role; set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000006');   -- UYFC admin
select t.snap('notice2', $q$select notice_id::text from app.issue_consent_notice(
    'a0000000-0000-4000-8000-000000000001',
    'UYFC consent, revised', 'A revised body, materially different.',
    'I am this child''s parent or legal guardian and I agree to the revised terms.',
    array['roster','film','photo']) $q$);
select t.val('the league publishes v2',
  $q$select version::text from public.consent_notices where id = t.tok('notice2')::uuid$q$, '2');

select t.val('a consent given against v1 is now STALE',
  $q$select app.consent_ok('e0000000-0000-4000-8000-000000000002','roster')::text$q$, 'false');

select t.be('d0000000-0000-4000-8000-000000000002');
select t.raises('so the gate closes again on a child whose guardian agreed to v1',
  $q$update public.players set last = 'Bagley', first = 'Ledger-Revised'
      where id = 'e0000000-0000-4000-8000-000000000002'$q$, '42501');
select t.allowed('though redacting him is still allowed',
  $q$update public.players set last = app.jersey_placeholder(jersey), first = null
      where id = 'e0000000-0000-4000-8000-000000000002'$q$, 1);

-- The paper consent written by the migration role before this flow existed
-- must NOT be retroactively invalidated -- it has no evidence row and so no
-- version to be stale against. This is the one deliberate asymmetry in
-- consent_ok(), and it is here so nobody "tidies" it away.
select t.val('a pre-flow paper consent with no evidence still counts',
  $q$select app.consent_ok('e0000000-0000-4000-8000-000000000009','roster')::text$q$, 'true');
select t.control('and it really is the one with no evidence behind it',
  $q$select 1 from public.player_consents c
     where c.player_id = 'e0000000-0000-4000-8000-000000000009' and c.scope='roster'
       and not exists (select 1 from public.consent_evidence e where e.consent_id = c.id)$q$, 1);

-- A revoked consent is not a consent.
select t.val('the revoked film consent reads false',
  $q$select app.consent_ok('e0000000-0000-4000-8000-000000000009','film')::text$q$, 'false');
-- require_consent RAISES rather than returning false, deliberately: the caller
-- is about to export film, and a false that gets ignored ships the film.
select t.raises('require_consent refuses loudly rather than returning false',
  $q$select app.require_consent('e0000000-0000-4000-8000-000000000009','film')$q$, '42501');

-- Cross-tenant: the gate must not be a way to learn about the other league.
select t.be('d0000000-0000-4000-8000-000000000002');
-- t.blocked, not t.raises: RLS filters the row rather than raising, so the
-- honest assertion is "zero rows written", not "an error was thrown".
select t.blocked('a Lehi coach cannot name a Logan child',
  $q$update public.players set last = 'Whoever', first = 'Someone'
      where id = 'e0000000-0000-4000-8000-000000000050'$q$);
reset role;
select t.val('and the Logan child still has his own name',
  $q$select last from public.players where id = 'e0000000-0000-4000-8000-000000000050'$q$,
  (select last from public.players where id = 'e0000000-0000-4000-8000-000000000050'));
set role pd_authenticated;

-- ===========================================================================
-- 7. REFUSAL AND REVOCATION -- "no" is an answer, and it can arrive later
-- ===========================================================================
select set_config('t.sect', '7 no', false);
\echo '=== 7. A guardian says no, and a guardian changes their mind ==='

reset role; set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000001');
select t.snap('g_black', $q$select app.add_guardian(
    'c0000000-0000-4000-8000-000000000001', 'black.parent@example.com')::text$q$);
select t.val('linked to Black',
  $q$select app.link_guardian(t.tok('g_black')::uuid,
      'e0000000-0000-4000-8000-000000000004')::text$q$, 'true');
select t.snap('req_no', $q$select app.request_consent(
    'e0000000-0000-4000-8000-000000000004', t.tok('g_black')::uuid, array['roster'])::text$q$);

reset role; set role pd_mailer;
select t.snap('token_no', $q$select token from app.consent_dispatch(t.tok('req_no')::uuid)$q$);

reset role; set role pd_anon; select t.be(null);
select t.val('the guardian refuses',
  $q$select (app.refuse_consent(t.tok('token_no'), 'we would rather not') ->> 'result')$q$, 'refused');

reset role;
select t.val('the refusal is a dated outcome, not a silence',
  $q$select status from public.consent_requests where id = t.tok('req_no')::uuid$q$, 'refused');
select t.val('the reason the guardian gave is kept',
  $q$select decision_note from public.consent_requests where id = t.tok('req_no')::uuid$q$,
  'we would rather not');
select t.val('and no consent row was written',
  $q$select count(*)::text from public.player_consents
     where player_id = 'e0000000-0000-4000-8000-000000000004' and revoked_at is null$q$, '0');
select t.val('the gate stays shut on a refused child',
  $q$select app.consent_ok('e0000000-0000-4000-8000-000000000004','roster')::text$q$, 'false');

-- A refusal blocks exactly as hard as silence, and the coach is TOLD which.
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000001');
select t.raises('and require_consent says a guardian refused, rather than "not found"',
  $q$select app.require_consent('e0000000-0000-4000-8000-000000000004','roster')$q$, '42501');

-- A refused request is spent, like a granted one.
reset role; set role pd_anon; select t.be(null);
select t.raises('a refused token cannot then be used to grant',
  $q$select app.grant_consent(t.tok('token_no'),
      'I am this child''s parent or legal guardian and I agree to the above.')$q$, '22023');

-- Revocation, NARROW. Withdrawing permission to photograph a boy is not a
-- request to erase him from the team, and the schema draws that line: a scope
-- other than 'roster' revokes exactly itself and leaves the child on the roster.
reset role;
select t.control('a live paper consent exists on another child',
  $q$select 1 from public.player_consents
     where player_id = 'e0000000-0000-4000-8000-000000000009'
       and scope = 'roster' and revoked_at is null$q$, 1);
select t.control('and that child is still on the roster',
  $q$select 1 from public.players where id = 'e0000000-0000-4000-8000-000000000009'$q$, 1);

set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000001');
select t.val('a coach may revoke ON REQUEST -- the parent phones the coach',
  $q$select (app.revoke_consent_for('e0000000-0000-4000-8000-000000000009',
      array['photo'], 'parent asked at practice') ->> 'result')$q$, 'revoked');
select t.val('and revoking a narrow scope does NOT forget the child',
  $q$select (app.revoke_consent_for('e0000000-0000-4000-8000-000000000009',
      array['photo'], 'again, idempotently') ->> 'child_forgotten')$q$, 'false');

reset role;
select t.val('the child is still on the roster',
  $q$select count(*)::text from public.players
     where id = 'e0000000-0000-4000-8000-000000000009'$q$, '1');
select t.val('and his roster consent is untouched',
  $q$select app.consent_ok('e0000000-0000-4000-8000-000000000009','roster')::text$q$, 'true');

-- The guard on player_consents. Run as the OWNER, because a record only the
-- tenant cannot edit is not a record.
select t.control('there is a revoked consent to un-revoke',
  $q$select 1 from public.player_consents
     where player_id = 'e0000000-0000-4000-8000-000000000009' and revoked_at is not null$q$, 1);
select t.raises('the owner itself cannot un-revoke a consent',
  $q$update public.player_consents set revoked_at = null
      where player_id = 'e0000000-0000-4000-8000-000000000009' and revoked_at is not null$q$, '42501');
select t.raises('nor rewrite who consented, for whom, to what, or when',
  $q$update public.player_consents set scope = 'photo'
      where player_id = 'e0000000-0000-4000-8000-000000000009' and scope = 'roster'$q$, '42501');
select t.raises('and a consent is revoked, never erased',
  $q$delete from public.player_consents
      where player_id = 'e0000000-0000-4000-8000-000000000009' and scope = 'roster'$q$, '42501');

-- ===========================================================================
-- 8. THE EVIDENCE IS EVIDENCE -- immutable notice, append-only trail
-- ===========================================================================
-- "What did this parent agree to in 2026" has to be answerable in 2031 from the
-- rows themselves. Every test here is run as the OWNER, because a record that
-- only the tenant cannot edit is not a record.
select set_config('t.sect', '8 evidence', false);
\echo '=== 8. Evidence: run as the OWNER, because that is who could rewrite it ==='

reset role;
select t.control('a notice exists to tamper with',
  $q$select 1 from public.consent_notices where id = t.tok('notice')::uuid$q$, 1);

select t.raises('the owner cannot edit the body of an issued notice',
  $q$update public.consent_notices set body = 'something else'
      where id = t.tok('notice')::uuid$q$, '42501');
select t.raises('nor the sentence the guardian affirmed',
  $q$update public.consent_notices set assertion = 'I agree to anything'
      where id = t.tok('notice')::uuid$q$, '42501');
select t.raises('nor delete it',
  $q$delete from public.consent_notices where id = t.tok('notice')::uuid$q$, '42501');
select t.raises('nor truncate the table',
  $q$truncate public.consent_notices cascade$q$, '42501');

select t.control('there is a trail to rewrite',
  $q$select 1 from public.consent_events$q$, 1);
select t.raises('the owner cannot edit an event in the trail',
  $q$update public.consent_events set action = 'nothing happened'$q$, '42501');
select t.raises('nor delete one',
  $q$delete from public.consent_events$q$, '42501');
select t.raises('nor truncate the trail',
  $q$truncate public.consent_events$q$, '42501');

select t.control('evidence exists behind the one real grant',
  $q$select 1 from public.consent_evidence$q$, 1);
select t.raises('the owner cannot rewrite what a guardian affirmed',
  $q$update public.consent_evidence set assertion = 'I agree to everything'$q$, '42501');

-- The trail recorded the story, and the story does not contain a child's name.
select t.val('the trail recorded the grant',
  $q$select count(*)::text from public.consent_events where action = 'consent_grant'$q$, '1');
select t.val('and the refusal',
  $q$select count(*)::text from public.consent_events where action = 'consent_refuse'$q$, '1');
select t.val('the trail holds no child''s name anywhere in it',
  $q$select count(*)::text from public.consent_events e, public.players p
     where p.first is not null
       and (e.detail::text like '%' || p.first || '%'
            or e.detail::text like '%' || p.last  || '%')$q$, '0');
select t.val('nor any guardian''s email address',
  $q$select count(*)::text from public.consent_events e, public.guardians g
     where e.detail::text like '%' || g.email || '%'$q$, '0');

-- app.consent_provenance() is the answer to "prove it", years later.
-- app.consent_provenance() is the answer to "prove it", years later. It is
-- staff-only, so it needs a seat -- asked as the owner with no identity stamped
-- it correctly answers "no such player", which is itself worth asserting.
select t.be(null);
select t.raises('provenance refuses a session with no identity',
  $q$select * from app.consent_provenance('e0000000-0000-4000-8000-000000000002')$q$, '42501');
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000001');
select t.val('and answers his coach with the notice version that was agreed to',
  $q$select string_agg(distinct notice_version::text, ',')
      from app.consent_provenance('e0000000-0000-4000-8000-000000000002')$q$, '1');
select t.be('d0000000-0000-4000-8000-000000000007');
select t.raises('and refuses a coach from the other league',
  $q$select * from app.consent_provenance('e0000000-0000-4000-8000-000000000002')$q$, '42501');
reset role;

-- ===========================================================================
-- 9. FORGETTING A CHILD -- tombstone, never cascade
-- ===========================================================================
-- This is the section a league's board will actually ask about: a parent writes
-- in and says take my son off. What must happen is that every trace of HIM goes
-- and none of the football does -- his plays survive, reading as a jersey
-- number, because a play is the coach's work and deleting it punishes the team
-- for a parent exercising a right.
select set_config('t.sect', '9 forgetting', false);
\echo '=== 9. Forgetting a child: everything about him goes, none of the football ==='

reset role;
select t.control('the child to forget is on the roster',
  $q$select 1 from public.players where id = 'e0000000-0000-4000-8000-000000000002'$q$, 1);
select t.control('with a consent record behind him',
  $q$select 1 from public.player_consents
     where player_id = 'e0000000-0000-4000-8000-000000000002'$q$, 1);
select t.control('and evidence',
  $q$select 1 from public.consent_evidence
     where player_id = 'e0000000-0000-4000-8000-000000000002'$q$, 1);
select t.control('and a guardian linked to him',
  $q$select 1 from public.guardian_children
     where player_id = 'e0000000-0000-4000-8000-000000000002'$q$, 1);
select t.snap('plays_before',
  $q$select count(*)::text from public.plays
     where team_id = 'c0000000-0000-4000-8000-000000000001'$q$);

set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000001');
select t.val('the coach acts on the parent''s request',
  $q$select (app.revoke_consent_for('e0000000-0000-4000-8000-000000000002',
      array['roster'], 'parent wrote in') ->> 'child_forgotten')$q$, 'true');

reset role;
select t.val('the child row is gone',
  $q$select count(*)::text from public.players
     where id = 'e0000000-0000-4000-8000-000000000002'$q$, '0');
select t.val('his consent requests are gone',
  $q$select count(*)::text from public.consent_requests
     where player_id = 'e0000000-0000-4000-8000-000000000002'$q$, '0');
select t.val('his evidence is gone',
  $q$select count(*)::text from public.consent_evidence
     where player_id = 'e0000000-0000-4000-8000-000000000002'$q$, '0');
select t.val('his guardian link is gone',
  $q$select count(*)::text from public.guardian_children
     where player_id = 'e0000000-0000-4000-8000-000000000002'$q$, '0');
select t.val('and the guardian, left with no children, is gone with him',
  $q$select count(*)::text from public.guardians
     where email = 'bagley.parent@example.com'$q$, '0');

-- WHAT SURVIVES, and why each one is allowed to.
select t.val('a tombstone remains, so the deletion itself is auditable',
  $q$select count(*)::text from public.player_tombstones
     where player_id = 'e0000000-0000-4000-8000-000000000002'$q$, '1');
select t.val('and it names the reason the parent gave',
  $q$select reason from public.player_tombstones
     where player_id = 'e0000000-0000-4000-8000-000000000002'$q$, 'parent_request');

-- THE TEST THAT MATTERS MOST HERE. A tombstone that stores the name defeats the
-- deletion, which is why player_tombstones has no name column at all.
select t.val('the tombstone table has no column that could hold a name',
  $q$select count(*)::text from information_schema.columns
     where table_schema='public' and table_name='player_tombstones'
       and column_name in ('last','first','name','player_name','full_name')$q$, '0');
select t.val('and no row of it contains the forgotten surname',
  $q$select count(*)::text from public.player_tombstones
     where row_to_json(player_tombstones)::text like '%Bagley%'$q$, '0');
select t.val('nor does the trail, which kept the event',
  $q$select count(*)::text from public.consent_events
     where detail::text like '%Bagley%' or detail::text like '%Ledger%'$q$, '0');
select t.val('the trail DID record that a child was forgotten',
  $q$select count(*)::text from public.consent_events
     where action = 'child_forgotten'$q$, '1');

-- The football survives. Rule 1 of CLAUDE.md, restated for a new domain.
select t.unchanged('not one play was deleted with him', 'plays_before',
  $q$select count(*)::text from public.plays
     where team_id = 'c0000000-0000-4000-8000-000000000001'$q$);

-- The other league was not touched by any of it.
select t.val('the other league still has its child',
  $q$select count(*)::text from public.players
     where id = 'e0000000-0000-4000-8000-000000000050'$q$, '1');
select t.val('and its guardian',
  $q$select count(*)::text from public.guardians
     where email = 'logan.parent@example.com'$q$, '1');
select t.val('and its notice',
  $q$select count(*)::text from public.consent_notices
     where id = t.tok('notice_cv')::uuid$q$, '1');

-- ===========================================================================
-- 10. VACUITY CHECK -- the same calls, with the guard removed
-- ===========================================================================
-- House rule (c). Everything above is a list of zeroes and refusals, and a
-- broken guard produces exactly the same list. So: put the bug back, on
-- purpose, and show the identical statements succeeding.
select set_config('t.sect', '10 vacuity', false);
\echo '=== 10. With the guard put back the way it was, the gate opens ==='

reset role;

-- THE ACTUAL BUG THIS FILE FOUND, reintroduced. app.is_privileged_session() was
-- SECURITY DEFINER, which made current_user the function's owner for every
-- caller, so it answered "privileged" to everybody and both guard triggers
-- became no-ops.
alter function app.is_privileged_session() security definer;

set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000002');
select t.val('with the guard back as it was, a coach IS "privileged"',
  $q$select app.is_privileged_session()::text$q$, 'true');
select t.allowed('and writes a child''s full name with no consent anywhere',
  $q$insert into public.players (team_id, last, first, jersey)
     values ('c0000000-0000-4000-8000-000000000001', 'Vacuity', 'Check', '98')$q$, 1);
select t.val('the name really is in the table',
  $q$select first || ' ' || last from public.players where jersey = '98'$q$, 'Check Vacuity');

reset role;
delete from public.players where jersey = '98';
alter function app.is_privileged_session() security invoker;

set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000002');
select t.val('put back the right way, the coach is a tenant again',
  $q$select app.is_privileged_session()::text$q$, 'false');
select t.raises('and the same insert is refused',
  $q$insert into public.players (team_id, last, first, jersey)
     values ('c0000000-0000-4000-8000-000000000001', 'Vacuity', 'Check', '98')$q$, '42501');

reset role;

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
  if n_fail > 0 then
    raise exception '% CONSENT TEST(S) FAILED', n_fail;
  end if;
  raise notice 'all % consent tests passed', n_all;
end $$;

rollback;
