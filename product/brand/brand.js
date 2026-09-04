/* brand.js — the white-label layer.
 *
 * One codebase, one engine, one field renderer; every league and every team
 * gets its own look. A coach at another club opens the app and it is HIS
 * club's — his name, his colours, his field. Nobody edits CSS to make that
 * happen: a tenant hands us a brand record, this file turns it into CSS
 * custom properties on :root and into the palette object the field renderer
 * already takes.
 *
 * Constraints this file exists to hold:
 *
 *   - No dependencies, no build step. It is a plain <script> and it also
 *     works from file:// and from inside an artifact viewer, which is why it
 *     never fetches anything on its own. The caller supplies the records.
 *   - No webfonts. A brand CANNOT supply a font URL: it picks a stack by NAME
 *     from FONT_STACKS below, all of which ship with the OS. This gets used on
 *     a sideline with no signal and nothing may block on the network.
 *   - Print is the game-day output. Every brand degrades to the SAME black-on-
 *     white palette; a brand cannot override it and put a green block on a
 *     cartridge. See PRINT.
 *   - Contrast is not a taste question. audit() computes real WCAG ratios for
 *     the places that actually carry meaning — the label inside a player
 *     circle, the name chip, the chalk on the grass — compositing translucent
 *     fills over their real backdrop first. A brand that fails is a bug.
 *
 * The record shape (everything but id/name has a default):
 *
 * {
 *   id: 'lehi',                       // stable key, never a display name
 *   name: 'Lehi Youth Football',      // the league or club, spelled out
 *   shortName: 'Lehi',
 *   scheme: 'dark' | 'light',         // drives color-scheme, nothing else
 *   colors: {                         // the page chrome
 *     page,    // app background
 *     board,   // raised surface: header, field box
 *     deep,    // recessed surface: buttons, selects, chips
 *     chalk,   // primary text ON page/board/deep (ink, whatever its colour)
 *     soft,    // muted text: labels, hints
 *     accent,  // the club colour that does the work: active states, wordmark
 *     warm     // the second accent: alerts, collisions, the X-man badge
 *   },
 *   field: {                          // the picture the plays are drawn on
 *     grass,   // turf
 *     chalk,   // yard lines, hashes, sidelines, player names, their X marks
 *     line,    // routes, arrowheads, the LOS, the circle stroke and its label
 *     plate,   // the little filled chip a name or the LOS label sits on
 *     hot,     // selection, collision rings, X-man badge
 *     circleFill, routeFill,          // may be rgba(); composited when audited
 *     stroke,                         // route/circle stroke width
 *     gridOp, hashOp, sideOp, themOp, chipOp, losChipOp, leadOp, aimOp
 *   },
 *   wordmark: { text: 'Lehi Special Teams', accent: 'Special Teams' },
 *   mark: { initials: 'LHI', shape: 'shield'|'disc'|'chevron', fg, bg },
 *   fonts: { body:'system', mono:'system', display:'condensed' }   // names only
 * }
 *
 * field is optional: leave it out and it is derived from colors, so a tenant
 * can be onboarded with six hex codes and still get a coherent field.
 */
