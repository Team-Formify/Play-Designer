-- product/db/test-brand.sql
-- The adversarial suite for brand.sql. Same house rules as test-isolation.sql,
-- test-auth.sql and test-platform.sql, because the same three things are being
-- proved: that authority is what we said it is, that isolation did not widen,
-- and that the guard which refuses a bad write actually refuses it.
--
-- RUN:
--   node product/db/test.mjs brand
--
-- That builds pd_brand from product/db/migrations/ via the migration runner and
-- applies the seeds in order, then runs this file. The hand-ordered list of
-- -f flags that used to live here was wrong twice and is now in test.mjs,
-- executed rather than described.
--
-- Against a database you have already built:
--   psql -h /tmp -p 5433 -U app -d pd_brand -f product/db/test-brand.sql
--
-- Everything runs inside one transaction and ROLLS BACK, so the suite is
-- rerunnable and leaves the seed untouched. No SAVEPOINTs, for the same reason
-- the other three files have none: rolling back to one would roll back the
-- results table with it.
--
-- HOUSE RULES, inherited:
--   (a) Every refusal is paired with a CONTROL run as the bypassing owner,
--       proving the row was really there to be taken. A refusal whose control
--       returns 0 is a broken test, not a pass.
--   (b) Attacks address the other tenant's rows by literal uuid. A subselect
--       would return NULL under RLS and the attack would "pass" by asking
--       about nothing.
--   (c) Section 11 briefly DROPS the guard trigger and ADDS a permissive
--       policy, and shows the identical statements succeeding, so nobody has to
--       take the refusals on faith.
--
-- THE CLAIM THIS FILE TESTS, IN ONE SENTENCE. A club's colours resolve the same
-- way for every client, only the people who already run a tenant can change
-- them, nobody can change anybody else's, the database refuses a palette a
-- human cannot read and says which pair failed and by how much, and none of it
-- gives the platform owner one row it did not already have.
--
-- WHAT THIS FILE CANNOT PROVE. Stated here rather than buried:
--   * That the palette in section 7 is still what product/brand/brands.json
--     says. A SQL suite cannot read a file in the repo (pg_read_file is
--     superuser-only and rooted at the data directory), so the record is copied
--     into this file by hand and asserted equal to the one brand-seed.sql
--     copied. That catches the seed and the test drifting apart; it does not
--     catch both of them drifting from brands.json. The out-of-band check is
--     running Brand.audit() in node over brands.json, which is what
--     product/test/test-brand.js is for.
--   * That the GUCs were stamped honestly. app.user_id -> auth.uid() is the
--     same assumption the other three suites already rest on.
--   * That a colour a human calls "our club colour" is the colour in the
--     record. The database can say a palette is legible; it cannot say it is
--     the right one.
--   * Anything about how the browser paints. Contrast is arithmetic and is
--     checked here; whether a 12px label in that colour is actually readable at
--     arm's length on a phone in July sun is a screenshot, not a query.

\set ON_ERROR_STOP on
\timing off
\pset pager off

begin;

-- ===========================================================================
-- Harness -- identical in shape to the other three suites
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

-- The refusal this file exists for has to NAME the failing pair, so a test that
-- only checks the SQLSTATE would pass on "invalid brand" -- which is exactly
-- the message that sends a volunteer coach back to guessing. This asserts the
-- state AND that the message carries the needle.
create function t.raises_like(p_name text, p_sql text, p_state text, p_needle text) returns void
language plpgsql as $fn$
begin
  execute p_sql;
  perform t.note(p_name, false, format('LEAK: statement succeeded, expected SQLSTATE %s', p_state));
exception when others then
  perform t.note(p_name, sqlstate = p_state and position(p_needle in sqlerrm) > 0,
    format('SQLSTATE %s (want %s), message %s %s: %s',
           sqlstate, p_state,
           case when position(p_needle in sqlerrm) > 0 then 'names' else 'DOES NOT NAME' end,
           quote_literal(p_needle), left(sqlerrm, 150)));
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

-- A call that is supposed to WORK. The other suites use t.val for this; a
-- setter returns the record it stored, and what matters is that it did not
-- raise and that the id landed.
create function t.sets(p_name text, p_sql text, p_want_id text) returns void
language plpgsql as $fn$
declare got jsonb;
begin
  execute p_sql into got;
  perform t.note(p_name, (got ->> 'id') is not distinct from p_want_id,
    format('stored brand id %s, want %s', coalesce(quote_literal(got ->> 'id'), 'NULL'),
           coalesce(quote_literal(p_want_id), 'NULL')));
exception when others then
  perform t.note(p_name, false, format('REFUSED %s: %s', sqlstate, left(sqlerrm, 110)));
end $fn$;

create table t.state (k text primary key, v text);
grant select, insert, update, delete on t.state to public;

create function t.be(p_user uuid, p_email text default null) returns void
language plpgsql as $fn$
begin
  perform set_config('app.user_id',    coalesce(p_user::text, ''), false);
  perform set_config('app.user_email', coalesce(p_email, ''), false);
end $fn$;

-- ---------------------------------------------------------------------------
-- The fixtures. Held as functions rather than inline literals so an attack and
-- its control are provably the same palette, and so a bad record cannot be
-- quietly mistyped into a good one.
-- ---------------------------------------------------------------------------

-- The reference palette, copied by hand from product/brand/brands.json. Section
-- 7 asserts it is identical to the one brand-seed.sql stored, which is what
-- keeps the two hand-copies honest with each other.
create function t.brand_lehi() returns jsonb language sql immutable as $fn$
  select '{
    "id": "lehi",
    "name": "Lehi Youth Football",
    "shortName": "Lehi",
    "scheme": "dark",
    "colors": {
      "page": "#13251F", "board": "#1D3A31", "deep": "#0D1B16",
      "chalk": "#EDEBE0", "soft": "#9AA69C",
      "accent": "#E3B547", "warm": "#E58A6B"
    },
    "field": {
      "grass": "#1D3A31", "chalk": "#EDEBE0", "line": "#E3B547",
      "plate": "#13251F", "hot": "#E58A6B",
      "circleFill": "rgba(19,37,31,.55)", "routeFill": "rgba(227,181,71,.28)",
      "stroke": 2, "gridOp": 0.09, "hashOp": 0.2, "sideOp": 0.3,
      "themOp": 0.42, "chipOp": 0.82, "losChipOp": 0.72,
      "leadOp": 0.42, "aimOp": 0.85
    },
    "wordmark": { "text": "Play Designer", "accent": "Designer" },
    "mark": { "initials": "LHI", "shape": "shield" },
    "fonts": { "body": "system", "mono": "mono", "display": "condensed" }
  }'::jsonb
$fn$;

