/* POST /api/signout -- drop the session cookie.
 *
 * Nothing server-side to revoke: the session IS the signed cookie, so clearing
 * it is the whole operation. Deliberately POST, so a link somebody is tricked
 * into following cannot sign them out.
 */
const { clearedSessionCookie } = require("./_lib/session.js");
module.exports = async function handler(req, res) {
  if ((req.method || "GET").toUpperCase() !== "POST") {
    res.setHeader("Allow", "POST");
    res.statusCode = 405;
    res.setHeader("content-type", "application/json");
    return res.end(JSON.stringify({ error: "POST only" }));
  }
  res.statusCode = 200;
  res.setHeader("content-type", "application/json; charset=utf-8");
  res.setHeader("cache-control", "no-store");
  res.setHeader("Set-Cookie", clearedSessionCookie());
  res.end(JSON.stringify({ ok: true }));
};
