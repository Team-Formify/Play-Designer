-- product/db/migrations/0006_brand.sql
-- Per-tenant branding, and the contrast floor that makes it safe to hand out.
--
-- WHY THIS EXISTS
-- product/brand/brand.js already themes the entire app from one record: the
-- chrome, the field the plays are drawn on, the wordmark, the club mark. What
-- it does not have is anywhere to keep a record. Today the brands live in
-- product/brand/brands.json, which means a club's colours are a file edit by
-- us, which means branding is not a feature a customer has -- it is a support
-- ticket. This file gives leagues and teams a `brand jsonb` column, one
-- resolver so every client falls back identically, two setters with the
-- authority helpers that already exist, and the part that is actually worth
-- doing in SQL rather than in a form:
--
--   THE DATABASE REFUSES AN UNREADABLE PALETTE.
--
-- A volunteer coach picking his club's colours will pick navy on navy, or a
-- yellow that vanishes on grass. Client-side validation is advice; a column is
-- a promise. So the WCAG 2.x relative-luminance and contrast-ratio maths are
-- implemented here in plpgsql, mirroring Brand.audit() check for check and
-- floor for floor, and a BEFORE trigger refuses the write with the failing pair
-- named and the shortfall measured. Nothing is clamped, nothing is "corrected":
-- a brand that cannot be read is not stored, and the coach is told which pair
-- of colours failed and by how much.
--
-- THE FLOORS, from Brand.MIN, unchanged:
--   text     4.5   something a coach or a boy has to READ -- the position label
--                  inside a player circle, the name on its chip, the chalk on
--                  the grass, the line-of-scrimmage label, all the UI text
--   graphic  3.0   something that has to be SEEN, not read -- a route line, a
--                  collision ring, the circle stroke
--   faint    1.6   deliberately recessive -- the yard grid, the sidelines, the
--                  other team's marks. Visible without competing with the
--                  eleven men who matter.
--
-- Load order: schema.sql -> rls.sql -> auth.sql -> platform.sql -> brand.sql
--             -> seed.sql -> auth-seed.sql -> platform-seed.sql -> brand-seed.sql
-- Tests:      test-isolation.sql (183, unchanged), test-auth.sql (243,
--             unchanged), test-platform.sql (252, unchanged), test-brand.sql.
--
-- ADDITIVE, like auth.sql and platform.sql. Two nullable columns, their check
-- constraints, one guard trigger apiece, and a set of functions in app. Nothing
-- in schema.sql, rls.sql, auth.sql or platform.sql is edited or replaced. Every
-- guard added here is inert for a row whose brand is NULL, and every existing
-- row's brand is NULL, which is why the 678 tests that came before it do not
-- move.
--
-- FOUR THINGS THIS FILE DELIBERATELY DOES NOT DO
--
--   1. IT ADDS NO ROW-LEVEL REACH TO ANYBODY. There is no new policy in this
--      file. `brand` is a column on two tables that already have policies, so
--      it is visible to exactly the people who could already read the row and
--      to nobody else. app.team_brand() is SECURITY INVOKER for the same
--      reason app.league_rule() is: a definer resolver would hand any signed-in
--      coach any club's colours, and a platform owner the whole customer list's
--      identity in one call. A tenant you cannot see resolves to the product
--      default, exactly as if it had no brand.
--
--   2. IT DOES NOT OPEN A ROW FOR WRITING. A head coach still holds no UPDATE
--      policy on public.teams and no tenant holds one on public.leagues. The
--      setters are SECURITY DEFINER and touch one column of one row after
--      asking app.may_staff_team() / app.may_staff_league(). Column-level RLS
--      does not exist; a policy that let a head coach write his team's brand
--      would let him write his team's league_id.
--
--   3. IT DOES NOT INVENT AN AUTHORITY. "A league admin brands the league, a
--      head coach brands his team, an assistant cannot" is not a new rule --
--      it is app.may_staff_league() and app.may_staff_team() exactly as
--      auth.sql already defines them. If who-is-in-charge ever changes, it
--      changes in one place and this file follows.
--
--   4. IT DOES NOT LET A BRAND FETCH ANYTHING. brand.js takes a font stack by
--      NAME from a fixed list because a page on a practice field may never
--      block on a CDN. The client falls back to the system stack and warns when
--      it does not recognise a name; the column is stricter and REFUSES the
--      record, because a stored URL is a URL somebody will eventually load.
--      That is the one place the database is deliberately harder than the
--      client, and it is called out below.

\set ON_ERROR_STOP on

-- The transaction is supplied by the runner (product/db/migrate.mjs), which
-- wraps this file and its ledger row in ONE transaction. A migration that
-- committed itself could succeed while its ledger row failed, and the next run
-- would replay it. Do not add begin/commit here.

-- ===========================================================================
-- 1. Colour arithmetic -- the same functions brand.js has, in plpgsql
-- ===========================================================================
-- A colour is a double precision[4]: r, g, b in 0..255 and alpha in 0..1, held
-- UNROUNDED because every composite in the audit below is a fractional colour
-- (a chip is a plate at 0.82 over the grass) and rounding it to a byte before
-- measuring it would quietly move the ratio.
--
-- Rounding, where it does happen, is floor(x + 0.5) and not round(). round() on
-- double precision is platform-dependent and is banker's rounding on most
-- builds, so round(127.5) is 128 here and could be 127 elsewhere; JavaScript's
-- Math.round is always half-up. The printed sideline composites to exactly
-- 127.5, so this is not a hypothetical.

