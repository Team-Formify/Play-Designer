-- product/db/seed.sql
-- Two leagues that must never see each other, with enough inside them that a
-- missing policy shows up as data rather than as a shrug.
--
-- Deliberate traps for the test suite, so an attack has something to succeed at:
--   * Both Lehi 8th (UYFC) and Logan 8th (CVYFL) carry a play with slug
--     'punt-base'. Two teams, one slug -- that is the UNIQUE (team_id, slug)
--     contract, and a global unique slug would have rejected the second.
--   * Both leagues have a player wearing 22 and a player wearing 55.
--   * Logan carries a player with the non-numeric jersey 'TBD', so a coach of
--     Lehi running `where jersey::int > 0` will ERROR if -- and only if -- the
--     RLS qual was applied after his own qual and rows leaked.
--   * Lehi 8th (2019) is a team on an expired season, with players AND plays,
--     so retention has something to age out and something it must not touch.
--   * One user (the stranger) holds a perfectly valid uuid and no membership.
--
-- Run as the owner/service role. RLS is FORCEd but a superuser bypasses it,
-- which is what a migration role is for -- and is exactly why the test suite
-- refuses to trust this connection and SET ROLEs down into pd_authenticated.

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------------
-- Leagues. Same product, different rulebooks -- which is the point of `ruleset`.
-- ---------------------------------------------------------------------------

insert into public.leagues (id, name, ruleset) values
('a0000000-0000-4000-8000-000000000001', 'UYFC', jsonb_build_object(
  'field_yards', 100,
  'kickoff_from_yard', 40,
  'quarter_minutes', 16,
  'play_clock_seconds', 25,
  'field_goals_allowed', false,
  'min_plays', 10,
  'special_teams_snaps_count', true,
  'min_plays_escalation', jsonb_build_object('trigger_lead', 21, 'q1', 16, 'q2', 13, 'q3', 12),
  'x_man_min_weight_lb', 165,
  'x_man_restricted_to_lines', true,
  'x_man_may_fake_punt', false,
  'conversions', jsonb_build_object('one_point_from', 1.5, 'two_point_from', 3),
  'illegal', jsonb_build_array('pop_up_kick', 'wedge_3', 'blindside_block'),
  'grades', jsonb_build_object(
     '9', jsonb_build_object('field_goals_allowed', true),
     '8', jsonb_build_object('x_man_min_weight_lb', 165),
     '7', jsonb_build_object('x_man_min_weight_lb', 145, 'field_yards', 80)
  ))),
('a0000000-0000-4000-8000-000000000002', 'Cache Valley Youth Football', jsonb_build_object(
  'field_yards', 80,
  'kickoff_from_yard', 35,
  'quarter_minutes', 12,
  'play_clock_seconds', 30,
  'field_goals_allowed', true,          -- a different league, a fifth unit
  'min_plays', 8,
  'special_teams_snaps_count', false,   -- and special teams do not count toward it
  'x_man_min_weight_lb', 155,
  'x_man_restricted_to_lines', true,
  'x_man_may_fake_punt', true,
  'illegal', jsonb_build_array('pop_up_kick'),
  'grades', jsonb_build_object('8', jsonb_build_object('min_plays', 10))));

-- ---------------------------------------------------------------------------
-- Seasons. Retention hangs off ends_on + retain_roster_days.
-- ---------------------------------------------------------------------------

insert into public.seasons (id, league_id, name, starts_on, ends_on, retain_roster_days) values
('b0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001', '2026', '2026-08-01', '2026-11-07', 400),
('b0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000001', '2019', '2019-08-01', '2019-11-02', 400),
('b0000000-0000-4000-8000-000000000003', 'a0000000-0000-4000-8000-000000000002', '2026', '2026-08-15', '2026-11-14', 180);

-- ---------------------------------------------------------------------------
-- Teams
-- ---------------------------------------------------------------------------

