/**
 * play-diagram.js
 * Renders a special teams play from special-teams-plays.json as inline SVG.
 * No dependencies, no framework. Works in vanilla JS, React, Vue, anything.
 *
 *   import { renderPlay, playSVG } from './play-diagram.js';
 *   renderPlay(document.getElementById('box'), play, { roster });
 *
 * Or get a string for server rendering:
 *   const svg = playSVG(play, { roster, theme: 'light' });
 */

const THEMES = {
  dark:  { field: '#1D3A31', line: '#EDEBE0', lineOp: 0.10, hash: 0.20,
           us: '#E3B547', them: '#EDEBE0', themOp: 0.35, los: '#E3B547',
           label: '#EDEBE0', chip: '#13251F', xman: '#E58A6B' },
  light: { field: '#FFFFFF', line: '#111111', lineOp: 0.12, hash: 0.30,
           us: '#111111', them: '#111111', themOp: 0.35, los: '#8A6D12',
           label: '#111111', chip: '#FFFFFF', xman: '#A33B2A' }
};

const FIELD = { w: 420, h: 500, left: 14, right: 406 };

function esc(s) {
  return String(s).replace(/[&<>"']/g, c =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

/** Group players into horizontal rows so crowded lines can stagger their labels. */
function layout(players) {
  const ours = players.filter(p => p.team === 'us');
  const bands = [];
  let cur = null;
  ours.slice().sort((a, b) => a.y - b.y || a.x - b.x).forEach(p => {
    if (!cur || Math.abs(p.y - cur.y) > 26) { cur = { y: p.y, items: [] }; bands.push(cur); }
    cur.items.push(p);
  });
  const out = {};
  bands.forEach(band => {
    band.items.sort((a, b) => a.x - b.x);
    const gaps = band.items.map((p, i) => {
      const l = i > 0 ? p.x - band.items[i - 1].x : 999;
      const r = i < band.items.length - 1 ? band.items[i + 1].x - p.x : 999;
      return Math.min(l, r);
    });
    const tight = Math.min(...gaps) < 62;
    band.items.forEach((p, i) => {
      let room = gaps[i];
      if (tight) {
        const l2 = i > 1 ? p.x - band.items[i - 2].x : 999;
        const r2 = i < band.items.length - 2 ? band.items[i + 2].x - p.x : 999;
        room = Math.min(l2, r2);
      }
      out[p.id] = { dy: tight && i % 2 === 1 ? 12 : 0, room };
    });
  });
  return out;
}

function nameFor(player, roster, room) {
  if (!player) return '';
  const r = (roster || []).find(x => x.last === player) || { last: player, number: null };
  const full = r.last.toUpperCase() + (r.number ? ' ' + r.number : '');
  if (room >= 999) return full;
  const chars = Math.max(3, Math.floor((room - 6) / 5));
  if (full.length <= chars) return full;
  const short = r.last.toUpperCase();
  if (short.length <= chars) return short;
  if (r.number && String(r.number).length <= chars) return String(r.number);
  return short.slice(0, chars);
}

/** Returns the play as an SVG string. */
export function playSVG(play, opts = {}) {
  const t = THEMES[opts.theme === 'light' ? 'light' : 'dark'];
  const roster = opts.roster || [];
  const showNames = opts.showNames !== false;
  const lay = layout(play.players);
  const byId = Object.fromEntries(play.players.map(p => [p.id, p]));
  const s = [];

  s.push(`<svg viewBox="0 0 ${FIELD.w} ${FIELD.h}" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="${esc(play.name)}">`);
  s.push(`<rect width="${FIELD.w}" height="${FIELD.h}" fill="${t.field}"/>`);

  for (let y = 10; y <= FIELD.h - 6; y += 28) {
    s.push(`<line x1="${FIELD.left}" x2="${FIELD.right}" y1="${y}" y2="${y}" stroke="${t.line}" stroke-opacity="${t.lineOp}"/>`);
  }
  [FIELD.left + 126, FIELD.right - 126].forEach(hx => {
    for (let y = 10; y <= FIELD.h - 6; y += 28) {
      s.push(`<line x1="${hx - 3}" x2="${hx + 3}" y1="${y}" y2="${y}" stroke="${t.line}" stroke-opacity="${t.hash}"/>`);
    }
  });
  s.push(`<line x1="${FIELD.left}" x2="${FIELD.left}" y1="0" y2="${FIELD.h}" stroke="${t.line}" stroke-opacity="0.3" stroke-width="2"/>`);
  s.push(`<line x1="${FIELD.right}" x2="${FIELD.right}" y1="0" y2="${FIELD.h}" stroke="${t.line}" stroke-opacity="0.3" stroke-width="2"/>`);

  const los = play.lineOfScrimmage;
  s.push(`<line x1="0" x2="${FIELD.w}" y1="${los}" y2="${los}" stroke="${t.los}" stroke-width="1.8" stroke-dasharray="6 4"/>`);
  if (play.lineLabel) {
    s.push(`<text x="6" y="${los - 6}" fill="${t.los}" font-family="ui-monospace,Menlo,monospace" font-size="8.5" letter-spacing="1">${esc(play.lineLabel)}</text>`);
  }

  (play.routes || []).forEach(r => {
    const owner = byId[r.playerId];
    if (!owner || !r.points.length) return;
    let d = `M${owner.x},${owner.y}`;
    r.points.forEach(pt => { d += ` L${pt.x},${pt.y}`; });
    s.push(`<path d="${d}" fill="none" stroke="${t.us}" stroke-width="2" stroke-linecap="round"/>`);
    const last = r.points[r.points.length - 1];
    const prev = r.points.length > 1 ? r.points[r.points.length - 2] : owner;
    const a = Math.atan2(last.y - prev.y, last.x - prev.x);
    [2.8, -2.8].forEach(off => {
      s.push(`<line x1="${last.x}" y1="${last.y}" x2="${(last.x - 9 * Math.cos(a) + off * Math.sin(a)).toFixed(1)}" y2="${(last.y - 9 * Math.sin(a) - off * Math.cos(a)).toFixed(1)}" stroke="${t.us}" stroke-width="2" stroke-linecap="round"/>`);
    });
  });

  play.players.forEach(p => {
    if (p.team === 'them') {
      s.push(`<g stroke="${t.them}" stroke-opacity="${t.themOp}" stroke-width="2.2" stroke-linecap="round">`
        + `<line x1="${p.x - 7}" y1="${p.y - 7}" x2="${p.x + 7}" y2="${p.y + 7}"/>`
        + `<line x1="${p.x - 7}" y1="${p.y + 7}" x2="${p.x + 7}" y2="${p.y - 7}"/></g>`);
      return;
    }
    s.push(`<circle cx="${p.x}" cy="${p.y}" r="12" fill="none" stroke="${t.us}" stroke-width="2"/>`);
    if (p.label) {
      s.push(`<text x="${p.x}" y="${p.y + 3.4}" text-anchor="middle" fill="${t.us}" font-family="ui-monospace,Menlo,monospace" font-size="9">${esc(p.label)}</text>`);
    }
    if (showNames && p.player) {
      const info = lay[p.id] || { dy: 0, room: 999 };
      const txt = nameFor(p.player, roster, info.room);
      const w = txt.length * 9.5 * 0.58;
      s.push(`<rect x="${(p.x - w / 2 - 2.5).toFixed(1)}" y="${p.y + 16 + info.dy}" width="${(w + 5).toFixed(1)}" height="12" rx="2" fill="${t.chip}" fill-opacity="0.82"/>`);
      s.push(`<text x="${p.x}" y="${p.y + 25 + info.dy}" text-anchor="middle" fill="${t.label}" font-family="ui-monospace,Menlo,monospace" font-size="9.5">${esc(txt)}</text>`);
      if (info.dy > 0) {
        s.push(`<line x1="${p.x}" y1="${p.y + 12}" x2="${p.x}" y2="${p.y + 16 + info.dy}" stroke="${t.label}" stroke-opacity="0.3"/>`);
      }
      const r = (roster || []).find(x => x.last === p.player);
      if (r && r.xman) {
        s.push(`<text x="${p.x + 15}" y="${p.y - 9}" text-anchor="middle" fill="${t.xman}" font-family="ui-monospace,Menlo,monospace" font-size="8.5" font-weight="bold">X</text>`);
      }
    }
  });

  s.push('</svg>');
  return s.join('');
}

/** Drops the SVG into a DOM node. */
export function renderPlay(el, play, opts) {
  el.innerHTML = playSVG(play, opts);
  return el;
}

/** Ordered list of positions and who fills them — for a printed lineup card. */
export function lineup(play, roster) {
  const ours = play.players.filter(p => p.team === 'us');
  const bands = [];
  let cur = null;
  ours.slice().sort((a, b) => a.y - b.y || a.x - b.x).forEach(p => {
    if (!cur || Math.abs(p.y - cur.y) > 26) { cur = { y: p.y, items: [] }; bands.push(cur); }
    cur.items.push(p);
  });
  return bands.map((b, i) => ({
    row: i + 1,
    spots: b.items.sort((a, c) => a.x - c.x).map(p => {
      const r = (roster || []).find(x => x.last === p.player);
      return {
        label: p.label,
        player: p.player,
        number: r ? r.number : null,
        xman: r ? !!r.xman : false
      };
    })
  }));
}

export default { playSVG, renderPlay, lineup };