create or replace function app.brand_rgb(p_c text)
returns double precision[]
language plpgsql immutable
set search_path = ''
as $$
declare
  s     text;
  h     text;
  m     text[];
  parts text[];
begin
  if p_c is null then return null; end if;
  s := btrim(p_c);

  m := regexp_match(s, '^#([0-9a-fA-F]{3,8})$');
  if m is not null then
    h := m[1];
    if length(h) in (3, 4) then
      h := regexp_replace(h, '(.)', '\1\1', 'g');
    end if;
    -- brand.js will happily index past the end of a 5- or 7-digit hex and
    -- produce NaN channels. Refusing is the safer half of that disagreement:
    -- the database stores nothing it cannot measure.
    if length(h) not in (6, 8) then return null; end if;
    return array[
      ('x' || substr(h, 1, 2))::bit(8)::int::double precision,
      ('x' || substr(h, 3, 2))::bit(8)::int::double precision,
      ('x' || substr(h, 5, 2))::bit(8)::int::double precision,
      case when length(h) = 8
           then ('x' || substr(h, 7, 2))::bit(8)::int::double precision / 255.0
           else 1.0 end
    ];
  end if;

  m := regexp_match(s, '^rgba?\(([^)]+)\)$', 'i');
  if m is not null then
    -- Same split as brand.js: commas, whitespace and the CSS4 slash all
    -- separate, and empty pieces are dropped.
    select array_agg(x order by ord)
      into parts
      from unnest(regexp_split_to_array(btrim(m[1]), '[,[:space:]/]+'))
             with ordinality as u(x, ord)
     where x <> '';
    if parts is null or array_length(parts, 1) < 3 then return null; end if;
    if not (parts[1] ~ '^[-+]?[0-9]*\.?[0-9]+$'
        and parts[2] ~ '^[-+]?[0-9]*\.?[0-9]+$'
        and parts[3] ~ '^[-+]?[0-9]*\.?[0-9]+$') then return null; end if;
    if array_length(parts, 1) > 3
       and parts[4] !~ '^[-+]?[0-9]*\.?[0-9]+$' then return null; end if;
    return array[
      parts[1]::double precision,
      parts[2]::double precision,
      parts[3]::double precision,
      case when array_length(parts, 1) > 3 then parts[4]::double precision else 1.0 end
    ];
  end if;

  return null;
exception when others then
  return null;
end $$;

comment on function app.brand_rgb(text) is
  'Parse #rgb, #rrggbb, #rrggbbaa, rgb() and rgba() into [r,g,b,a]. NULL for anything else -- the one place this is stricter than brand.js''s parse(), which returns NaN channels for a malformed hex.';

-- '#rrggbb', lowercase, matching brand.js hex().
create or replace function app.brand_hex(p double precision[])
returns text
language sql immutable
set search_path = ''
as $$
  select case when p is null then '#000000' else
    '#' || lpad(to_hex(floor(greatest(0, least(255, p[1])) + 0.5)::int), 2, '0')
        || lpad(to_hex(floor(greatest(0, least(255, p[2])) + 0.5)::int), 2, '0')
        || lpad(to_hex(floor(greatest(0, least(255, p[3])) + 0.5)::int), 2, '0')
  end
$$;

-- Composite a possibly-translucent foreground over an opaque backdrop. Every
-- contrast number below runs through this, because rgba(19,37,31,.55) is not a
-- colour until you know what is underneath it.
create or replace function app.brand_over(
  p_fg double precision[], p_bg double precision[], p_alpha double precision default null)
returns double precision[]
language sql immutable
set search_path = ''
as $$
  select case
    when p_fg is null then coalesce(p_bg, array[0,0,0,1]::double precision[])
    when p_bg is null then p_fg
    else array[
      p_fg[1] * coalesce(p_alpha, p_fg[4]) + p_bg[1] * (1 - coalesce(p_alpha, p_fg[4])),
      p_fg[2] * coalesce(p_alpha, p_fg[4]) + p_bg[2] * (1 - coalesce(p_alpha, p_fg[4])),
      p_fg[3] * coalesce(p_alpha, p_fg[4]) + p_bg[3] * (1 - coalesce(p_alpha, p_fg[4])),
      1
    ] end
$$;

-- WCAG 2.x relative luminance. sRGB channels are linearised with the 0.03928 /
-- 12.92 knee and the 2.4 gamma, then weighted 0.2126 / 0.7152 / 0.0722.
create or replace function app.brand_luminance(p double precision[])
returns double precision
language plpgsql immutable
set search_path = ''
as $$
declare
  l double precision := 0;
  v double precision;
  w double precision[] := array[0.2126, 0.7152, 0.0722];
  i int;
begin
  if p is null then return 0; end if;
  for i in 1..3 loop
    v := p[i] / 255.0;
    if v <= 0.03928 then
      v := v / 12.92;
    else
      v := power((v + 0.055) / 1.055, 2.4);
    end if;
    l := l + w[i] * v;
  end loop;
  return l;
end $$;

-- WCAG 2.x contrast ratio. Both arguments must already be opaque; use
-- app.brand_over() first if either is not.
create or replace function app.brand_contrast(a double precision[], b double precision[])
returns double precision
language sql immutable
set search_path = ''
as $$
  select (greatest(app.brand_luminance(a), app.brand_luminance(b)) + 0.05)
       / (least(   app.brand_luminance(a), app.brand_luminance(b)) + 0.05)
