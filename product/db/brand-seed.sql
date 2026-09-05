-- product/db/brand-seed.sql
-- Two real brand records, and the three states of the fallback chain.
--
-- Load order: migrations/0002_schema.sql -> migrations/0003_rls.sql -> migrations/0004_auth.sql -> migrations/0005_platform.sql -> migrations/0006_brand.sql
--             -> seed.sql -> auth-seed.sql -> platform-seed.sql -> brand-seed.sql
--
-- WHAT IS IN HERE, AND WHY EXACTLY THIS
--
--   teams.brand   on Lehi 8 (2026)      = the `lehi` record from
--                 product/brand/brands.json, VERBATIM. Its colours are taken
--                 from designer.html's own :root and PAL_SCREEN, so it is the
--                 proof that theming cost the existing look nothing -- and,
--                 loaded through the trigger in migrations/0006_brand.sql, it is also the proof
--                 that our own reference palette clears the WCAG floors we are
--                 about to hold customers to. If this file ever fails to load,
--                 that is a finding about our theme, not a reason to lower a
--                 floor.
--
--   leagues.brand on Cache Valley       = the `willow-creek` record, verbatim.
--                 A light theme, so the fixture is not two variations on one
--                 dark green, and sitting on a LEAGUE so the middle link of the
--                 chain has something to resolve to.
--
-- Those two rows give all three states of app.team_brand() from the seed alone:
--
--   c..01  Lehi 8 (2026)   -> its OWN brand          (source 'team')
--   c..02  Lehi 7          -> UYFC has none either   (source 'default')
--   c..03  Lehi 8 (2019)   -> UYFC has none either   (source 'default')
--   c..04  Logan 8         -> Cache Valley's brand   (source 'league')
--   c..05  Smithfield 8    -> Cache Valley's brand   (source 'league')
--
-- UYFC is deliberately left UNBRANDED. It is the league the suite's admin runs,
-- so leaving it blank means test-brand.sql can watch a league go from default
-- to branded inside its own rolled-back transaction, rather than asserting
-- against a value the seed already put there.
--
-- WHAT THIS FILE DELIBERATELY DOES NOT DO
-- It adds no league, no season, no team, no player, no play, no invitation, no
-- membership and no platform row. It writes two columns on rows that already
-- exist. test-isolation.sql asserts exact counts of all of those (31 players,
-- 6 plays, 7 memberships, 3 board seats, 23 visible to Dom, 26 to the board),
-- test-auth.sql and test-platform.sql add their own on top, and all 678 of them
-- have to keep passing with this file loaded.
--
-- These are UPDATEs and not INSERTs on purpose: a brand belongs to a tenant
-- that already exists, and a seed that created its own league to hang a colour
-- on would move every count in three other suites.

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------------
-- Lehi Youth Football -- the reference palette, on the team that runs it.
-- Verbatim from product/brand/brands.json. Do not "tidy" the values: the point
-- of this record is that it is byte-for-byte what designer.html already paints.
-- ---------------------------------------------------------------------------

update public.teams
   set brand = jsonb_build_object(
     'id',        'lehi',
     'name',      'Lehi Youth Football',
     'shortName', 'Lehi',
     'scheme',    'dark',
     'colors', jsonb_build_object(
       'page',   '#13251F',
       'board',  '#1D3A31',
       'deep',   '#0D1B16',
       'chalk',  '#EDEBE0',
       'soft',   '#9AA69C',
       'accent', '#E3B547',
       'warm',   '#E58A6B'),
     'field', jsonb_build_object(
       'grass',      '#1D3A31',
       'chalk',      '#EDEBE0',
       'line',       '#E3B547',
       'plate',      '#13251F',
       'hot',        '#E58A6B',
       'circleFill', 'rgba(19,37,31,.55)',
       'routeFill',  'rgba(227,181,71,.28)',
       'stroke',     2,
       'gridOp',     0.09,
       'hashOp',     0.2,
       'sideOp',     0.3,
       'themOp',     0.42,
       'chipOp',     0.82,
       'losChipOp',  0.72,
       'leadOp',     0.42,
       'aimOp',      0.85),
     'wordmark', jsonb_build_object('text', 'Play Designer', 'accent', 'Designer'),
     'mark',     jsonb_build_object('initials', 'LHI', 'shape', 'shield'),
     'fonts',    jsonb_build_object('body', 'system', 'mono', 'mono', 'display', 'condensed'))
 where id = 'c0000000-0000-4000-8000-000000000001';

