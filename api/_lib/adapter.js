/* Node (req, res) <-> Web (Request, Response).
 *
 * NOT generated -- scripts/sync-api-lib.mjs writes every other file in this
 * directory from product/hub/lib, and this one is hand-written because it has
 * no TypeScript counterpart. It exists to bridge two shapes:
 *
 *   product/hub/lib/routes/*   written against Request/Response, because they
 *                              were written for Next. 67 tests attack the data
 *                              layer under them.
 *   api/*.js                   Vercel Node functions, (req, res), CommonJS,
 *                              which is what the two live functions already are.
 *
 * Writing the handlers twice would mean two security models, so the handlers
 * stay as they are and this adapts around them.
 *
 * WHAT IT DELIBERATELY DOES NOT DO: decide anything. No auth, no role check, no
 * tenant filter. Identity comes from the cookie via lib/session.js and is bound
 * to the transaction by lib/db.js; every refusal is the database's. This file
 * moves bytes.
 */
const { configurePool } = require("./db.js");

let configured = false;

/** One pool for the process, from the environment, on first use. */
function ensurePool() {
  if (configured) return true;
  const conn = process.env.HUB_DATABASE_URL || process.env.DATABASE_URL;
  if (!conn) return false;
  // Serverless: many short-lived instances, each holding a few connections.
  // Neon's pooled endpoint expects exactly this shape.
  configurePool({ connectionString: conn, max: Number(process.env.HUB_POOL_MAX || 3) });
  configured = true;
  return true;
}

function baseUrl(req) {
  const proto = String(req.headers["x-forwarded-proto"] || "https").split(",")[0];
  const host = String(req.headers["x-forwarded-host"] || req.headers.host || "localhost");
  return proto + "://" + host;
}

function toRequest(req, rawBody) {
  const headers = new Headers();
  for (const [k, v] of Object.entries(req.headers || {})) {
    if (v === undefined) continue;
    headers.set(k, Array.isArray(v) ? v.join(", ") : String(v));
  }
  const method = (req.method || "GET").toUpperCase();
  const init = { method, headers };
  if (method !== "GET" && method !== "HEAD" && rawBody && rawBody.length) init.body = rawBody;
  return new Request(baseUrl(req) + (req.url || "/"), init);
}

function readRaw(req) {
  // Vercel may have parsed the body already. Re-serialise rather than read the
  // stream twice -- a consumed stream is an empty body and a silent 400.
  if (req.body !== undefined && req.body !== null) {
    if (typeof req.body === "string") return Promise.resolve(Buffer.from(req.body));
    if (Buffer.isBuffer(req.body)) return Promise.resolve(req.body);
    if (typeof req.body === "object") return Promise.resolve(Buffer.from(JSON.stringify(req.body)));
  }
  return new Promise((resolve) => {
    const chunks = [];
    let size = 0;
    req.on("data", (c) => {
      size += c.length;
      if (size > 1_000_000) { req.destroy(); return; }
      chunks.push(c);
    });
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", () => resolve(Buffer.alloc(0)));
  });
}

async function sendResponse(res, webRes) {
  res.statusCode = webRes.status;
  webRes.headers.forEach((value, key) => {
    // set-cookie must not be folded into one comma-joined header.
    if (key.toLowerCase() === "set-cookie") return;
    res.setHeader(key, value);
  });
  const setCookie = typeof webRes.headers.getSetCookie === "function"
    ? webRes.headers.getSetCookie()
    : (webRes.headers.get("set-cookie") ? [webRes.headers.get("set-cookie")] : []);
  if (setCookie.length) res.setHeader("Set-Cookie", setCookie);
  const body = Buffer.from(await webRes.arrayBuffer());
  res.end(body);
}

/**
 * Wrap a Request->Response handler as a Vercel function.
 *
 * `methods` is the only thing it enforces, and it is not authorization: it is
 * so a GET cannot reach a handler that writes. `params` lets a handler that
 * expects a path segment (teamId) read it from the query string instead, since
 * these functions live at flat paths.
 */
function handler(fn, { methods = ["GET"], params = () => ({}) } = {}) {
  return async function (req, res) {
    const method = (req.method || "GET").toUpperCase();
    if (!methods.includes(method)) {
      res.setHeader("Allow", methods.join(", "));
      res.statusCode = 405;
      res.setHeader("content-type", "application/json");
      return res.end(JSON.stringify({ error: methods.join(" or ") + " only" }));
    }

    if (!ensurePool()) {
      // Same shape as api/save-playbook.js when it is not configured: a 501
      // that says what is missing, rather than a 500 that looks like a bug.
      res.statusCode = 501;
      res.setHeader("content-type", "application/json");
      return res.end(JSON.stringify({
        error: "This deployment has no database. Set HUB_DATABASE_URL in the Vercel project.",
        configured: false,
      }));
    }

    try {
      const raw = await readRaw(req);
      const webReq = toRequest(req, raw);
      const url = new URL(webReq.url);
      const ctx = { params: Promise.resolve(params(url)) };
      const webRes = await fn(webReq, ctx);
      await sendResponse(res, webRes);
    } catch (err) {
      // route() already turns handler throws into responses; this catches the
      // adapter's own failures -- a dead database, a malformed URL.
      res.statusCode = 500;
      res.setHeader("content-type", "application/json");
      res.end(JSON.stringify({ error: String((err && err.message) || err).slice(0, 200) }));
    }
  };
}

module.exports = { handler, ensurePool, toRequest, readRaw };