insert into public.teams (id, league_id, name, grade, season_id) values
('c0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001', 'Lehi',        '8', 'b0000000-0000-4000-8000-000000000001'),
('c0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000001', 'Lehi',        '7', 'b0000000-0000-4000-8000-000000000001'),
('c0000000-0000-4000-8000-000000000003', 'a0000000-0000-4000-8000-000000000001', 'Lehi',        '8', 'b0000000-0000-4000-8000-000000000002'),
('c0000000-0000-4000-8000-000000000004', 'a0000000-0000-4000-8000-000000000002', 'Logan',       '8', 'b0000000-0000-4000-8000-000000000003'),
('c0000000-0000-4000-8000-000000000005', 'a0000000-0000-4000-8000-000000000002', 'Smithfield',  '8', 'b0000000-0000-4000-8000-000000000003');

-- ---------------------------------------------------------------------------
-- People
--   d..01 Dom      assistant, Lehi 8 (2026) and Lehi 8 (2019)   <- the app's user
--   d..02 Steve    head,      Lehi 8 (2026)
--   d..03 Parent   helper,    Lehi 8 (2026)  -- read only
--   d..04 Kaye     head,      Lehi 7
--   d..05 Reeves   board,     UYFC
--   d..06 Whitmore admin,     UYFC
--   d..07 Ostler   head,      Logan 8        (other league)
--   d..08 Nielsen  head,      Smithfield 8   (other league)
--   d..09 Barlow   board,     Cache Valley
--   d..0a Stranger nothing at all
-- ---------------------------------------------------------------------------

insert into public.memberships (user_id, team_id, role) values
('d0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000001', 'assistant'),
('d0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000003', 'assistant'),
('d0000000-0000-4000-8000-000000000002', 'c0000000-0000-4000-8000-000000000001', 'head'),
('d0000000-0000-4000-8000-000000000003', 'c0000000-0000-4000-8000-000000000001', 'helper'),
('d0000000-0000-4000-8000-000000000004', 'c0000000-0000-4000-8000-000000000002', 'head'),
('d0000000-0000-4000-8000-000000000007', 'c0000000-0000-4000-8000-000000000004', 'head'),
('d0000000-0000-4000-8000-000000000008', 'c0000000-0000-4000-8000-000000000005', 'head');

insert into public.league_memberships (user_id, league_id, role) values
('d0000000-0000-4000-8000-000000000005', 'a0000000-0000-4000-8000-000000000001', 'board'),
('d0000000-0000-4000-8000-000000000006', 'a0000000-0000-4000-8000-000000000001', 'admin'),
('d0000000-0000-4000-8000-000000000009', 'a0000000-0000-4000-8000-000000000002', 'board');

-- ---------------------------------------------------------------------------
-- Roster. Lehi 8 is the real 21 from CLAUDE.md -- name and number, nothing else.
-- ---------------------------------------------------------------------------

