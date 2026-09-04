/* validate.js — run the football rules over every formation in the catalog.
 *
 *     node product/formations/validate.js
 *     node product/formations/validate.js --json
 *
 * Exits non-zero if anything fails. A formation that fails is a bug in the
 * GENERATOR or in the parameters, never a reason to loosen the check: the
 * whole value of shipping geometry instead of pictures is that the geometry
 * can be proved legal before a coach ever sees it.
 *
 * What is checked, and why each one is football and not style:
 *
 *   eleven men          — a formation with ten is a penalty, with twelve it is
 *                         a flag. It is also the single commonest way a
 *                         generated alignment goes wrong.
 *   inside the field    — x between the sidelines (14–406), y on the picture.
 *   a body apart        — two men cannot occupy one spot. A player circle is
 *                         24px, so anything under 26px centre to centre is two
 *                         men drawn inside each other.
 *   seven on the line   — the legality rule for the team snapping the ball.
 *                         Punt teams count: five interior and two gunners.
 *   nobody over the ball— the offence cannot be past the line before the snap;
 *                         the defence and the punt-return team cannot be in the
 *                         neutral zone.
 *   free kick           — every K man behind the restraining line, and at
 *                         least four either side of the kicker.
 *   free kick zone      — every R man at least ten yards off K's line.
 *   declared front      — a 4-3 has four men down on the ball; if the label set
 *                         says four and five are down, the picture is lying.
 *   labels              — unique, house convention (L/R prefix by side, M in
 *                         the middle), numbered outward from the reference man,
 *                         hands team left to right.
 *   alignment only      — no routes, no target, no jobs, no names. That one is
 *                         the licence boundary, checked like any other rule.
 *
 * The checks themselves live in formations.js so the browser runs the same
 * ones live while a coach drags a slider. This file is the runner.
 */
var fs = require('fs'), path = require('path');
var HERE = __dirname;
var F = require(path.join(HERE, 'formations.js'));
var CATALOG = JSON.parse(fs.readFileSync(path.join(HERE, 'catalog.json'), 'utf8'));

var asJSON = process.argv.indexOf('--json') >= 0;
var results = [], failed = 0, ids = {};

CATALOG.formations.forEach(function (entry) {
  var d, res;
  if (ids[entry.id]) { results.push({ id: entry.id, ok: false, errors: ['duplicate catalog id'] }); failed++; return; }
  ids[entry.id] = 1;
  try { d = F.build(entry); }
  catch (err) { results.push({ id: entry.id, ok: false, errors: ['threw: ' + err.message] }); failed++; return; }

  res = F.check(d);
  if (entry.family && entry.family !== d.family) {
    res.errors.push('catalog says family "' + entry.family + '", generator says "' + d.family + '"');
    res.ok = false;
  }
  if (!/^fm-/.test(d.slug)) { res.errors.push('slug "' + d.slug + '" is not namespaced fm-'); res.ok = false; }
  if (!res.ok) failed++;
  results.push({
    id: entry.id, name: entry.name, family: d.family, ok: res.ok, errors: res.errors,
    men: res.men, onLine: res.onLine, closest: res.closest, closestPair: res.closestPair,
    span: res.span, depth: res.depth
  });
});

/* Two properties that only mean anything across the whole library. */
var extra = [];
(function () {
  /* Every family the product promises is actually in the box. */
  var want = ['punt', 'punt-return', 'kickoff', 'kick-return', 'offense', 'defense'];
  var have = {}; results.forEach(function (r) { have[r.family] = 1; });
  want.forEach(function (f) { if (!have[f]) extra.push('no ' + f + ' formation in the catalog'); });
})();
(function () {
  /* The parameters have to actually drive the geometry, or this is a picture
     library with extra steps. Nudge one number on each generator and require
     the alignment to move. */
  var probes = [
    ['spreadPunt', { split: 1 }, { split: 3 }],
    ['puntReturn', { jammerWidth: 21 }, { jammerWidth: 15 }],
    ['kickoff', { left: { count: 5, near: 4, far: 24 } }, { left: { count: 5, near: 6, far: 24 } }],
    ['kickReturn', { deepPairWidth: 10 }, { deepPairWidth: 20 }],
    ['offenseSet', { qbDepth: 5 }, { qbDepth: 4 }],
    ['defenseFront', { lbDepth: 4.5 }, { lbDepth: 6.5 }]
  ];
  probes.forEach(function (p) {
    var a = F.generators[p[0]](p[1]), b = F.generators[p[0]](p[2]);
    var moved = a.players.filter(function (m, i) {
      return m.x !== b.players[i].x || m.y !== b.players[i].y;
    }).length;
    if (!moved) extra.push(p[0] + ': changing a parameter moved nobody');
    if (!F.check(b).ok) extra.push(p[0] + ': the nudged parameters produce an illegal formation');
  });
})();
(function () {
  /* Mirroring has to flip the geometry AND the labels together. */
  var a = F.spreadPunt({ te: 'R' }), b = F.spreadPunt({ mirror: true });
  var bx = a.params.ballX;
  var byLabel = {}; b.players.forEach(function (p) { byLabel[p.label] = p; });
  a.players.forEach(function (p) {
    var m = byLabel[F.swapSideLabel(p.label)];
    if (!m) { extra.push('mirror lost ' + p.label); return; }
    if (Math.abs((2 * bx - p.x) - m.x) > 0.11) extra.push('mirror put ' + p.label + ' in the wrong place');
  });
  if (!F.check(b).ok) extra.push('a mirrored punt does not validate');
})();

