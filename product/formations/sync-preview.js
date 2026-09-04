/* sync-preview.js — inline formations.js, catalog.json, brand.js and the
 * brand records into preview.html.
 *
 *     node product/formations/sync-preview.js            # rewrite the blocks
 *     node product/formations/sync-preview.js --check    # exit 1 if they drifted
 *
 * Same pattern and the same reason as product/brand/sync-preview.js and
 * scripts/sync-engine.js: a <script src> cannot be read when the page is
 * opened as a downloaded file or run inside an artifact viewer (CLAUDE.md
 * rule 4), so the page carries its own copies — and a copy that nothing
 * checks is a copy that silently drifts. Maintenance command, not a build
 * step: opening preview.html needs nothing at all.
 */
var fs = require('fs'), path = require('path');
var HERE = __dirname, ROOT = path.join(HERE, '..', '..');
var PAGE = path.join(HERE, 'preview.html');

var SRC = [
  { id: 'brand-js', file: path.join(ROOT, 'product', 'brand', 'brand.js'), kind: 'js' },
  { id: 'formations-js', file: path.join(HERE, 'formations.js'), kind: 'js' },
  { id: 'brand-data', file: path.join(ROOT, 'product', 'brand', 'brands.json'), kind: 'json' },
  { id: 'formation-catalog', file: path.join(HERE, 'catalog.json'), kind: 'json' }
];

function payload(s) {
  var raw = fs.readFileSync(s.file, 'utf8');
  if (s.kind === 'js') return raw.replace(/<\/script>/gi, '<\\/script>');
  return raw.trim();
}
function splice(html, id, body) {
  var re = new RegExp('(<script[^>]*id="' + id + '"[^>]*>)([\\s\\S]*?)(</script>)');
  if (!re.test(html)) throw new Error('sync-preview: no <script id="' + id + '"> block in preview.html');
  return html.replace(re, function (m, open, old, close) { return open + '\n' + body + '\n' + close; });
}

var html = fs.readFileSync(PAGE, 'utf8'), out = html;
SRC.forEach(function (s) { out = splice(out, s.id, payload(s)); });

if (process.argv.indexOf('--check') >= 0) {
  if (out !== html) {
    console.error('preview.html has drifted from its sources — run: node product/formations/sync-preview.js');
    process.exit(1);
  }
  console.log('preview.html is in sync with formations.js, catalog.json, brand.js and brands.json');
  process.exit(0);
}
fs.writeFileSync(PAGE, out);
console.log('preview.html: inlined ' + SRC.map(function (s) { return path.basename(s.file); }).join(', ') +
  ' (' + Math.round(out.length / 1024) + ' kB)');
