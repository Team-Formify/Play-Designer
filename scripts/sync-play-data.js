#!/usr/bin/env node
/* Rewrites the <script type="application/json" id="play-data"> fallback block in
   index.html from special-teams-plays.json.

   The .json file is the source of truth. The embedded block exists only because
   fetch() cannot reach a sibling file when index.html is opened as a downloaded
   local file or run inside the artifact viewer. Run this after editing the JSON:

       node scripts/sync-play-data.js
       node scripts/sync-play-data.js --check    # exit 1 if they have drifted

   No dependencies, no build step. This is a maintenance command, not part of
   running the app. */

const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const HTML = path.join(root, 'index.html');
const JSON_FILE = path.join(root, 'special-teams-plays.json');
const OPEN = '<script type="application/json" id="play-data">';
const CLOSE = '</script>';

const check = process.argv.includes('--check');

let data;
try {
  data = JSON.parse(fs.readFileSync(JSON_FILE, 'utf8'));
} catch (e) {
  console.error('Could not read special-teams-plays.json: ' + e.message);
  process.exit(1);
}
if (!Array.isArray(data.plays) || !data.plays.length) {
  console.error('special-teams-plays.json has no plays in it. Refusing to write.');
  process.exit(1);
}
const missing = data.plays.filter(p => !p.slug);
if (missing.length) {
  console.error(`${missing.length} play(s) have no slug. Slugs are the key — refusing to write.`);
  process.exit(1);
}

const compact = JSON.stringify(data);
if (compact.includes('</script')) {
  console.error('Play data contains "</script" and would break out of the tag. Refusing to write.');
  process.exit(1);
}

const html = fs.readFileSync(HTML, 'utf8');
const start = html.indexOf(OPEN);
if (start === -1) {
  console.error('No play-data block found in index.html.');
  process.exit(1);
}
const from = start + OPEN.length;
const end = html.indexOf(CLOSE, from);
if (end === -1) {
  console.error('play-data block is not closed in index.html.');
  process.exit(1);
}

const current = html.slice(from, end);
if (current === compact) {
  console.log(`In sync — ${data.plays.length} plays, ${(data.roster || []).length} on the roster.`);
  process.exit(0);
}
if (check) {
  console.error('DRIFT: the embedded copy does not match special-teams-plays.json.');
  console.error('Run `node scripts/sync-play-data.js` to fix it.');
  process.exit(1);
}

fs.writeFileSync(HTML, html.slice(0, from) + compact + html.slice(end));
console.log(`Synced — ${data.plays.length} plays, ${(data.roster || []).length} on the roster.`);