insert into public.players (id, team_id, last, first, jersey) values
('e0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000001', 'Archuletta', 'Cree',    '14'),
('e0000000-0000-4000-8000-000000000002', 'c0000000-0000-4000-8000-000000000001', 'Bagley',     'Ledger',  '27'),
('e0000000-0000-4000-8000-000000000003', 'c0000000-0000-4000-8000-000000000001', 'Bearnson',   'Ryker',   '49'),
('e0000000-0000-4000-8000-000000000004', 'c0000000-0000-4000-8000-000000000001', 'Black',      'Brave',   '12'),
('e0000000-0000-4000-8000-000000000005', 'c0000000-0000-4000-8000-000000000001', 'Bullock',    'Tistyn',  null),
('e0000000-0000-4000-8000-000000000006', 'c0000000-0000-4000-8000-000000000001', 'Dalley',     'Caleb',   '17'),
('e0000000-0000-4000-8000-000000000007', 'c0000000-0000-4000-8000-000000000001', 'Debenham',   'Dolan',   '16'),
('e0000000-0000-4000-8000-000000000008', 'c0000000-0000-4000-8000-000000000001', 'Grover',     'Ja''corey','55'),
('e0000000-0000-4000-8000-000000000009', 'c0000000-0000-4000-8000-000000000001', 'Martinez',   'Daxton',  '22'),
('e0000000-0000-4000-8000-00000000000a', 'c0000000-0000-4000-8000-000000000001', 'Mineer',     'Mason',   '47'),
('e0000000-0000-4000-8000-00000000000b', 'c0000000-0000-4000-8000-000000000001', 'Mitchell',   'Cole',    '48'),
('e0000000-0000-4000-8000-00000000000c', 'c0000000-0000-4000-8000-000000000001', 'Pace',       'Kyler',   '10'),
('e0000000-0000-4000-8000-00000000000d', 'c0000000-0000-4000-8000-000000000001', 'Paulich',    'Andrew',  '35'),
('e0000000-0000-4000-8000-00000000000e', 'c0000000-0000-4000-8000-000000000001', 'Prasad',     'Joseph',  '67'),
('e0000000-0000-4000-8000-00000000000f', 'c0000000-0000-4000-8000-000000000001', 'Reary',      'Cache',   '9'),
('e0000000-0000-4000-8000-000000000010', 'c0000000-0000-4000-8000-000000000001', 'Rowley',     'Mason',   '73'),
('e0000000-0000-4000-8000-000000000011', 'c0000000-0000-4000-8000-000000000001', 'Ruelas',     'Jehudiel','74'),
('e0000000-0000-4000-8000-000000000012', 'c0000000-0000-4000-8000-000000000001', 'Scott',      'Rowan',   '99'),
('e0000000-0000-4000-8000-000000000013', 'c0000000-0000-4000-8000-000000000001', 'Severts',    'Cooper',  '34'),
('e0000000-0000-4000-8000-000000000014', 'c0000000-0000-4000-8000-000000000001', 'Steinke',    'Zander',  '33'),
('e0000000-0000-4000-8000-000000000015', 'c0000000-0000-4000-8000-000000000001', 'Wentzel',    'Carter',  '7');

-- Lehi 7 (same league, different team)
insert into public.players (id, team_id, last, first, jersey) values
('e0000000-0000-4000-8000-000000000030', 'c0000000-0000-4000-8000-000000000002', 'Ashby',   'Tate',  '22'),
('e0000000-0000-4000-8000-000000000031', 'c0000000-0000-4000-8000-000000000002', 'Fife',    'Boone', '55'),
('e0000000-0000-4000-8000-000000000032', 'c0000000-0000-4000-8000-000000000002', 'Gundry',  'Ike',   '3');

-- Lehi 8, season 2019 -- aged out, and Dom still coaches this row's playbook
insert into public.players (id, team_id, last, first, jersey) values
('e0000000-0000-4000-8000-000000000040', 'c0000000-0000-4000-8000-000000000003', 'Hutchings', 'Bo',   '11'),
('e0000000-0000-4000-8000-000000000041', 'c0000000-0000-4000-8000-000000000003', 'Isom',      'Wes',  '44');

-- Cache Valley. 'TBD' is not a number, on purpose: see the qual-ordering attack.
insert into public.players (id, team_id, last, first, jersey) values
('e0000000-0000-4000-8000-000000000050', 'c0000000-0000-4000-8000-000000000004', 'Ostler',   'Briggs', '22'),
('e0000000-0000-4000-8000-000000000051', 'c0000000-0000-4000-8000-000000000004', 'Petersen', 'Hank',   '55'),
('e0000000-0000-4000-8000-000000000052', 'c0000000-0000-4000-8000-000000000004', 'Quayle',   'Sam',    'TBD'),
('e0000000-0000-4000-8000-000000000053', 'c0000000-0000-4000-8000-000000000005', 'Nielsen',  'Rex',    '5'),
('e0000000-0000-4000-8000-000000000054', 'c0000000-0000-4000-8000-000000000005', 'Olsen',    'Trey',   '8');

-- ---------------------------------------------------------------------------
-- Consents
-- ---------------------------------------------------------------------------