$$;

-- Text-in, text-out overload, so a caller can ask the obvious question without
-- learning the array shape: select app.brand_contrast('#E3B547', '#1D3A31');
create or replace function app.brand_contrast(a text, b text)
returns double precision
language sql immutable
set search_path = ''
as $$
  select app.brand_contrast(app.brand_rgb(a), app.brand_rgb(b))
$$;

comment on function app.brand_contrast(text, text) is
  'WCAG 2.x contrast ratio between two opaque colours. Mirrors Brand.contrast() in product/brand/brand.js exactly.';

-- Shortest decimal for an alpha, so rgba() strings come out the way
-- JavaScript writes them: 0.55, not 0.550000.
create or replace function app.brand_num(v double precision)
returns text
language sql immutable
set search_path = ''
as $$
  select case when v = floor(v) and abs(v) < 1e15 then floor(v)::bigint::text
              else btrim(to_char(v, 'FM9999999990.999999999'), ' ') end
$$;

create or replace function app.brand_rgba(p_c text, p_a double precision)
returns text
language sql immutable
set search_path = ''
as $$
  select 'rgba(' || floor((app.brand_rgb(p_c))[1] + 0.5)::int || ','
                 || floor((app.brand_rgb(p_c))[2] + 0.5)::int || ','
                 || floor((app.brand_rgb(p_c))[3] + 0.5)::int || ','
                 || app.brand_num(p_a) || ')'
$$;

create or replace function app.brand_mix(a text, b text, t double precision)
returns text
language sql immutable
set search_path = ''
as $$
  select app.brand_hex(array[
    (app.brand_rgb(a))[1] + ((app.brand_rgb(b))[1] - (app.brand_rgb(a))[1]) * t,
    (app.brand_rgb(a))[2] + ((app.brand_rgb(b))[2] - (app.brand_rgb(a))[2]) * t,
    (app.brand_rgb(a))[3] + ((app.brand_rgb(b))[3] - (app.brand_rgb(a))[3]) * t,
    1
  ])
$$;

-- brand.js isDark(): luminance below 0.22. It is what decides whether a derived
-- board is mixed toward white or toward black.
create or replace function app.brand_is_dark(p_c text)
returns boolean
language sql immutable
set search_path = ''
as $$
  select app.brand_luminance(app.brand_rgb(p_c)) < 0.22
$$;

-- ===========================================================================
-- 2. The record: defaults, normalisation, and the font rule
-- ===========================================================================

-- A JSON string field, treated the way JavaScript's `||` treats it: absent,
-- null, a non-string or the empty string all mean "not given".
create or replace function app.brand_jstr(p jsonb, p_key text)
returns text
language sql immutable
set search_path = ''
as $$
  select nullif(case when jsonb_typeof(p -> p_key) = 'string' then p ->> p_key end, '')
$$;

-- A JSON number field. brand.js keeps a 0 here (it tests == null, not
-- falsiness), so this does too: an opacity of 0 is a choice, not an omission.
create or replace function app.brand_jnum(p jsonb, p_key text, p_default double precision)
returns double precision
language sql immutable
set search_path = ''
as $$
  select coalesce(
    case when jsonb_typeof(p -> p_key) = 'number' then (p ->> p_key)::double precision end,
    p_default)
$$;

-- The font stacks, by name. Exactly the keys of Brand.FONT_STACKS. The stacks
-- themselves are not stored: the client owns the strings, the database owns the
-- list of legal names, and a brand that names something else -- above all a URL,
-- which is the failure this guard exists for -- is refused.
create or replace function app.brand_font_names()
returns text[]
language sql immutable
set search_path = ''
as $$ select array['system','mono','condensed','grotesk','slab','humanist'] $$;

-- Fill every slot, exactly as Brand.normalize() does, so nothing downstream --
-- here or in the client -- has to test for a missing key, and a tenant can be
-- onboarded with six hex codes and still get a whole field.
--
-- ONE DELIBERATE DIFFERENCE FROM brand.js, and it is a bug fix rather than a
-- drift: fonts stay NAMES. Brand.normalize() expands 'grotesk' to its stack,
-- which is right for a record on its way to the DOM and wrong for a record on
-- its way back into Brand.normalize() -- the expanded stack is not a key of
-- FONT_STACKS, so a second pass warns and falls back to system. Keeping names
-- makes app.team_brand()'s output round-trip through Brand.normalize()
-- unchanged, which is the whole point of a resolver every client shares.
create or replace function app.brand_normalize(p jsonb)
returns jsonb
language plpgsql immutable
set search_path = ''
as $$
declare
  src jsonb;
  fs  jsonb;
  w   jsonb;
  mk  jsonb;
  fr  jsonb;
  c_page text; c_board text; c_deep text; c_chalk text; c_soft text;
  c_accent text; c_warm text;
  f_grass text; f_chalk text; f_line text; f_plate text; f_hot text;
  f_circle text; f_route text;
  m_bg text; m_fg text; m_initials text; m_shape text;
  v_short text; v_scheme text; v_id text; v_name text;
  colors jsonb; field jsonb;