var Brand = (function () {
  'use strict';

  /* ---------- fonts: names, never URLs ----------
     A brand chooses from this list. There is no escape hatch that takes a
     font file, because the one thing that must never happen on a practice
     field is the page waiting on a CDN. */
  var FONT_STACKS = {
    system: "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,'Helvetica Neue',Arial,sans-serif",
    mono: "ui-monospace,SFMono-Regular,Menlo,Consolas,'Liberation Mono',monospace",
    condensed: "'Haettenschweiler','Arial Narrow',Impact,-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif",
    grotesk: "'Segoe UI',Roboto,'Helvetica Neue',Helvetica,Arial,sans-serif",
    slab: "'Rockwell','Roboto Slab',Georgia,'Times New Roman',serif",
    humanist: "'Optima','Gill Sans','Gill Sans MT',Candara,Calibri,sans-serif"
  };

  /* ---------- colour maths ---------- */
  function parse(c) {
    if (c == null) return null;
    if (typeof c === 'object' && c.length === 4) return c.slice();
    var s = String(c).trim();
    var m = s.match(/^#([0-9a-f]{3,8})$/i);
    if (m) {
      var h = m[1];
      if (h.length === 3 || h.length === 4) h = h.split('').map(function (x) { return x + x; }).join('');
      var a = h.length === 8 ? parseInt(h.slice(6, 8), 16) / 255 : 1;
      return [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16), a];
    }
    m = s.match(/^rgba?\(([^)]+)\)$/i);
    if (m) {
      var p = m[1].split(/[,\s/]+/).filter(function (x) { return x !== ''; }).map(Number);
      return [p[0], p[1], p[2], p.length > 3 ? p[3] : 1];
    }
    return null;
  }

  function hex(c) {
    var p = parse(c); if (!p) return '#000000';
    return '#' + [0, 1, 2].map(function (i) {
      var v = Math.round(Math.max(0, Math.min(255, p[i]))).toString(16);
      return v.length < 2 ? '0' + v : v;
    }).join('');
  }

  /* Composite fg (which may be translucent) over an opaque backdrop. Every
     contrast number below runs through this, because a circle fill of
     rgba(19,37,31,.55) is not a colour until you know what is under it. */
  function over(fg, bg, alphaOverride) {
    var f = parse(fg), b = parse(bg);
    if (!f) return b ? b.slice() : [0, 0, 0, 1];
    if (!b) return f.slice();
    var a = alphaOverride == null ? f[3] : alphaOverride;
    return [f[0] * a + b[0] * (1 - a), f[1] * a + b[1] * (1 - a), f[2] * a + b[2] * (1 - a), 1];
  }

  function luminance(c) {
    var p = parse(c); if (!p) return 0;
    function ch(v) { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }
    return 0.2126 * ch(p[0]) + 0.7152 * ch(p[1]) + 0.0722 * ch(p[2]);
  }

  /* WCAG 2.1 relative-contrast ratio. Both arguments must already be opaque —
     use over() first if either is not. */
  function contrast(a, b) {
    var l1 = luminance(a), l2 = luminance(b);
    return (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05);
  }

  function mix(a, b, t) {
    var x = parse(a), y = parse(b);
    return hex([x[0] + (y[0] - x[0]) * t, x[1] + (y[1] - x[1]) * t, x[2] + (y[2] - x[2]) * t, 1]);
  }

  function rgba(c, a) {
    var p = parse(c);
    return 'rgba(' + Math.round(p[0]) + ',' + Math.round(p[1]) + ',' + Math.round(p[2]) + ',' + a + ')';
  }

  function isDark(c) { return luminance(c) < 0.22; }

  /* ---------- the print palette ----------
     Deliberately not per-brand and deliberately not overridable. Print is the
     game-day output and toner costs money: black on white, every tenant, the
     same way designer.html has always done it. */
  var PRINT = {
    grass: '#FFFFFF', chalk: '#000000', line: '#000000', plate: '#FFFFFF', hot: '#000000',
    gridOp: 0.13, hashOp: 0.26, sideOp: 0.5, themOp: 0.8, chipOp: 1, losChipOp: 1,
    leadOp: 0.5, aimOp: 1, circleFill: '#FFFFFF', routeFill: '#FFFFFF', stroke: 1.6
  };

  var FIELD_DEFAULT_OPS = {
    gridOp: 0.09, hashOp: 0.2, sideOp: 0.3, themOp: 0.42, chipOp: 0.82,
    losChipOp: 0.72, leadOp: 0.42, aimOp: 0.85, stroke: 2
  };

  /* ---------- normalise ----------
     Fills every slot so the rest of the file never has to test for one, and
     derives a whole field from the chrome colours when a tenant only gave us
     six hex codes. Additive: it never drops a key it did not recognise. */
  function normalize(rec) {
    if (!rec || !rec.id) throw new Error('brand: a record needs an id');
    var b = {};
    for (var k in rec) if (Object.prototype.hasOwnProperty.call(rec, k)) b[k] = rec[k];

    var c = {};
    var src = rec.colors || {};
    c.page = src.page || '#13251F';
    c.board = src.board || mix(c.page, isDark(c.page) ? '#FFFFFF' : '#000000', 0.06);
    c.deep = src.deep || mix(c.page, isDark(c.page) ? '#000000' : '#FFFFFF', 0.35);
    c.chalk = src.chalk || (isDark(c.page) ? '#EDEBE0' : '#16211C');
    c.soft = src.soft || mix(c.chalk, c.page, 0.42);
    c.accent = src.accent || '#E3B547';
    c.warm = src.warm || '#E58A6B';
    b.colors = c;

    b.scheme = rec.scheme || (isDark(c.page) ? 'dark' : 'light');

    var f = {}, fs = rec.field || {};
    f.grass = fs.grass || c.board;
    f.chalk = fs.chalk || c.chalk;
    f.line = fs.line || c.accent;
    f.plate = fs.plate || c.page;
    f.hot = fs.hot || c.warm;
    f.circleFill = fs.circleFill || rgba(f.plate, 0.55);
    f.routeFill = fs.routeFill || rgba(f.line, 0.28);
    Object.keys(FIELD_DEFAULT_OPS).forEach(function (k) {
      f[k] = fs[k] == null ? FIELD_DEFAULT_OPS[k] : fs[k];
    });
    b.field = f;

    var w = rec.wordmark || {};
    b.wordmark = { text: w.text || rec.name, accent: w.accent || '' };

    var m = rec.mark || {};
    b.mark = {
      initials: (m.initials || (rec.shortName || rec.name || '?').slice(0, 3)).toUpperCase(),
      shape: m.shape || 'shield',
      bg: m.bg || c.accent,
      fg: m.fg || (isDark(m.bg || c.accent) ? c.chalk : c.page)
    };

    b.shortName = rec.shortName || rec.name;

    /* Fonts by name only. An unknown name — or anything that looks like a URL,
       which is the failure this guard exists for — falls back to the system
       stack and says so, rather than shipping a page that waits on a CDN. */
    var fr = rec.fonts || {};
    b.fonts = {
      body: stack(fr.body, 'system'),
      mono: stack(fr.mono, 'mono'),
      display: stack(fr.display, 'condensed')
    };
    return b;
  }

  /* The most legible of the brand's own surfaces against a filled accent. */
  function accentInk(c, printing) {
    if (printing) return '#FFFFFF';
    var best = c.page, bestR = 0;
    [c.page, c.deep, c.chalk, c.board].forEach(function (cand) {
      var r = contrast(cand, c.accent);
      if (r > bestR) { bestR = r; best = cand; }
    });
    return best;
  }

  function stack(name, fallback) {
    if (!name) return FONT_STACKS[fallback];
    if (FONT_STACKS[name]) return FONT_STACKS[name];
    if (typeof console !== 'undefined' && console.warn) {
      console.warn('brand: unknown font stack "' + name + '" — no webfonts are allowed, using ' + fallback);
    }
    return FONT_STACKS[fallback];
  }

  /* ---------- the field palette ----------
     Same shape designer.html's PAL_SCREEN/PAL_PRINT already have, including the
     legacy key names (gold, deep), so a renderer written against those keeps
     working with no edit: pal() becomes Brand.palette(current, printing). */
  function palette(rec, printing) {
    var b = rec && rec.field ? rec : normalize(rec || { id: 'default' });
    var f = printing ? PRINT : b.field;
    return {
      grass: f.grass, chalk: f.chalk, line: f.line, plate: f.plate, hot: f.hot,
      gold: f.line,   // legacy name: the accent that draws routes and circles
      deep: f.plate,  // legacy name: the chip backdrop
      gridOp: f.gridOp, hashOp: f.hashOp, sideOp: f.sideOp, themOp: f.themOp,
      chipOp: f.chipOp, losChipOp: f.losChipOp, leadOp: f.leadOp, aimOp: f.aimOp,
      circleFill: f.circleFill, routeFill: f.routeFill, stroke: f.stroke,
      printing: !!printing
    };
  }

  /* ---------- the CSS custom properties ----------
     The whole point of the layer: everything the chrome needs is a var, so a
     tenant changes by data and no stylesheet is touched. Returns the map it
     set, which is what a test asserts against. */
  function vars(rec, printing) {
    var b = rec && rec.colors ? rec : normalize(rec);
    var P = palette(b, printing);
    var c = b.colors, ink, page;

    if (printing) {
      page = '#FFFFFF'; ink = '#000000';
      c = { page: page, board: page, deep: page, chalk: ink, soft: ink, accent: ink, warm: ink };
    }
    /* Dark keeps designer.html's own rgba(237,235,224,.25) so Lehi is
       byte-identical to today. A light theme needs more: the same alpha over a
       white button collapsed to 1.01:1, which is a border nobody can see. */
    var dark = !printing && b.scheme === 'dark';
    var hair = rgba(c.chalk, dark ? 0.25 : 0.45);

    var v = {
      '--page': c.page, '--board': c.board, '--deep': c.deep,
      '--chalk': c.chalk, '--soft': c.soft,
      '--accent': c.accent, '--warm': c.warm,
      /* designer.html's stylesheet says var(--gold); keeping the alias means an
         existing page themes with no CSS edit at all. */
      '--gold': c.accent,
      '--hairline': hair,
      '--hairline-strong': rgba(c.chalk, dark ? 0.4 : 0.6),
      /* Text on an accent-filled button. "Dark accent means light text" is the
         obvious rule and it is wrong: on a light theme with a crimson accent it
         picks the dark ink and lands at 1.85:1. Pick whichever surface the brand
         already owns actually reads on it. */
      '--accent-ink': accentInk(c, printing),
      '--field-grass': P.grass, '--field-chalk': P.chalk, '--field-line': P.line,
      '--field-plate': P.plate, '--field-hot': P.hot,
      '--field-circle-fill': P.circleFill, '--field-route-fill': P.routeFill,
      '--field-stroke': String(P.stroke),
      '--body': b.fonts.body, '--mono': b.fonts.mono, '--display': b.fonts.display
    };
    return v;
  }

  /* Apply to a root element (default :root). Also sets color-scheme so form
     controls and scrollbars follow the theme, and data-brand so a page can
     hang a rule off the tenant if it ever has to. */
  function apply(rec, opts) {
    opts = opts || {};
    var b = rec && rec.colors ? rec : normalize(rec);
    var root = opts.root || (typeof document !== 'undefined' ? document.documentElement : null);
    if (!root) return null;
    var v = vars(b, opts.print);
    Object.keys(v).forEach(function (k) { root.style.setProperty(k, v[k]); });
    root.style.setProperty('color-scheme', opts.print ? 'light' : b.scheme);
    if (root.setAttribute) {
      root.setAttribute('data-brand', b.id);
      root.setAttribute('data-scheme', opts.print ? 'print' : b.scheme);
    }
    return v;
  }

  /* ---------- wordmark and mark ---------- */
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (ch) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch];
    });
  }

  /* "Lehi Special Teams" with "Special Teams" in the club colour. The accent
     run is matched literally and only the first occurrence is wrapped. */
  function wordmarkHTML(rec) {
    var b = rec && rec.wordmark ? rec : normalize(rec);
    var t = b.wordmark.text || b.name, a = b.wordmark.accent;
    if (!a) return esc(t);
    var i = t.indexOf(a);
    if (i < 0) return esc(t);
    return esc(t.slice(0, i)) + '<span class="wm-accent">' + esc(a) + '</span>' + esc(t.slice(i + a.length));
  }

  /* A club mark with no image file behind it: initials in a shape, drawn from
     the brand's own colours. Nothing to host, nothing to load offline. */
  function markSVG(rec, size, printing) {
    var b = rec && rec.mark ? rec : normalize(rec);
    var s = size || 28, m = b.mark, d;
    /* On paper the club mark is an outline, not a block of club colour. Same
       reason the field goes black on white: toner. */
    if (printing) m = { initials: m.initials, shape: m.shape, bg: '#FFFFFF', fg: '#000000' };
    if (m.shape === 'disc') d = 'M14,1 A13,13 0 1,1 13.99,1 Z';
    else if (m.shape === 'chevron') d = 'M2,3 H26 L14,27 Z';
    else d = 'M3,3 H25 V14 C25,21 20,25 14,27 C8,25 3,21 3,14 Z';
    var fsz = m.initials.length > 2 ? 9 : 11;
    return '<svg viewBox="0 0 28 28" width="' + s + '" height="' + s + '" role="img" aria-label="' +
      esc(b.shortName || b.name) + '">' +
      '<path d="' + d + '" fill="' + esc(m.bg) + '"' +
      (printing ? ' stroke="#000000" stroke-width="1.5"' : '') + '/>' +
      '<text x="14" y="' + (m.shape === 'chevron' ? 15 : 18) + '" text-anchor="middle" fill="' + esc(m.fg) +
      '" font-family="' + esc(FONT_STACKS.mono) + '" font-size="' + fsz + '" font-weight="700"' +
      ' letter-spacing="0.5">' + esc(m.initials) + '</text></svg>';
  }

  /* ---------- contrast audit ----------
     Every check names the real pair of colours a human actually looks at, with
     the translucent layers composited first. Tiers:
       text     4.5  something a coach or a boy has to read
       graphic  3.0  a line or a ring that has to be seen, not read
       faint    1.6  deliberately recessive: the yard grid, the sidelines,
                     the other team's marks. They must be visible without
                     competing with the eleven men who matter. */
  var MIN = { text: 4.5, graphic: 3.0, faint: 1.6 };

  function audit(rec, printing) {
    var b = rec && rec.colors ? rec : normalize(rec);
    var f = printing ? PRINT : b.field, c = b.colors;
    if (printing) c = { page: '#FFFFFF', board: '#FFFFFF', deep: '#FFFFFF', chalk: '#000000', soft: '#000000', accent: '#000000', warm: '#000000' };

    var circle = over(f.circleFill, f.grass);
    var chip = over(f.plate, f.grass, f.chipOp);
    var losChip = over(f.plate, f.grass, f.losChipOp);
    /* Read the button ink back out of vars(), so the audit can never pass a
       colour the page does not actually paint. */
    var ink = vars(b, printing)['--accent-ink'];

    var checks = [
      ck('label-on-circle', 'position label inside a player circle', f.line, circle, 'text'),
      ck('name-on-chip', 'player name on its chip', f.chalk, chip, 'text'),
      ck('chalk-on-grass', 'field ink on the grass', f.chalk, f.grass, 'text'),
      ck('los-label', 'line-of-scrimmage label on its chip', f.line, losChip, 'text'),
      ck('route-on-grass', 'a route line on the grass', f.line, f.grass, 'graphic'),
      ck('collision-on-grass', 'collision ring / X-man badge', f.hot, f.grass, 'graphic'),
      ck('circle-edge', 'the circle stroke against the grass', f.line, f.grass, 'graphic'),
      ck('them-on-grass', 'the other team\'s marks', over(f.chalk, f.grass, f.themOp), f.grass, 'faint'),
      ck('sideline-on-grass', 'sideline', over(f.chalk, f.grass, f.sideOp), f.grass, 'faint'),
      ck('ui-text', 'body text on the page', c.chalk, c.page, 'text'),
      ck('ui-muted', 'hint and label text', c.soft, c.page, 'text'),
      ck('ui-on-board', 'header text on the raised surface', c.chalk, c.board, 'text'),
      ck('ui-accent', 'the club colour in the wordmark', c.accent, c.board, 'text'),
      ck('ui-button', 'button text', c.chalk, c.deep, 'text'),
      ck('ui-accent-button', 'text on an accent-filled button', ink, c.accent, 'text'),
      ck('ui-border', 'a control\'s hairline against the control', over(vars(b, printing)['--hairline'], c.deep), c.deep, 'faint'),
      ck('ui-warm', 'the second accent in the chrome', c.warm, c.page, 'graphic')
    ];
    var fails = checks.filter(function (x) { return !x.pass; });
    return { id: b.id, print: !!printing, checks: checks, fails: fails, pass: fails.length === 0 };
  }

  function ck(id, what, fg, bg, tier) {
    var r = contrast(fg, bg);
    return {
      id: id, what: what, tier: tier, min: MIN[tier],
      fg: hex(fg), bg: hex(bg),
      ratio: Math.round(r * 100) / 100, pass: r + 1e-9 >= MIN[tier]
    };
  }

  /* Throws with the failing lines named. Use it in a test, not on a field. */
  function assertContrast(rec) {
    var out = [audit(rec, false), audit(rec, true)];
    var bad = out.reduce(function (a, o) {
      return a.concat(o.fails.map(function (x) {
        return (o.print ? 'print ' : '') + x.id + ' ' + x.ratio + ':1 (needs ' + x.min + ')';
      }));
    }, []);
    if (bad.length) throw new Error('brand ' + (rec.id || '?') + ' fails contrast: ' + bad.join('; '));
    return true;
  }

  /* ---------- the registry ----------
     No fetching in here on purpose (rule 4): the page decides where records
     come from — an inlined <script type="application/json">, a fetch when one
     is reachable, or a tenant row out of the database. */
  var REG = {}, ORDER = [];
  function register(recs) {
    (Array.isArray(recs) ? recs : [recs]).forEach(function (r) {
      var b = normalize(r);
      if (!REG[b.id]) ORDER.push(b.id);
      REG[b.id] = b;
    });
    return ORDER.map(function (id) { return REG[id]; });
  }
  function get(id) { return REG[id] || null; }
  function all() { return ORDER.map(function (id) { return REG[id]; }); }

  return {
    FONT_STACKS: FONT_STACKS, PRINT: PRINT, MIN: MIN,
    normalize: normalize, palette: palette, vars: vars, apply: apply,
    wordmarkHTML: wordmarkHTML, markSVG: markSVG,
    audit: audit, assertContrast: assertContrast, contrast: contrast,
    luminance: luminance, over: over, mix: mix, rgba: rgba, hex: hex, parse: parse,
    register: register, get: get, all: all
  };
})();

if (typeof module !== 'undefined' && module.exports) module.exports = Brand;
