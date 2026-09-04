/* sync-preview.js — inline the engine, the field renderer, brand.js and the
 * brand records into the pages in this folder.
 *
 *     node product/brand/sync-preview.js            # rewrite the blocks
 *     node product/brand/sync-preview.js --check    # exit 1 if they drifted
 *
 * Two pages now: preview.html (three tenants at once, the proof the layer
 * works) and picker.html (one club builds its own). Both are self-contained.
 *
 * Same pattern, and the same reason, as scripts/sync-engine.js and
 * scripts/sync-play-data.js: a <script src> cannot be read when the page is
 * opened as a downloaded file or run inside an artifact viewer (CLAUDE.md rule
 * 4), so the page carries its own copy — and a copy that nothing checks is a
 * copy that silently drifts. This is a maintenance command, not a build step:
 * opening either page needs nothing.
 */
var fs = require('fs'), path = require('path');
var HERE = __dirname, ROOT = path.join(HERE, '..', '..');

var ENGINE = { id: 'play-engine', file: path.join(ROOT, 'product', 'engine', 'play-engine.js'), kind: 'js' };
var RENDER = { id: 'field-render', file: path.join(HERE, 'field-render.js'), kind: 'js' };
var BRANDJS = { id: 'brand-js', file: path.join(HERE, 'brand.js'), kind: 'js' };
var BRANDS = { id: 'brand-data', file: path.join(HERE, 'brands.json'), kind: 'json' };
var PLAYS = { id: 'play-fallback', file: path.join(ROOT, 'special-teams-plays.json'), kind: 'play' };

var PAGES = [
  { file: path.join(HERE, 'preview.html'), src: [ENGINE, RENDER, BRANDJS, BRANDS, PLAYS] },
  { file: path.join(HERE, 'picker.html'), src: [ENGINE, RENDER, BRANDJS, BRANDS, PLAYS] }
];

/* The fallback carries ONE unit plus the roster numbers, not the whole book:
   the page fetches the real file when it can reach it, and this only has to be
   enough to draw a real eleven offline. */
var FALLBACK_SLUG = 'std-punt';

function payload(s) {
  var raw = fs.readFileSync(s.file, 'utf8');
  if (s.kind === 'js') return raw.replace(/<\/script>/gi, '<\\/script>');
  if (s.kind === 'json') return raw.trim();
  var book = JSON.parse(raw);
  var play = book.plays.filter(function (p) { return p.slug === FALLBACK_SLUG; })[0];
  if (!play) throw new Error('sync-preview: ' + FALLBACK_SLUG + ' is not in the playbook any more');
  return JSON.stringify({ generated: book.generated, roster: book.roster, plays: [play] }, null, 1);
}

function splice(html, id, body, name) {
  var re = new RegExp('(<script[^>]*id="' + id + '"[^>]*>)([\\s\\S]*?)(</script>)');
  if (!re.test(html)) throw new Error('sync-preview: no <script id="' + id + '"> block in ' + name);
  return html.replace(re, function (m, open, old, close) { return open + '\n' + body + '\n' + close; });
}

var check = process.argv.indexOf('--check') >= 0, drifted = [], done = [];

PAGES.forEach(function (page) {
  var name = path.basename(page.file);
  if (!fs.existsSync(page.file)) throw new Error('sync-preview: ' + name + ' is missing');
  var html = fs.readFileSync(page.file, 'utf8'), out = html;
  page.src.forEach(function (s) { out = splice(out, s.id, payload(s), name); });
  if (check) { if (out !== html) drifted.push(name); return; }
  if (out !== html) fs.writeFileSync(page.file, out);
  done.push(name + ' (' + Math.round(out.length / 1024) + ' kB)');
});

if (check) {
  if (drifted.length) {
    console.error(drifted.join(' and ') + ' drifted from the sources — run: node product/brand/sync-preview.js');
    process.exit(1);
  }
  console.log('preview.html and picker.html are in sync with the engine, field-render.js, brand.js and brands.json');
  process.exit(0);
}
console.log('inlined ' + [ENGINE, RENDER, BRANDJS, BRANDS, PLAYS].map(function (s) { return path.basename(s.file); }).join(', ') +
  ' into ' + done.join(', '));