begin
  if p is null or jsonb_typeof(p) <> 'object' then
    raise exception 'brand: a record is a json object' using errcode = '22023';
  end if;
  v_id := app.brand_jstr(p, 'id');
  if v_id is null then
    raise exception 'brand: a record needs an id' using errcode = '22023';
  end if;
  v_name := coalesce(app.brand_jstr(p, 'name'), v_id);

  src := coalesce(case when jsonb_typeof(p -> 'colors') = 'object' then p -> 'colors' end, '{}'::jsonb);

  c_page  := coalesce(app.brand_jstr(src, 'page'), '#13251F');
  c_board := coalesce(app.brand_jstr(src, 'board'),
                      app.brand_mix(c_page, case when app.brand_is_dark(c_page) then '#FFFFFF' else '#000000' end, 0.06));
  c_deep  := coalesce(app.brand_jstr(src, 'deep'),
                      app.brand_mix(c_page, case when app.brand_is_dark(c_page) then '#000000' else '#FFFFFF' end, 0.35));
  c_chalk := coalesce(app.brand_jstr(src, 'chalk'),
                      case when app.brand_is_dark(c_page) then '#EDEBE0' else '#16211C' end);
  c_soft  := coalesce(app.brand_jstr(src, 'soft'), app.brand_mix(c_chalk, c_page, 0.42));
  c_accent := coalesce(app.brand_jstr(src, 'accent'), '#E3B547');
  c_warm   := coalesce(app.brand_jstr(src, 'warm'), '#E58A6B');

  v_scheme := coalesce(app.brand_jstr(p, 'scheme'),
                       case when app.brand_is_dark(c_page) then 'dark' else 'light' end);

  fs := coalesce(case when jsonb_typeof(p -> 'field') = 'object' then p -> 'field' end, '{}'::jsonb);
  f_grass  := coalesce(app.brand_jstr(fs, 'grass'), c_board);
  f_chalk  := coalesce(app.brand_jstr(fs, 'chalk'), c_chalk);
  f_line   := coalesce(app.brand_jstr(fs, 'line'),  c_accent);
  f_plate  := coalesce(app.brand_jstr(fs, 'plate'), c_page);
  f_hot    := coalesce(app.brand_jstr(fs, 'hot'),   c_warm);
  f_circle := coalesce(app.brand_jstr(fs, 'circleFill'), app.brand_rgba(f_plate, 0.55));
  f_route  := coalesce(app.brand_jstr(fs, 'routeFill'),  app.brand_rgba(f_line, 0.28));

  colors := jsonb_build_object(
    'page', c_page, 'board', c_board, 'deep', c_deep, 'chalk', c_chalk,
    'soft', c_soft, 'accent', c_accent, 'warm', c_warm);

  field := jsonb_build_object(
    'grass', f_grass, 'chalk', f_chalk, 'line', f_line, 'plate', f_plate, 'hot', f_hot,
    'circleFill', f_circle, 'routeFill', f_route,
    'gridOp',    app.brand_jnum(fs, 'gridOp',    0.09),
    'hashOp',    app.brand_jnum(fs, 'hashOp',    0.2),
    'sideOp',    app.brand_jnum(fs, 'sideOp',    0.3),
    'themOp',    app.brand_jnum(fs, 'themOp',    0.42),
    'chipOp',    app.brand_jnum(fs, 'chipOp',    0.82),
    'losChipOp', app.brand_jnum(fs, 'losChipOp', 0.72),
    'leadOp',    app.brand_jnum(fs, 'leadOp',    0.42),
    'aimOp',     app.brand_jnum(fs, 'aimOp',     0.85),
    'stroke',    app.brand_jnum(fs, 'stroke',    2));

  w := coalesce(case when jsonb_typeof(p -> 'wordmark') = 'object' then p -> 'wordmark' end, '{}'::jsonb);
  mk := coalesce(case when jsonb_typeof(p -> 'mark') = 'object' then p -> 'mark' end, '{}'::jsonb);
  fr := coalesce(case when jsonb_typeof(p -> 'fonts') = 'object' then p -> 'fonts' end, '{}'::jsonb);

  v_short := coalesce(app.brand_jstr(p, 'shortName'), v_name);
  m_initials := upper(coalesce(app.brand_jstr(mk, 'initials'), substr(v_short, 1, 3)));
  m_shape := coalesce(app.brand_jstr(mk, 'shape'), 'shield');
  m_bg := coalesce(app.brand_jstr(mk, 'bg'), c_accent);
  m_fg := coalesce(app.brand_jstr(mk, 'fg'),
                   case when app.brand_is_dark(m_bg) then c_chalk else c_page end);

  return jsonb_strip_nulls(jsonb_build_object(
    'id', v_id,
    'name', v_name,
    'shortName', v_short,
    'scheme', v_scheme,
    'colors', colors,
    'field', field,
    'wordmark', jsonb_build_object(
       'text',   coalesce(app.brand_jstr(w, 'text'), v_name),
       'accent', coalesce(app.brand_jstr(w, 'accent'), '')),
    'mark', jsonb_build_object(
       'initials', m_initials, 'shape', m_shape, 'bg', m_bg, 'fg', m_fg),
    'fonts', jsonb_build_object(
       'body',    coalesce(app.brand_jstr(fr, 'body'),    'system'),
       'mono',    coalesce(app.brand_jstr(fr, 'mono'),    'mono'),
       'display', coalesce(app.brand_jstr(fr, 'display'), 'condensed'))
  ));
end $$;