-- A real, loud, PASSING palette that is nowhere in the fixture yet, so the
-- accept path is not just "the thing that was already there".
create function t.brand_ridgeline() returns jsonb language sql immutable as $fn$
  select '{
    "id": "ridgeline",
    "name": "Ridgeline Raptors",
    "shortName": "Ridgeline",
    "scheme": "dark",
    "colors": {
      "page": "#0C0716", "board": "#241548", "deep": "#150C2A",
      "chalk": "#FFFFFF", "soft": "#BFB2E6",
      "accent": "#D8FF3E", "warm": "#FF4FA3"
    },
    "field": {
      "grass": "#241548", "chalk": "#FFFFFF", "line": "#D8FF3E",
      "plate": "#0C0716", "hot": "#FF4FA3",
      "circleFill": "rgba(12,7,22,.62)", "routeFill": "rgba(216,255,62,.3)",
      "stroke": 2.2, "gridOp": 0.12, "hashOp": 0.24, "sideOp": 0.38,
      "themOp": 0.46, "chipOp": 0.86, "losChipOp": 0.78,
      "leadOp": 0.45, "aimOp": 0.9
    },
    "wordmark": { "text": "Ridgeline Raptors", "accent": "Raptors" },
    "mark": { "initials": "RR", "shape": "chevron" },
    "fonts": { "body": "grotesk", "mono": "mono", "display": "condensed" }
  }'::jsonb
$fn$;

-- Six hex codes and a name -- the whole onboarding story. Everything else is
-- derived. This is the record a new club actually sends.
create function t.brand_six_codes() returns jsonb language sql immutable as $fn$
  select '{
    "id": "harbor", "name": "Harbor City Youth Football", "shortName": "Harbor",
    "colors": { "page": "#101A24", "board": "#17293A", "deep": "#0A1119",
                "chalk": "#E8EEF4", "soft": "#9BAFC0",
                "accent": "#F0A830", "warm": "#EF7B6B" }
  }'::jsonb
$fn$;

-- THE YELLOW THAT VANISHES ON GRASS. The brief's own example: chrome that is
-- perfectly fine -- every one of the six UI checks passes -- with a field a
-- coach cannot read. This is what makes the guard worth having: a client-side
-- colour picker showing swatches would look completely reasonable.
create function t.brand_vanishing() returns jsonb language sql immutable as $fn$
  select '{
    "id": "vanishing-yellow", "name": "Meadow Falls",
    "colors": { "page": "#13251F", "board": "#1D3A31", "deep": "#0D1B16",
                "chalk": "#EDEBE0", "soft": "#9AA69C",
                "accent": "#E3B547", "warm": "#E58A6B" },
    "field": { "grass": "#8FA86B", "chalk": "#EDEBE0", "line": "#E3B547",
               "plate": "#13251F", "hot": "#E58A6B" }
  }'::jsonb
$fn$;

-- NAVY ON NAVY. The other half of the brief: a club whose colours are all one
-- colour. Every check fails, including the ones a designer would never look at.
create function t.brand_navy() returns jsonb language sql immutable as $fn$
  select '{
    "id": "navy-on-navy", "name": "Navy Youth Football",
    "colors": { "page": "#101C33", "board": "#132038", "deep": "#0C1626",
                "chalk": "#1B2A4A", "soft": "#1B2A4A",
                "accent": "#16305A", "warm": "#16305A" }
  }'::jsonb
$fn$;

-- Legible everywhere except the one place that matters most: the position
-- label inside the player circle. Nothing else fails. If the audit only checked
-- "text on background" and not the composited circle fill, this would pass.
create function t.brand_label_only() returns jsonb language sql immutable as $fn$
  select jsonb_set(t.brand_lehi(), '{field,line}', '"#8FA05A"')
$fn$;

-- A font that is a URL. brand.js warns and falls back; the column refuses.
create function t.brand_webfont() returns jsonb language sql immutable as $fn$
  select jsonb_set(t.brand_lehi(), '{fonts,display}',
                   '"https://fonts.example.com/Clubface.woff2"')
$fn$;

grant execute on all functions in schema t to public;

-- ===========================================================================
-- 0. CONTROL -- what the brand layer starts with, seen by the bypassing owner
-- ===========================================================================
select set_config('t.sect', '0 control', false);
\echo '=== 0. What the brand layer starts with (owner, RLS bypassed) ==='

select (select count(*) from public.teams   where brand is not null) as branded_teams,
       (select count(*) from public.leagues where brand is not null) as branded_leagues,
       (select count(*) from public.teams)                           as teams,
       (select count(*) from public.leagues)                         as leagues;

select t.name || ' ' || t.grade as team,
       app.team_brand_source(t.id)      as source,
       app.team_brand(t.id) ->> 'id'    as shows,
       app.team_brand(t.id) -> 'field' ->> 'grass' as grass
  from public.teams t order by t.id;

select t.control('a branded team exists to inherit from',
  $q$select 1 from public.teams where brand is not null$q$, 1);
select t.control('a branded league exists to inherit from',
  $q$select 1 from public.leagues where brand is not null$q$, 1);
select t.control('unbranded teams exist to fall back',
  $q$select 1 from public.teams where brand is null$q$, 4);

-- The seed loaded, which means both palettes went through the guard trigger.
select t.val('the reference palette is stored on the team that runs it',
  $q$select brand->>'id' from public.teams where id='c0000000-0000-4000-8000-000000000001'$q$, 'lehi');
select t.val('the second club is stored on the second league',
  $q$select brand->>'id' from public.leagues where id='a0000000-0000-4000-8000-000000000002'$q$, 'willow-creek');
select t.val('and the league the suite will brand is deliberately blank',
  $q$select coalesce(brand->>'id','<none>') from public.leagues where id='a0000000-0000-4000-8000-000000000001'$q$, '<none>');

-- The columns are additive: nothing that existed before this file has a brand.
select t.val('every other team is unbranded',
  $q$select count(*)::text from public.teams where brand is null$q$, '4');
select t.val('every other league is unbranded',
  $q$select count(*)::text from public.leagues where brand is null$q$, '1');

-- ===========================================================================
-- 1. The maths -- the database and brand.js agree, or the feature is a lie
-- ===========================================================================
-- Every number on the right of these was produced by running Brand.audit() and
-- Brand.contrast() in node over product/brand/brands.json. If a check here goes
-- red, the client and the database have drifted and a coach can be told his
-- palette is fine by one and refused by the other.
select set_config('t.sect', '1 wcag maths', false);
\echo '=== 1. The WCAG maths matches product/brand/brand.js ==='

select t.val('luminance of white is 1',  $q$select app.brand_luminance(app.brand_rgb('#FFFFFF'))::text$q$, '1');
select t.val('luminance of black is 0',  $q$select app.brand_luminance(app.brand_rgb('#000000'))::text$q$, '0');
select t.val('white on black is 21:1',   $q$select round(app.brand_contrast('#FFFFFF','#000000')::numeric,2)::text$q$, '21.00');
select t.val('a colour against itself is 1:1',
  $q$select round(app.brand_contrast('#8E1B2E','#8E1B2E')::numeric,2)::text$q$, '1.00');

-- The parser takes every form brand.js takes.
select t.val('short hex expands',       $q$select array_to_string(app.brand_rgb('#abc'),',')$q$, '170,187,204,1');
select t.val('eight-digit hex carries its alpha',
  $q$select round(app.brand_rgb('#13251F8C')[4]::numeric,3)::text$q$, '0.549');