-- ---------------------------------------------------------------------------
-- The second club, on the second league. Light theme, crimson accent, slab
-- display face -- chosen because a light theme is where the naive rules break:
-- the same hairline alpha that reads on dark green collapses to 1.01:1 on a
-- white button, and "dark accent means light text" picks the wrong ink on
-- crimson and lands at 1.85:1. brand.js already solves both; this row is what
-- makes the database agree.
-- ---------------------------------------------------------------------------

update public.leagues
   set brand = jsonb_build_object(
     'id',        'willow-creek',
     'name',      'Willow Creek Junior Football',
     'shortName', 'Willow Creek',
     'scheme',    'light',
     'colors', jsonb_build_object(
       'page',   '#F3F1E9',
       'board',  '#FFFFFF',
       'deep',   '#FFFFFF',
       'chalk',  '#17211C',
       'soft',   '#4E5A53',
       'accent', '#8E1B2E',
       'warm',   '#0F5C74'),
     'field', jsonb_build_object(
       'grass',      '#E7EEE2',
       'chalk',      '#1B2A22',
       'line',       '#8E1B2E',
       'plate',      '#FFFFFF',
       'hot',        '#0F5C74',
       'circleFill', 'rgba(255,255,255,.82)',
       'routeFill',  'rgba(142,27,46,.16)',
       'stroke',     2,
       'gridOp',     0.16,
       'hashOp',     0.3,
       'sideOp',     0.45,
       'themOp',     0.5,
       'chipOp',     0.92,
       'losChipOp',  0.88,
       'leadOp',     0.5,
       'aimOp',      0.9),
     'wordmark', jsonb_build_object('text', 'Willow Creek Football', 'accent', 'Football'),
     'mark',     jsonb_build_object('initials', 'WC', 'shape', 'disc'),
     'fonts',    jsonb_build_object('body', 'system', 'mono', 'mono', 'display', 'slab'))
 where id = 'a0000000-0000-4000-8000-000000000002';

-- ---------------------------------------------------------------------------
-- Load-time proof. Both rows went through app.brand_readable_guard() on the way
-- in, so reaching here at all means both palettes cleared all seventeen checks
-- on screen and in print. These two asserts are belt and braces: they catch the
-- case where a future edit makes the column nullable-by-accident or the UPDATE
-- matches no row, which would otherwise be a silent no-op.
-- ---------------------------------------------------------------------------

do $$
declare n int;
begin
  select count(*) into n from public.teams
   where id = 'c0000000-0000-4000-8000-000000000001' and brand ->> 'id' = 'lehi';
  if n <> 1 then raise exception 'brand-seed: the lehi brand did not land on Lehi 8'; end if;

  select count(*) into n from public.leagues
   where id = 'a0000000-0000-4000-8000-000000000002' and brand ->> 'id' = 'willow-creek';
  if n <> 1 then raise exception 'brand-seed: the willow-creek brand did not land on Cache Valley'; end if;

  select count(*) into n from public.teams where brand is not null;
  if n <> 1 then raise exception 'brand-seed: expected exactly one branded team, found %', n; end if;

  select count(*) into n from public.leagues where brand is not null;
  if n <> 1 then raise exception 'brand-seed: expected exactly one branded league, found %', n; end if;

  raise notice 'brand-seed: 2 palettes stored, both cleared the contrast floors on the way in';
end $$;

commit;
