/* formations.js — the shippable geometry.
 *
 * A team that signs up gets an EMPTY playbook. It cannot get anybody else's
 * plays: a play is a coach's IP, and a product whose content is one club's
 * offense is worthless to a buyer. What it CAN get is formations — a spread
 * punt, a 6-2-2-1, ten across from the 40. That is public-domain football
 * every coach already knows, and it is the difference between an empty screen
 * and a coach drawing his first route in ninety seconds.
 *
 *   Ship alignments. Never ship plays.
 *
 * So everything in here emits alignment and labels ONLY. No routes, no jobs,
 * no target mark, no player names, no team name. check() enforces that, not
 * as a style rule but as the licence boundary: the moment a formation carries
 * a route it has stopped being geometry and started being somebody's call.
 *
 * NOT COORDINATES — PARAMETERS. Nothing in this file was lifted out of an
 * existing playbook. Every man's spot is computed from numbers a coach says
 * out loud: one-yard splits, punter at fourteen, gunners at the numbers,
 * returner at forty. That is the product. A coach who wants wider splits
 * changes a number and the geometry follows; a coach who is handed a picture
 * has to drag eleven circles.
 *
 * ---- the two scales, and why they are not the same ----
 *
 * ACROSS the field is true: 392px between the sidelines is 53.3 yards, so
 * across(yd) is honest and a gunner at 21 yards from the ball is drawn where
 * 21 yards is.
 *
 * A SPLIT between two neighbours cannot be. A player circle is 24px across —
 * 3.3 yards — so a true two-foot line split draws five men in one pile. So
 * split(yd) = one body + the true distance. Two-foot splits and two-yard
 * splits still draw differently, in the right order, by the right amount;
 * they are simply both pushed out by a body. The root app already made this
 * compromise by hand for its offensive line. This is that compromise, named,
 * measured and in one function.
 *
 * DEPTH is compressed past six yards, because a formation has to hold a wing
 * one yard off the ball AND a kick returner forty-five yards away inside 500
 * pixels. depth() is piecewise linear and strictly increasing: nothing ever
 * reorders, a deeper man is always drawn deeper.
 *
 * ---- conventions ----
 *
 * Labels follow the house convention (CLAUDE.md, "Label convention"):
 * L/R prefix for the side, numbering OUTWARD from the reference man (the ball,
 * or the kicker). L is screen-left of the ball in every formation here;
 * mirror() flips the geometry AND the labels together, so it stays true.
 *
 * Our team is always at LARGER y — downfield is up the screen, toward y=0.
 *
 * No dependencies, no build step, works from file://.
 */
