/* sync-preview.js — inline the engine, brand.js and the brand records into
 * preview.html.
 *
 *     node product/brand/sync-preview.js            # rewrite the blocks
 *     node product/brand/sync-preview.js --check    # exit 1 if they drifted
 *
 * Same pattern, and the same reason, as scripts/sync-engine.js and
 * scripts/sync-play-data.js: a <script src> cannot be read when the page is
 * opened as a downloaded file or run inside an artifact viewer (CLAUDE.md rule
 * 4), so the page carries its own copy — and a copy that nothing checks is a
 * copy that silently drifts. This is a maintenance command, not a build step:
 * opening preview.html needs nothing.
 */
var fs = require('fs'), path = require('path');
var HERE = __dirname, ROOT = path.join(HERE, '..', '..');
var PAGE = path.join(HERE, 'preview.html');

var SRC = [
  { id: 'play-engine', file: path.join(ROOT, 'product', 'engine', 'play-engine.js'), kind: 'js' },
  { id: 'brand-js', file: path.join(HERE, 'brand.js'), kind: 'js' },
  { id: 'brand-data', file: path.join(HERE, 'brands.json'), kind: 'json' },
  { id: 'play-fallback', file: path.join(ROOT, 'special-teams-plays.json'), kind: 'play' }
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

function splice(html, id, body) {
  var re = new RegExp('(<script[^>]*id="' + id + '"[^>]*>)([\\s\\S]*?)(</script>)');
  if (!re.test(html)) throw new Error('sync-preview: no <script id="' + id + '"> block in preview.html');
  return html.replace(re, function (m, open, old, close) { return open + '\n' + body + '\n' + close; });
}

var html = fs.readFileSync(PAGE, 'utf8'), out = html;
SRC.forEach(function (s) { out = splice(out, s.id, payload(s)); });

if (process.argv.indexOf('--check') >= 0) {
  if (out !== html) { console.error('preview.html has drifted from its sources — run: node product/brand/sync-preview.js'); process.exit(1); }
  console.log('preview.html is in sync with the engine, brand.js and brands.json');
  process.exit(0);
}
fs.writeFileSync(PAGE, out);
console.log('preview.html: inlined ' + SRC.map(function (s) { return path.basename(s.file); }).join(', ') +
  ' (' + Math.round(out.length / 1024) + ' kB)');