select t.val('rgba() with a bare decimal',
  $q$select array_to_string(app.brand_rgb('rgba(19,37,31,.55)'),',')$q$, '19,37,31,0.55');
select t.val('rgb() with the CSS4 slash',
  $q$select array_to_string(app.brand_rgb('rgb(19 37 31 / .55)'),',')$q$, '19,37,31,0.55');
select t.val('a colour name is not a colour',
  $q$select coalesce(array_to_string(app.brand_rgb('navy'),','),'NULL')$q$, 'NULL');
select t.val('and neither is a URL',
  $q$select coalesce(array_to_string(app.brand_rgb('https://example.com/blue.png'),','),'NULL')$q$, 'NULL');

-- Half-up, not banker's. The printed sideline composites to exactly 127.5, so
-- round() on double precision would be one grey level out on some builds.
select t.val('black at 50% over white rounds half UP, like Math.round',
  $q$select app.brand_hex(app.brand_over(app.brand_rgb('#000000'), app.brand_rgb('#FFFFFF'), 0.5))$q$, '#808080');
select t.val('the derived board matches brand.js mix()',
  $q$select app.brand_mix('#13251F','#FFFFFF',0.06)$q$, '#21322c');

-- The three floors, from Brand.MIN.
select t.val('the text floor is 4.5',    $q$select app.brand_floor('text')::text$q$, '4.5');
select t.val('the graphic floor is 3',   $q$select app.brand_floor('graphic')::text$q$, '3');
select t.val('the faint floor is 1.6',   $q$select app.brand_floor('faint')::text$q$, '1.6');

-- Seventeen checks, the same ids brand.js has.
select t.val('the audit runs seventeen checks',
  $q$select count(*)::text from app.brand_audit(t.brand_lehi(), false)$q$, '17');
select t.val('and they are the same seventeen brand.js has',
  $q$select string_agg(check_id, ',' order by check_id) from app.brand_audit(t.brand_lehi(), false)$q$,
  'chalk-on-grass,circle-edge,collision-on-grass,label-on-circle,los-label,name-on-chip,route-on-grass,sideline-on-grass,them-on-grass,ui-accent,ui-accent-button,ui-border,ui-button,ui-muted,ui-text,ui-warm');

-- Spot values against node, including the two composited ones.
select t.val('lehi chalk-on-grass is 10.32:1',
  $q$select ratio::text from app.brand_audit(t.brand_lehi(),false) where check_id='chalk-on-grass'$q$, '10.32');
select t.val('lehi label-on-circle is 7.49:1 over the composited circle #182e27',
  $q$select ratio::text||' on '||bg from app.brand_audit(t.brand_lehi(),false) where check_id='label-on-circle'$q$,
  '7.49 on #182e27');
select t.val('lehi them-on-grass composites the 0.42 alpha first',
  $q$select fg||' '||ratio::text from app.brand_audit(t.brand_lehi(),false) where check_id='them-on-grass'$q$,
  '#74847b 3.14');

-- The accent-ink rule. "Dark accent means light text" is the obvious rule and
-- it is wrong; brand.js picks whichever surface the brand already owns actually
-- reads on the accent, and so does this.
select t.val('the naive ink on willow-creek crimson would be 1.85:1',
  $q$select round(app.brand_contrast('#17211C','#8E1B2E')::numeric,2)::text$q$, '1.85');
select t.val('the ink actually chosen is white at 8.95:1',
  $q$select fg||' '||ratio::text from app.brand_audit(
       (select brand from public.leagues where id='a0000000-0000-4000-8000-000000000002'), false)
     where check_id='ui-accent-button'$q$, '#ffffff 8.95');

-- Print is not per-brand and is not overridable.
select t.val('print is the same black on white for the dark brand',
  $q$select string_agg(distinct fg||'/'||bg, ',') from app.brand_audit(t.brand_lehi(), true)
     where check_id in ('chalk-on-grass','route-on-grass')$q$, '#000000/#ffffff');
select t.val('and for the loud one',
  $q$select string_agg(distinct fg||'/'||bg, ',') from app.brand_audit(t.brand_ridgeline(), true)
     where check_id in ('chalk-on-grass','route-on-grass')$q$, '#000000/#ffffff');
select t.val('the printed sideline is the 127.5 case, and it is #808080 at 3.98:1',
  $q$select fg||' '||ratio::text from app.brand_audit(t.brand_lehi(), true)
     where check_id='sideline-on-grass'$q$, '#808080 3.98');

-- ===========================================================================
-- 2. The fallback chain -- all three states, one resolver
-- ===========================================================================
select set_config('t.sect', '2 fallback', false);
\echo '=== 2. team brand, else league brand, else the product default ==='
set role pd_authenticated;

-- (a) The team has its own.
select t.be('d0000000-0000-4000-8000-000000000002', 'steve@example.com');
select t.val('a team with its own brand shows its own',
  $q$select app.team_brand('c0000000-0000-4000-8000-000000000001')->>'id'$q$, 'lehi');
select t.val('and says so',
  $q$select app.team_brand_source('c0000000-0000-4000-8000-000000000001')$q$, 'team');
select t.val('its field grass is the club''s, not the product''s',
  $q$select app.team_brand('c0000000-0000-4000-8000-000000000001')->'field'->>'grass'$q$, '#1D3A31');

-- (b) The team has none; the league does.
select t.be('d0000000-0000-4000-8000-000000000007', 'ostler@example.com');
select t.val('a team with no brand inherits its league''s',
  $q$select app.team_brand('c0000000-0000-4000-8000-000000000004')->>'id'$q$, 'willow-creek');
select t.val('and says so',
  $q$select app.team_brand_source('c0000000-0000-4000-8000-000000000004')$q$, 'league');
-- The sibling is the interesting case, and the original expectation here was
-- written without asking WHO is looking. app.team_brand() is SECURITY INVOKER
-- on purpose — its own comment says a team you cannot see must resolve to the
-- default rather than leak another tenant's colours. This seat is a coach of
-- team 0004 and is NOT a member of 0005, so the default is the CORRECT answer
-- and 'willow-creek' would have been the bug. Assert the security property.
select t.val('a coach cannot resolve the brand of a team he is not on',
  $q$select app.team_brand('c0000000-0000-4000-8000-000000000005')->>'id'$q$, 'product');
select t.val('and it does not even tell him a league answered',
  $q$select app.team_brand_source('c0000000-0000-4000-8000-000000000005')$q$, 'default');

-- (c) Neither has one.
select t.be('d0000000-0000-4000-8000-000000000004', 'kaye@example.com');
select t.val('a team whose league is unbranded gets the product default',
  $q$select app.team_brand('c0000000-0000-4000-8000-000000000002')->>'id'$q$, 'product');
select t.val('and says so',
  $q$select app.team_brand_source('c0000000-0000-4000-8000-000000000002')$q$, 'default');
select t.val('the product default is nobody''s club',
  $q$select app.brand_default()->>'name'$q$, 'Play Designer');
select t.val('and it is itself legible -- no failing check',
  $q$select count(*)::text from app.brand_audit(app.brand_default(), false) where not pass$q$, '0');

