-- product/db/auth-seed.sql
-- Fixtures for the auth layer: invitations in every state, and player words.
--
-- Load order: schema.sql -> rls.sql -> auth.sql -> seed.sql -> auth-seed.sql
--
-- WHAT THIS FILE DELIBERATELY DOES NOT DO
-- It adds no league, no season, no team, no player, no play and NO MEMBERSHIP.
-- test-isolation.sql asserts exact counts of all six (31 players, 6 plays, 7
-- memberships, 3 board seats, 23 visible to Dom, 26 to the board), and those
-- 183 tests have to keep passing with this file loaded. Everything here lives
-- in the three tables auth.sql adds. An invitation is not a membership until
-- somebody accepts it, which is the entire point of the feature and is also
-- what makes it safe to seed.
--
-- THE TOKENS BELOW ARE WRITTEN DOWN, AND THAT IS THE ONE THING A REAL TOKEN
-- NEVER IS. A real invitation exists in plaintext exactly twice: in the return
-- value of app.issue_invite() and in the email that carries it. These fixtures
-- are inserted by hand, as the owner, precisely so the test suite can hold a
-- token it knows -- the same reason seed.sql is not a production file. Note
-- that even here the column stores app.hash_secret(...), never the token: the
-- storage rule holds even for a fixture.
--
-- Deliberate traps, so an attack has something to succeed at:
--   * The SAME address (newcoach@example.com) holds a live invitation to a UYFC
--     team AND one to a Cache Valley team. Redeeming one must not touch the
--     other league, and the team must come from the row, not from the request.
--   * An expired invitation and a withdrawn one, so refusal has to be a
--     property of the row rather than of the token being unknown.
--   * Lehi 8 and Logan 8 both have a player word, and Lehi 7's has expired.
--     Presenting one team's word against another team's id must resolve to
--     nothing at all.

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------------
-- People who appear here and hold nothing yet. None of them has a membership,
-- which is what keeps test-isolation.sql's counts intact.
--   d..0b newcoach@example.com     invited assistant, Lehi 8   (and Logan 8)
--   d..0c latecomer@example.com    invitation expired
--   d..0d newboard@example.com     invited to the UYFC board
--   d..0e outsider@example.com     invited nowhere; holds a valid account
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Invitations
-- ---------------------------------------------------------------------------

insert into public.invites
  (id, team_id, league_id, role, email, token_hash, issued_by, issued_at, expires_at, accepted_at, accepted_by, revoked_at)
values
-- 1. Live. Steve (head, Lehi 8) invites an assistant.
('90000000-0000-4000-8000-000000000001',
 'c0000000-0000-4000-8000-000000000001', null, 'assistant', 'newcoach@example.com',
 app.hash_secret('seed-live-lehi8-assistant'),
 'd0000000-0000-4000-8000-000000000002', now() - interval '1 day', now() + interval '13 days',
 null, null, null),

-- 2. Live, other league, SAME ADDRESS. Ostler (head, Logan 8) invites the same
--    person. Two live tokens, two teams, one mailbox: the team has to come off
--    the row or these two become interchangeable.
('90000000-0000-4000-8000-000000000002',
 'c0000000-0000-4000-8000-000000000004', null, 'helper', 'newcoach@example.com',
 app.hash_secret('seed-live-logan8-helper'),
 'd0000000-0000-4000-8000-000000000007', now() - interval '1 day', now() + interval '13 days',
 null, null, null),

-- 3. Expired eleven days ago. Everything else about it is perfect.
('90000000-0000-4000-8000-000000000003',
 'c0000000-0000-4000-8000-000000000001', null, 'helper', 'latecomer@example.com',
 app.hash_secret('seed-expired-lehi8-helper'),
 'd0000000-0000-4000-8000-000000000002', now() - interval '25 days', now() - interval '11 days',
 null, null, null),

-- 4. Withdrawn. Sent to the wrong address and taken back.
('90000000-0000-4000-8000-000000000004',
 'c0000000-0000-4000-8000-000000000001', null, 'assistant', 'wrongperson@example.com',
 app.hash_secret('seed-revoked-lehi8-assistant'),
 'd0000000-0000-4000-8000-000000000002', now() - interval '3 days', now() + interval '11 days',
 null, null, now() - interval '2 days'),

-- 5. Live, and addressed to somebody who already coaches the team. Accepting it
--    must not duplicate Dom's row and must not promote him to head.
('90000000-0000-4000-8000-000000000005',
 'c0000000-0000-4000-8000-000000000001', null, 'head', 'dom@example.com',
 app.hash_secret('seed-live-lehi8-head-for-dom'),
 'd0000000-0000-4000-8000-000000000002', now() - interval '1 day', now() + interval '13 days',
 null, null, null),

-- 6. Live league invitation: Whitmore (UYFC admin) appoints a board member.
('90000000-0000-4000-8000-000000000006',
 null, 'a0000000-0000-4000-8000-000000000001', 'board', 'newboard@example.com',
 app.hash_secret('seed-live-uyfc-board'),
 'd0000000-0000-4000-8000-000000000006', now() - interval '1 day', now() + interval '13 days',
 null, null, null);

-- The log records the issuance, as it would have if these had gone through
-- app.issue_invite(). Written as the owner, which is what a migration is.
insert into public.auth_events (actor, action, team_id, league_id, subject_email, detail)
select i.issued_by, 'invite_issue', i.team_id, i.league_id, i.email,
       jsonb_build_object('invite', i.id, 'role', i.role, 'expires_at', i.expires_at, 'seeded', true)
  from public.invites i
 order by i.id;

insert into public.auth_events (actor, action, team_id, subject_email, detail)
select i.issued_by, 'invite_revoke', i.team_id, i.email,
       jsonb_build_object('invite', i.id, 'role', i.role, 'seeded', true)
  from public.invites i where i.revoked_at is not null;

-- ---------------------------------------------------------------------------
-- Player words. One row per team, and the primary key is the team -- there is
-- nowhere to write a second team, which is the scoping guarantee.
-- ---------------------------------------------------------------------------

insert into public.player_words (team_id, word_hash, rotated_at, rotated_by, expires_at) values
-- Lehi 8: the word Dom would read out at practice.
('c0000000-0000-4000-8000-000000000001', app.hash_secret('kicker-forty-one'),
 now() - interval '2 days', 'd0000000-0000-4000-8000-000000000001', null),
-- Logan 8, another league. A different word for a different team.
('c0000000-0000-4000-8000-000000000004', app.hash_secret('bear-river-nine'),
 now() - interval '2 days', 'd0000000-0000-4000-8000-000000000007', null),
-- Lehi 7: last season's word, expired. A word with an end date is how a season
-- ends for the boys' page without anybody having to remember to turn it off.
('c0000000-0000-4000-8000-000000000002', app.hash_secret('old-word-seven'),
 now() - interval '400 days', 'd0000000-0000-4000-8000-000000000004', now() - interval '300 days');

insert into public.auth_events (actor, action, team_id, detail)
select w.rotated_by, 'player_word_rotate', w.team_id,
       jsonb_build_object('expires_at', w.expires_at, 'seeded', true)
  from public.player_words w order by w.team_id;

commit;
