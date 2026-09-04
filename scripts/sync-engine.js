#!/usr/bin/env node
/* Rewrites the <script id="play-engine"> block in designer.html and learn.html
   from play-engine.js.

   play-engine.js is the source of truth. The embedded copies exist because a
   <script src> cannot be read when the page is opened as a downloaded local
   file or run inside the artifact viewer — the same reason the play data is
   embedded. Run this after editing the engine:

       node scripts/sync-engine.js
       node scripts/sync-engine.js --check    # exit 1 if they have drifted

   No dependencies, no build step. This is a maintenance command, not part of
   running the app. */

const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const SRC = path.join(root, 'play-engine.js');
const PAGES = ['designer.html', 'learn.html', 'bridge/demo.html', 'bridge/combined-shell.html'];
const OPEN = '<script id="play-engine">';
const CLOSE = '</script>';

const check = process.argv.includes('--check');

let engine;
try {
  engine = fs.readFileSync(SRC, 'utf8');
} catch (e) {
  console.error('Could not read play-engine.js: ' + e.message);
  process.exit(1);
}

/* The module tail is for Node and the tests; the browser copy does not want it. */
engine = engine.replace(/\nif \(typeof module[\s\S]*$/, '\n');

if (!/var PE = \(function/.test(engine)) {
  console.error('play-engine.js does not define PE. Refusing to write.');
  process.exit(1);
}
if (engine.includes('</script')) {
  console.error('The engine contains "</script" and would break out of the tag. Refusing to write.');
  process.exit(1);
}

const body = '\n/* Generated from play-engine.js by scripts/sync-engine.js. Do not edit here —\n' +
             '   edit play-engine.js and re-run it, or the two copies drift apart again. */\n' +
             engine;

/* The product carries a standalone copy of the engine, because its field client
   is static and offline like this one. A copy is exactly how this project ended
   up with two engines and fixed the same bug four times in a day, so it is kept
   honest here rather than by good intentions. */
const COPIES = ['product/engine/play-engine.js'];

let drifted = [];
let wrote = [];

for (const rel of COPIES) {
  const file = path.join(root, rel);
  if (!fs.existsSync(path.dirname(file))) continue;
  const want = fs.readFileSync(SRC, 'utf8');
  const have = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : null;
  if (have === want) continue;
  if (check) { drifted.push(rel); continue; }
  fs.writeFileSync(file, want);
  wrote.push(rel);
}

for (const page of PAGES) {
  const file = path.join(root, page);
  const html = fs.readFileSync(file, 'utf8');
  const start = html.indexOf(OPEN);
  if (start === -1) {
    console.error(`No play-engine block found in ${page}.`);
    process.exit(1);
  }
  const from = start + OPEN.length;
  const end = html.indexOf(CLOSE, from);
  if (end === -1) {
    console.error(`play-engine block is not closed in ${page}.`);
    process.exit(1);
  }
  if (html.slice(from, end) === body) continue;
  if (check) { drifted.push(page); continue; }
  fs.writeFileSync(file, html.slice(0, from) + body + html.slice(end));
  wrote.push(page);
}

if (check && drifted.length) {
  console.error('DRIFT: ' + drifted.join(' and ') + ' do not match play-engine.js.');
  console.error('Run `node scripts/sync-engine.js` to fix it.');
  process.exit(1);
}

const lines = engine.trimEnd().split('\n').length;
console.log(wrote.length
  ? `Synced — ${lines} lines of engine into ${wrote.join(', ')}.`
  : `In sync — ${lines} lines of engine across ${PAGES.length} pages.`);