insert into public.player_consents (player_id, team_id, granted_by, scope, note) values
('e0000000-0000-4000-8000-000000000009', 'c0000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000003', 'roster', 'Martinez guardian, paper form'),
('e0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000003', 'roster', null),
('e0000000-0000-4000-8000-000000000050', 'c0000000-0000-4000-8000-000000000004', 'd0000000-0000-4000-8000-000000000007', 'roster', null);

insert into public.player_consents (player_id, team_id, granted_by, scope, granted_at, revoked_at) values
('e0000000-0000-4000-8000-000000000009', 'c0000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000003', 'film',
 now() - interval '30 days', now() - interval '2 days');

-- ---------------------------------------------------------------------------
-- Plays. `doc` is the app's own play shape, unchanged: players[] with the label,
-- the x/y, the lane and the written job; routes keyed by the doc-local player id
-- (p0, p1 ...), not by the roster uuid -- which is why a roster deletion cannot
-- break a route. `rosterId` is the soft link to public.players, deliberately not
-- a foreign key.
-- ---------------------------------------------------------------------------

insert into public.plays (id, team_id, slug, doc) values
('f0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000001', 'punt-base', jsonb_build_object(
  'slug','punt-base','name','Punt — Base','phase','special','order',1,
  'lineOfScrimmage',190,'lineLabel','LOS',
  'howItWorks','Spread punt, 1-yard splits, punter at 14 yards. Personal protector sits about 2 yards off the midline so the snap lane is clear.',
  'mirrorOf','punt-return-purple',
  'players', jsonb_build_array(
    jsonb_build_object('id','p0','rosterId','e0000000-0000-4000-8000-00000000000d','player','Paulich','jersey','35','label','S','x',210,'y',190,'role','SNAPPER','job','Snap it back to the punter, then get your head up and run straight down the field at the returner.'),
    jsonb_build_object('id','p1','rosterId','e0000000-0000-4000-8000-000000000009','player','Martinez','jersey','22','label','LGD','x',186,'y',190,'role','PROTECT','job','Punch the man over you, count two, then release inside the coverage.'),
    jsonb_build_object('id','p2','rosterId','e0000000-0000-4000-8000-000000000011','player','Ruelas','jersey','74','label','RGD','x',234,'y',190,'role','PROTECT','job','Punch the man over you, count two, then release inside the coverage.'),
    jsonb_build_object('id','p3','rosterId','e0000000-0000-4000-8000-000000000010','player','Rowley','jersey','73','label','LT','x',162,'y',190,'role','PROTECT','job','Nobody crosses your face. Inside gap first.'),
    jsonb_build_object('id','p4','rosterId','e0000000-0000-4000-8000-00000000000b','player','Mitchell','jersey','48','label','RT','x',258,'y',190,'role','PROTECT','job','Nobody crosses your face. Inside gap first.'),
    jsonb_build_object('id','p5','rosterId','e0000000-0000-4000-8000-000000000012','player','Scott','jersey','99','label','LG','x',60,'y',190,'role','GUNNER','job','Beat the jammer and get to the returner before the ball does.'),
    jsonb_build_object('id','p6','rosterId','e0000000-0000-4000-8000-000000000015','player','Wentzel','jersey','7','label','RG','x',360,'y',190,'role','GUNNER','job','Beat the jammer and get to the returner before the ball does.'),
    jsonb_build_object('id','p7','rosterId','e0000000-0000-4000-8000-000000000006','player','Dalley','jersey','17','label','LW','x',138,'y',200,'role','WING','job','Protect first. Once the ball is gone you are the contain man on your side.'),
    jsonb_build_object('id','p8','rosterId','e0000000-0000-4000-8000-000000000013','player','Severts','jersey','34','label','RW','x',282,'y',200,'role','WING','job','Protect first. Once the ball is gone you are the contain man on your side.'),
    jsonb_build_object('id','p9','rosterId','e0000000-0000-4000-8000-000000000001','player','Archuletta','jersey','14','label','PP','x',196,'y',232,'role','PROTECTOR','job','You are the last man. Call the count, take anything that comes free.'),
    jsonb_build_object('id','p10','rosterId','e0000000-0000-4000-8000-00000000000f','player','Reary','jersey','9','label','P','x',210,'y',330,'role','PUNTER','job','Two steps and get it off in 2.1 seconds. Outside leg to the sideline.')),
  'routes', jsonb_build_array(
    jsonb_build_object('playerId','p0','points', jsonb_build_array(jsonb_build_object('x',210,'y',182), jsonb_build_object('x',210,'y',130), jsonb_build_object('x',210,'y',78))),
    jsonb_build_object('playerId','p5','points', jsonb_build_array(jsonb_build_object('x',60,'y',182), jsonb_build_object('x',72,'y',120), jsonb_build_object('x',96,'y',62))),
    jsonb_build_object('playerId','p6','points', jsonb_build_array(jsonb_build_object('x',360,'y',182), jsonb_build_object('x',348,'y',120), jsonb_build_object('x',324,'y',62)))),
  'aim', jsonb_build_object('x',96,'y',56,'label','PUNT — LEFT HASH, INSIDE THE 15','from','P'))),