comment on function app.brand_normalize(jsonb) is
  'Fill every slot of a brand record the way Brand.normalize() does, deriving a whole field from six chrome colours when none was given. One deliberate difference: fonts stay names, not stacks, so the result round-trips back through Brand.normalize() unchanged.';

-- ===========================================================================
-- 3. The audit -- Brand.audit(), check for check
-- ===========================================================================

create or replace function app.brand_floor(p_tier text)
returns double precision
language sql immutable
set search_path = ''
as $$
  select case p_tier when 'text' then 4.5 when 'graphic' then 3.0 when 'faint' then 1.6 end
$$;

-- The product default. Deliberately NOT any customer's palette: it is what
-- Brand.normalize({id, name}) derives from its own built-in chrome, so a tenant
-- with no brand at all still gets a coherent, audited field. Six hex codes and
-- a name is the whole onboarding story.
create or replace function app.brand_default()
returns jsonb
language sql immutable
set search_path = ''
as $$
  select app.brand_normalize(jsonb_build_object(
    'id',        'product',
    'name',      'Play Designer',
    'shortName', 'Play Designer',
    'wordmark',  jsonb_build_object('text', 'Play Designer', 'accent', 'Designer')
  ))
$$;


comment on function app.brand_floor(text) is
  'Brand.MIN: 4.5 for anything a person reads, 3.0 for a line or a ring that must be seen, 1.6 for the deliberately recessive grid and sidelines.';

-- The most legible of the brand's own surfaces against a filled accent. Not
-- "dark accent means light text", which is the obvious rule and is wrong: on a
-- light theme with a crimson accent it picks the dark ink and lands at 1.85:1.
create or replace function app.brand_accent_ink(p_colors jsonb, p_print boolean)
returns text
language plpgsql immutable
set search_path = ''
as $$
declare
  best text; best_r double precision := 0; r double precision; cand text;
begin
  if p_print then return '#FFFFFF'; end if;
  best := p_colors ->> 'page';
  foreach cand in array array[p_colors ->> 'page', p_colors ->> 'deep',
                              p_colors ->> 'chalk', p_colors ->> 'board'] loop
    r := app.brand_contrast(app.brand_rgb(cand), app.brand_rgb(p_colors ->> 'accent'));
    if r > best_r then best_r := r; best := cand; end if;
  end loop;
  return best;
end $$;

-- Every check names the real pair of colours a human actually looks at, with
-- the translucent layers composited first. The print column is not per-brand
-- and is not overridable -- print is the game-day output and toner costs money,
-- so every tenant degrades to the same black on white -- but it is still
-- audited, because "the same for everybody" is a claim worth measuring once.
create or replace function app.brand_audit(p_brand jsonb, p_print boolean default false)
returns table (
  check_id text,
  what     text,
  tier     text,
  floor_ratio double precision,
  fg       text,
  bg       text,
  ratio    numeric,
  pass     boolean
)
language plpgsql immutable
set search_path = ''
as $$
declare
  b jsonb := app.brand_normalize(p_brand);
  c jsonb;
  fld jsonb;
  is_dark_scheme boolean;
  g       double precision[]; ch double precision[]; ln double precision[];
  pl      double precision[]; ht double precision[];
  circle  double precision[]; chip double precision[]; loschip double precision[];
  ink     double precision[]; hair double precision[];
  chip_op double precision; los_op double precision;
  them_op double precision; side_op double precision;