/* --- do the checks actually fire? ---
   A check that cannot fail is decoration. Each case below breaks one rule on
   purpose and the runner insists the matching complaint comes back. This is
   why "all 16 pass" means something. */
var negatives = [];
(function () {
  function broken(mut) {
    var d = F.spreadPunt({});
    d = JSON.parse(JSON.stringify(d));
    mut(d);
    return F.check(d).errors.join(' | ');
  }
  var cases = [
    ['eleven men', function (d) { d.players.pop(); }, /has 10 men/],
    ['sidelines', function (d) { d.players[0].x = 2; }, /outside the sideline/],
    ['off the picture', function (d) { d.players[0].y = 498; }, /off the picture/],
    ['a body apart', function (d) { d.players[1].x = d.players[0].x + 4; }, /closer than a body/],
    ['seven on the line', function (d) { d.players[1].y += 40; }, /men on the line, not 7/],
    ['over the line', function (d) { d.players[1].y = d.lineOfScrimmage - 20; }, /over the line/],
    ['unique labels', function (d) { d.players[1].label = d.players[0].label; }, /two men are labelled/],
    ['side convention', function (d) { d.players[3].x = d.params.ballX + 90; }, /L label but sits right/],
    ['no routes', function (d) { d.routes = [{ playerId: 'f1', points: [] }]; }, /alignment only, never a play/],
    ['no names', function (d) { d.players[0].player = 'Somebody'; }, /ship no personnel/]
  ];
  cases.forEach(function (c) {
    var got = broken(c[1]);
    if (!c[2].test(got)) negatives.push('the "' + c[0] + '" check did not fire (got: ' + (got || 'no complaint at all') + ')');
  });
  /* numbering outward, on a formation that actually numbers */
  var ko = JSON.parse(JSON.stringify(F.kickoff({})));
  var a = ko.players[0], b2 = ko.players[1], tx = a.x; a.x = b2.x; b2.x = tx;
  if (!/numbering runs outward/.test(F.check(ko).errors.join(' | ')))
    negatives.push('the "numbering outward" check did not fire');
  /* four either side of the kicker */
  var ko2 = JSON.parse(JSON.stringify(F.kickoff({})));
  [0, 1].forEach(function (i, n) {
    ko2.players[i].x = ko2.params.kickerX + 40 + n * 30; ko2.players[i].label = 'R' + (8 + n);
  });
  if (!/four either side/.test(F.check(ko2).errors.join(' | ')))
    negatives.push('the "four either side of the kicker" check did not fire');
  /* the free kick zone on a return */
  var kr = JSON.parse(JSON.stringify(F.kickReturn({})));
  kr.players[0].y = kr.lineOfScrimmage + 10;
  if (!/free kick zone/.test(F.check(kr).errors.join(' | ')))
    negatives.push('the "free kick zone" check did not fire');
})();
extra = extra.concat(negatives);

if (asJSON) {
  console.log(JSON.stringify({ results: results, library: extra, pass: failed === 0 && !extra.length }, null, 2));
} else {
  var pad = function (s, n) { s = String(s); while (s.length < n) s += ' '; return s; };
  var lpad = function (s, n) { s = String(s); while (s.length < n) s = ' ' + s; return s; };
  console.log('formation library — ' + results.length + ' formations from ' +
    Object.keys(F.generators).length + ' generators\n');
  console.log(pad('', 5) + pad('id', 30) + pad('family', 14) + lpad('men', 4) + lpad('online', 8) +
    lpad('closest', 10) + lpad('span', 10) + lpad('depth', 10));
  console.log('-'.repeat(91));
  results.forEach(function (r) {
    console.log(pad(r.ok ? ' ok ' : 'FAIL', 5) + pad(r.id, 30) + pad(r.family || '?', 14) +
      lpad(r.men, 4) + lpad(r.onLine, 8) + lpad(r.closest + 'px', 10) +
      lpad(r.span + 'px', 10) + lpad(r.depth + 'px', 10));
    (r.errors || []).forEach(function (m) { console.log('      · ' + m); });
  });
  console.log('');
  if (extra.length) { console.log('library checks:'); extra.forEach(function (m) { console.log('  · ' + m); }); }
  else console.log('library checks: every family present, every generator responds to its parameters, ' +
    'mirror is honest, and all ' + (10 + 3) + ' rules fire on a formation that breaks them.');
  console.log('');
  console.log(failed || extra.length
    ? (failed + ' formation(s) failed, ' + extra.length + ' library problem(s)')
    : 'all ' + results.length + ' formations pass: 11 men, inside the sidelines, a body apart, ' +
      'legal on the line, labelled to convention, alignment only.');
}

process.exit(failed || extra.length ? 1 : 0);