-- The resolver always returns a WHOLE record, whichever link answered, so no
-- client has to test for a missing key.
select t.be('d0000000-0000-4000-8000-000000000002', 'steve@example.com');
select t.val('every resolved brand carries every slot',
  $q$select (app.team_brand('c0000000-0000-4000-8000-000000000002') ?& array[
       'id','name','shortName','scheme','colors','field','wordmark','mark','fonts'])::text$q$, 'true');
select t.val('including a field derived from the chrome',
  $q$select (app.team_brand('c0000000-0000-4000-8000-000000000002')->'field' ?& array[
       'grass','chalk','line','plate','hot','circleFill','routeFill','stroke',
       'gridOp','hashOp','sideOp','themOp','chipOp','losChipOp','leadOp','aimOp'])::text$q$, 'true');
-- Fonts are NAMES, not stacks. A stack would not survive a second pass through
-- Brand.normalize(), which is the one deliberate difference from brand.js.
select t.val('fonts come back as names, so the record round-trips',
  $q$select app.team_brand('c0000000-0000-4000-8000-000000000001')->'fonts'->>'display'$q$, 'condensed');

-- A team the caller cannot see is not a hole in the chain -- it is the default.
select t.val('a UYFC coach resolving a Cache Valley team gets the default, not their colours',
  $q$select app.team_brand('c0000000-0000-4000-8000-000000000004')->>'id'$q$, 'product');
select t.val('and cannot even learn that they HAVE a brand',
  $q$select app.team_brand_source('c0000000-0000-4000-8000-000000000004')$q$, 'default');
select t.control('CONTROL: they really do have one',
  $q$select 1 from public.leagues where id='a0000000-0000-4000-8000-000000000002' and brand is not null$q$, 0);
reset role;
select t.control('CONTROL as owner: Cache Valley really is branded',
  $q$select 1 from public.leagues where id='a0000000-0000-4000-8000-000000000002' and brand is not null$q$, 1);
set role pd_authenticated;

-- An anonymous session resolves to the default and learns nothing.
select t.be(null, null);
reset role; set role pd_anon;
select t.val('an anonymous session gets the product default for a branded team',
  $q$select app.team_brand('c0000000-0000-4000-8000-000000000001')->>'id'$q$, 'product');
reset role;

-- ===========================================================================
-- 3. A head coach brands HIS team -- and only his
-- ===========================================================================
select set_config('t.sect', '3 head coach', false);
\echo '=== 3. A head coach brands his own team and no other ==='
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000002', 'steve@example.com');

select t.sets('the head coach brands his own team',
  $q$select app.set_team_brand('c0000000-0000-4000-8000-000000000001', t.brand_ridgeline())$q$, 'ridgeline');
select t.val('and the resolver shows it immediately',
  $q$select app.team_brand('c0000000-0000-4000-8000-000000000001')->>'id'$q$, 'ridgeline');

-- Another team IN HIS OWN LEAGUE is the sharper test: same tenant boundary at
-- the league level, different team.
select t.raises('he cannot brand another team in his own league',
  $q$select app.set_team_brand('c0000000-0000-4000-8000-000000000002', t.brand_ridgeline())$q$, '42501');
select t.raises('nor a team in another league',
  $q$select app.set_team_brand('c0000000-0000-4000-8000-000000000004', t.brand_ridgeline())$q$, '42501');
select t.raises('nor the league he plays in',
  $q$select app.set_league_brand('a0000000-0000-4000-8000-000000000001', t.brand_ridgeline())$q$, '42501');

-- The column is not open for writing even to the man who may set it by function.
select t.blocked('he cannot write the column directly either',
  $q$update public.teams set brand = t.brand_ridgeline()
      where id='c0000000-0000-4000-8000-000000000002'$q$);
select t.blocked('and cannot reach a league row at all',
  $q$update public.leagues set brand = t.brand_ridgeline()
      where id='a0000000-0000-4000-8000-000000000001'$q$);

-- Clearing falls back up the chain. This is the only "delete" in the feature
-- and it removes a colour, nothing else.
select t.val('clearing his brand returns NULL',
  $q$select coalesce(app.set_team_brand('c0000000-0000-4000-8000-000000000001', null)::text, 'NULL')$q$, 'NULL');
select t.val('and the team falls back to the product default',
  $q$select app.team_brand('c0000000-0000-4000-8000-000000000001')->>'id'$q$, 'product');
select t.val('clearing a brand removed no play',
  $q$select count(*)::text from public.plays where team_id='c0000000-0000-4000-8000-000000000001'$q$, '4');
select t.sets('and he can put the reference palette back',
  $q$select app.set_team_brand('c0000000-0000-4000-8000-000000000001', t.brand_lehi())$q$, 'lehi');

-- The other head coach, from the other end.
select t.be('d0000000-0000-4000-8000-000000000004', 'kaye@example.com');
select t.sets('the OTHER head coach brands HIS team',
  $q$select app.set_team_brand('c0000000-0000-4000-8000-000000000002', t.brand_ridgeline())$q$, 'ridgeline');
select t.raises('and cannot touch the first one',
  $q$select app.set_team_brand('c0000000-0000-4000-8000-000000000001', t.brand_ridgeline())$q$, '42501');
select t.val('the first team''s brand did not move',
  $q$select app.team_brand('c0000000-0000-4000-8000-000000000001')->>'id'$q$, 'lehi');

-- A head coach in ANOTHER LEAGUE, addressing by literal uuid.
select t.be('d0000000-0000-4000-8000-000000000007', 'ostler@example.com');
select t.raises('a head coach in another league is refused',
  $q$select app.set_team_brand('c0000000-0000-4000-8000-000000000001', t.brand_ridgeline())$q$, '42501');
select t.raises('and refused on the league too',
  $q$select app.set_league_brand('a0000000-0000-4000-8000-000000000001', t.brand_ridgeline())$q$, '42501');
reset role;
select t.control('CONTROL: the team he was refused really exists',
  $q$select 1 from public.teams where id='c0000000-0000-4000-8000-000000000001'$q$, 1);
set role pd_authenticated;

-- ===========================================================================
-- 4. An assistant cannot. Nor a helper, a stranger, or nobody.
-- ===========================================================================
-- app.may_staff_team() does not list an assistant, which is the same reason he
-- cannot mint an invitation or staff the team. Dom is an assistant. He edits
-- the plays; he does not choose the club's colours.
select set_config('t.sect', '4 not the assistant', false);
\echo '=== 4. An assistant coaches. He does not brand. ==='

select t.be('d0000000-0000-4000-8000-000000000001', 'dom@example.com');
select t.val('the assistant really is on that team',
  $q$select role from public.memberships
      where user_id='d0000000-0000-4000-8000-000000000001'
        and team_id='c0000000-0000-4000-8000-000000000001'$q$, 'assistant');
select t.val('and he can read its brand perfectly well',
  $q$select app.team_brand('c0000000-0000-4000-8000-000000000001')->>'id'$q$, 'lehi');
select t.raises('but he cannot set it',
  $q$select app.set_team_brand('c0000000-0000-4000-8000-000000000001', t.brand_ridgeline())$q$, '42501');