begin
  c   := b -> 'colors';
  fld := b -> 'field';

  if p_print then
    -- Brand.PRINT, verbatim, plus vars()'s print chrome.
    g  := app.brand_rgb('#FFFFFF');
    ch := app.brand_rgb('#000000');
    ln := app.brand_rgb('#000000');
    pl := app.brand_rgb('#FFFFFF');
    ht := app.brand_rgb('#000000');
    circle := app.brand_rgb('#FFFFFF');
    chip_op := 1; los_op := 1; them_op := 0.8; side_op := 0.5;
    c := jsonb_build_object('page','#FFFFFF','board','#FFFFFF','deep','#FFFFFF',
                            'chalk','#000000','soft','#000000',
                            'accent','#000000','warm','#000000');
    is_dark_scheme := false;
  else
    g  := app.brand_rgb(fld ->> 'grass');
    ch := app.brand_rgb(fld ->> 'chalk');
    ln := app.brand_rgb(fld ->> 'line');
    pl := app.brand_rgb(fld ->> 'plate');
    ht := app.brand_rgb(fld ->> 'hot');
    circle := app.brand_over(app.brand_rgb(fld ->> 'circleFill'), g);
    chip_op := (fld ->> 'chipOp')::double precision;
    los_op  := (fld ->> 'losChipOp')::double precision;
    them_op := (fld ->> 'themOp')::double precision;
    side_op := (fld ->> 'sideOp')::double precision;
    is_dark_scheme := (b ->> 'scheme') = 'dark';
  end if;

  chip    := app.brand_over(pl, g, chip_op);
  loschip := app.brand_over(pl, g, los_op);
  -- Read the button ink and the hairline back out of the same derivation the
  -- page paints from, so the audit can never pass a colour the app does not use.
  ink  := app.brand_rgb(app.brand_accent_ink(c, p_print));
  hair := app.brand_over(
            app.brand_rgb(app.brand_rgba(c ->> 'chalk',
              case when is_dark_scheme then 0.25 else 0.45 end)),
            app.brand_rgb(c ->> 'deep'));

  return query
  select x.cid, x.cwhat, x.ctier,
         app.brand_floor(x.ctier),
         app.brand_hex(x.cfg), app.brand_hex(x.cbg),
         round(app.brand_contrast(x.cfg, x.cbg)::numeric, 2),
         app.brand_contrast(x.cfg, x.cbg) + 1e-9 >= app.brand_floor(x.ctier)
    from (values
      ('label-on-circle',    'position label inside a player circle',        ln, circle, 'text'),
      ('name-on-chip',       'player name on its chip',                      ch, chip,   'text'),
      ('chalk-on-grass',     'field ink on the grass',                       ch, g,      'text'),
      ('los-label',          'line-of-scrimmage label on its chip',          ln, loschip,'text'),
      ('route-on-grass',     'a route line on the grass',                    ln, g,      'graphic'),
      ('collision-on-grass', 'collision ring / X-man badge',                 ht, g,      'graphic'),
      ('circle-edge',        'the circle stroke against the grass',          ln, g,      'graphic'),
      ('them-on-grass',      'the other team''s marks',    app.brand_over(ch, g, them_op), g, 'faint'),
      ('sideline-on-grass',  'sideline',                   app.brand_over(ch, g, side_op), g, 'faint'),
      ('ui-text',            'body text on the page',
         app.brand_rgb(c ->> 'chalk'),  app.brand_rgb(c ->> 'page'),  'text'),
      ('ui-muted',           'hint and label text',
         app.brand_rgb(c ->> 'soft'),   app.brand_rgb(c ->> 'page'),  'text'),
      ('ui-on-board',        'header text on the raised surface',
         app.brand_rgb(c ->> 'chalk'),  app.brand_rgb(c ->> 'board'), 'text'),
      ('ui-accent',          'the club colour in the wordmark',
         app.brand_rgb(c ->> 'accent'), app.brand_rgb(c ->> 'board'), 'text'),
      ('ui-button',          'button text',
         app.brand_rgb(c ->> 'chalk'),  app.brand_rgb(c ->> 'deep'),  'text'),
      ('ui-accent-button',   'text on an accent-filled button',
         ink,                           app.brand_rgb(c ->> 'accent'), 'text'),
      ('ui-border',          'a control''s hairline against the control',
         hair,                          app.brand_rgb(c ->> 'deep'),  'faint'),
      ('ui-warm',            'the second accent in the chrome',
         app.brand_rgb(c ->> 'warm'),   app.brand_rgb(c ->> 'page'),  'graphic')
    ) as x(cid, cwhat, cfg, cbg, ctier);
end $$;

comment on function app.brand_audit(jsonb, boolean) is
  'The seventeen contrast checks of Brand.audit(), same ids, same tiers, same floors, with translucent layers composited first. Pass is measured on the unrounded ratio; the ratio column is rounded for reading.';

-- ===========================================================================
-- 4. The refusal
-- ===========================================================================
-- Named, measured, and never clamped. A coach who picks navy on navy is told
-- which pair he broke and by how much, because "invalid brand" sends him back
-- to guessing and this whole file exists to stop the guessing.

create or replace function app.brand_assert(p_brand jsonb)
returns boolean
language plpgsql stable
set search_path = ''
as $$
declare
  b        jsonb;
  bad      text;
  slot     text;
  nm       text;
  v        double precision;
begin
  if p_brand is null then return true; end if;
  if jsonb_typeof(p_brand) <> 'object' then
    raise exception 'brand: a record is a json object' using errcode = '22023';
  end if;
  if app.brand_jstr(p_brand, 'id') is null then
    raise exception 'brand: a record needs an id' using errcode = '22023';
  end if;

  b := app.brand_normalize(p_brand);

  -- No webfonts. brand.js warns and falls back; the column refuses, because a
  -- stored URL is a URL somebody eventually loads, and this app is used on a
  -- practice field with no signal.
  foreach slot in array array['body','mono','display'] loop
    nm := b -> 'fonts' ->> slot;
    if not (nm = any (app.brand_font_names())) then
      raise exception 'brand %: fonts.% is %, which is not one of the built-in stacks (%). A brand names a font, it never supplies one -- nothing may block on the network.',
        b ->> 'id', slot, quote_literal(nm), array_to_string(app.brand_font_names(), ', ')
        using errcode = '22023';
    end if;
  end loop;

  -- Every colour slot has to be a colour. An unparseable one would otherwise
  -- audit as black and could pass by accident.
  foreach slot in array array['page','board','deep','chalk','soft','accent','warm'] loop
    if app.brand_rgb(b -> 'colors' ->> slot) is null then
      raise exception 'brand %: colors.% is %, which is not a colour',
        b ->> 'id', slot, quote_literal(b -> 'colors' ->> slot) using errcode = '22023';
    end if;
  end loop;
  foreach slot in array array['grass','chalk','line','plate','hot','circleFill','routeFill'] loop
    if app.brand_rgb(b -> 'field' ->> slot) is null then
      raise exception 'brand %: field.% is %, which is not a colour',
        b ->> 'id', slot, quote_literal(b -> 'field' ->> slot) using errcode = '22023';
    end if;
  end loop;

  -- Opacities are opacities. brand.js would carry a 7 through to the renderer
  -- and draw an opaque yard grid over the eleven men.
  foreach slot in array array['gridOp','hashOp','sideOp','themOp','chipOp','losChipOp','leadOp','aimOp'] loop
    v := (b -> 'field' ->> slot)::double precision;
    if v < 0 or v > 1 then
      raise exception 'brand %: field.% is %, and an opacity is between 0 and 1',
        b ->> 'id', slot, v using errcode = '22023';
    end if;
  end loop;
  v := (b -> 'field' ->> 'stroke')::double precision;
  if v <= 0 or v > 8 then
    raise exception 'brand %: field.stroke is %, and a route is between 0 and 8 units wide',
      b ->> 'id', v using errcode = '22023';
  end if;

  -- And then the part that matters.
  select string_agg(
           format('%s (%s) %s on %s is %s:1, needs %s:1 (short by %s)',
                  case when a.print then 'print ' else '' end || a.check_id,
                  a.what, a.fg, a.bg, a.ratio, a.floor_ratio,
                  round((a.floor_ratio - a.ratio)::numeric, 2)),
           '; ' order by a.print, a.check_id)
    into bad
    from (
      select false as print, q.* from app.brand_audit(p_brand, false) q
      union all
      select true  as print, q.* from app.brand_audit(p_brand, true)  q
    ) a
   where not a.pass;

  if bad is not null then
    raise exception 'brand % fails contrast: %', b ->> 'id', bad
      using errcode = '23514',
            hint = 'Nothing is clamped. Change one of the named colours until the ratio clears its floor, or use app.brand_audit(<record>) to see all seventeen checks.';
  end if;
  return true;
