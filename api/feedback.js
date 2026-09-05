/* The lightbulb: an idea or a problem, filed without leaving the app.
 *
 * Runs on Vercel and files a GitHub issue on this repo, reusing the same
 * server-side GITHUB_TOKEN that api/save-playbook.js already needs. Nothing new
 * to sign up for, and the note lands where the work actually happens rather
 * than in an inbox.
 *
 * NO PASSPHRASE, deliberately, and it is the one difference from save-playbook.
 * That endpoint writes the playbook and must be guarded. This one writes a note
 * to a list. Making him type a passphrase to report that something is broken is
 * how a feedback button goes unused. What guards it instead is that it can only
 * ever create an issue -- it cannot read, edit or close one -- plus a length cap
 * and a per-IP rate limit.
 *
 * THE REPO IS PUBLIC. An issue filed here is readable by anybody, so the browser
 * side says so plainly above the box, and this side strips anything that looks
 * like a roster before posting. A coach typing "Bagley's circle is in the wrong
 * place" must not publish a child's name because he wanted to be helpful.
 *
 * Needs, in Vercel -> Settings -> Environment Variables:
 *   GITHUB_TOKEN   the same fine-grained PAT, plus Issues: read and write
 * Optional: GITHUB_REPO (default Team-Formify/Play-Designer),
 *           FEEDBACK_LABEL (default 'from the app')
 */

const REPO  = process.env.GITHUB_REPO || 'Team-Formify/Play-Designer';
const LABEL = process.env.FEEDBACK_LABEL || 'from the app';

const MAX_MESSAGE = 4000;
const MAX_CONTEXT = 1200;
const KINDS = { idea: 'Idea', problem: 'Problem' };

// A single container, so it resets when the function goes cold. Not a real rate
// limiter -- that needs shared state -- but enough to stop a stuck retry loop
// from filing four hundred issues, which is the failure this actually has.
const seen = new Map();
const WINDOW_MS = 60 * 1000;
const MAX_PER_WINDOW = 5;

function rateLimited(key) {
  const now = Date.now();
  const hits = (seen.get(key) || []).filter((t) => now - t < WINDOW_MS);
  hits.push(now);
  seen.set(key, hits);
  if (seen.size > 500) seen.clear();          // unbounded maps are a leak
  return hits.length > MAX_PER_WINDOW;
}

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
  }).then(async (r) => {
    const body = await r.text();
    if (!r.ok) throw new Error('GitHub ' + r.status + ' on ' + path + ': ' + body.slice(0, 300));
    return body ? JSON.parse(body) : null;
  });
}

/* Anything that could be a child. Deliberately blunt: a false positive costs a
 * word in an issue nobody was going to read closely, and a false negative
 * publishes a twelve-year-old's name on the open internet. Applied to the
 * message the coach typed AND to the context the page collected. */
function redact(s) {
  return String(s == null ? '' : s)
    // email addresses -- a parent's, most likely
    .replace(/[\w.+-]+@[\w-]+\.[\w.-]+/g, '[email]')
    // phone numbers, loosely
    .replace(/(?:\+?\d[\s().-]?){9,}\d/g, '[phone]')
    // "Bagley's", "Archuletta is" -- a capitalised word next to a jersey number
    // is the shape a roster note takes in this app
    .replace(/\b([A-Z][a-z]{2,})\b(?=[^\n]{0,12}#\d{1,2}\b)/g, '[name]')
    .replace(/(?<=#\d{1,2}\b[^\n]{0,12})\b([A-Z][a-z]{2,})\b/g, '[name]');
}

function readBody(req) {
  if (req.body && typeof req.body === 'object') return Promise.resolve(req.body);
  if (typeof req.body === 'string') {
    try { return Promise.resolve(JSON.parse(req.body)); } catch { return Promise.resolve(null); }
  }
  return new Promise((resolve) => {
    let raw = '';
    req.on('data', (c) => { raw += c; if (raw.length > 64 * 1024) req.destroy(); });
    req.on('end', () => { try { resolve(JSON.parse(raw)); } catch { resolve(null); } });
    req.on('error', () => resolve(null));
  });
}

module.exports = async function handler(req, res) {
  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST');
    return res.status(405).json({ error: 'POST only' });
  }

  const token = process.env.GITHUB_TOKEN;
  if (!token) {
    // 501, matching save-playbook: the app treats this as "keep it on the
    // device" rather than as a lost note.
    return res.status(501).json({
      error: 'Sending feedback is not set up yet. GITHUB_TOKEN is not set on this deployment.',
      keepLocal: true
    });
  }

  const ip = String(req.headers['x-forwarded-for'] || req.socket?.remoteAddress || 'unknown')
    .split(',')[0].trim();
  if (rateLimited(ip)) {
    return res.status(429).json({ error: 'Too many just now. Try again in a minute.', keepLocal: true });
  }

  const body = await readBody(req);
  if (!body) return res.status(400).json({ error: 'Send JSON.' });

  const kind = KINDS[String(body.kind || '').toLowerCase()];
  if (!kind) return res.status(400).json({ error: 'kind must be "idea" or "problem".' });

  const message = redact(String(body.message || '').trim()).slice(0, MAX_MESSAGE);
  if (message.length < 3) return res.status(400).json({ error: 'Say a bit more than that.' });

  // What the page knows about itself: build, path, current play slug, viewport.
  // Never the roster -- see the browser side, which assembles this.
  const context = redact(String(body.context || '').trim()).slice(0, MAX_CONTEXT);

  const firstLine = message.split('\n')[0].trim();
  const title = kind + ': ' + (firstLine.length > 70 ? firstLine.slice(0, 67) + '...' : firstLine);

  const issueBody =
    message + '\n\n---\n' +
    (context ? '```\n' + context + '\n```\n' : '') +
    '_Filed from the app. Names and addresses are stripped before posting; this repo is public._\n';

  try {
    const issue = await gh('/repos/' + REPO + '/issues', token, {
      method: 'POST',
      body: JSON.stringify({ title, body: issueBody, labels: [LABEL, kind.toLowerCase()] })
    });
    return res.status(200).json({ ok: true, number: issue.number, url: issue.html_url });
  } catch (e) {
    // A label that does not exist on the repo is a 422, and it should not lose
    // his note. Retry once with no labels rather than failing.
    try {
      const issue = await gh('/repos/' + REPO + '/issues', token, {
        method: 'POST',
        body: JSON.stringify({ title, body: issueBody })
      });
      return res.status(200).json({ ok: true, number: issue.number, url: issue.html_url, unlabelled: true });
    } catch (e2) {
      return res.status(502).json({ error: String(e2.message || e2).slice(0, 300), keepLocal: true });
    }
  }
};

// Exported for product/test/test-feedback.mjs. Nothing else imports these.
module.exports.redact = redact;
module.exports._rateLimited = rateLimited;
