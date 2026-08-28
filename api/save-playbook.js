/* Commit the playbook straight from the app.
 *
 * Runs on Vercel, so the GitHub token lives in a server-side environment
 * variable and never reaches the browser. The app sends a passphrase which is
 * checked against another environment variable — without both set, this refuses
 * to do anything.
 *
 * Writes special-teams-plays.json AND the embedded fallback block inside
 * designer.html in one commit, via the git trees API, so the two can never drift
 * apart. That drift is the whole reason scripts/sync-play-data.js exists.
 *
 * Needs, in Vercel → Settings → Environment Variables:
 *   GITHUB_TOKEN   fine-grained PAT, this repo only, Contents: read and write
 *   SAVE_SECRET    a passphrase you pick; you type it into the app once
 * Optional: GITHUB_REPO (default Team-Formify/Play-Designer), GITHUB_BRANCH (main)
 */

const REPO   = process.env.GITHUB_REPO   || 'Team-Formify/Play-Designer';
const BRANCH = process.env.GITHUB_BRANCH || 'main';
const JSON_PATH = 'special-teams-plays.json';
const HTML_PATH = 'designer.html';
const OPEN = '<script type="application/json" id="play-data">';
const CLOSE = '</script>';
const MAX_BYTES = 2 * 1024 * 1024;

function gh(path, token, init) {
  return fetch('https://api.github.com' + path, {
    ...init,
    headers: {
      Authorization: 'Bearer ' + token,
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'Content-Type': 'application/json',
      'User-Agent': 'play-designer',
      ...(init && init.headers)
    }
  }).then(async r => {
    const body = await r.text();
    if (!r.ok) throw new Error('GitHub ' + r.status + ' on ' + path + ': ' + body.slice(0, 300));
    return body ? JSON.parse(body) : null;
  });
}

// Length-independent comparison, so a wrong guess leaks nothing from timing.
function secretMatches(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  let diff = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    diff |= a.charCodeAt(i % a.length || 0) ^ b.charCodeAt(i % b.length || 0);
  }
  return diff === 0;
}

function validate(d) {
  if (!d || typeof d !== 'object') return 'not an object';
  if (!Array.isArray(d.plays) || !d.plays.length) return 'no plays in it';
  if (d.plays.some(p => !p || !p.slug)) return 'a play has no slug';
  if (d.plays.some(p => !Array.isArray(p.players))) return 'a play has no players';
  if (!Array.isArray(d.roster)) return 'no roster';
  const slugs = new Set(d.plays.map(p => p.slug));
  if (slugs.size !== d.plays.length) return 'two plays share a slug';
  return null;
}

module.exports = async function handler(req, res) {
  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST');
    return res.status(405).json({ error: 'POST only' });
  }
  const token = process.env.GITHUB_TOKEN;
  const secret = process.env.SAVE_SECRET;
  if (!token || !secret) {
    return res.status(501).json({
      error: 'Saving to the repo is not set up yet. GITHUB_TOKEN and SAVE_SECRET ' +
             'need to be added to the Vercel project, then redeploy.'
    });
  }
  if (!secretMatches(String(req.headers['x-save-secret'] || ''), secret)) {
    return res.status(401).json({ error: 'That passphrase is not right.' });
  }

  let data = req.body;
  try { if (typeof data === 'string') data = JSON.parse(data); }
  catch { return res.status(400).json({ error: 'Body was not JSON.' }); }

  const bad = validate(data);
  if (bad) return res.status(400).json({ error: 'Refusing to save — ' + bad + '.' });

  const pretty = JSON.stringify(data, null, 2) + '\n';
  const compact = JSON.stringify(data);
  if (Buffer.byteLength(pretty) > MAX_BYTES) {
    return res.status(413).json({ error: 'Playbook is too large.' });
  }
  if (compact.includes('</script')) {
    return res.status(400).json({ error: 'Playbook contains "</script" and would break the page.' });
  }

  try {
    const ref = await gh(`/repos/${REPO}/git/ref/heads/${BRANCH}`, token);
    const headSha = ref.object.sha;
    const headCommit = await gh(`/repos/${REPO}/git/commits/${headSha}`, token);

    // Patch the embedded copy inside designer.html so it cannot drift from the JSON.
    const htmlMeta = await gh(
      `/repos/${REPO}/contents/${HTML_PATH}?ref=${BRANCH}`, token);
    const html = Buffer.from(htmlMeta.content, 'base64').toString('utf8');
    const start = html.indexOf(OPEN);
    if (start === -1) return res.status(500).json({ error: 'No play-data block in designer.html.' });
    const from = start + OPEN.length;
    const end = html.indexOf(CLOSE, from);
    if (end === -1) return res.status(500).json({ error: 'play-data block is not closed.' });
    const newHtml = html.slice(0, from) + compact + html.slice(end);

    const files = [
      { path: JSON_PATH, content: pretty },
      { path: HTML_PATH, content: newHtml }
    ];
    const blobs = [];
    for (const f of files) {
      const b = await gh(`/repos/${REPO}/git/blobs`, token, {
        method: 'POST',
        body: JSON.stringify({ content: Buffer.from(f.content).toString('base64'), encoding: 'base64' })
      });
      blobs.push({ path: f.path, mode: '100644', type: 'blob', sha: b.sha });
    }

    const tree = await gh(`/repos/${REPO}/git/trees`, token, {
      method: 'POST',
      body: JSON.stringify({ base_tree: headCommit.tree.sha, tree: blobs })
    });

    // Nothing changed — say so rather than making an empty commit.
    if (tree.sha === headCommit.tree.sha) {
      return res.status(200).json({ ok: true, unchanged: true, sha: headSha,
        message: 'Already saved — nothing had changed.' });
    }

    const plays = data.plays.length;
    const spots = data.plays.reduce(
      (n, p) => n + p.players.filter(q => q.team !== 'them').length, 0);
    const commit = await gh(`/repos/${REPO}/git/commits`, token, {
      method: 'POST',
      body: JSON.stringify({
        message: `Playbook update from the app — ${plays} plays, ${spots} spots\n\n` +
                 `Saved from the Play Designer. Both special-teams-plays.json and the ` +
                 `embedded copy in designer.html are written together so they cannot drift.`,
        tree: tree.sha,
        parents: [headSha]
      })
    });

    await gh(`/repos/${REPO}/git/refs/heads/${BRANCH}`, token, {
      method: 'PATCH',
      body: JSON.stringify({ sha: commit.sha, force: false })
    });

    return res.status(200).json({
      ok: true, sha: commit.sha, url: commit.html_url,
      message: `Saved to the repo — ${plays} plays.`
    });
  } catch (e) {
    return res.status(502).json({ error: String(e.message || e) });
  }
};