end $$;

comment on function app.brand_assert(jsonb) is
  'Refuse an unreadable brand, naming every failing pair and its shortfall. Mirrors Brand.assertContrast(): screen and print, seventeen checks each. Also refuses a font that is not one of the built-in stacks -- the one place the database is stricter than the client.';

-- ===========================================================================
-- 5. The columns
-- ===========================================================================
-- Nullable, and NULL means "inherit". There is deliberately no DEFAULT: a
-- default would make every existing row branded, and then a league changing its
-- colours would silently fail to reach the teams that had been given a copy of
-- the old ones. Inheritance is the feature; a stored copy is the bug it avoids.

alter table public.leagues add column if not exists brand jsonb;
alter table public.teams   add column if not exists brand jsonb;

comment on column public.leagues.brand is
  'The league''s look, in the shape product/brand/brand.js takes. NULL means the product default. Set through app.set_league_brand(); a league admin may write it, nobody else.';
comment on column public.teams.brand is
  'The club''s own look, overriding its league''s. NULL means "use the league''s, or the product default". Set through app.set_team_brand(); the head coach or a league admin may write it.';

alter table public.leagues
  add constraint leagues_brand_object check (brand is null or jsonb_typeof(brand) = 'object'),
  add constraint leagues_brand_id     check (brand is null or
    (jsonb_typeof(brand -> 'id') = 'string' and length(btrim(brand ->> 'id')) > 0));

alter table public.teams
  add constraint teams_brand_object check (brand is null or jsonb_typeof(brand) = 'object'),
  add constraint teams_brand_id     check (brand is null or
    (jsonb_typeof(brand -> 'id') = 'string' and length(btrim(brand ->> 'id')) > 0));

-- The contrast floor cannot be a CHECK constraint: a check may not call a
-- function that raises a useful message, and "violates check constraint
-- teams_brand_readable" tells a coach nothing. A BEFORE trigger can name the
-- pair. It binds the table OWNER too, which a policy would not, so a migration
-- or a seed cannot slip an unreadable palette in either -- brand-seed.sql
-- passing is therefore a real test of our own two palettes.
create or replace function app.brand_readable_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.brand is not null then
    perform app.brand_assert(new.brand);
  end if;
  return new;
end $$;

comment on function app.brand_readable_guard() is
  'BEFORE INSERT OR UPDATE OF brand. Inert when brand is NULL, which is every row that existed before this file.';

create trigger leagues_brand_readable
  before insert or update of brand on public.leagues
  for each row execute function app.brand_readable_guard();

create trigger teams_brand_readable
  before insert or update of brand on public.teams
  for each row execute function app.brand_readable_guard();

-- ===========================================================================
-- 6. The resolver -- one fallback chain, shared by every client
-- ===========================================================================
-- team brand, then its league's, then the product default. Exposed as a
-- function so no client reimplements the chain; three clients each writing
-- their own coalesce is three chances for a team to show its league's colours
-- on one screen and its own on the next.
--
-- SECURITY INVOKER, deliberately, for the same reason app.league_rule() is: RLS
-- on public.teams and public.leagues applies, so a tenant you cannot see
-- resolves to the product default and hands you nothing. That is also the
-- answer for the platform owner, who holds no row-level reach anywhere and
-- therefore reads the product default for every team in the database.

create or replace function app.team_brand(p_team uuid)
returns jsonb
language sql stable
set search_path = ''
as $$
  select app.brand_normalize(coalesce(
    (select t.brand from public.teams t where t.id = p_team),
    (select l.brand from public.leagues l
       join public.teams t on t.league_id = l.id
      where t.id = p_team),
    app.brand_default()))
$$;

comment on function app.team_brand(uuid) is
  'The brand a team actually shows: its own, else its league''s, else the product default. Security INVOKER, so RLS applies and a team you cannot see resolves to the default rather than leaking another tenant''s colours.';

