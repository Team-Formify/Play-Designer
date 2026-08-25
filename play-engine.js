/* play-engine.js — the shared geometry behind both apps.
 *
 * The coach's app and the boys' app were each carrying their own copy of this,
 * and every fix had to be written twice. Four times in one day the second copy
 * was the one that went wrong. This is the one source of truth for it.
 *
 * Pure functions only: no DOM, no storage, no knowledge of either page's data
 * shapes. Each page passes plain numbers in and decorates what comes back.
 *
 * It is INLINED into index.html and learn.html by scripts/sync-engine.js, the
 * same way special-teams-plays.json is, because a <script src> cannot be read
 * when the page is opened as a downloaded file or run inside the artifact
 * viewer. Edit this file, then run:
 *
 *     node scripts/sync-engine.js
 *     node scripts/sync-engine.js --check     # exit 1 if they have drifted
 *
 * No dependencies, no build step. Running the app needs nothing.
 */
var PE = (function () {
  var VBW = 420, VBH = 500;

  /* ---------- curves ----------
     Nobody runs in straight lines with corners on them. The stored points are
     the shape of the run; these round them into one continuous path and sample
     that same path, so a man runs along the line that is drawn rather than
     cutting its corners. Two points stay a straight line, because that is what
     a straight line is. */
  var CURVE = 0.5;

  function smoothD(pts) {
    if (!pts || pts.length < 2) return '';
    var d = 'M' + pts[0].x + ',' + pts[0].y;
    if (pts.length === 2) return d + ' L' + pts[1].x + ',' + pts[1].y;
    for (var i = 0; i < pts.length - 1; i++) {
      var p0 = pts[i - 1] || pts[i], p1 = pts[i], p2 = pts[i + 1], p3 = pts[i + 2] || pts[i + 1];
      d += ' C' + (p1.x + (p2.x - p0.x) / 6 * CURVE) + ',' + (p1.y + (p2.y - p0.y) / 6 * CURVE) +
           ' ' + (p2.x - (p3.x - p1.x) / 6 * CURVE) + ',' + (p2.y - (p3.y - p1.y) / 6 * CURVE) +
           ' ' + p2.x + ',' + p2.y;
    }
    return d;
  }

  function smoothPts(pts) {
    if (!pts || pts.length < 3) return pts || [];
    var out = [{ x: pts[0].x, y: pts[0].y }], STEP = 6;
    for (var i = 0; i < pts.length - 1; i++) {
      var p0 = pts[i - 1] || pts[i], p1 = pts[i], p2 = pts[i + 1], p3 = pts[i + 2] || pts[i + 1];
      var c1x = p1.x + (p2.x - p0.x) / 6 * CURVE, c1y = p1.y + (p2.y - p0.y) / 6 * CURVE;
      var c2x = p2.x - (p3.x - p1.x) / 6 * CURVE, c2y = p2.y - (p3.y - p1.y) / 6 * CURVE;
      for (var k = 1; k <= STEP; k++) {
        var u = k / STEP, v = 1 - u;
        out.push({ x: v * v * v * p1.x + 3 * v * v * u * c1x + 3 * v * u * u * c2x + u * u * u * p2.x,
                   y: v * v * v * p1.y + 3 * v * v * u * c1y + 3 * v * u * u * c2y + u * u * u * p2.y });
      }
    }
    return out;
  }

  /* Where a man is when the clock reads t, along the whole path. */
  function walk(pts, t) {
    if (!pts || !pts.length) return { x: 0, y: 0 };
    var segs = [], total = 0, i;
    for (i = 1; i < pts.length; i++) {
      var L = Math.hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y);
      segs.push(L); total += L;
    }
    if (total <= 0) return pts[0];
    var want = total * t, run = 0;
    for (i = 0; i < segs.length; i++) {
      if (run + segs[i] >= want) {
        var f = segs[i] ? (want - run) / segs[i] : 0;
        return { x: pts[i].x + (pts[i + 1].x - pts[i].x) * f,
                 y: pts[i].y + (pts[i + 1].y - pts[i].y) * f };
      }
      run += segs[i];
    }
    return pts[pts.length - 1];
  }

  function rectsOverlap(a, b) {
    return !(a.x + a.w <= b.x || b.x + b.w <= a.x || a.y + a.h <= b.y || b.y + b.h <= a.y);
  }

  /* ---------- the other team ----------
     A kickoff and a kick return are the two sides of the same snap, so the
     likely opposing look on one IS the other: his own coached play, reflected
     across the line of scrimmage and flipped left to right, because their left
     is our right. Scaled so it fits the depth the host play has to spare.

       host = {los, ours:[{x,y}]}
       src  = {los, ours:[{id,x,y,...}], routes:[{playerId, points:[{x,y}]}]}

     Returns {men:[{x,y,q,path}], routes:[{from,points}]}, where q is the source
     player untouched — labels, lanes and jobs come along with him, which is what
     lets the matchup be named instead of invented. */
  function mid(list, key) {
    return list.reduce(function (a, q) { return a + q[key]; }, 0) / (list.length || 1);
  }

  function mirror(host, src) {
    var ho = host.ours || [], so = src.ours || [];
    if (!ho.length || !so.length) return { men: [], routes: [] };
    var sSgn = Math.sign(mid(so, 'y') - src.los) || 1;
    var hSgn = -(Math.sign(mid(ho, 'y') - host.los) || 1);
    var depth = Math.max.apply(null, so.map(function (q) { return Math.abs(q.y - src.los); })) || 1;
    var room = (hSgn < 0 ? (host.los - 18) : (VBH - 18 - host.los));
    var k = Math.min(1, Math.max(0.2, room / depth));
    function M(x, y) { return { x: VBW - x, y: host.los + hSgn * ((y - src.los) * sSgn) * k }; }

    var rt = {};
    (src.routes || []).forEach(function (r) { rt[r.playerId] = r; });
    var routes = [];
    var men = so.map(function (q) {
      var m = M(q.x, q.y);
      m.q = q;
      var r = rt[q.id];
      m.path = [{ x: m.x, y: m.y }].concat(
        (r && r.points) ? r.points.map(function (t) { return M(t.x, t.y); }) : []);
      if (m.path.length > 1) routes.push({ from: m.path[0], points: m.path.slice(1) });
      return m;
    });
    return { men: men, routes: routes };
  }

  /* ---------- who is across from whom ----------
     Anything he has assigned by hand is the answer and takes its man off the
     board first. Nearest-man is a fair guess on a kickoff and a poor one on a
     return, where a wall man blocks the cover man arriving in his zone rather
     than the one standing closest at the snap. Best pair first, so two of ours
     cannot claim the same man while a third goes unmatched.

       ours = [{id, x, y, covers}]        men = from mirror(), or stored X's
       labelOf(man) -> the label to match `covers` against

     Returns {ourId: {bi, assigned}}. */
  function matchups(ours, men, labelOf) {
    var out = {}, usedA = {}, usedB = {};
    if (!men.length) return out;
    labelOf = labelOf || function (m) { return (m.q && m.q.label) || m.label || ''; };

    ours.forEach(function (a) {
      if (!a.covers) return;
      var bi = -1;
      men.forEach(function (m, i) { if (bi < 0 && labelOf(m) === a.covers) bi = i; });
      if (bi < 0 || usedB[bi]) return;   // a label renamed on the other play: fall back to auto
      usedA[a.id] = 1; usedB[bi] = 1;
      out[a.id] = { bi: bi, assigned: true };
    });

    var pairs = [];
    ours.forEach(function (a) {
      if (usedA[a.id]) return;
      men.forEach(function (b, bi) {
        if (usedB[bi]) return;
        pairs.push({ a: a, bi: bi, d: Math.hypot(a.x - b.x, a.y - b.y) });
      });
    });
    pairs.sort(function (x, y) { return x.d - y.d; });
    pairs.forEach(function (pr) {
      if (usedA[pr.a.id] || usedB[pr.bi]) return;
      usedA[pr.a.id] = 1; usedB[pr.bi] = 1;
      out[pr.a.id] = { bi: pr.bi, assigned: false };
    });
    return out;
  }

  /* ---------- where they collide ----------
     Both men are walked down their own routes on one clock. The collision is the
     first step where they are within touching distance AND somebody has actually
     run there — a pair lined up across the ball starts inside touching distance,
     and without that check the very first sample counts and both men freeze on
     their own alignment without ever moving. A pair that never quite touches
     counts at its closest approach, provided that is close enough to be a
     collision and not two men passing on opposite sides of the field. A pair he
     assigned himself always gets a mark, however far apart their routes keep
     them: he has said this man takes that man, so a mark sitting off on its own
     is the app telling him the route needs redrawing.

       pairs = [{id, bi, assigned, ours:[pts], theirs:[pts]}]

     Returns [{id, bi, assigned, t, a, b, d, x, y}] — a and b are where each man
     stops, x/y the point between them. */
  var TOUCH = 22, NEAR = 44, MOVED = 16;

  function meets(pairs) {
    var out = [];
    (pairs || []).forEach(function (pr) {
      var a = pr.ours || [], b = pr.theirs || [];
      if (a.length < 2 && b.length < 2) return;   // nobody moves; there is no collision
      var a0 = a[0], b0 = b[0], hit = null, near = null;
      for (var i = 0; i <= 120; i++) {
        var t = i / 120, pa = walk(a, t), pb = walk(b, t);
        var gone = Math.hypot(pa.x - a0.x, pa.y - a0.y) + Math.hypot(pb.x - b0.x, pb.y - b0.y);
        if (gone < MOVED) continue;
        var d = Math.hypot(pa.x - pb.x, pa.y - pb.y);
        if (!near || d < near.d) near = { t: t, a: pa, b: pb, d: d };
        if (d <= TOUCH) { hit = { t: t, a: pa, b: pb, d: d }; break; }
      }
      var c = hit || ((near && (pr.assigned || near.d <= NEAR)) ? near : null);
      if (!c) return;
      out.push({ id: pr.id, bi: pr.bi, assigned: !!pr.assigned,
                 t: c.t, a: c.a, b: c.b, d: c.d,
                 x: (c.a.x + c.b.x) / 2, y: (c.a.y + c.b.y) / 2 });
    });
    return out;
  }

  return {
    VBW: VBW, VBH: VBH, CURVE: CURVE,
    MEET_TOUCH: TOUCH, MEET_NEAR: NEAR, MEET_MOVED: MOVED,
    smoothD: smoothD, smoothPts: smoothPts, walk: walk, rectsOverlap: rectsOverlap,
    mirror: mirror, matchups: matchups, meets: meets
  };
})();
if (typeof module !== 'undefined' && module.exports) module.exports = PE;