select t.blocked('nor write the column directly',
  $q$update public.teams set brand = t.brand_ridgeline()
      where id='c0000000-0000-4000-8000-000000000001'$q$);
select t.val('the brand did not move',
  $q$select app.team_brand('c0000000-0000-4000-8000-000000000001')->>'id'$q$, 'lehi');

select t.be('d0000000-0000-4000-8000-000000000003', 'parent@example.com');
select t.raises('a helper cannot set it',
  $q$select app.set_team_brand('c0000000-0000-4000-8000-000000000001', t.brand_ridgeline())$q$, '42501');

select t.be('d0000000-0000-4000-8000-00000000000a', 'stranger@example.com');
select t.raises('a stranger cannot set it',
  $q$select app.set_team_brand('c0000000-0000-4000-8000-000000000001', t.brand_ridgeline())$q$, '42501');
select t.raises('nor set a league brand',
  $q$select app.set_league_brand('a0000000-0000-4000-8000-000000000001', t.brand_ridgeline())$q$, '42501');

select t.be(null, null);
select t.raises('an unidentified session cannot set a team brand',
  $q$select app.set_team_brand('c0000000-0000-4000-8000-000000000001', t.brand_ridgeline())$q$, '42501');
select t.raises('nor a league brand',
  $q$select app.set_league_brand('a0000000-0000-4000-8000-000000000001', t.brand_ridgeline())$q$, '42501');
reset role;

-- pd_anon holds no privilege on the setters at all -- the privilege check fails
-- before the identity check is even reached.
set role pd_anon;
select t.raises('pd_anon holds no EXECUTE on the team setter',
  $q$select app.set_team_brand('c0000000-0000-4000-8000-000000000001', t.brand_ridgeline())$q$, '42501');
select t.raises('nor on the league setter',
  $q$select app.set_league_brand('a0000000-0000-4000-8000-000000000001', t.brand_ridgeline())$q$, '42501');
reset role;
select t.val('and that is a privilege, not just a policy',
  $q$select has_function_privilege('pd_anon','app.set_team_brand(uuid,jsonb)','execute')::text$q$, 'false');

-- ===========================================================================
-- 5. A league admin brands the league -- and only his league
-- ===========================================================================
select set_config('t.sect', '5 league admin', false);
\echo '=== 5. A league admin brands his league, and not the other one ==='
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000006', 'whitmore@example.com');

select t.sets('the league admin brands his league',
  $q$select app.set_league_brand('a0000000-0000-4000-8000-000000000001', t.brand_six_codes())$q$, 'harbor');
select t.val('and every unbranded team in it now shows those colours',
  $q$select app.team_brand('c0000000-0000-4000-8000-000000000003')->>'id'$q$, 'harbor');
select t.val('through the league link of the chain',
  $q$select app.team_brand_source('c0000000-0000-4000-8000-000000000003')$q$, 'league');
select t.val('while a team with its OWN brand keeps it',
  $q$select app.team_brand('c0000000-0000-4000-8000-000000000001')->>'id'$q$, 'lehi');

select t.raises('he cannot brand the other league',
  $q$select app.set_league_brand('a0000000-0000-4000-8000-000000000002', t.brand_six_codes())$q$, '42501');
select t.raises('nor a team in it',
  $q$select app.set_team_brand('c0000000-0000-4000-8000-000000000004', t.brand_six_codes())$q$, '42501');
reset role;
select t.val('CONTROL: the other league''s brand is untouched',
  $q$select brand->>'id' from public.leagues where id='a0000000-0000-4000-8000-000000000002'$q$, 'willow-creek');
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000006', 'whitmore@example.com');

-- A league admin IS on app.may_staff_team() for his league's teams -- the same
-- pair rls.sql's memberships_write_head allows. That is inherited authority,
-- not a new one, and it is asserted here so it is a decision rather than a
-- surprise.
select t.sets('a league admin may also brand a team inside his league',
  $q$select app.set_team_brand('c0000000-0000-4000-8000-000000000003', t.brand_ridgeline())$q$, 'ridgeline');
select t.val('which is app.may_staff_team(), unchanged',
  $q$select app.may_staff_team('c0000000-0000-4000-8000-000000000003')::text$q$, 'true');
select t.val('and it stops at his league boundary',
  $q$select app.may_staff_team('c0000000-0000-4000-8000-000000000004')::text$q$, 'false');

-- A board member is oversight, not staffing. rls.sql already says so.
select t.be('d0000000-0000-4000-8000-000000000005', 'reeves@example.com');
select t.val('a board member really is on that league',
  $q$select role from public.league_memberships
      where user_id='d0000000-0000-4000-8000-000000000005'
        and league_id='a0000000-0000-4000-8000-000000000001'$q$, 'board');
select t.raises('but a board member cannot brand the league',
  $q$select app.set_league_brand('a0000000-0000-4000-8000-000000000001', t.brand_ridgeline())$q$, '42501');
select t.raises('nor a team in it',
  $q$select app.set_team_brand('c0000000-0000-4000-8000-000000000001', t.brand_ridgeline())$q$, '42501');

-- The other league's board, addressing by literal uuid.
select t.be('d0000000-0000-4000-8000-000000000009', 'barlow@example.com');
select t.raises('the other league''s board is refused on this one',
  $q$select app.set_league_brand('a0000000-0000-4000-8000-000000000001', t.brand_ridgeline())$q$, '42501');
select t.raises('and on its OWN league too, because board is not admin',
  $q$select app.set_league_brand('a0000000-0000-4000-8000-000000000002', t.brand_ridgeline())$q$, '42501');
reset role;

-- ===========================================================================
-- 6. THE REFUSAL -- an unreadable palette does not get stored
-- ===========================================================================
-- The point of doing this in SQL rather than in a form. Each refusal has to
-- NAME the pair and say by how much, because "invalid brand" is what sends a
-- volunteer coach back to guessing.
select set_config('t.sect', '6 refusal', false);
\echo '=== 6. The database refuses a palette a human cannot read ==='
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000002', 'steve@example.com');

-- (a) The yellow that vanishes on grass. Chrome is fine; the field is not.
select t.val('the vanishing yellow''s CHROME is perfectly legible',
  $q$select count(*)::text from app.brand_audit(t.brand_vanishing(), false)
      where check_id like 'ui-%' and not pass$q$, '0');
select t.val('but seven field checks fail',
  $q$select count(*)::text from app.brand_audit(t.brand_vanishing(), false) where not pass$q$, '7');
select t.raises_like('it is refused, naming the chalk on the grass',
  $q$select app.set_team_brand('c0000000-0000-4000-8000-000000000001', t.brand_vanishing())$q$,
  '23514', 'chalk-on-grass (field ink on the grass) #edebe0 on #8fa86b is 2.20:1, needs 4.5:1 (short by 2.30)');
select t.raises_like('and naming the route lines at their own 3:1 floor',
  $q$select app.set_team_brand('c0000000-0000-4000-8000-000000000001', t.brand_vanishing())$q$,
  '23514', 'route-on-grass (a route line on the grass) #e3b547 on #8fa86b is 1.37:1, needs 3:1');