var Formations = (function () {
  'use strict';

  /* ---------- the field ---------- */
  var FIELD = { W: 420, H: 500, left: 14, right: 406, yardsWide: 53.3 };
  var PX_PER_YD = (FIELD.right - FIELD.left) / FIELD.yardsWide;   /* 7.3546 */
  var BODY = 24;    /* a player circle is r=12 */
  var CLEAR = 26;   /* centre to centre: a body, plus a hair so two never kiss */
  var DEPTH = { nearYd: 6, near: 10, far: 5.2 };
  var LINE_TOL = 5; /* within half a yard of the line counts as ON the line */

  function across(yd) { return yd * PX_PER_YD; }
  function split(yd) { return CLEAR + Math.max(0, yd) * PX_PER_YD; }
  function depth(yd, d) {
    d = d || DEPTH;
    if (yd <= d.nearYd) return yd * d.near;
    return d.nearYd * d.near + (yd - d.nearYd) * d.far;
  }
  function yards(px) { return px / PX_PER_YD; }
  function r1(v) { return Math.round(v * 10) / 10; }

  /* ---------- small helpers ---------- */
  function def(v, d) { return v === undefined || v === null ? d : v; }
  function merge() {
    var out = {}, i, k;
    for (i = 0; i < arguments.length; i++) {
      var o = arguments[i]; if (!o) continue;
      for (k in o) if (Object.prototype.hasOwnProperty.call(o, k)) out[k] = o[k];
    }
    return out;
  }
  function fail(msg) { throw new Error('formations: ' + msg); }
  /* A width that may be one number for both sides, or {left,right} when the
     ball is not in the middle of the field and the two sides are not the
     same job. */
  function sideVal(v, side) { return (v && typeof v === 'object') ? v[side] : v; }

  /* Evenly spaced splits from `near` to `far`, in yards, n of them.
     n===1 sits at the near number, not at the average of the two, because a
     coach who says "one man, four yards off me" means four. */
  function ladder(n, near, far) {
    var out = [], i;
    if (n <= 0) return out;
    if (n === 1) return [near];
    for (i = 0; i < n; i++) out.push(near + (far - near) * (i / (n - 1)));
    return out;
  }

  /* Symmetric neighbour splits around a middle: n men, gap g px between
     neighbours. Returns px offsets from the middle, left to right. */
  function row(n, g) {
    var out = [], i, start = -(n - 1) / 2;
    for (i = 0; i < n; i++) out.push((start + i) * g);
    return out;
  }

  /* ---------- the document ---------- */
  var SEQ = 0;
  function man(label, x, y) {
    return { id: 'f' + (++SEQ), team: 'us', label: label, x: r1(x), y: r1(y) };
  }
  function doc(o) {
    var d = {
      slug: o.slug || null,
      name: o.name || null,
      formation: true,
      family: o.family,
      phase: o.phase,
      generator: o.generator,
      params: o.params,
      lineOfScrimmage: r1(o.los),
      lineLabel: o.lineLabel,
      players: o.players
    };
    if (o.params.mirror) { d = mirror(d); d.params = merge(d.params, { mirror: true }); }
    return d;
  }

  /* ---------- mirror ----------
     Flips about the ball and swaps the side labels with it, so L stays
     screen-left and a formation's STRENGTH is what actually changes. This is
     the only sanctioned way to flip: hand-rolling one is how a look called
     "ball left" ended up running right. */
  var PAIRS = { WILL: 'SAM', SAM: 'WILL' };
  function swapSideLabel(lab) {
    if (PAIRS[lab]) return PAIRS[lab];
    if (/^L[A-Z0-9]/.test(lab)) return 'R' + lab.slice(1);
    if (/^R[A-Z0-9]/.test(lab)) return 'L' + lab.slice(1);
    return lab;
  }
  function mirror(d) {
    var bx = d.params.ballX;
    var players = d.players.map(function (p) {
      return { id: p.id, team: p.team, label: swapSideLabel(p.label), x: r1(2 * bx - p.x), y: p.y };
    });
    return merge(d, { players: players });
  }

  /* ================================================================
     1. PUNT — the spread punt, and every punt between spread and tight
     ================================================================
     { split, punterDepth, wingDepth, protectorOffset } are the four numbers a
     punt coach actually says. Seven on the line: five interior plus the two
     gunners. The wings are OFF the line by design — that is what makes the
     seven legal, and it is checked, not assumed. */
  var PUNT = {
    los: 190, ballX: 210, lineLabel: 'LINE OF SCRIMMAGE',
    split: 1,             /* yd between interior linemen */
    tackleSplit: null,    /* defaults to split */
    gunnerSplit: 21,      /* yd from the ball out to the gunner; a number, or
                             {left,right} when the ball is on a hash and the
                             boundary gunner has less field to work with */
    wingSplit: 1,         /* yd outside the tackle */
    wingDepth: 1.5,       /* yd behind the line */
    protectorDepth: 5,
    protectorOffset: 2,   /* yd off the midline, so the snap lane is clear */
    protectorSide: 'L',
    punterDepth: 14,
    mirror: false
  };
  function spreadPunt(opts) {
    var q = merge(PUNT, opts || {});
    if (q.tackleSplit == null) q.tackleSplit = q.split;
    var g = split(q.split), t = g + split(q.tackleSplit), P = [];
    var b = q.ballX, los = q.los;

    P.push(man('S', b, los));
    P.push(man('LGD', b - g, los));
    P.push(man('RGD', b + g, los));
    P.push(man('LT', b - t, los));
    P.push(man('RT', b + t, los));
    P.push(man('LG', b - across(sideVal(q.gunnerSplit, 'left')), los));   /* gunners, on the line */
    P.push(man('RG', b + across(sideVal(q.gunnerSplit, 'right')), los));
    P.push(man('LW', b - t - split(q.wingSplit), los + depth(q.wingDepth)));
    P.push(man('RW', b + t + split(q.wingSplit), los + depth(q.wingDepth)));
    P.push(man('PP', b + (q.protectorSide === 'L' ? -1 : 1) * across(q.protectorOffset),
      los + depth(q.protectorDepth)));
    P.push(man('P', b, los + depth(q.punterDepth)));

    return doc({
      family: 'punt', phase: 'special', generator: 'spreadPunt', params: q,
      los: los, lineLabel: q.lineLabel, players: P
    });
  }

  /* ================================================================
     2. PUNT RETURN — any n-n-n-1 shape
     ================================================================
     shape is read, not hardcoded: '6-2-2-1' is six up front, two second
     level, two in the wall, one returner. Change it to '5-2-3-1' and the rows
     rebuild with the right labels. */
  var PUNT_RETURN = {
    los: 126, ballX: 210, lineLabel: 'LINE OF SCRIMMAGE',
    shape: '6-2-2-1',
    jammerWidth: 21,     /* yd from the ball — they line up on the gunners */
    holdUpSplit: 2.5,    /* yd between the interior front men */
    frontDepth: 1.5,     /* yd off the ball: nobody in the neutral zone */
    level2Depth: 8, level2Width: 6,
    wallDepth: 16, wallWidth: 9, wallSplit: 5,
    returnerDepth: 40, returnerWidth: 5,
    mirror: false
  };
  function rows(shape) {
    var r = String(shape).split('-').map(Number);
    if (r.some(function (n) { return !(n > 0) || n !== Math.round(n); })) fail('shape "' + shape + '" is not a row count');
    var sum = r.reduce(function (a, b) { return a + b; }, 0);
    if (sum !== 11) fail('shape "' + shape + '" adds up to ' + sum + ', not 11');
    return r;
  }
  /* Interior labels, numbered OUTWARD from the middle. One per side drops the
     numeral (LH, not LH1) because that is how it is said out loud. */
  function outward(n, base) {
    var per = n >> 1, out = [], i, mid = n % 2 === 1;
    for (i = per; i >= 1; i--) out.push('L' + base + (per > 1 ? i : ''));
    if (mid) out.push('M' + base);
    for (i = 1; i <= per; i++) out.push('R' + base + (per > 1 ? i : ''));
    return out;
  }
  function puntReturn(opts) {
    var q = merge(PUNT_RETURN, opts || {});
    var R = rows(q.shape), b = q.ballX, los = q.los, P = [];
    if (R.length < 3) fail('a punt return needs a front, a second level and a returner');

    /* front row: two jammers on the gunners, the rest holding up inside */
    var nf = R[0];
    if (nf < 3) fail('front row of ' + nf + ' has no room for two jammers and a hold-up man');
    var fy = los + depth(q.frontDepth);
    P.push(man('LJ', b - across(q.jammerWidth), fy));
    P.push(man('RJ', b + across(q.jammerWidth), fy));
    var inner = outward(nf - 2, 'H'), off = row(nf - 2, split(q.holdUpSplit));
    inner.forEach(function (lab, i) { P.push(man(lab, b + off[i], fy)); });

    /* the middle rows: second level, then the wall */
    var mid = R.slice(1, R.length - 1);
    mid.forEach(function (n, i) {
      var last = i === mid.length - 1;
      var base = last ? 'W' : 'M';
      var dep = mid.length === 1 ? q.wallDepth
        : q.level2Depth + (q.wallDepth - q.level2Depth) * (i / (mid.length - 1));
      var wid = last ? q.wallWidth : q.level2Width;
      var y = los + depth(dep);
      if (n === 2) {
        P.push(man('L' + base, b - across(wid), y));
        P.push(man('R' + base, b + across(wid), y));
      } else {
        var labs = outward(n, base), o = row(n, split(q.wallSplit));
        labs.forEach(function (lab, j) { P.push(man(lab, b + o[j], y)); });
      }
    });

    /* the returner, or a pair of them */
    var nr = R[R.length - 1], ry = los + depth(q.returnerDepth);
    if (nr === 1) P.push(man('PR', b, ry));
    else if (nr === 2) {
      P.push(man('LPR', b - across(q.returnerWidth), ry));
      P.push(man('RPR', b + across(q.returnerWidth), ry));
    } else fail('a punt return fields one or two returners, not ' + nr);

    return doc({
      family: 'punt-return', phase: 'special', generator: 'puntReturn', params: q,
      los: los, lineLabel: q.lineLabel, players: P
    });
  }

  /* ================================================================
     3. KICKOFF — from { kicker spot, how many either side, restraining line }
     ================================================================
     Each side is its own object so a 6/4 onside look is the same generator as
     ten across: the kick side bunches (near 3, far 15), the away side spreads.
     `rows` staggers alternate men back — that is what a cluster IS, and it is
     also the only way eleven men fit inside the numbers without overlapping. */
  var KICKOFF = {
    los: 330, kickerX: 210, lineLabel: 'FREE KICK LINE',
    kickerDepth: 6,   /* his approach, drawn behind the line */
    lineDepth: 0.5,   /* the cover men, a half yard behind it */
    left: { count: 5, near: 4, far: 24, rows: 1, rowGap: 2.5 },
    right: { count: 5, near: 4, far: 24, rows: 1, rowGap: 2.5 },
    mirror: false
  };
  function kickoff(opts) {
    var q = merge(KICKOFF, opts || {});
    q.left = merge(KICKOFF.left, q.left); q.right = merge(KICKOFF.right, q.right);
    var n = q.left.count + q.right.count;
    if (n !== 10) fail('a kickoff has ten cover men plus the kicker, not ' + n);
    var los = q.los, k = q.kickerX, P = [];

    ['left', 'right'].forEach(function (side) {
      var s = q[side], sign = side === 'left' ? -1 : 1;
      ladder(s.count, s.near, s.far).forEach(function (yd, i) {
        var back = s.rows > 1 ? (i % s.rows) * s.rowGap : 0;
        P.push(man((side === 'left' ? 'L' : 'R') + (i + 1),
          k + sign * across(yd), los + depth(q.lineDepth + back)));
      });
    });
    P.push(man('K', k, los + depth(q.kickerDepth)));

    return doc({
      family: 'kickoff', phase: 'special', generator: 'kickoff', params: q,
      los: los, lineLabel: q.lineLabel, players: P
    });
  }

  /* ================================================================
     4. KICK RETURN — { front line count, wall depth, deep pair width }
     ================================================================
     First row is the hands team, H1..Hn left to right. Last row is the deep
     pair. Everything between is blockers: one middle row is the wall (LB/RB),
     two rows are a second level (LM/RM) and then the wall. */
  var KICK_RETURN = {
    los: 60, ballX: 210, lineLabel: 'THEIR FREE KICK LINE',
    shape: '5-2-2-2',
    frontDepth: 10,     /* the receiving team's own restraining line */
    frontSpread: 22,    /* yd from the ball out to the widest hands man */
    midDepth: 20, midWidth: 6,
    wallDepth: 28, wallWidth: 9, wallSplit: 4,
    deepDepth: 45, deepPairWidth: 10,   /* width BETWEEN the two deep men */
    mirror: false
  };
  function kickReturn(opts) {
    var q = merge(KICK_RETURN, opts || {});
    var R = rows(q.shape), b = q.ballX, los = q.los, P = [];
    if (R.length < 2) fail('a kick return needs a front line and a deep man');

    var fy = los + depth(q.frontDepth), nf = R[0];
    ladder(nf, -q.frontSpread, q.frontSpread).forEach(function (yd, i) {
      P.push(man('H' + (i + 1), b + across(yd), fy));
    });

    var mid = R.slice(1, R.length - 1);
    mid.forEach(function (n, i) {
      var last = i === mid.length - 1;
      var base = last ? 'B' : 'M';
      var dep = mid.length === 1 ? q.wallDepth
        : q.midDepth + (q.wallDepth - q.midDepth) * (i / (mid.length - 1));
      var wid = last ? q.wallWidth : q.midWidth;
      var y = los + depth(dep);
      if (n === 2) {
        P.push(man('L' + base, b - across(wid), y));
        P.push(man('R' + base, b + across(wid), y));
      } else {
        var labs = outward(n, base), o = row(n, split(q.wallSplit));
        labs.forEach(function (lab, j) { P.push(man(lab, b + o[j], y)); });
      }
    });

    var nd = R[R.length - 1], dy = los + depth(q.deepDepth);
    if (nd === 2) {
      P.push(man('LR', b - across(q.deepPairWidth / 2), dy));
      P.push(man('RR', b + across(q.deepPairWidth / 2), dy));
    } else if (nd === 1) P.push(man('R1', b, dy));
    else fail('a kick return keeps one or two men deep, not ' + nd);

    return doc({
      family: 'kick-return', phase: 'special', generator: 'kickReturn', params: q,
      los: los, lineLabel: q.lineLabel, players: P
    });
  }

  /* ================================================================
     5. OFFENSE — a scrimmage set, from splits, back depth, receiver width
     ================================================================
     Seven on the line is not a preference, it is the rule the whole formation
     is built around, so this generator SOLVES for it: five linemen, plus the
     tight end if there is one, plus as many outside receivers as it takes to
     reach seven — outermost first, which is exactly how a legal trips set is
     aligned. If the personnel cannot make seven it throws rather than emit an
     illegal formation. */
  var OFFENSE = {
    los: 250, ballX: 210, lineLabel: 'LINE OF SCRIMMAGE',
    lineSplit: 0.66,      /* two feet. Drawn a body apart; see split(). */
    te: 'R',              /* 'L', 'R' or 'none' */
    teSplit: 1,
    wide: { left: [18, 12.5], right: [18] },  /* yd from the ball; a 2x2 with the TE */
    qbDepth: 5,
    backs: [{ depth: 8, offset: 3 }],
    offBall: 1.2,         /* how far a receiver off the line is drawn back */
    mirror: false
  };
  var SLOT_LABELS = ['H', 'Y', 'W', 'A'];
  var BACK_LABELS = ['F', 'H', 'B', 'T'];
  function offenseSet(opts) {
    var q = merge(OFFENSE, opts || {});
    q.wide = merge(OFFENSE.wide, q.wide);
    var b = q.ballX, los = q.los, P = [], used = {};
    var te = q.te === 'L' || q.te === 'R' ? q.te : null;

    var nw = q.wide.left.length + q.wide.right.length;
    var nb = q.backs.length;
    var total = 5 + (te ? 1 : 0) + nw + 1 + nb;
    if (total !== 11) fail('this set has ' + total + ' men: 5 line + ' + (te ? 1 : 0) +
      ' TE + ' + nw + ' wide + QB + ' + nb + ' back(s)');

    /* the five, and the tight end beside a tackle */
    var g = split(q.lineSplit), t = 2 * g;
    P.push(man('C', b, los)); used.C = 1;
    P.push(man('LG', b - g, los)); P.push(man('RG', b + g, los));
    P.push(man('LT', b - t, los)); P.push(man('RT', b + t, los));
    var teX = null;
    if (te) {
      teX = te === 'L' ? b - t - split(q.teSplit) : b + t + split(q.teSplit);
      P.push(man('Y', teX, los)); used.Y = 1;
    }

    /* how many wide receivers have to be on the line to make seven */
    var need = 7 - 5 - (te ? 1 : 0);
    if (need < 0 || need > nw) fail('cannot make seven on the line with ' + nw +
      ' receiver(s) and ' + (te ? 'a' : 'no') + ' tight end');

    /* widest first, backside (the side without the tight end) first: the
       outermost man on a side is the one who may be on the line without
       covering up the man inside him. */
    var sides = te === 'R' ? ['left', 'right'] : ['right', 'left'];
    var order = [], slot = 0;
    sides.forEach(function (side) {
      q.wide[side].slice().sort(function (a, c) { return c - a; }).forEach(function (yd, i) {
        order.push({ side: side, yd: yd, outermost: i === 0 });
      });
    });
    var onLine = 0;
    order.forEach(function (w) {
      w.online = w.outermost && onLine < need;
      if (w.online) onLine++;
    });
    if (onLine !== need) fail('only ' + onLine + ' receiver(s) can legally be on the line; needed ' + need);

    order.forEach(function (w) {
      var sign = w.side === 'left' ? -1 : 1, lab;
      if (w.outermost) lab = w.side === 'left' ? 'X' : 'Z';
      else { while (used[SLOT_LABELS[slot]]) slot++; lab = SLOT_LABELS[slot]; }
      used[lab] = 1;
      P.push(man(lab, b + sign * across(w.yd), los + (w.online ? 0 : depth(q.offBall))));
    });

    P.push(man('QB', b, los + depth(q.qbDepth))); used.QB = 1;
    var bi = 0;
    q.backs.forEach(function (bk) {
      while (used[BACK_LABELS[bi]]) bi++;
      var lab = BACK_LABELS[bi]; used[lab] = 1;
      P.push(man(lab, b + across(def(bk.offset, 0)), los + depth(bk.depth)));
    });

    return doc({
      family: 'offense', phase: 'offense', generator: 'offenseSet', params: q,
      los: los, lineLabel: q.lineLabel, players: P
    });
  }

  /* ================================================================
     6. DEFENSE — a front, from { front, backers, widths, depths }
     ================================================================
     front + backers + two corners + whatever is left at safety = 11, so 4-3
     and 5-2 keep two safeties and a 4-4 keeps one. The defence has no
     seven-on-the-line rule; what IS checked is that the declared front is the
     number of men actually down on the ball. */
  var DEFENSE = {
    los: 250, ballX: 210, lineLabel: 'LINE OF SCRIMMAGE',
    front: 4, backers: 3,
    dlSplit: 2,      /* yd between down linemen */
    dlDepth: 1,      /* off the ball */
    lbDepth: 4.5, lbWidth: 5, lbSplit: 5,
    cbDepth: 5, cbWidth: 16,
    safetyDepth: 12, safetyWidth: 8,
    mirror: false
  };
  var DL4 = ['LDE', 'LDT', 'RDT', 'RDE'];
  var DL5 = ['LDE', 'LDT', 'NG', 'RDT', 'RDE'];
  var DL3 = ['LDE', 'NG', 'RDE'];
  var DL6 = ['LDE', 'LDT', 'LNG', 'RNG', 'RDT', 'RDE'];
  var LB2 = ['WILL', 'SAM'], LB3 = ['WILL', 'MIKE', 'SAM'], LB4 = ['WILL', 'MIKE', 'SAM', 'ROVER'];
  function defenseFront(opts) {
    var q = merge(DEFENSE, opts || {});
    var b = q.ballX, los = q.los, P = [];
    var dl = { 3: DL3, 4: DL4, 5: DL5, 6: DL6 }[q.front];
    var lb = { 2: LB2, 3: LB3, 4: LB4 }[q.backers];
    if (!dl) fail('no label set for a ' + q.front + '-man front');
    if (!lb) fail('no label set for ' + q.backers + ' linebackers');
    var safeties = 11 - q.front - q.backers - 2;
    if (safeties < 0 || safeties > 2) fail('a ' + q.front + '-' + q.backers +
      ' leaves ' + safeties + ' safeties; that is not a defence');

    var off = row(q.front, split(q.dlSplit)), dy = los + depth(q.dlDepth);
    dl.forEach(function (lab, i) { P.push(man(lab, b + off[i], dy)); });

    var ly = los + depth(q.lbDepth);
    if (q.backers === 3) {
      P.push(man('WILL', b - across(q.lbWidth), ly));
      P.push(man('MIKE', b, ly));
      P.push(man('SAM', b + across(q.lbWidth), ly));
    } else {
      var lo = row(q.backers, split(q.lbSplit));
      lb.forEach(function (lab, i) { P.push(man(lab, b + lo[i], ly)); });
    }

    P.push(man('LCB', b - across(q.cbWidth), los + depth(q.cbDepth)));
    P.push(man('RCB', b + across(q.cbWidth), los + depth(q.cbDepth)));
    var sy = los + depth(q.safetyDepth);
    if (safeties === 2) {
      P.push(man('FS', b - across(q.safetyWidth), sy));
      P.push(man('SS', b + across(q.safetyWidth), sy));
    } else if (safeties === 1) P.push(man('FS', b, sy));

    return doc({
      family: 'defense', phase: 'defense', generator: 'defenseFront', params: q,
      los: los, lineLabel: q.lineLabel, players: P
    });
  }

  /* ================================================================
     check() — validate the FOOTBALL, not just the code
     ================================================================
     Shared with the browser on purpose. A coach dragging a slider gets told
     his alignment is illegal; nothing is silently clamped, because a clamp
     lies about what he asked for. */
  var GEN = {
    spreadPunt: spreadPunt, puntReturn: puntReturn, kickoff: kickoff,
    kickReturn: kickReturn, offenseSet: offenseSet, defenseFront: defenseFront
  };
  var SNAPPING = { punt: true, offense: true };

  function dist(a, c) { return Math.sqrt((a.x - c.x) * (a.x - c.x) + (a.y - c.y) * (a.y - c.y)); }

  function check(d) {
    var errs = [], warn = [], P = d.players || [], los = d.lineOfScrimmage;
    var b = (d.params && d.params.ballX) || (d.params && d.params.kickerX) || FIELD.W / 2;
    function e(m) { errs.push(m); }

    /* --- eleven men --- */
    if (P.length !== 11) e('has ' + P.length + ' men, not 11');

    /* --- the licence boundary: alignment only --- */
    ['routes', 'aim', 'looks', 'howItWorks', 'mirrorOf'].forEach(function (k) {
      if (d[k] != null) e('carries "' + k + '" — a formation is alignment only, never a play');
    });
    P.forEach(function (p) {
      ['player', 'name', 'job', 'role', 'covers', 'number'].forEach(function (k) {
        if (p[k] != null) e(p.label + ' carries "' + k + '" — formations ship no personnel');
      });
    });

    /* --- inside the field --- */
    P.forEach(function (p) {
      if (p.x < FIELD.left || p.x > FIELD.right)
        e(p.label + ' is outside the sideline at x=' + p.x + ' (field is ' + FIELD.left + '–' + FIELD.right + ')');
      if (p.y < 8 || p.y > FIELD.H - 8)
        e(p.label + ' is off the picture at y=' + p.y + ' (0–' + FIELD.H + ')');
    });

    /* --- a body width apart --- */
    var closest = { d: Infinity, a: null, b: null }, i, j;
    for (i = 0; i < P.length; i++) for (j = i + 1; j < P.length; j++) {
      var dd = dist(P[i], P[j]);
      if (dd < closest.d) closest = { d: dd, a: P[i].label, b: P[j].label };
      if (dd < CLEAR) e(P[i].label + ' and ' + P[j].label + ' are ' + r1(dd) +
        'px apart — closer than a body (' + CLEAR + 'px)');
    }

    /* --- labels: unique, and the house convention --- */
    var seen = {};
    P.forEach(function (p) {
      if (!p.label) e('a man has no label');
      else if (seen[p.label]) e('two men are labelled ' + p.label);
      else if (!/^[A-Z][A-Z0-9]{0,4}$/.test(p.label)) e('label "' + p.label + '" is not the house convention');
      seen[p.label] = 1;
    });
    /* L is one side of the reference, R is the other, M is on it. */
    P.forEach(function (p) {
      if (/^L[A-Z0-9]/.test(p.label) && p.x >= b) e(p.label + ' is an L label but sits right of the ball');
      if (/^R[A-Z0-9]/.test(p.label) && p.x <= b) e(p.label + ' is an R label but sits left of the ball');
      if (/^M[A-Z]$/.test(p.label) && Math.abs(p.x - b) > CLEAR)
        e(p.label + ' is a middle label but sits ' + r1(Math.abs(p.x - b)) + 'px off the ball');
    });
    /* numbering runs OUTWARD from the reference (L1 nearest, L5 widest) */
    var groups = {};
    P.forEach(function (p) {
      var m = /^([LR][A-Z]*?)(\d+)$/.exec(p.label);
      if (m) { (groups[m[1]] = groups[m[1]] || []).push({ n: +m[2], x: p.x, label: p.label }); }
    });
    Object.keys(groups).forEach(function (k) {
      var g = groups[k].sort(function (a, c) { return a.n - c.n; });
      for (var i2 = 1; i2 < g.length; i2++)
        if (Math.abs(g[i2].x - b) <= Math.abs(g[i2 - 1].x - b))
          e(g[i2].label + ' is not further out than ' + g[i2 - 1].label + ' — numbering runs outward');
    });
    /* the hands team reads left to right */
    var H = P.filter(function (p) { return /^H\d+$/.test(p.label); })
      .sort(function (a, c) { return +a.label.slice(1) - +c.label.slice(1); });
    for (i = 1; i < H.length; i++)
      if (H[i].x <= H[i - 1].x) e(H[i].label + ' is not right of ' + H[i - 1].label);

    /* --- the football, per family --- */
    var onLine = P.filter(function (p) { return Math.abs(p.y - los) <= LINE_TOL; });
    if (SNAPPING[d.family]) {
      if (onLine.length !== 7)
        e('has ' + onLine.length + ' men on the line, not 7 (' +
          onLine.map(function (p) { return p.label; }).join(' ') + ')');
      P.forEach(function (p) {
        if (p.y < los - 0.01) e(p.label + ' is over the line of scrimmage');
      });
    }
    if (d.family === 'punt-return' || d.family === 'defense') {
      P.forEach(function (p) {
        if (p.y <= los + 3) e(p.label + ' is in the neutral zone at y=' + p.y);
      });
    }
    if (d.family === 'defense') {
      var down = P.filter(function (p) { return p.y <= los + depth(2) + 0.01; });
      if (down.length !== d.params.front)
        e('declared a ' + d.params.front + '-man front but ' + down.length + ' men are down on the ball');
    }
    if (d.family === 'kickoff') {
      P.forEach(function (p) {
        if (p.y < los - 0.01) e(p.label + ' is over the restraining line at y=' + p.y);
      });
      var k = P.filter(function (p) { return p.label === 'K'; })[0];
      if (!k) e('no kicker');
      else {
        var L = P.filter(function (p) { return p.x < k.x; }).length;
        var R = P.filter(function (p) { return p.x > k.x; }).length;
        if (L < 4) e('only ' + L + ' men left of the kicker; a free kick needs four either side');
        if (R < 4) e('only ' + R + ' men right of the kicker; a free kick needs four either side');
      }
    }
    if (d.family === 'kick-return') {
      var lim = los + depth(10) - 0.5;
      P.forEach(function (p) {
        if (p.y < lim) e(p.label + ' is inside the ten-yard free kick zone at y=' + p.y);
      });
    }

    return {
      ok: errs.length === 0, errors: errs, warnings: warn,
      men: P.length, onLine: onLine.length,
      closest: r1(closest.d), closestPair: closest.a + '/' + closest.b,
      span: r1(Math.max.apply(null, P.map(function (p) { return p.x; })) -
        Math.min.apply(null, P.map(function (p) { return p.x; }))),
      depth: r1(Math.max.apply(null, P.map(function (p) { return p.y; })) - los)
    };
  }

  /* build a catalog entry: { id, name, generator, params } */
  function build(entry) {
    var g = GEN[entry.generator];
    if (!g) fail('no generator called ' + entry.generator);
    var d = g(entry.params || {});
    d.slug = entry.id; d.name = entry.name;
    if (entry.lineLabel) d.lineLabel = entry.lineLabel;
    return d;
  }
  function buildAll(catalog) {
    return (catalog.formations || []).map(build);
  }

  return {
    FIELD: FIELD, PX_PER_YD: PX_PER_YD, BODY: BODY, CLEAR: CLEAR, DEPTH: DEPTH, LINE_TOL: LINE_TOL,
    across: across, split: split, depth: depth, yards: yards,
    spreadPunt: spreadPunt, puntReturn: puntReturn, kickoff: kickoff,
    kickReturn: kickReturn, offenseSet: offenseSet, defenseFront: defenseFront,
    generators: GEN, defaults: {
      spreadPunt: PUNT, puntReturn: PUNT_RETURN, kickoff: KICKOFF,
      kickReturn: KICK_RETURN, offenseSet: OFFENSE, defenseFront: DEFENSE
    },
    mirror: mirror, swapSideLabel: swapSideLabel,
    check: check, build: build, buildAll: buildAll
  };
})();

if (typeof module !== 'undefined' && module.exports) module.exports = Formations;