('f0000000-0000-4000-8000-000000000002', 'c0000000-0000-4000-8000-000000000001', 'punt-villanova-fake', jsonb_build_object(
  'slug','punt-villanova-fake','name','Punt — Villanova Fake','phase','special','order',2,
  'lineOfScrimmage',190,'lineLabel','LOS','mirrorOf','punt-return-purple',
  'howItWorks','Hiked to the protector. Both wings and the whole line flow one way; he shows them the ball going that way and comes out the back door the other side. The punter never touches it.',
  'players', jsonb_build_array(
    jsonb_build_object('id','p0','rosterId','e0000000-0000-4000-8000-00000000000d','player','Paulich','jersey','35','label','S','x',210,'y',190,'role','SNAPPER','job','Snap it to the protector, not the punter. Then sell the punt.'),
    jsonb_build_object('id','p1','rosterId','e0000000-0000-4000-8000-000000000009','player','Martinez','jersey','22','label','LGD','x',186,'y',190,'role','PULL','job','Flow with the line. You are part of the lie.'),
    jsonb_build_object('id','p2','rosterId','e0000000-0000-4000-8000-000000000001','player','Archuletta','jersey','14','label','PP','x',196,'y',232,'role','BALL','job','Show it right, pull it, out the back door left, behind your escort.'),
    jsonb_build_object('id','p3','rosterId','e0000000-0000-4000-8000-00000000000c','player','Pace','jersey','10','label','LW','x',138,'y',200,'role','ESCORT','job','Left sideline. Take the first man who shows.'),
    jsonb_build_object('id','p4','rosterId','e0000000-0000-4000-8000-000000000008','player','Grover','jersey','55','label','RW','x',282,'y',200,'role','ESCORT','job','Right sideline on the mirror call. Take the first man who shows.'),
    jsonb_build_object('id','p5','rosterId','e0000000-0000-4000-8000-00000000000f','player','Reary','jersey','9','label','P','x',210,'y',330,'role','DECOY','job','You never touch it. Sell a punt that is not happening.')),
  'looks', jsonb_build_array(
    jsonb_build_object('id','left','name','Ball left',
      'how','Everything flows right. He comes out the back door left, where Pace leads him up the sideline.',
      'aim', jsonb_build_object('x',38,'y',40,'label','ARCHULETTA — LEFT SIDELINE BEHIND PACE','from',''),
      'routes', jsonb_build_array(jsonb_build_object('playerId','p2','points', jsonb_build_array(jsonb_build_object('x',196,'y',232), jsonb_build_object('x',150,'y',214), jsonb_build_object('x',60,'y',150), jsonb_build_object('x',44,'y',60))))),
    jsonb_build_object('id','right','name','Ball right',
      'how','The mirror. Grover escorts.',
      'aim', jsonb_build_object('x',382,'y',40,'label','ARCHULETTA — RIGHT SIDELINE BEHIND GROVER','from',''),
      'routes', jsonb_build_array(jsonb_build_object('playerId','p2','points', jsonb_build_array(jsonb_build_object('x',196,'y',232), jsonb_build_object('x',270,'y',214), jsonb_build_object('x',360,'y',150), jsonb_build_object('x',376,'y',60)))))))),

