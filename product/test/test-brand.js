/* test-brand.js — the theming layer, checked with no browser.
 *
 *     node product/test/test-brand.js
 *
 * Exits non-zero if any tenant's palette fails a contrast floor, if a brand
 * tries to smuggle in a webfont, if the print palette is anything other than
 * black on white, or if the Lehi record has drifted from the look that
 * designer.html ships today. That last one is the whole argument: theming is
 * only free if the existing app looks identical after it.
 */
var fs = require('fs'), path = require('path');
var Brand = require(path.join(__dirname, '..', 'brand', 'brand.js'));
var DATA = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'brand', 'brands.json'), 'utf8'));

var fails = 0;
function ok(cond, msg) { if (!cond) { fails++; console.log('  FAIL  ' + msg); } else console.log('  ok    ' + msg); }

var brands = Brand.register(DATA.brands);
console.log('\n' + brands.length + ' brands: ' + brands.map(function (b) { return b.id; }).join(', '));

/* 1. Lehi must reproduce today's look exactly. Values lifted from
   designer.html :root (line 18) and PAL_SCREEN (line 831). */
var lehi = Brand.get('lehi');
var TODAY_CSS = { '--page': '#13251F', '--board': '#1D3A31', '--deep': '#0D1B16', '--chalk': '#EDEBE0', '--soft': '#9AA69C', '--gold': '#E3B547', '--warm': '#E58A6B' };
var v = Brand.vars(lehi, false);
console.log('\ndesigner.html :root reproduced');
Object.keys(TODAY_CSS).forEach(function (k) {
  ok(String(v[k]).toUpperCase() === TODAY_CSS[k], k + ' = ' + v[k]);
});
var TODAY_PAL = { grass: '#1D3A31', chalk: '#EDEBE0', gold: '#E3B547', deep: '#13251F', hot: '#E58A6B', gridOp: 0.09, hashOp: 0.2, sideOp: 0.3, themOp: 0.42, chipOp: 0.82, losChipOp: 0.72, leadOp: 0.42, aimOp: 0.85, circleFill: 'rgba(19,37,31,.55)', routeFill: 'rgba(227,181,71,.28)', stroke: 2 };
console.log('\nPAL_SCREEN reproduced');
var P = Brand.palette(lehi, false);
Object.keys(TODAY_PAL).forEach(function (k) { ok(P[k] === TODAY_PAL[k], 'PAL_SCREEN.' + k + ' = ' + P[k]); });

/* 2. Print: same black-on-white for every tenant, non-negotiable. */
var TODAY_PRINT = { grass: '#FFFFFF', chalk: '#000000', gold: '#000000', deep: '#FFFFFF', hot: '#000000', gridOp: 0.13, hashOp: 0.26, sideOp: 0.5, themOp: 0.8, chipOp: 1, losChipOp: 1, leadOp: 0.5, aimOp: 1, circleFill: '#FFFFFF', routeFill: '#FFFFFF', stroke: 1.6 };
console.log('\nPAL_PRINT reproduced, and identical for every tenant');
brands.forEach(function (b) {
  var pp = Brand.palette(b, true);
  var same = Object.keys(TODAY_PRINT).every(function (k) { return pp[k] === TODAY_PRINT[k]; });
  ok(same, b.id + ' prints black on white');
  var pv = Brand.vars(b, true);
  ok(pv['--page'] === '#FFFFFF' && pv['--chalk'] === '#000000' && pv['--gold'] === '#000000',
    b.id + ' chrome prints black on white');
});

/* 3. A brand cannot ship a webfont. */
console.log('\nno webfonts');
var sneaky = Brand.normalize({ id: 'sneaky', name: 'Sneaky', fonts: { body: 'https://fonts.example/x.css' } });
ok(sneaky.fonts.body === Brand.FONT_STACKS.system, 'a font URL is refused and falls back to the system stack');
brands.forEach(function (b) {
  var bad = ['body', 'mono', 'display'].some(function (k) { return /url\(|https?:|\/\//.test(b.fonts[k]); });
  ok(!bad, b.id + ' uses system stacks only');
});

/* 4. Contrast, screen and print. */
[false, true].forEach(function (printing) {
  console.log('\ncontrast — ' + (printing ? 'PRINT' : 'SCREEN'));
  var head = 'check'.padEnd(20) + 'tier'.padEnd(9) + 'min'.padEnd(6) + brands.map(function (b) { return b.id.padEnd(14); }).join('');
  console.log('  ' + head);
  var audits = brands.map(function (b) { return Brand.audit(b, printing); });
  audits[0].checks.forEach(function (c, i) {
    var row = c.id.padEnd(20) + c.tier.padEnd(9) + String(c.min).padEnd(6) +
      audits.map(function (a) {
        return (a.checks[i].ratio.toFixed(2) + ':1' + (a.checks[i].pass ? '' : ' X')).padEnd(14);
      }).join('');
    console.log('  ' + row);
  });
  audits.forEach(function (a) {
    ok(a.pass, a.id + (printing ? ' print' : ' screen') + ' passes every contrast floor' +
      (a.pass ? '' : ' — ' + a.fails.map(function (f) { return f.id + ' ' + f.ratio; }).join(', ')));
  });
});

/* 5. A record with six hex codes and nothing else still produces a whole
      field — that is what onboarding a league actually looks like. */
console.log('\nminimal record');
var mini = Brand.normalize({ id: 'mini', name: 'Six Hex Codes FC', colors: { page: '#101418', chalk: '#F2F5F7', accent: '#5AC8FA' } });
ok(!!mini.field.grass && !!mini.field.line && !!mini.field.plate, 'field derived from chrome colours: grass ' + mini.field.grass + ', line ' + mini.field.line);
ok(mini.mark.initials.length > 0 && Brand.markSVG(mini).indexOf('<svg') === 0, 'mark renders with no image file');

console.log('\n' + (fails ? fails + ' FAILURES' : 'all checks passed'));
process.exit(fails ? 1 : 0);