create or replace function app.league_brand(p_league uuid)
returns jsonb
language sql stable
set search_path = ''
as $$
  select app.brand_normalize(coalesce(
    (select l.brand from public.leagues l where l.id = p_league),
    app.brand_default()))
$$;

-- Which link of the chain answered. Useful to a settings screen ("your team is
-- using the league's colours") and to a test suite, and it is the same
-- SECURITY INVOKER read, so it cannot tell you about a tenant you cannot see.
create or replace function app.team_brand_source(p_team uuid)
returns text
language sql stable
set search_path = ''
as $$
  select case
    when exists (select 1 from public.teams t where t.id = p_team and t.brand is not null) then 'team'
    when exists (select 1 from public.leagues l join public.teams t on t.league_id = l.id
                  where t.id = p_team and l.brand is not null) then 'league'
    else 'default' end
$$;

-- ===========================================================================
-- 7. The setters -- authority from auth.sql, not from a new idea
-- ===========================================================================
-- A league admin sets the league brand. A head coach sets his own team's. An
-- assistant cannot, because app.may_staff_team() does not list him, which is
-- the same reason he cannot mint an invitation or staff the team. Nobody sets
-- another tenant's, because both helpers are scoped to the row being written.
--
-- SECURITY DEFINER because no tenant holds an UPDATE policy on public.leagues
-- at all, and only a league admin holds one on public.teams. The definer writes
-- exactly one column of exactly one row, after asking. Passing NULL clears the
-- brand and falls back up the chain -- which is the only "delete" in this file
-- and removes nothing but a colour.

create or replace function app.set_league_brand(p_league uuid, p_brand jsonb)
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare v_out jsonb;
begin
  if (select auth.uid()) is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  if p_league is null then
    raise exception 'name a league' using errcode = '22023';
  end if;
  if not app.may_staff_league(p_league) then
    raise exception 'you are not an admin of that league' using errcode = '42501',
      hint = 'A league brand is set by a league admin. A head coach brands his own team with app.set_team_brand().';
  end if;
  if p_brand is not null then
    perform app.brand_assert(p_brand);
  end if;
  update public.leagues set brand = p_brand where id = p_league
    returning brand into v_out;
  if not found then
    raise exception 'no such league' using errcode = '42501';
  end if;
  return v_out;
end $$;

create or replace function app.set_team_brand(p_team uuid, p_brand jsonb)
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare v_out jsonb;
begin
  if (select auth.uid()) is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  if p_team is null then
    raise exception 'name a team' using errcode = '22023';
  end if;
  if not app.may_staff_team(p_team) then
    raise exception 'you do not run that team' using errcode = '42501',
      hint = 'A team brand is set by its head coach, or by an admin of its league. An assistant coaches; he does not staff or brand.';
  end if;
  if p_brand is not null then
    perform app.brand_assert(p_brand);
  end if;
  update public.teams set brand = p_brand where id = p_team
    returning brand into v_out;
  if not found then
    raise exception 'no such team' using errcode = '42501';
  end if;
  return v_out;
end $$;

comment on function app.set_team_brand(uuid, jsonb) is
  'Set or clear one team''s brand. Authority is app.may_staff_team() -- head of this team, or admin of its league -- and the palette must clear the contrast floors first.';

-- ===========================================================================
-- 8. Privileges
-- ===========================================================================
-- Same discipline as auth.sql and platform.sql: SECURITY DEFINER functions are
-- EXECUTE-to-PUBLIC by default, which would hand an anonymous session a
-- function running as the owner. Take it all back first, then hand out exactly
-- what is meant.

revoke all on function
  app.set_league_brand(uuid, jsonb), app.set_team_brand(uuid, jsonb),
  app.brand_readable_guard()
from public;

grant execute on function
  app.set_league_brand(uuid, jsonb), app.set_team_brand(uuid, jsonb)
to pd_authenticated;

-- The pure maths and the resolver are readable by anybody signed in or not:
-- they hold no tenant data, and app.team_brand() is INVOKER, so an anonymous
-- session asking about a team it cannot see gets the product default.
grant execute on function
  app.brand_rgb(text), app.brand_hex(double precision[]),
  app.brand_over(double precision[], double precision[], double precision),
  app.brand_luminance(double precision[]),
  app.brand_contrast(double precision[], double precision[]),
  app.brand_contrast(text, text),
  app.brand_num(double precision), app.brand_rgba(text, double precision),
  app.brand_mix(text, text, double precision), app.brand_is_dark(text),
  app.brand_jstr(jsonb, text), app.brand_jnum(jsonb, text, double precision),
  app.brand_font_names(), app.brand_default(), app.brand_normalize(jsonb),
  app.brand_floor(text), app.brand_accent_ink(jsonb, boolean),
  app.brand_audit(jsonb, boolean), app.brand_assert(jsonb),
  app.team_brand(uuid), app.league_brand(uuid), app.team_brand_source(uuid)
to pd_anon, pd_authenticated;

-- NO NEW POLICY IS CREATED IN THIS FILE, and that is the point. `brand` is a
-- column on two tables whose policies already say who may read the row, so it
-- is visible to exactly those people and to nobody else. In particular nothing
-- here gives a platform owner a row it did not already have: it holds no
-- membership by construction (platform.sql's separation rule), so
-- app.visible_league_ids() is empty for it, leagues_select and teams_select
-- return nothing, and app.team_brand() -- being INVOKER -- answers the product
-- default for every team in the database.

-- (no commit; the runner commits)