('f0000000-0000-4000-8000-000000000003', 'c0000000-0000-4000-8000-000000000002', 'kickoff-spread', jsonb_build_object(
  'slug','kickoff-spread','name','Kickoff — Spread','phase','special','lineOfScrimmage',300,'lineLabel','40',
  'players', jsonb_build_array(
    jsonb_build_object('id','p0','rosterId','e0000000-0000-4000-8000-000000000030','player','Ashby','jersey','22','label','K','x',210,'y',300,'role','SAFETY','job','Kick it, then you are the last man.'),
    jsonb_build_object('id','p1','rosterId','e0000000-0000-4000-8000-000000000031','player','Fife','jersey','55','label','L1','x',186,'y',300,'role','BALL','job','Run to the ball.')),
  'aim', jsonb_build_object('x',96,'y',56,'label','DEEP LEFT CORNER','from','K'))),

-- Same slug, different team, different league. The UNIQUE is (team_id, slug).
('f0000000-0000-4000-8000-000000000004', 'c0000000-0000-4000-8000-000000000004', 'punt-base', jsonb_build_object(
  'slug','punt-base','name','Punt (Logan)','phase','special','lineOfScrimmage',190,'lineLabel','LOS',
  'howItWorks','Cache Valley runs it from a tight punt.',
  'players', jsonb_build_array(
    jsonb_build_object('id','p0','rosterId','e0000000-0000-4000-8000-000000000050','player','Ostler','jersey','22','label','S','x',210,'y',190,'role','SNAPPER','job','Snap and cover.'),
    jsonb_build_object('id','p1','rosterId','e0000000-0000-4000-8000-000000000051','player','Petersen','jersey','55','label','P','x',210,'y',326,'role','PUNTER','job','Get it off.')),
  'aim', jsonb_build_object('x',96,'y',56,'label','PUNT — LEFT HASH','from','P'))),

('f0000000-0000-4000-8000-000000000005', 'c0000000-0000-4000-8000-000000000005', 'kick-return-5-2-2-2', jsonb_build_object(
  'slug','kick-return-5-2-2-2','name','Kick Return — 5-2-2-2','phase','special','lineOfScrimmage',120,'lineLabel','KR',
  'players', jsonb_build_array(
    jsonb_build_object('id','p0','rosterId','e0000000-0000-4000-8000-000000000053','player','Nielsen','jersey','5','label','H1','x',150,'y',120,'role','HANDS','job','Catch it if it comes short.'),
    jsonb_build_object('id','p1','rosterId','e0000000-0000-4000-8000-000000000054','player','Olsen','jersey','8','label','LR','x',180,'y',60,'role','RETURNER','job','Catch it and get to the wall.')))),

-- The 2019 book. Its roster will age out; this play must still be here after.
('f0000000-0000-4000-8000-000000000006', 'c0000000-0000-4000-8000-000000000003', 'punt-base', jsonb_build_object(
  'slug','punt-base','name','Punt — Base (2019)','phase','special','lineOfScrimmage',190,'lineLabel','LOS',
  'howItWorks','Kept because a playbook is worth more than the roster that ran it.',
  'players', jsonb_build_array(
    jsonb_build_object('id','p0','rosterId','e0000000-0000-4000-8000-000000000040','player','Hutchings','jersey','11','label','S','x',210,'y',190,'role','SNAPPER','job','Snap and cover.'),
    jsonb_build_object('id','p1','rosterId','e0000000-0000-4000-8000-000000000041','player','Isom','jersey','44','label','P','x',210,'y',330,'role','PUNTER','job','Get it off in 2.1.'))));

commit;
