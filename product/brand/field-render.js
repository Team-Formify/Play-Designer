/* field-render.js — the brand-agnostic field drawing, in one place.
 *
 * It came out of preview.html because there are two pages in this folder now
 * (preview.html, which shows three tenants at once, and picker.html, where a
 * club builds its own) and CLAUDE.md is explicit about what happens next: both
 * pages carry their own copy, every fix has to be written twice, and the second
 * copy is the one that goes wrong. That is why play-engine.js exists; this is
 * the same argument one layer up.
 *
 * It is pure of branding: EVERY colour in here is C.something, where C is
 * Brand.palette(record, printing). There is not one literal colour below, which
 * is the whole claim the white-label layer is making.
 *
 * Depends on the global PE (product/engine/play-engine.js) for the curves and
 * the geometry. No DOM assumptions beyond an <svg> to draw into, no storage,
 * no fetch — the caller supplies the play.
 *
 *   FieldRender.draw(svg, play, C, {names:true, nameOf:fn})
 *   FieldRender.adapt(rawPlayFromJSON, lookIndex) -> play
 *   FieldRender.looksOf(rawPlayFromJSON)          -> [{name,how,aim,routes}]
 */
var FieldRender = (function () {
  'use strict';

  var SVGNS = 'http://www.w3.org/2000/svg';
  var MONO = "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace";

  function E(tag, attrs) {
    var n = document.createElementNS(SVGNS, tag);
    for (var k in attrs) n.setAttribute(k, attrs[k]);
    return n;
  }

  /* ---------- the play, in the shape the renderer wants ----------
     special-teams-plays.json calls it lineOfScrimmage and puts the name on
     `player`; a play may carry several looks. This is the only adapter. */
  function looksOf(raw) {
    if (raw.looks && raw.looks.length) return raw.looks;
    return [{ name: '', how: raw.howItWorks || '', aim: raw.aim, routes: raw.routes || [] }];
  }
  function adapt(raw, li) {
    var L = looksOf(raw)[li] || looksOf(raw)[0];
    return {
      slug: raw.slug, name: raw.name,
      los: raw.lineOfScrimmage, losLabel: raw.lineLabel || '',
      players: raw.players.filter(function (p) { return p.team !== 'them'; }).map(function (p) {
        return { id: p.id, label: p.label || '', name: p.player || '', x: p.x, y: p.y, xman: !!p.xman };
      }),
      routes: L.routes || [], aim: L.aim || null, how: L.how || raw.howItWorks || '', look: L.name || ''
    };
  }

  /* ---------- the view ----------
     Crop to what is actually on the field, the way the app does, so a cropped
     punt does not sit in a sea of empty grass in a 3-across preview. */
  function computeView(p, rects) {
    var VBW = PE.VBW, VBH = PE.VBH;
    var xs = [], ys = [];
    p.players.forEach(function (q) { xs.push(q.x); ys.push(q.y); });
    (p.routes || []).forEach(function (r) { (r.points || []).forEach(function (t) { xs.push(t.x); ys.push(t.y); }); });
    if (p.aim) { xs.push(p.aim.x); ys.push(p.aim.y); }
    ys.push(p.los);
    (rects || []).forEach(function (r) { xs.push(r.x, r.x + r.w); ys.push(r.y, r.y + r.h); });
    var x0 = Math.min.apply(null, xs) - 18, x1 = Math.max.apply(null, xs) + 18;
    var y0 = Math.min.apply(null, ys) - 22, y1 = Math.max.apply(null, ys) + 24;
    var w = x1 - x0, h = y1 - y0, c;
    if (w < 300) { c = (x0 + x1) / 2; x0 = c - 150; w = 300; }
    if (h < 250) { c = (y0 + y1) / 2; y0 = c - 125; h = 250; }
    /* Cap the zoom, or a cluster kickoff blows up so far you lose where on the
       field it is happening. */
    var scale = Math.min(VBW / w, VBH / h);
    if (scale > 2.4) { var cx = x0 + w / 2, cy = y0 + h / 2; w = VBW / 2.4; h = VBH / 2.4; x0 = cx - w / 2; y0 = cy - h / 2; }
    return { x: x0, y: y0, w: w, h: h };
  }

  /* Names must not sit on a circle, on another name, or on top of each other.
     First offset that is clear wins; the renderer draws a leader line whenever a
     name had to leave its default spot. */
  var SPOTS = [[0, 20], [0, -26], [30, 4], [-30, 4], [0, 34], [34, -18], [-34, -18], [0, -38]];
  function placeLabels(p, nameOf) {
    var out = {}, taken = [];
    p.players.forEach(function (q) { taken.push({ x: q.x - 13, y: q.y - 13, w: 26, h: 26 }); });
    p.players.forEach(function (q) {
      var txt = nameOf(q.name), w = Math.max(24, txt.length * 5.4 + 8);
      for (var i = 0; i < SPOTS.length; i++) {
        var dx = SPOTS[i][0], dy = SPOTS[i][1];
        var r = { x: q.x + dx - w / 2, y: q.y + dy, w: w, h: 12 };
        var clash = taken.some(function (t) { return PE.rectsOverlap(r, t); });
        if (!clash || i === SPOTS.length - 1) { taken.push(r); out[q.id] = { dx: dx, dy: dy, w: w, text: txt, rect: r }; break; }
      }
    });
    return out;
  }

  /* ---------- the field ---------- */
  function draw(svg, p, C, opts) {
    opts = opts || {};
    var showNames = opts.names !== false;
    var nameOf = opts.nameOf || function (n) { return n || ''; };
    var VBH = PE.VBH;
    svg.innerHTML = '';
    var lay = showNames ? placeLabels(p, nameOf) : {};
    var rects = Object.keys(lay).map(function (k) { return lay[k].rect; });
    var V = computeView(p, rects);
    svg.setAttribute('viewBox', V.x + ' ' + V.y + ' ' + V.w + ' ' + V.h);

    svg.appendChild(E('rect', { x: V.x, y: V.y, width: V.w, height: V.h, fill: C.grass }));

    var g = E('g', {}), y;
    for (y = 10; y <= VBH - 6; y += 28) g.appendChild(E('line', { x1: 14, x2: 406, y1: y, y2: y, stroke: C.chalk, 'stroke-opacity': C.gridOp }));
    [140, 280].forEach(function (hx) {
      for (y = 10; y <= VBH - 6; y += 28) g.appendChild(E('line', { x1: hx - 3, x2: hx + 3, y1: y, y2: y, stroke: C.chalk, 'stroke-opacity': C.hashOp }));
    });
    [14, 406].forEach(function (sx) {
      g.appendChild(E('line', { x1: sx, x2: sx, y1: 0, y2: VBH, stroke: C.chalk, 'stroke-opacity': C.sideOp, 'stroke-width': 2 }));
    });
    svg.appendChild(g);

    // line of scrimmage, and its chip
    svg.appendChild(E('line', {
      x1: V.x, x2: V.x + V.w, y1: p.los, y2: p.los, stroke: C.line,
      'stroke-width': 1.8, 'stroke-dasharray': '6 4'
    }));
    if (p.losLabel) {
      /* Anchored at the left of the view and moved OFF the line rather than along
         it: eleven men are standing on the line, so there is no horizontal gap to
         slide into. Same offsets designer.html's losLabelRect() uses. */
      var lw = p.losLabel.length * 5.6 + 8, lx = V.x + 6, ly = -6, offs = [-6, -25, 20, 36];
      for (var i = 0; i < offs.length; i++) {
        var rr = { x: lx - 3, y: p.los + offs[i] - 8, w: lw, h: 11 };
        var clash = p.players.some(function (q) { return PE.rectsOverlap(rr, { x: q.x - 15, y: q.y - 15, w: 30, h: 30 }); });
        if (!clash) { ly = offs[i]; break; }
      }
      svg.appendChild(E('rect', { x: lx - 3, y: p.los + ly - 8, width: lw, height: 11, rx: 2, fill: C.plate, 'fill-opacity': C.losChipOp }));
      var lt = E('text', { x: lx + 1, y: p.los + ly + 0.5, fill: C.line, 'font-family': MONO, 'font-size': 8.5 });
      lt.textContent = p.losLabel; svg.appendChild(lt);
    }

    // routes, drawn as the curve the engine draws and walks
    var byId = {}; p.players.forEach(function (q) { byId[q.id] = q; });
    (p.routes || []).forEach(function (r) {
      var o = byId[r.playerId]; if (!o || !r.points || !r.points.length) return;
      var pts = [{ x: o.x, y: o.y }].concat(r.points);
      svg.appendChild(E('path', {
        d: PE.smoothD(pts), fill: 'none', stroke: C.line, 'stroke-width': C.stroke,
        'stroke-linecap': 'round', 'stroke-linejoin': 'round'
      }));
      var sm = PE.smoothPts(pts), last = r.points[r.points.length - 1];
      var prev = sm.length > 2 ? sm[sm.length - 2] : pts[pts.length - 2];
      var ang = Math.atan2(last.y - prev.y, last.x - prev.x);
      [2.8, -2.8].forEach(function (s) {
        svg.appendChild(E('line', {
          x1: last.x, y1: last.y,
          x2: last.x - 9 * Math.cos(ang) + s * Math.sin(ang), y2: last.y - 9 * Math.sin(ang) - s * Math.cos(ang),
          stroke: C.line, 'stroke-width': C.stroke, 'stroke-linecap': 'round'
        }));
      });
    });

    // the other team, mirrored out of the play this one faces
    if (p.them) {
      p.them.men.forEach(function (m) {
        [[-7, -7, 7, 7], [-7, 7, 7, -7]].forEach(function (d) {
          svg.appendChild(E('line', {
            x1: m.x + d[0], y1: m.y + d[1], x2: m.x + d[2], y2: m.y + d[3],
            stroke: C.chalk, 'stroke-opacity': C.themOp, 'stroke-width': 2.2, 'stroke-linecap': 'round'
          }));
        });
      });
    }

    // the target mark: where the ball is meant to end up
    if (p.aim) drawAim(svg, p, C, V);

    // the eleven
    p.players.forEach(function (q) {
      svg.appendChild(E('circle', { cx: q.x, cy: q.y, r: 12, fill: C.circleFill, stroke: C.line, 'stroke-width': C.stroke }));
      if (q.label) {
        var t = E('text', { x: q.x, y: q.y + 3.4, 'text-anchor': 'middle', fill: C.line, 'font-family': MONO, 'font-size': 9 });
        t.textContent = q.label; svg.appendChild(t);
      }
      var L = lay[q.id];
      if (L && q.name) {
        var lx = q.x + L.dx, ly = q.y + L.dy;
        if (Math.abs(L.dx) > 4 || L.dy < 0 || L.dy > 20) {
          svg.appendChild(E('line', {
            x1: q.x, y1: q.y + (L.dy < 0 ? -12 : 12), x2: lx, y2: L.dy < 0 ? ly + 12 : ly,
            stroke: C.chalk, 'stroke-opacity': C.leadOp
          }));
        }
        svg.appendChild(E('rect', { x: lx - L.w / 2, y: ly, width: L.w, height: 12, rx: 2, fill: C.plate, 'fill-opacity': C.chipOp }));
        var n = E('text', {
          x: lx, y: ly + 9, 'text-anchor': 'middle', fill: C.chalk, 'font-family': MONO,
          'font-size': 9.5, 'letter-spacing': .2
        });
        n.textContent = L.text; svg.appendChild(n);
      }
    });
    return V;
  }

  function drawAim(svg, p, C, V) {
    var a = p.aim, from = p.players.filter(function (q) { return q.label === a.from; })[0];
    if (from) {
      var mx = (from.x + a.x) / 2 + (a.x - from.x) * 0.1, my = (from.y + a.y) / 2 - 34;
      svg.appendChild(E('path', {
        d: 'M' + from.x + ',' + from.y + ' Q' + mx + ',' + my + ' ' + a.x + ',' + a.y, fill: 'none',
        stroke: C.line, 'stroke-opacity': C.aimOp * .7, 'stroke-width': 1.3, 'stroke-dasharray': '2 5'
      }));
    }
    svg.appendChild(E('circle', { cx: a.x, cy: a.y, r: 8, fill: 'none', stroke: C.hot, 'stroke-opacity': C.aimOp, 'stroke-width': 1.6 }));
    [[-13, 0, 13, 0], [0, -13, 0, 13]].forEach(function (d) {
      svg.appendChild(E('line', {
        x1: a.x + d[0], y1: a.y + d[1], x2: a.x + d[2], y2: a.y + d[3],
        stroke: C.hot, 'stroke-opacity': C.aimOp, 'stroke-width': 1.4
      }));
    });
    if (!a.label) return;
    // Break the caption at the em dash and clamp it inside the view, or a long
    // line runs off the side of a cropped field.
    var lines = String(a.label).split(/\s*—\s*/), fs = 8;
    // a mono glyph is ~0.6em wide; underestimating it ran the caption off its chip
    var w = Math.max.apply(null, lines.map(function (s) { return s.length * fs * 0.62 + 8; }));
    var x = Math.max(V.x + 3, Math.min(V.x + V.w - w - 3, a.x - w / 2));
    var y = (a.y + 16 + lines.length * 10 > V.y + V.h - 3) ? a.y - 16 - lines.length * 10 : a.y + 14;
    svg.appendChild(E('rect', { x: x, y: y, width: w, height: lines.length * 10 + 2, rx: 2, fill: C.plate, 'fill-opacity': C.chipOp }));
    lines.forEach(function (s, i) {
      var t = E('text', { x: x + 4, y: y + 9 + i * 10, fill: C.hot, 'font-family': MONO, 'font-size': fs, 'letter-spacing': .3 });
      t.textContent = s; svg.appendChild(t);
    });
  }

  return { draw: draw, view: computeView, placeLabels: placeLabels, adapt: adapt, looksOf: looksOf, MONO: MONO };
})();

if (typeof module !== 'undefined' && module.exports) module.exports = FieldRender;