select t.raises_like('and the label inside the circle, over its composited fill',
  $q$select app.set_team_brand('c0000000-0000-4000-8000-000000000001', t.brand_vanishing())$q$,
  '23514', 'label-on-circle (position label inside a player circle) #e3b547 on #4b6041 is 3.60:1, needs 4.5:1 (short by 0.90)');
select t.val('and nothing was clamped -- the old brand is still there, unmodified',
  $q$select app.team_brand('c0000000-0000-4000-8000-000000000001')->>'id'$q$, 'lehi');

-- (b) Navy on navy. Everything fails, including the chrome.
select t.val('navy on navy fails all seventeen',
  $q$select count(*)::text from app.brand_audit(t.brand_navy(), false) where not pass$q$, '17');
select t.raises_like('refused, naming the body text',
  $q$select app.set_team_brand('c0000000-0000-4000-8000-000000000001', t.brand_navy())$q$,
  '23514', 'ui-text (body text on the page) #1b2a4a on #101c33 is 1.19:1, needs 4.5:1 (short by 3.31)');
select t.raises_like('and the men''s labels',
  $q$select app.set_team_brand('c0000000-0000-4000-8000-000000000001', t.brand_navy())$q$,
  '23514', 'label-on-circle');
select t.raises_like('the refusal tells him what to do next',
  $q$select app.set_team_brand('c0000000-0000-4000-8000-000000000001', t.brand_navy())$q$,
  '23514', 'fails contrast');

-- (c) One check away. Everything legible except the position label inside the
-- circle -- which is the check a naive "text on background" audit would miss,
-- because the circle fill is translucent and has to be composited first.
select t.val('the near-miss fails exactly one check',
  $q$select count(*)::text from app.brand_audit(t.brand_label_only(), false) where not pass$q$, '1');
select t.val('and it is the label inside the circle',
  $q$select check_id from app.brand_audit(t.brand_label_only(), false) where not pass$q$, 'label-on-circle');
select t.raises_like('one failing check is enough to refuse the whole record',
  $q$select app.set_team_brand('c0000000-0000-4000-8000-000000000001', t.brand_label_only())$q$,
  '23514', 'label-on-circle');

-- (d) A league brand is held to the same floor.
select t.be('d0000000-0000-4000-8000-000000000006', 'whitmore@example.com');
select t.raises_like('a league admin is refused an unreadable league palette',
  $q$select app.set_league_brand('a0000000-0000-4000-8000-000000000001', t.brand_navy())$q$,
  '23514', 'fails contrast');
select t.val('and his league keeps what it had',
  $q$select app.league_brand('a0000000-0000-4000-8000-000000000001')->>'id'$q$, 'harbor');

-- (e) No webfonts. brand.js warns and falls back; the column refuses, because a
-- stored URL is a URL somebody eventually loads and this app is used with no
-- signal. The one place the database is deliberately stricter than the client.
select t.raises_like('a font that is a URL is refused',
  $q$select app.set_league_brand('a0000000-0000-4000-8000-000000000001', t.brand_webfont())$q$,
  '22023', 'nothing may block on the network');
select t.raises_like('and so is a font name we do not ship',
  $q$select app.set_league_brand('a0000000-0000-4000-8000-000000000001',
       jsonb_set(t.brand_lehi(), '{fonts,body}', '"Clubface Bold"'))$q$,
  '22023', 'not one of the built-in stacks');

-- (f) The shape guards, so a malformed record cannot audit as black-on-black
-- and pass by accident.
select t.raises('a record with no id is refused',
  $q$select app.set_league_brand('a0000000-0000-4000-8000-000000000001',
       t.brand_lehi() - 'id')$q$, '22023');
select t.raises_like('a colour that is not a colour is refused',
  $q$select app.set_league_brand('a0000000-0000-4000-8000-000000000001',
       jsonb_set(t.brand_lehi(), '{colors,accent}', '"club gold"'))$q$,
  '22023', 'which is not a colour');
select t.raises_like('an opacity outside 0..1 is refused',
  $q$select app.set_league_brand('a0000000-0000-4000-8000-000000000001',
       jsonb_set(t.brand_lehi(), '{field,gridOp}', '7'))$q$,
  '22023', 'an opacity is between 0 and 1');
select t.raises('a brand that is an array is refused',
  $q$select app.set_league_brand('a0000000-0000-4000-8000-000000000001', '[]'::jsonb)$q$, '22023');
reset role;

-- (g) The guard is a TRIGGER, so it binds every path -- including the one the
-- setter does not own (a league admin holds a real UPDATE policy on teams) and
-- including the table owner, which no policy would bind.
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000006', 'whitmore@example.com');
select t.val('a league admin really does hold a direct UPDATE on his league''s teams',
  $q$select count(*)::text from pg_policies
      where schemaname='public' and tablename='teams' and policyname='teams_write_admin'$q$, '1');
select t.raises_like('and the trigger refuses him just the same, going round the setter',
  $q$update public.teams set brand = t.brand_navy()
      where id='c0000000-0000-4000-8000-000000000001'$q$, '23514', 'fails contrast');
reset role;
select t.raises_like('the trigger binds the table OWNER too, so a migration cannot slip one in',
  $q$update public.leagues set brand = t.brand_navy()
      where id='a0000000-0000-4000-8000-000000000001'$q$, '23514', 'fails contrast');
select t.raises_like('and an INSERT carrying one is refused at birth',
  $q$insert into public.leagues (id, name, brand)
     values (gen_random_uuid(), 'Bad Palette League', t.brand_navy())$q$, '23514', 'fails contrast');

-- ===========================================================================
-- 7. A passing palette is accepted -- including our own
-- ===========================================================================
select set_config('t.sect', '7 acceptance', false);
\echo '=== 7. The palettes that should pass, do ==='

-- THE ONE THAT MATTERS. If the exact Lehi palette in brands.json fails, that is
-- a finding about our own theme and the floor does not move to accommodate it.
select t.val('the exact reference palette passes all seventeen on screen',
  $q$select count(*)::text from app.brand_audit(t.brand_lehi(), false) where not pass$q$, '0');
select t.val('and all seventeen in print',
  $q$select count(*)::text from app.brand_audit(t.brand_lehi(), true) where not pass$q$, '0');
select t.val('brand_assert accepts it outright',
  $q$select app.brand_assert(t.brand_lehi())::text$q$, 'true');
select t.val('its worst check is them-on-grass at 3.14:1 against a 1.6 floor',
  $q$select check_id||' '||ratio::text from app.brand_audit(t.brand_lehi(), false)
     order by ratio limit 1$q$, 'sideline-on-grass 2.30');
select t.val('its worst READ check is label-on-circle at 7.49:1 against 4.5',
  $q$select check_id||' '||ratio::text from app.brand_audit(t.brand_lehi(), false)
     where tier='text' order by ratio limit 1$q$, 'label-on-circle 7.49');
-- The hand copy in this file and the hand copy in brand-seed.sql must agree, or
-- one of them has drifted and the other is testing nothing.
select t.val('and it is byte-identical to the one brand-seed.sql stored',
  $q$select (t.brand_lehi() = (select brand from public.teams
       where id='c0000000-0000-4000-8000-000000000001'))::text$q$, 'true');

select t.val('the second seeded club passes too',
  $q$select count(*)::text from app.brand_audit(
       (select brand from public.leagues where id='a0000000-0000-4000-8000-000000000002'), false)
     where not pass$q$, '0');
select t.val('the loud one passes',
  $q$select count(*)::text from app.brand_audit(t.brand_ridgeline(), false) where not pass$q$, '0');
select t.val('and a club that sent six hex codes and a name passes on derived values alone',
  $q$select count(*)::text from app.brand_audit(t.brand_six_codes(), false) where not pass$q$, '0');
select t.val('its whole field really was derived, not supplied',
  $q$select (t.brand_six_codes() ? 'field')::text$q$, 'false');
select t.val('and the derived grass is the derived board',
  $q$select app.brand_normalize(t.brand_six_codes())->'field'->>'grass'$q$, '#17293A');

-- Round-tripping. app.brand_normalize() is idempotent, which is what lets a
-- resolved record be stored again without drifting.
select t.val('normalising a normalised record changes nothing',
  $q$select (app.brand_normalize(app.brand_normalize(t.brand_six_codes()))
           = app.brand_normalize(t.brand_six_codes()))::text$q$, 'true');
select t.val('and a resolved record is still acceptable to the setter''s guard',
  $q$select app.brand_assert(app.brand_normalize(t.brand_six_codes()))::text$q$, 'true');

set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000002', 'steve@example.com');
select t.sets('and the whole passing record actually goes in',
  $q$select app.set_team_brand('c0000000-0000-4000-8000-000000000001', t.brand_six_codes())$q$, 'harbor');
select t.val('stored verbatim -- the setter normalises nothing on the way in',
  $q$select (t.brand_six_codes() = (select app.team_brand_raw from
       (select brand as app_team_brand_raw from public.teams
         where id='c0000000-0000-4000-8000-000000000001') s(app_team_brand_raw)
       ) )::text$q$, 'true');
reset role;

-- ===========================================================================
-- 8. Isolation did not widen
-- ===========================================================================
-- `brand` is a column on two tables that already had policies. It is visible to
-- exactly the people who could already read the row, and this file creates no
-- policy at all.
select set_config('t.sect', '8 no new reach', false);
\echo '=== 8. A colour column is not a new door ==='

select t.val('brand.sql created no policy on teams beyond the two that were there',
  $q$select string_agg(policyname, ',' order by policyname) from pg_policies
      where schemaname='public' and tablename='teams'$q$, 'teams_select,teams_write_admin');
select t.val('nor on leagues beyond the one that was there',
  $q$select string_agg(policyname, ',' order by policyname) from pg_policies
      where schemaname='public' and tablename='leagues'$q$, 'leagues_select');
select t.val('leagues are still read-only to every tenant',
  $q$select (has_table_privilege('pd_authenticated','public.leagues','update')
         or has_table_privilege('pd_anon','public.leagues','update'))::text$q$, 'false');
select t.val('the brand column carries no default, so nothing was branded behind our backs',
  $q$select count(*)::text from information_schema.columns
      where table_schema='public' and column_name='brand' and column_default is not null$q$, '0');
select t.val('and it lives on exactly two tables',
  $q$select string_agg(table_name, ',' order by table_name) from information_schema.columns
      where table_schema='public' and column_name='brand'$q$, 'leagues,teams');

set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000002', 'steve@example.com');
select t.rows('a UYFC coach cannot read the Cache Valley league row',
  $q$select brand from public.leagues where id='a0000000-0000-4000-8000-000000000002'$q$, 0);
select t.rows('nor a Cache Valley team row',
  $q$select brand from public.teams where id='c0000000-0000-4000-8000-000000000004'$q$, 0);
select t.rows('he reads exactly his own two league rows worth of brand -- one league',
  $q$select brand from public.leagues$q$, 1);
reset role;
select t.control('CONTROL: there are two leagues to read',
  $q$select 1 from public.leagues$q$, 2);
set role pd_authenticated;

-- A board member sees his league's teams (rls.sql says so) and therefore their
-- brands. That is inherited, not new: a brand is less sensitive than the roster
-- he can already read.
select t.be('d0000000-0000-4000-8000-000000000005', 'reeves@example.com');
select t.rows('a board member reads his own league''s team brands',
  $q$select brand from public.teams where league_id='a0000000-0000-4000-8000-000000000001'$q$, 3);
select t.rows('and none of the other league''s',
  $q$select brand from public.teams where league_id='a0000000-0000-4000-8000-000000000002'$q$, 0);
reset role;

-- ===========================================================================
-- 9. THE PLATFORM OWNER GAINS NOTHING
-- ===========================================================================
-- platform.sql's rule 1: the vendor seat holds NO row-level reach. Branding is
-- tenant data, so it is on the wrong side of that line, and the check here is
-- that adding a column did not quietly move the line.
select set_config('t.sect', '9 platform owner', false);
\echo '=== 9. Branding is tenant data, and the vendor still cannot see it ==='
set role pd_authenticated;
select t.be('10000000-0000-4000-8000-000000000001', 'founder@example.com');

select t.val('he really is the platform owner', $q$select app.is_platform_owner()::text$q$, 'true');
select t.rows('and reads no league brand',  $q$select brand from public.leagues$q$, 0);
select t.rows('and no team brand',          $q$select brand from public.teams$q$, 0);
select t.rows('not even by literal uuid',
  $q$select brand from public.teams where id='c0000000-0000-4000-8000-000000000001'$q$, 0);
select t.rows('nor the other league''s, by literal uuid',
  $q$select brand from public.leagues where id='a0000000-0000-4000-8000-000000000002'$q$, 0);

-- The resolver is SECURITY INVOKER, so it answers him the way it answers a
-- stranger: the product default. A DEFINER resolver here would have handed the
-- vendor every customer's identity in one call, which is precisely the mistake
-- app.league_rule() already documents.
select t.val('app.team_brand() answers him the product default',
  $q$select app.team_brand('c0000000-0000-4000-8000-000000000001')->>'id'$q$, 'product');
select t.val('and will not even tell him a brand exists',
  $q$select app.team_brand_source('c0000000-0000-4000-8000-000000000001')$q$, 'default');
select t.val('app.league_brand() the same',
  $q$select app.league_brand('a0000000-0000-4000-8000-000000000002')->>'id'$q$, 'product');

-- He cannot write one either. The separation rule means he holds no membership,
-- so both authority helpers are false for him.
select t.val('he holds no team membership, by construction',
  $q$select count(*)::text from public.memberships
      where user_id='10000000-0000-4000-8000-000000000001'$q$, '0');
select t.val('so may_staff_team is false for him',
  $q$select app.may_staff_team('c0000000-0000-4000-8000-000000000001')::text$q$, 'false');
select t.raises('and he cannot brand a team',
  $q$select app.set_team_brand('c0000000-0000-4000-8000-000000000001', t.brand_ridgeline())$q$, '42501');
select t.raises('nor a league',
  $q$select app.set_league_brand('a0000000-0000-4000-8000-000000000001', t.brand_ridgeline())$q$, '42501');
select t.blocked('nor write the column directly on teams',
  $q$update public.teams set brand = t.brand_ridgeline()
      where id='c0000000-0000-4000-8000-000000000001'$q$);
select t.blocked('nor on leagues',
  $q$update public.leagues set brand = t.brand_ridgeline()
      where id='a0000000-0000-4000-8000-000000000001'$q$);

-- And nothing the vendor CAN read carries a colour. This is the sweep
-- test-platform.sql section 4 runs for children's names, pointed at hex codes.
select t.val('no platform function returns the club''s accent',
  $q$select (position('E3B547' in upper(coalesce((
       select string_agg(row_to_json(q)::text, ' ') from app.platform_leagues() q), '')
       || ' ' || coalesce((
       select string_agg(row_to_json(q)::text, ' ')
         from app.platform_league('a0000000-0000-4000-8000-000000000001') q), '')
       || ' ' || coalesce((
       select string_agg(row_to_json(q)::text, ' ')
         from app.platform_league('a0000000-0000-4000-8000-000000000002') q), '')
       )) > 0)::text$q$, 'false');
select t.val('nor the word "brand" at all',
  $q$select (position('BRAND' in upper(coalesce((
       select string_agg(row_to_json(q)::text, ' ') from app.platform_leagues() q), '')
       || ' ' || coalesce((
       select string_agg(row_to_json(q)::text, ' ')
         from app.platform_league('a0000000-0000-4000-8000-000000000001') q), '')
       )) > 0)::text$q$, 'false');
reset role;
select t.control('CONTROL: the accent really is stored, in a row he cannot reach',
  $q$select 1 from public.teams
      where id='c0000000-0000-4000-8000-000000000001' and brand::text ilike '%E3B547%'$q$, 0);
select t.control('CONTROL: a brand really is stored on a team',
  $q$select 1 from public.teams where brand is not null$q$, 1);

-- The co-founder seat is no different from the founder seat.
set role pd_authenticated;
select t.be('10000000-0000-4000-8000-000000000002', 'cofounder@example.com');
select t.rows('the second vendor seat reads no brand either',  $q$select brand from public.teams$q$, 0);
select t.raises('and cannot set one',
  $q$select app.set_team_brand('c0000000-0000-4000-8000-000000000001', t.brand_ridgeline())$q$, '42501');
reset role;

-- ===========================================================================
-- 10. CLAUDE.md rule 1, in a new domain: a colour change destroys nothing
-- ===========================================================================
select set_config('t.sect', '10 nothing destroyed', false);
\echo '=== 10. Rebranding is a colour, not a migration ==='

select t.val('every play is still where it was',
  $q$select count(*)::text from public.plays$q$, '6');
select t.val('every child is still where they were',
  $q$select count(*)::text from public.players$q$, '31');
select t.val('every membership survived the section 3-7 churn',
  $q$select count(*)::text from public.memberships$q$, '7');
select t.val('and every team',
  $q$select count(*)::text from public.teams$q$, '5');
select t.val('the branded team''s playbook is untouched',
  $q$select count(*)::text from public.plays where team_id='c0000000-0000-4000-8000-000000000001'$q$, '4');

-- Clearing a brand is the only removal the feature has, and it removes a
-- colour. Rule 1 restated: nothing else goes with it.
set role pd_authenticated;
select t.be('d0000000-0000-4000-8000-000000000002', 'steve@example.com');
select t.val('clearing a team brand returns NULL',
  $q$select coalesce(app.set_team_brand('c0000000-0000-4000-8000-000000000001', null)::text,'NULL')$q$, 'NULL');
reset role;
select t.val('and took no play with it',
  $q$select count(*)::text from public.plays where team_id='c0000000-0000-4000-8000-000000000001'$q$, '4');
select t.val('and no player',
  $q$select count(*)::text from public.players where team_id='c0000000-0000-4000-8000-000000000001'$q$, '21');

-- ===========================================================================
-- 11. VACUITY CHECK -- with the guard gone, the same statements land
-- ===========================================================================
-- Nobody has to take the zeroes above on faith. Drop the trigger and the
-- unreadable palette goes straight in; add a permissive policy and the vendor
-- reads every customer's colours.
select set_config('t.sect', '11 vacuity check', false);
\echo '=== 11. With the guard dropped, navy-on-navy is stored ==='

drop trigger teams_brand_readable on public.teams;
select t.allowed('with no trigger, the navy palette lands on the team',
  $q$update public.teams set brand = t.brand_navy()
      where id='c0000000-0000-4000-8000-000000000001'$q$, 1);
select t.val('and the app would now paint 1.19:1 body text',
  $q$select ratio::text from app.brand_audit(
       (select brand from public.teams where id='c0000000-0000-4000-8000-000000000001'), false)
     where check_id='ui-text'$q$, '1.19');
update public.teams set brand = null where id='c0000000-0000-4000-8000-000000000001';
create trigger teams_brand_readable
  before insert or update of brand on public.teams
  for each row execute function app.brand_readable_guard();
select t.raises_like('put back: refused again',
  $q$update public.teams set brand = t.brand_navy()
      where id='c0000000-0000-4000-8000-000000000001'$q$, '23514', 'fails contrast');

\echo '=== 11b. With one permissive policy, the vendor reads every club''s colours ==='
create policy tmp_leak_team_brand on public.teams for select to pd_authenticated using (true);
set role pd_authenticated;
select t.be('10000000-0000-4000-8000-000000000001', 'founder@example.com');
select t.val('with USING(true): the vendor enumerates all five teams',
  $q$select count(*)::text from public.teams$q$, '5');
select t.val('and app.team_brand() hands him the league''s colours',
  $q$select app.team_brand('c0000000-0000-4000-8000-000000000004')->>'id'$q$, 'willow-creek');
reset role;
drop policy tmp_leak_team_brand on public.teams;
set role pd_authenticated;
select t.be('10000000-0000-4000-8000-000000000001', 'founder@example.com');
select t.rows('taken away again: zero teams',  $q$select 1 from public.teams$q$, 0);
select t.val('and back to the product default',
  $q$select app.team_brand('c0000000-0000-4000-8000-000000000004')->>'id'$q$, 'product');
reset role;

-- ===========================================================================
-- Results
-- ===========================================================================
\echo ''
\echo '=== CONTRAST NUMBERS FOR THE TWO SEEDED BRANDS (screen) ==='
select b.who, a.check_id, a.tier, a.floor_ratio as floor, a.fg, a.bg, a.ratio,
       case when a.pass then 'ok' else 'FAIL' end as verdict
  from (select 'lehi (team)' as who, t.brand_lehi() as rec
        union all
        select 'willow-creek (league)',
               (select brand from public.leagues where id='a0000000-0000-4000-8000-000000000002')) b,
       lateral app.brand_audit(b.rec, false) a
 order by b.who, a.ratio;

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
    raise exception '% BRAND TEST(S) FAILED', bad;
  end if;
  raise notice 'all % brand tests passed', (select count(*) from t.results);
end $$;

rollback;
